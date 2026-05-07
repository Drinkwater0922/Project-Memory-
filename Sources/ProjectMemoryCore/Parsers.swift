import Foundation
import PDFKit

public enum ParserError: Error, Equatable {
    case unsupported(String)
    case unreadable
}

public final class SourceParser {
    public init() {}

    public func extractText(from data: Data, fileExtension: String) throws -> String {
        switch fileExtension.lowercased() {
        case "md", "markdown", "txt":
            guard let text = String(data: data, encoding: .utf8) else {
                throw ParserError.unreadable
            }
            return text
        case "html", "htm":
            guard let html = String(data: data, encoding: .utf8) else {
                throw ParserError.unreadable
            }
            return stripHTML(html)
        case "pdf":
            guard let document = PDFDocument(data: data) else {
                throw ParserError.unreadable
            }
            return (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        default:
            throw ParserError.unsupported(fileExtension)
        }
    }

    private func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "<script\\b[^>]*>[\\s\\S]*?</script>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<style\\b[^>]*>[\\s\\S]*?</style>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
