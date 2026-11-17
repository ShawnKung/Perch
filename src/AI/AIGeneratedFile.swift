import AppKit
import SwiftUI

struct AIGeneratedFile: Codable, Identifiable, Equatable {
    var id = UUID()
    let name: String
    let content: String

    static let contentLimit = 64 * 1024
    // JSON escaping can expand a UTF-8 byte to six bytes.
    static let argumentLimit = 512 * 1024
    static let instruction = "用户要求生成可独立使用的完整脚本或文本文件（包括修改先前文件）时，调用 create_text_file 交付完整文件，并用正文简述用途与使用方法。不用正文代码块替代文件交付，不重复粘贴完整内容，不编造下载链接。解释性代码片段仍使用 Markdown。文件卡片由客户端提供下载；工具不会执行文件。"

    static func definition(protocol apiProtocol: AIProtocol) -> [String: Any] {
        let schema: [String: Any] = ["type": "object", "properties": [
            "name": ["type": "string", "description": "单个文件名，包含正确扩展名，如 report.py 或 helper.user.js；不能含目录。"],
            "content": ["type": "string", "description": "完整原始 UTF-8 文本，不包裹 Markdown 围栏，不使用省略号代替代码。最大 64 KiB。"]
        ], "required": ["name", "content"], "additionalProperties": false]
        let description = "创建可下载的独立脚本或文本文件（Python、Shell、JavaScript、Markdown、JSON、CSV、HTML 等）。只创建会话内文件，不执行、不写入用户目录。每轮最多 8 个文件、合计 256 KiB；本轮同名调用更新该文件，后续回答保留旧版本。"
        switch apiProtocol {
        case .openAI: return ["type": "function", "function": ["name": "create_text_file", "description": description, "parameters": schema]]
        case .responses: return ["type": "function", "name": "create_text_file", "description": description, "parameters": schema]
        case .anthropic: return ["name": "create_text_file", "description": description, "input_schema": schema]
        }
    }

    static func validate(name: String, content: String) throws {
        guard !name.isEmpty, name.utf8.count <= 180, !name.hasPrefix("."),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else {
            throw PerchError("name 必须是含扩展名的单个可见文件名，不能包含目录、冒号或控制字符。")
        }
        guard !content.isEmpty, content.utf8.count <= contentLimit, !content.contains("\0") else {
            throw PerchError("content 必须是完整的非空文本，不能含 NUL，且不超过 64 KiB。请拆分较大的文件。")
        }
    }

    static func receive(_ arguments: String, files: inout [AIGeneratedFile]) throws -> String {
        var result: [String: Any]
        do {
            guard arguments.utf8.count <= argumentLimit,
                  let input = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
                  Set(input.keys) == Set(["name", "content"]),
                  let name = input["name"] as? String, let content = input["content"] as? String else {
                throw PerchError("请仅提供字符串字段 name 和 content，并使用完整 JSON。")
            }
            try validate(name: name, content: content)
            var next = files
            let file = AIGeneratedFile(id: files.first(where: { $0.name == name })?.id ?? UUID(), name: name, content: content)
            if let index = next.firstIndex(where: { $0.name == name }) { next[index] = file }
            else { next.append(file) }
            guard next.count <= 8, next.reduce(0, { $0 + $1.content.utf8.count }) <= 256 * 1024 else {
                throw PerchError("本轮最多交付 8 个文件、合计 256 KiB。请在后续回答继续交付。")
            }
            files = next
            result = ["file_id": file.id.uuidString, "name": name, "bytes": content.utf8.count,
                      "status": "ready", "message": "文件已成功交付，并在回答下方提供下载。若请求的文件均已交付，请用正文简述用途与使用方法并结束回答。仅在发现具体错误或仍有未交付文件时继续调用 create_text_file；不要仅为确认交付而重复生成同名文件，不需要创建 Markdown 下载链接。"]
        } catch {
            result = ["error": (error as? PerchError)?.message ?? "文件参数不是有效 JSON，请重新提供完整内容。"]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }

    var markdown: String {
        var fence = "```"
        while content.contains(fence) { fence += "`" }
        return "文件：\(name)\n\n\(fence)text\n\(content)\n\(fence)"
    }

    func download(to directory: URL) throws -> URL {
        try Self.validate(name: name, content: content)
        let suffix = name.hasSuffix(".user.js") ? "user.js" : (name as NSString).pathExtension
        let stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count + 1))
        for number in 0..<10000 {
            let filename = number == 0 ? name : "\(stem) (\(number))" + (suffix.isEmpty ? "" : "." + suffix)
            let url = directory.appendingPathComponent(filename)
            do {
                try Data(content.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
        }
        throw PerchError("同名文件过多，请使用另存为。")
    }

    @MainActor
    func saveAs(window: NSWindow? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(content.utf8).write(to: url, options: .atomic); completion(.success(url)) }
            catch { completion(.failure(error)) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}

struct AIGeneratedFileCard: View {
    @ObservedObject private var theme = PerchTheme.shared
    let file: AIGeneratedFile
    var versions: [AIGeneratedFile] = []
    @State private var selectedID: UUID?
    @State private var showChanges = false
    @State private var showPreview = true
    @State private var expanded = false
    @State private var savedURL: URL?
    @State private var error: String?
    private var selected: AIGeneratedFile { versions.first { $0.id == selectedID } ?? file }
    var body: some View {
        let file = selected
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(Style.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.system(size: 12, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.content.utf8.count), countStyle: .file))
                        .font(.caption2).foregroundStyle(Style.muted)
                }
                Spacer(minLength: 0)
                Button("下载") {
                    do {
                        let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                        complete(.success(try file.download(to: directory)))
                    } catch { complete(.failure(error)) }
                }.help("保存到下载文件夹")
                Menu {
                    Button("另存为…") { file.saveAs(window: NSApp.keyWindow, completion: complete) }
                    Button("复制源码") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.content, forType: .string)
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("文件操作")
            }
            if versions.count > 1 {
                HStack {
                    Picker("版本", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { index, value in
                            Text("v\(index + 1)" + (value.id == self.file.id ? " · 此轮" : "")).tag(value.id)
                        }
                    }.frame(maxWidth: 170)
                    Toggle("显示变更", isOn: $showChanges).toggleStyle(.checkbox)
                        .disabled(file.id == versions.first?.id)
                }.font(.caption)
            }
            if showChanges, let index = versions.firstIndex(where: { $0.id == file.id }), index > 0 {
                ScrollView([.horizontal, .vertical]) {
                    Text(AIFileDifference.text(from: versions[index - 1].content, to: file.content))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true).padding(8)
                }.frame(height: 220)
            } else if AIFilePreview.supports(file.name) {
                Picker("显示", selection: $showPreview) {
                    Text("预览").tag(true)
                    Text("源码").tag(false)
                }.pickerStyle(.segmented).frame(width: 150)
                if showPreview {
                    AIFilePreview(content: file.content).frame(height: 300)
                    Text("本地沙箱 · 不加载外部资源").font(.caption2).foregroundStyle(Style.muted)
                } else { source(file) }
            } else {
                DisclosureGroup("查看源码", isExpanded: $expanded) { source(file) }
                    .font(.caption).foregroundStyle(Style.muted)
            }
            if let savedURL {
                Button("已保存 · 在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Style.accent)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(10).background(Style.mint, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Style.line))
            .onChange(of: file.content) { _ in savedURL = nil; error = nil }
    }
    private func source(_ file: AIGeneratedFile) -> some View {
                ScrollView([.horizontal, .vertical]) {
                    Text(file.content).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(8)
                }.frame(height: 220)
    }
    private func complete(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): savedURL = url; error = nil
        case .failure(let failure): error = "保存失败：\(failure.localizedDescription)"
        }
    }
}

extension AISession {
    func fileVersions(name: String, through messageID: UUID) -> [AIGeneratedFile] {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return [] }
        return messages.prefix(index + 1).flatMap { $0.generatedFiles ?? [] }.filter { $0.name == name }
    }
}

enum AIFileDifference {
    static func text(from old: String, to new: String) -> AttributedString {
        let before = old.components(separatedBy: "\n"), after = new.components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        // Bound worst-case diff work for files containing thousands of short lines.
        if before.count + after.count <= 3000 {
            for change in after.difference(from: before) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
        } else {
            var start = 0, end = 0
            while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
            while end < min(before.count, after.count) - start,
                  before[before.count - end - 1] == after[after.count - end - 1] { end += 1 }
            removed = Set(start..<(before.count - end)); inserted = Set(start..<(after.count - end))
        }
        var result = AttributedString("+\(inserted.count) 行 / −\(removed.count) 行 · 与上一版本比较\n")
        var left = 0, right = 0
        func append(_ value: String, prefix: String, color: Color) {
            var line = AttributedString(prefix + value + "\n")
            line.foregroundColor = color
            result.append(line)
        }
        while left < before.count || right < after.count {
            if removed.contains(left), left < before.count {
                append(before[left], prefix: "− ", color: .red); left += 1
            } else if inserted.contains(right), right < after.count {
                append(after[right], prefix: "+ ", color: Style.accent); right += 1
            } else if right < after.count {
                append(after[right], prefix: "  ", color: Style.ink); right += 1; left += 1
            } else { left += 1 }
        }
        return result
    }
}
