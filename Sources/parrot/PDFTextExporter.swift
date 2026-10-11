import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Renders plain text to a paginated PDF using Core Text directly — no extra
/// dependency, and it's the standard low-level way to get real multi-page
/// output (an `NSTextView.dataWithPDF(inside:)` only captures one page).
enum PDFTextExporter {
    enum ExportError: Error, LocalizedError {
        case cannotCreateFile
        case cannotCreateContext
        case noProgress

        var errorDescription: String? {
            switch self {
            case .cannotCreateFile: "Impossibile creare il file PDF."
            case .cannotCreateContext: "Impossibile inizializzare il rendering PDF."
            case .noProgress: "Il testo non entra nella pagina — layout bloccato."
            }
        }
    }

    /// US Letter, in points, with a comfortable margin.
    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 54

    static func write(text: String, title: String, to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw ExportError.cannotCreateFile
        }
        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.cannotCreateContext
        }

        let textRect = pageRect.insetBy(dx: margin, dy: margin)
        let path = CGPath(rect: textRect, transform: nil)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16),
        ]
        let bodyParagraphStyle = NSMutableParagraphStyle()
        bodyParagraphStyle.lineSpacing = 3
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .paragraphStyle: bodyParagraphStyle,
        ]

        let content = NSMutableAttributedString(string: title + "\n\n", attributes: titleAttributes)
        content.append(NSAttributedString(string: text, attributes: bodyAttributes))

        let framesetter = CTFramesetterCreateWithAttributedString(content)
        var location = 0
        let totalLength = content.length

        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(location, 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            guard visibleRange.length > 0 else {
                context.closePDF()
                throw ExportError.noProgress
            }
            location += visibleRange.length
        } while location < totalLength

        context.closePDF()
    }
}
