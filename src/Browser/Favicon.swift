import AppKit
import WebKit
import ImageIO

@MainActor
enum FaviconCache {
    static func key(_ address: String) -> String? {
        guard let url = URLInput.parse(address, search: false), let host = url.host else { return nil }
        return "\(url.scheme!)://\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    static func image(for address: String, defaults: UserDefaults) -> NSImage? {
        guard let key = key(address),
              let data = defaults.dictionary(forKey: "favicons")?[key] as? Data else { return nil }
        return FaviconLoader.decode(data)
    }

    static func pngDataURLs(for addresses: [String], defaults: UserDefaults) -> [String: String] {
        guard let cache = defaults.dictionary(forKey: "favicons") else { return [:] }
        var urls: [String: String] = [:]
        for address in addresses {
            guard let key = key(address), urls[key] == nil,
                  let png = cache[key] as? Data, png.count <= 65536,
                  png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { continue }
            urls[key] = "data:image/png;base64," + png.base64EncodedString()
        }
        return urls
    }

    static func save(_ image: NSImage, for address: String, defaults: UserDefaults) {
        guard let key = key(address),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]),
              data.count <= 65536 else { return }
        var cache = defaults.dictionary(forKey: "favicons") as? [String: Data] ?? [:]
        cache[key] = data
        if cache.count > 256, let evicted = cache.keys.first(where: { $0 != key }) { cache.removeValue(forKey: evicted) }
        defaults.set(cache, forKey: "favicons")
    }
}

@MainActor
final class FaviconLoader {
    var changed: ((NSImage?) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        changed?(nil)
    }
    func load(from webView: WKWebView) {
        reset()
        let token = generation
        task = Task { [weak self, weak webView] in
            guard let self, let webView, let page = webView.url,
                  ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return }
            let script = """
            Array.from(document.querySelectorAll('link[rel]'))
              .filter(e => e.rel.toLowerCase().split(/\\s+/).some(v => v === 'icon' || v === 'apple-touch-icon'))
              .map(e => e.href).filter(Boolean).slice(0, 8)
            """
            let declared: [String] = await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                    continuation.resume(returning: (try? result.get()) as? [String] ?? [])
                }
            }
            let links = declared + [URL(string: "/favicon.ico", relativeTo: page)!.absoluteString]
            for link in links {
                guard !Task.isCancelled, self.generation == token else { return }
                guard let url = URL(string: link), url.user == nil, url.password == nil else { continue }
                do {
                    var data = Data()
                    if url.scheme == "data", let comma = link.firstIndex(of: ","),
                       link[..<comma].hasSuffix(";base64"), link.utf8.count < 700000 {
                        data = Data(base64Encoded: String(link[link.index(after: comma)...])) ?? Data()
                    } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        if Self.sameOrigin(url, page) {
                            let encoded: String? = await withCheckedContinuation { continuation in
                              webView.callAsyncJavaScript("""
                                if (location.href !== page || new URL(icon).origin !== location.origin) return null;
                                const response = await fetch(icon, {credentials: 'same-origin', redirect: 'error'});
                                if (!response.ok || !response.body) return null;
                                const length = Number(response.headers.get('content-length'));
                                if (length > 524288) return null;
                                const reader = response.body.getReader();
                                let size = 0, parts = [];
                                while (true) {
                                  const {done, value} = await reader.read();
                                  if (done) break;
                                  size += value.length;
                                  if (size > 524288) { await reader.cancel(); return null; }
                                  parts.push(value);
                                }
                                let binary = '';
                                for (const part of parts) {
                                  for (let i = 0; i < part.length; i += 8192)
                                    binary += String.fromCharCode(...part.subarray(i, i + 8192));
                                }
                                return btoa(binary);
                                """, arguments: ["icon": url.absoluteString, "page": page.absoluteString],
                                in: nil, in: .defaultClient) { result in
                                    continuation.resume(returning: (try? result.get()) as? String)
                                }
                            }
                            if let encoded { data = Data(base64Encoded: encoded) ?? Data() }
                            guard !Task.isCancelled, self.generation == token else { return }
                            if let image = Self.decode(data) { self.changed?(image); return }
                        }
                        var request = URLRequest(url: url)
                        request.setValue(webView.customUserAgent, forHTTPHeaderField: "User-Agent")
                        let (bytes, response) = try await self.session.bytes(for: request)
                        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                              response.expectedContentLength <= 524288 else { continue }
                        for try await byte in bytes {
                            if Task.isCancelled { return }
                            data.append(byte)
                            if data.count > 524288 { break }
                        }
                    }
                    guard let image = Self.decode(data), !Task.isCancelled, self.generation == token else { continue }
                    self.changed?(image)
                    return
                } catch { if Task.isCancelled { return } }
            }
        }
    }
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
            lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }
    static func decode(_ data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= 524288,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 16, height: 16))
    }
    deinit { task?.cancel(); session.invalidateAndCancel() }
}
