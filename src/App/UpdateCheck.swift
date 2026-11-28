import AppKit
import SwiftUI

struct UpdateIndicator: NSViewRepresentable {
    let release: UpdateCheck.Release
    let compact: Bool
    var alignment: NSTextAlignment = .left
    var openRelease: (URL) -> Bool = { NSWorkspace.shared.open($0) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 12)
        button.image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        button.imageHugsTitle = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked(_:))
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.indicator = self
        button.title = compact ? "" : "发现新版本"
        button.imagePosition = compact ? .imageOnly : .imageLeading
        button.alignment = compact ? .center : alignment
        button.contentTintColor = NSColor(Style.accent)
        button.toolTip = "检测到新 \(release.version) 版，点击更新"
        button.setAccessibilityLabel("更新 Perch")
        button.setAccessibilityHelp(button.toolTip)
    }

    final class Coordinator: NSObject {
        var indicator: UpdateIndicator
        init(_ indicator: UpdateIndicator) { self.indicator = indicator }
        @MainActor @objc func clicked(_ sender: NSButton) {
            if !indicator.openRelease(indicator.release.url) {
                sender.toolTip = "无法打开更新页面：\(indicator.release.url.absoluteString)"
            }
        }
    }
}

enum UpdateCheck {
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
    static let repositoryURL = URL(string: "https://github.com/ShawnKung/Perch")!
    static let apiURL = URL(string: "https://api.github.com/repos/ShawnKung/Perch/releases/latest")!
    static let releaseURL = URL(string: "https://github.com/ShawnKung/Perch/releases/latest")!
    static let feedURL = URL(string: "https://github.com/ShawnKung/Perch/releases.atom")!

    struct Release {
        let tag: String
        let version: String
        var notesHTML: String? = nil
        var url: URL { UpdateCheck.repositoryURL.appendingPathComponent("releases/tag").appendingPathComponent(tag) }
    }

    private struct APIRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let body_html: String?
    }

    private static func version(_ text: String) -> [Int]? {
        let parts = (text.hasPrefix("v") ? String(text.dropFirst()) : text)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let number = Int(part), String(number) == part else { return nil }
            return number
        }
        return numbers.count == 3 ? numbers : nil
    }

    private static func newerVersion(_ tag: String, than current: String) throws -> String? {
        guard let available = version(tag), let installed = version(current) else {
            throw PerchError("更新页面未返回有效版本")
        }
        guard installed.lexicographicallyPrecedes(available) else { return nil }
        return String(tag.drop(while: { $0 == "v" }))
    }

    static func newerRelease(in data: Data, than current: String) throws -> Release? {
        let release = try JSONDecoder().decode(APIRelease.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        guard let version = try newerVersion(release.tag_name, than: current) else { return nil }
        return Release(tag: release.tag_name, version: version, notesHTML: release.body_html)
    }

    static func newerRelease(at url: URL, than current: String) throws -> Release? {
        guard url.scheme == "https", url.host == repositoryURL.host,
              url.pathComponents.dropLast().elementsEqual(repositoryURL.appendingPathComponent("releases/tag").pathComponents),
              let tag = url.pathComponents.last else {
            throw PerchError("更新页面未返回有效版本")
        }
        guard repositoryURL.appendingPathComponent("releases/tag").appendingPathComponent(tag) == url else {
            throw PerchError("更新页面未返回有效版本")
        }
        guard let version = try newerVersion(tag, than: current) else { return nil }
        return Release(tag: tag, version: version)
    }

    static func latestRelease(current: String, session: URLSession = .shared) async throws -> Release? {
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github.html+json", forHTTPHeaderField: "Accept")
        request.setValue("Perch/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // Only an exhausted API quota warrants falling back to the public release redirect.
        if response.statusCode == 403, response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            guard var release = try await latestReleaseRedirect(current: current, session: session) else { return nil }
            release.notesHTML = try? await releaseNotes(for: release, current: current, session: session)
            return release
        }
        guard response.statusCode == 200 else { throw PerchError("检查更新失败（HTTP \(response.statusCode)）") }
        return try newerRelease(in: data, than: current)
    }

    private static func latestReleaseRedirect(current: String, session: URLSession) async throws -> Release? {
        var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue("Perch/\(current)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw URLError(.badServerResponse)
        }
        guard response.statusCode == 200 else { throw PerchError("检查更新失败（HTTP \(response.statusCode)）") }
        return try newerRelease(at: url, than: current)
    }

    private static func releaseNotes(for release: Release, current: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: feedURL, timeoutInterval: 5)
        request.setValue("Perch/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == feedURL else { return nil }
        let feed = ReleaseFeed(releaseURL: release.url)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = feed
        return parser.parse() ? feed.notes : nil
    }

    private final class ReleaseFeed: NSObject, XMLParserDelegate {
        let releaseURL: URL
        var notes: String?
        private var path: [String] = []
        private var matches = false
        private var content: String?

        init(releaseURL: URL) { self.releaseURL = releaseURL }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            path.append(element)
            switch path {
            case ["feed", "entry"]: matches = false; content = nil
            case ["feed", "entry", "link"]:
                if attributes["rel"] == "alternate", attributes["href"] == releaseURL.absoluteString { matches = true }
            case ["feed", "entry", "content"] where attributes["type"] == "html": content = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if path == ["feed", "entry", "content"] { content?.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if path == ["feed", "entry"], matches, notes == nil { notes = content }
            path.removeLast()
        }
    }
}
