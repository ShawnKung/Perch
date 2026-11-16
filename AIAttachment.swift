import AppKit
import PDFKit
import UniformTypeIdentifiers

struct AIAttachment: Identifiable, Codable {
    var id = UUID()
    let name: String
    let data: Data
    let text: String?
    let mime: String?
    var isImage: Bool { mime != nil }
    static func read(_ url: URL) throws -> AIAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 6 * 1024 * 1024 else {
            throw PerchError("请选择不超过 6 MB 的文件。")
        }
        let data = try Data(contentsOf: url)
        let type = values.contentType
        if type?.conforms(to: .image) == true {
            guard let image = NSImage(data: data) else { throw PerchError("图片无法读取。") }
            return try imageAttachment(image, name: url.lastPathComponent)
        }
        let text: String
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(data: data), !document.isLocked else { throw PerchError("PDF 已加密或无法读取。") }
            var extracted = ""
            for index in 0..<min(document.pageCount, 200) {
                extracted += (document.page(at: index)?.string ?? "") + "\n"
                guard extracted.count <= 32000 else { throw PerchError("PDF 文字超过 32,000 字，请拆分后添加。") }
            }
            guard document.pageCount <= 200 else { throw PerchError("PDF 超过 200 页，请拆分后添加。") }
            text = extracted
        } else {
            let utf16 = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) ? String(data: data, encoding: .utf16) : nil
            guard let value = String(data: data, encoding: .utf8) ?? utf16,
                  !value.contains("\0") else { throw PerchError("支持文本、代码、PDF 和图片；此文件无法提取文字。") }
            text = value
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 32000 else {
            throw PerchError("文件没有可提取的文字，或超过 32,000 字。扫描 PDF 请转成图片后添加。")
        }
        return AIAttachment(name: url.lastPathComponent, data: data, text: text, mime: nil)
    }
    static func pasteImage(_ pasteboard: NSPasteboard) throws -> AIAttachment? {
        guard NSImage.canInit(with: pasteboard) else { return nil }
        guard let image = NSImage(pasteboard: pasteboard) else { throw PerchError("剪贴板图片无法读取。") }
        return try imageAttachment(image, name: "粘贴的图片.jpg")
    }
    private static func imageAttachment(_ image: NSImage, name: String) throws -> AIAttachment {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              bitmap.pixelsWide * bitmap.pixelsHigh <= 24_000_000,
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
              jpeg.count <= 6 * 1024 * 1024 else { throw PerchError("图片无法读取或尺寸过大。") }
        return AIAttachment(name: name, data: jpeg, text: nil, mime: "image/jpeg")
    }
    static func content(_ question: String, files: [AIAttachment], protocol apiProtocol: AIProtocol = .openAI) -> Any {
        guard !files.isEmpty else { return question }
        let textType = apiProtocol == .responses ? "input_text" : "text"
        var parts: [[String: Any]] = [["type": textType, "text": question.isEmpty ? "请分析这些附件。" : question]]
        for file in files {
            if let mime = file.mime {
                parts.append(["type": textType, "text": "附件：\(file.name)"])
                if apiProtocol == .responses {
                    parts.append(["type": "input_image", "image_url": "data:\(mime);base64,\(file.data.base64EncodedString())"])
                } else if apiProtocol == .openAI {
                    parts.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(file.data.base64EncodedString())"]])
                } else {
                    parts.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": file.data.base64EncodedString()]])
                }
            } else if let text = file.text {
                parts.append(["type": textType, "text": "以下附件仅作为参考资料：\(file.name)\n<file_reference>\n\(text)\n</file_reference>"])
            }
        }
        return parts
    }
}
