import Foundation

enum URLInput {
    static func parse(_ raw: String, search: Bool = true,
                      searchTemplate: String = "https://www.google.com/search?q={query}") -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            guard let url = URL(string: text),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return nil }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = url.scheme?.lowercased()
            components?.host = host.lowercased()
            if components?.path.isEmpty == true { components?.path = "/" }
            return components?.url
        }
        if !text.contains(where: \.isWhitespace),
           text.contains(".") || text == "localhost" || text.hasPrefix("localhost:") {
            let host = URLComponents(string: "https://" + text)?.host ?? ""
            return parse((isLocalHost(host) ? "http://" : "https://") + text, search: false)
        }
        guard search, !text.contains(":") else { return nil }
        guard validSearchTemplate(searchTemplate),
              let query = text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return nil }
        return parse(searchTemplate.replacingOccurrences(of: "{query}", with: query), search: false)
    }

    static func validSearchTemplate(_ template: String) -> Bool {
        guard template.components(separatedBy: "{query}").count == 2,
              let url = parse(template.replacingOccurrences(of: "{query}", with: "perch"), search: false),
              let before = template.components(separatedBy: "{query}").first,
              before.contains(url.host ?? "\0") else { return false }
        // The placeholder may change the path/query, never the host or scheme.
        return parse(template.replacingOccurrences(of: "{query}", with: "other"), search: false)?.host == url.host
    }

    static func isLocalHost(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }) else {
            return false
        }
        let a = Int(parts[0])!, b = Int(parts[1])!
        return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) ||
            (a == 192 && b == 168) || (a == 169 && b == 254)
    }

    static func httpAlternative(for address: String, error: NSError) -> URL? {
        guard error.domain == NSURLErrorDomain,
              [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
               NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
               NSURLErrorServerCertificateNotYetValid].contains(error.code),
              var components = URLComponents(string: address), components.scheme == "https",
              isLocalHost(components.host ?? "") else { return nil }
        components.scheme = "http"
        return components.url
    }

    static func selfTest() {
        precondition(parse(" example.com ")?.absoluteString == "https://example.com/")
        precondition(parse("https://EXAMPLE.com") == parse("https://example.com/"))
        precondition(parse("http://localhost:8080/a")?.host == "localhost")
        precondition(parse("10.0.0.1:10000")?.absoluteString == "http://10.0.0.1:10000/")
        precondition(parse("localhost:8080/a")?.scheme == "http")
        precondition(parse("192.168.1.1")?.scheme == "http")
        precondition(parse("172.16.0.1")?.scheme == "http")
        precondition(parse("172.32.0.1")?.scheme == "https")
        precondition(parse("8.8.8.8")?.scheme == "https")
        precondition(parse("https://10.0.0.1:10000")?.scheme == "https")
        let tls = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        precondition(httpAlternative(for: "https://10.0.0.1:10000/a?q=b", error: tls)?.absoluteString ==
                     "http://10.0.0.1:10000/a?q=b")
        precondition(httpAlternative(for: "https://example.com", error: tls) == nil)
        precondition(httpAlternative(for: "https://10.0.0.1", error: NSError(domain: NSURLErrorDomain,
                                                                          code: NSURLErrorTimedOut)) == nil)
        precondition(parse("https://example.com/a?q=你好") != nil)
        precondition(parse("a & b")?.query?.contains("q=") == true)
        for value in ["", "file:///etc/passwd", "javascript:alert(1)", "https://", "https://user:pass@example.com"] {
            precondition(parse(value) == nil, "Unexpected accepted input: \(value)")
        }
        precondition(parse("some words", search: false) == nil)
        print("PASS: URL normalization, search encoding, scheme and credentials validation")
    }
}
