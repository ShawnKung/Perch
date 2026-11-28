import AppKit
import SwiftUI

struct UpdateIndicator: NSViewRepresentable {
    let version: String
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
        button.toolTip = "检测到新 \(version) 版，点击更新"
        button.setAccessibilityLabel("更新 Perch")
        button.setAccessibilityHelp(button.toolTip)
    }

    final class Coordinator: NSObject {
        var indicator: UpdateIndicator
        init(_ indicator: UpdateIndicator) { self.indicator = indicator }
        @MainActor @objc func clicked(_ sender: NSButton) {
            if !indicator.openRelease(UpdateCheck.releaseURL) {
                sender.toolTip = "无法打开更新页面：\(UpdateCheck.releaseURL.absoluteString)"
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

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
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

    static func newerVersion(in data: Data, than current: String) throws -> String? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        return try newerVersion(release.tag_name, than: current)
    }

    static func newerVersion(at url: URL, than current: String) throws -> String? {
        guard url.scheme == "https", url.host == repositoryURL.host,
              url.pathComponents.dropLast().elementsEqual(repositoryURL.appendingPathComponent("releases/tag").pathComponents),
              let tag = url.pathComponents.last else {
            throw PerchError("更新页面未返回有效版本")
        }
        return try newerVersion(tag, than: current)
    }

    static func latestVersion(current: String, session: URLSession = .shared) async throws -> String? {
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Perch/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // Only an exhausted API quota warrants falling back to the public release redirect.
        if response.statusCode == 403, response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            return try await latestReleaseVersion(current: current, session: session)
        }
        guard response.statusCode == 200 else { throw PerchError("检查更新失败（HTTP \(response.statusCode)）") }
        return try newerVersion(in: data, than: current)
    }

    private static func latestReleaseVersion(current: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue("Perch/\(current)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            throw URLError(.badServerResponse)
        }
        guard response.statusCode == 200 else { throw PerchError("检查更新失败（HTTP \(response.statusCode)）") }
        return try newerVersion(at: url, than: current)
    }

}
