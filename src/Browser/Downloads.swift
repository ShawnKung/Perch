import AppKit
import SwiftUI
import WebKit
import Combine

enum DownloadsPage {
    static let url = URL(string: "perch://downloads")!
    static func matches(_ url: URL?) -> Bool {
        InternalPage.matches(url, host: "downloads")
    }
}

@MainActor
final class DownloadsPageBridge: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    weak var downloads: DownloadController?
    private var changes: AnyCancellable?
    private var theme: AnyCancellable?
    private var timer: Timer?
    private var icons: [String: String] = [:]

    func stop() {
        changes = nil; theme = nil; timer?.invalidate(); timer = nil; icons = [:]
    }
    deinit { timer?.invalidate() }
    func start() {
        guard changes == nil, let downloads else { update(); return }
        changes = downloads.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }
        theme = PerchTheme.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }
    func update() {
        guard let web, DownloadsPage.matches(web.url), let downloads else { return }
        PerchTheme.shared.update(web)
        let records = downloads.records.map { record -> [String: Any] in
            var icon = ""
            if record.available, let url = record.destination {
                if icons[url.path] == nil { icons[url.path] = InternalPage.icon(NSWorkspace.shared.icon(forFile: url.path)) }
                icon = icons[url.path] ?? ""
            }
            return ["id": record.id.uuidString, "name": record.filename, "detail": record.detail,
                    "available": record.available, "icon": icon]
        }
        InternalPage.update(["records": records, "error": downloads.storageError ?? ""], web: web)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard InternalPage.accepts(message, web: web, matches: DownloadsPage.matches),
              let body = message.body as? [String: Any], let action = body["action"] as? String,
              let downloads else { return }
        if action == "ready" {
            start()
        } else if action == "clear" { downloads.clear() }
        else if let raw = body["id"] as? String, let id = UUID(uuidString: raw),
                let record = downloads.records.first(where: { $0.id == id }) {
            switch action {
            case "open": downloads.open(record)
            case "reveal": downloads.reveal(record)
            case "copy": downloads.copyLink(record)
            case "remove": downloads.remove(id)
            default: break
            }
        }
    }
}

struct DownloadRecord: Identifiable, Codable {
    enum State: String, Codable { case downloading, completed, failed }
    var id = UUID()
    var source: URL
    var filename: String
    var date = Date()
    var destination: URL?
    var received: Int64 = 0
    var total: Int64 = -1
    var state: State = .downloading
    var failure: String?

    var fraction: Double? {
        total > 0 ? min(1, max(0, Double(received) / Double(total))) : nil
    }
    var available: Bool {
        guard state == .completed, let destination, destination.isFileURL else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory) && !directory.boolValue
    }
    var detail: String {
        switch state {
        case .downloading:
            let size = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            return total > 0 ? "\(size) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" : "\(size) · 下载中"
        case .failed: return failure ?? "下载失败"
        case .completed:
            return available ? "\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) · \(date.formatted(date: .abbreviated, time: .shortened))" : "找不到文件"
        }
    }
}

@MainActor
final class DownloadController: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var storageError: String?
    private let defaults: UserDefaults
    private let directory: URL
    private var protectedStorage = false
    private struct Task {
        let download: WKDownload
        let id: UUID
        var destination: URL?
        var temporary: URL?
    }
    private var active: [ObjectIdentifier: Task] = [:]
    private var observations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    var isDownloading: Bool { !active.isEmpty }
    var progressRecord: DownloadRecord? {
        records.first(where: { $0.state == .downloading })
    }

    init(defaults: UserDefaults, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        super.init()
        if let data = defaults.data(forKey: "downloads") {
            do {
                records = try JSONDecoder().decode([DownloadRecord].self, from: data)
                guard Set(records.map(\.id)).count == records.count,
                      records.allSatisfy({ $0.destination == nil || $0.destination?.isFileURL == true }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                for index in records.indices where records[index].state == .downloading {
                    records[index].state = .failed
                    records[index].failure = "下载已中断"
                }
            } catch {
                records = []; protectedStorage = true
                storageError = "下载记录无法读取，已保留原数据。"
            }
        } else if defaults.object(forKey: "downloads") != nil {
            protectedStorage = true; storageError = "下载记录无法读取，已保留原数据。"
        }
    }

    func receive(_ download: WKDownload) {
        let record = DownloadRecord(source: download.originalRequest?.url ?? URL(string: "about:blank")!,
                                    filename: download.originalRequest?.url?.lastPathComponent ?? "下载文件")
        records.insert(record, at: 0)
        let key = ObjectIdentifier(download)
        active[key] = Task(download: download, id: record.id)
        download.delegate = self
        let progress = download.progress
        observations[key] = [
            progress.observe(\.completedUnitCount, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateProgress(key) }
            },
            progress.observe(\.totalUnitCount, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateProgress(key) }
            }
        ]
        save()
    }

    private func updateProgress(_ key: ObjectIdentifier) {
        guard let task = active[key], let index = records.firstIndex(where: { $0.id == task.id }) else { return }
        records[index].received = task.download.progress.completedUnitCount
        let total = task.download.progress.totalUnitCount
        if total > 0 { records[index].total = total }
    }

    static func destination(filename: String, directory: URL, reserved: Set<URL>) -> URL {
        let name = (filename as NSString).lastPathComponent
        let safeName = name.isEmpty || name == "." || name == ".." ? "下载文件" : name
        let base = directory.appendingPathComponent(safeName)
        var result = base
        var number = 1
        while reserved.contains(result) || FileManager.default.fileExists(atPath: result.path) {
            let ext = base.pathExtension
            let stem = ext.isEmpty ? safeName : base.deletingPathExtension().lastPathComponent
            result = directory.appendingPathComponent("\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        return result
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard let id = active[key]?.id else { completionHandler(nil); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let reserved = Set(active.values.compactMap(\.destination))
            let url = Self.destination(filename: suggestedFilename, directory: directory, reserved: reserved)
            let temporary = directory.appendingPathComponent(".perch-download-\(id.uuidString)")
            active[key]?.destination = url
            active[key]?.temporary = temporary
            if let index = records.firstIndex(where: { $0.id == id }) {
                records[index].destination = url
                records[index].filename = url.lastPathComponent
                records[index].total = response.expectedContentLength
                save()
            }
            completionHandler(temporary)
        } catch {
            finish(download, error: error)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) { finish(download, error: nil) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, error: error)
    }
    private func finish(_ download: WKDownload, error: Error?) {
        let key = ObjectIdentifier(download)
        updateProgress(key)
        guard let task = active[key] else { return }
        var failure = error
        if error == nil, let temporary = task.temporary, let destination = task.destination {
            do {
                // A file created outside Perch during the transfer must never be overwritten.
                let url = Self.destination(filename: destination.lastPathComponent, directory: directory,
                                           reserved: Set(active.values.filter { $0.id != task.id }.compactMap(\.destination)))
                try (temporary as NSURL).setResourceValue([
                    "LSQuarantineType": "LSQuarantineTypeWebDownload",
                    "LSQuarantineAgentName": "Perch",
                    "LSQuarantineDataURL": task.download.originalRequest?.url ?? URL(string: "about:blank")!
                ], forKey: .quarantinePropertiesKey)
                try FileManager.default.moveItem(at: temporary, to: url)
                if let index = records.firstIndex(where: { $0.id == task.id }) {
                    records[index].destination = url
                    records[index].filename = url.lastPathComponent
                }
            } catch { failure = error }
        }
        if let index = records.firstIndex(where: { $0.id == task.id }) {
            records[index].state = failure == nil ? .completed : .failed
            records[index].failure = failure?.localizedDescription
            if failure == nil, let url = records[index].destination {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    records[index].received = Int64(size)
                }
            }
        }
        if let temporary = task.temporary { try? FileManager.default.removeItem(at: temporary) }
        observations[key] = nil; active[key] = nil
        save()
    }

    func remove(_ id: UUID) { records.removeAll { $0.id == id }; save() }
    func clear() { records.removeAll(); save() }
    private func save() {
        guard !protectedStorage else { return }
        do { defaults.set(try JSONEncoder().encode(records), forKey: "downloads") }
        catch { storageError = "下载记录保存失败：\(error.localizedDescription)" }
    }
    func refreshFiles() { objectWillChange.send() }
    func open(_ record: DownloadRecord) {
        guard record.available, let url = record.destination else { refreshFiles(); return }
        NSWorkspace.shared.open(url)
    }
    func reveal(_ record: DownloadRecord) {
        guard record.available, let url = record.destination else { refreshFiles(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func copyLink(_ record: DownloadRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.source.absoluteString, forType: .string)
    }
}

struct DownloadToolbarButton: View {
    @ObservedObject var downloads: DownloadController
    let openAll: () -> Void
    @State private var presented = false
    var body: some View {
        if !downloads.records.isEmpty {
            Button { presented.toggle() } label: {
                ZStack {
                    if let record = downloads.progressRecord {
                        Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
                        DownloadRing(fraction: record.fraction)
                    } else {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 14))
                    }
                }.frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).help("下载").accessibilityLabel("近期下载任务")
                .foregroundStyle(Style.muted).arrowCursor()
                .accessibilityValue(downloads.progressRecord?.fraction.map { "\(Int($0 * 100))%" } ??
                    (downloads.progressRecord == nil ? "下载已完成" : "下载中"))
                .popover(isPresented: $presented, arrowEdge: .bottom) {
                    DownloadsList(downloads: downloads, recent: true) {
                        presented = false; openAll()
                    }.frame(width: 390).frame(maxHeight: 490)
                }
        }
    }
}

struct DownloadRing: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(Style.line, lineWidth: 2)
            if let fraction {
                Circle().trim(from: 0, to: fraction).stroke(Style.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    Circle().trim(from: 0, to: 0.25).stroke(Style.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? -90 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
            }
        }.frame(width: 24, height: 24).accessibilityHidden(true)
    }
}

struct DownloadsList: View {
    @ObservedObject var downloads: DownloadController
    var recent = false
    var openAll: (() -> Void)?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(recent ? "近期下载任务" : "下载记录").font(.system(size: recent ? 15 : 22, weight: .semibold))
                Spacer()
                Button("全部清空") { downloads.clear() }.buttonStyle(.plain)
                    .foregroundStyle(Style.muted).disabled(downloads.records.isEmpty)
                    .help("仅清空记录，保留文件和正在进行的下载")
            }.padding(recent ? 16 : 24)
            if let error = downloads.storageError { Text(error).font(.caption).foregroundStyle(Style.muted).padding(8) }
            ScrollView {
                LazyVStack(spacing: recent ? 2 : 8) {
                    if downloads.records.isEmpty {
                        Text("暂无下载记录").foregroundStyle(Style.muted).frame(maxWidth: .infinity).padding(40)
                    }
                    ForEach(recent ? Array(downloads.records.prefix(8)) : downloads.records) { record in
                        DownloadRow(downloads: downloads, record: record)
                    }
                }.padding(.horizontal, recent ? 8 : 24).padding(.bottom, 12)
            }
            if recent, let openAll {
                Divider()
                Button(action: openAll) {
                    HStack {
                        Text("完整的下载记录")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("完整的下载记录")
            }
        }
        .background(Style.paper)
        .onAppear { downloads.refreshFiles() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in downloads.refreshFiles() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in downloads.refreshFiles() }
    }
}

struct DownloadRow: View {
    @ObservedObject var downloads: DownloadController
    let record: DownloadRecord
    @State private var hovered = false
    @FocusState private var focusedAction: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            Button { downloads.open(record) } label: {
                HStack(spacing: 12) {
                    Group {
                        if let url = record.destination, record.available {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                        } else { Image(systemName: "doc").foregroundStyle(Style.muted) }
                    }.frame(width: 28, height: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.filename).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(record.detail).font(.system(size: 11)).foregroundStyle(Style.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!record.available)
                .accessibilityLabel(record.filename)
                .foregroundStyle(record.available || record.state == .downloading ? Style.ink : Style.muted)
            HStack(spacing: 2) {
                action("link", label: "复制下载链接") { downloads.copyLink(record) }
                action("folder", label: "在文件夹中显示", disabled: !record.available) { downloads.reveal(record) }
                action("xmark", label: "删除下载记录") { downloads.remove(record.id) }
            }.opacity(hovered || focusedAction != nil ? 1 : 0).allowsHitTesting(hovered || focusedAction != nil)
        }
        .padding(10).background(hovered ? Style.line.opacity(0.45) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .background(NativeHoverRegion(changed: { value in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { hovered = value }
            if value { downloads.refreshFiles() }
        }))
        .accessibilityAction(named: "复制下载链接") { downloads.copyLink(record) }
        .accessibilityAction(named: "在文件夹中显示") { downloads.reveal(record) }
        .accessibilityAction(named: "删除下载记录") { downloads.remove(record.id) }
    }
    private func action(_ symbol: String, label: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).help(label).accessibilityLabel(label)
            .focused($focusedAction, equals: symbol)
    }
}
