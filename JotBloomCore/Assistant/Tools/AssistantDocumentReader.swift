import Foundation
import AppKit
import PDFKit

public enum AssistantDocumentReader {
    public static func read(_ attachment: AssistantAttachment) throws -> String {
        guard attachment.kind == .file else { throw ExecutionError.denied("不是用户提供的文件。") }
        let url = URL(fileURLWithPath: attachment.reference)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20_971_520 else { throw ExecutionError.unreadable("文件超过 20MB 或不是普通文件，请选择较小的文字资料。") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 20_971_520 else { throw ExecutionError.unreadable("文件过大。") }
        let text: String
        switch url.pathExtension.lowercased() {
        case "md", "txt":
            guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw ExecutionError.unreadable("文件文字编码不支持，请另存为 UTF-8。") }; text = value
        case "pdf":
            guard let document = PDFDocument(data: data), !document.isLocked else { throw ExecutionError.unreadable("PDF 无法打开或需要密码。") }
            var value = ""
            for index in 0..<document.pageCount {
                value += (document.page(at: index)?.string ?? "") + "\n"
                if value.count >= 8001 { break }
            }
            text = value
        case "doc", "docx":
            let type: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "docx" ? .officeOpenXML : .docFormat
            text = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
        default: throw ExecutionError.unreadable("暂时只能读取 txt、md、PDF 和 Word 的文字。")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExecutionError.unreadable("这个文件没有可读取的文字，可能是扫描件；可以用其他资料继续。") }
        return String(text.prefix(8001))
    }
}
