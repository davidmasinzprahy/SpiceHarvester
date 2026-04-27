import Foundation
import PDFKit
import CoreGraphics

struct SHPDFParseResult: Sendable {
    let rawPages: [String]
    let hasTextLayer: Bool
    let pageCount: Int
}

struct SHPDFParser: Sendable {
    func parse(_ fileURL: URL) -> SHPDFParseResult {
        guard let document = PDFDocument(url: fileURL) else {
            return SHPDFParseResult(rawPages: [], hasTextLayer: false, pageCount: 0)
        }

        var pages: [String] = []
        var hasTextLayer = false
        let count = document.pageCount
        pages.reserveCapacity(count)

        for index in 0..<count {
            let text = autoreleasepool { () -> String in
                document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if !text.isEmpty {
                hasTextLayer = true
            }
            pages.append(text)
        }

        return SHPDFParseResult(rawPages: pages, hasTextLayer: hasTextLayer, pageCount: count)
    }

    /// Renders a PDF page into a CGImage using a thread-safe CGContext.
    /// Avoids NSImage.lockFocus, which is not safe to call from concurrent background tasks.
    func renderPageImage(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let pixelWidth = Int(max(bounds.width * scale, 1).rounded())
        let pixelHeight = Int(max(bounds.height * scale, 1).rounded())

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)

        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
