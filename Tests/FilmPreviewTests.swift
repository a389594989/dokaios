import CoreImage
import Metal
import UIKit
import XCTest
@testable import DokaiOS

/// 无需真机: 用静态照片验证 LUT 转换与构图分析, 把结果导出为图片/报告 (由 CI 作为产物上传)。
final class FilmPreviewTests: XCTestCase {
    private var outDir: URL {
        let path = ProcessInfo.processInfo.environment["DOKA_OUT_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleURLs() -> [URL] {
        let bundle = Bundle(for: Self.self)
        return (bundle.urls(forResourcesWithExtension: "jpg", subdirectory: "TestImages") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testLUTsLoad() {
        let ids = LUTStore.availableIDs()
        XCTAssertEqual(ids.count, 24, "应能在 Bundle 中找到 24 张 LUT")
        let store = LUTStore(device: nil)
        for id in ids { XCTAssertNotNil(store.lut(id), "LUT \(id) 解析失败 (尺寸应为 512x512)") }
    }

    /// 每张样图 × 每款胶片 -> 联系表 (contact sheet)。
    func testFilmContactSheets() throws {
        let urls = sampleURLs()
        XCTAssertFalse(urls.isEmpty, "TestImages 里没有样图")
        let store = LUTStore(device: nil)
        let processor = PhotoProcessor()
        let ids = LUTStore.availableIDs()
        var report = "film,avg_dR,avg_dG,avg_dB (相对原图的平均通道变化, 0-255)\n"
        var totals: [String: [Double]] = [:]

        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: url)
            guard let original = UIImage(data: data) else { XCTFail("读不了 \(name)"); continue }

            var cells: [(String, UIImage)] = [("ORIGINAL", original)]
            for id in ids {
                guard let lut = store.lut(id),
                      let out = processor.process(jpeg: data, lut: lut, intensity: 1, grain: 0, vignette: 0, comment: "test"),
                      let img = UIImage(data: out) else { XCTFail("\(name)/\(id) 处理失败"); continue }
                cells.append((LUTStore.displayName(id), img))
                let d = Self.meanDelta(original, img)
                totals[id, default: [0, 0, 0]] = zip(totals[id, default: [0, 0, 0]], d).map(+)
            }
            let sheet = Self.contactSheet(cells, columns: 5, cell: CGSize(width: 240, height: 180))
            try sheet.pngData()?.write(to: outDir.appendingPathComponent("films_\(name).png"))
        }
        for id in ids {
            let t = (totals[id] ?? [0, 0, 0]).map { $0 / Double(urls.count) }
            report += String(format: "%@,%.1f,%.1f,%.1f\n", id, t[0], t[1], t[2])
        }
        try report.write(to: outDir.appendingPathComponent("lut_report.csv"), atomically: true, encoding: .utf8)
    }

    /// 构图分析: 导出叠加了主体框/目标点的图, 以及文字报告。
    func testCompositionAnalysis() throws {
        let analyzer = VisionAnalyzer()
        var report = ""
        for url in sampleURLs() {
            let name = url.deletingPathExtension().lastPathComponent
            guard let img = UIImage(contentsOfFile: url.path), let cg = img.cgImage,
                  let pb = Self.pixelBuffer(from: cg) else { continue }

            let a = analyzer.analyzeSync(pb)
            let s = CompositionEngine.suggest(a, anchor: nil)
            let rec = FilmRecommender.recommend(a, available: Set(LUTStore.availableIDs()))

            report += "[\(name)] 范式=\(s.paradigm.rawValue) 对齐=\(String(format: "%.2f", s.alignment))"
            report += " 人脸=\(a.faceRect != nil) 主体=\(a.subject != nil)"
            report += " 倾斜=\(s.tiltDegrees.map { String(format: "%.1f°", $0) } ?? "-")"
            report += String(format: " 亮度=%.2f 饱和=%.2f 色温=%+.2f", a.stats.luma, a.stats.saturation, a.stats.warmth)
            report += " 推荐=\(rec.joined(separator: "/"))\n"

            let size = img.size
            let overlay = UIGraphicsImageRenderer(size: size).image { ctx in
                img.draw(at: .zero)
                let c = ctx.cgContext
                c.setLineWidth(max(2, size.width / 300))
                if let r = s.subjectRect {
                    c.setStrokeColor(UIColor.yellow.cgColor)
                    c.stroke(CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                    width: r.width * size.width, height: r.height * size.height))
                }
                if let t = s.targetPoint {
                    c.setStrokeColor(UIColor.green.cgColor)
                    let p = CGPoint(x: t.x * size.width, y: t.y * size.height)
                    c.strokeEllipse(in: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36))
                }
                c.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
                c.setLineWidth(1)
                for i in 1...2 {
                    c.move(to: CGPoint(x: size.width * CGFloat(i) / 3, y: 0))
                    c.addLine(to: CGPoint(x: size.width * CGFloat(i) / 3, y: size.height))
                    c.move(to: CGPoint(x: 0, y: size.height * CGFloat(i) / 3))
                    c.addLine(to: CGPoint(x: size.width, y: size.height * CGFloat(i) / 3))
                }
                c.strokePath()
            }
            try overlay.jpegData(compressionQuality: 0.85)?.write(to: outDir.appendingPathComponent("composition_\(name).jpg"))
        }
        try report.write(to: outDir.appendingPathComponent("composition_report.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(report.isEmpty)
    }

    // MARK: - 工具

    static func pixelBuffer(from cg: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return buf
    }

    /// 两图 (同尺寸) 的平均 RGB 差值 (有符号, 0-255)。
    static func meanDelta(_ a: UIImage, _ b: UIImage) -> [Double] {
        func mean(_ img: UIImage) -> [Double] {
            let w = 32, h = 32
            var px = [UInt8](repeating: 0, count: w * h * 4)
            guard let cg = img.cgImage,
                  let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [0, 0, 0] }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var s = [0.0, 0.0, 0.0]
            for i in 0..<(w * h) { for c in 0..<3 { s[c] += Double(px[i * 4 + c]) } }
            return s.map { $0 / Double(w * h) }
        }
        return zip(mean(b), mean(a)).map { $0 - $1 }
    }

    static func contactSheet(_ cells: [(String, UIImage)], columns: Int, cell: CGSize) -> UIImage {
        let label: CGFloat = 20
        let rows = (cells.count + columns - 1) / columns
        let size = CGSize(width: CGFloat(columns) * cell.width, height: CGFloat(rows) * (cell.height + label))
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                                                         .foregroundColor: UIColor.white]
            for (i, item) in cells.enumerated() {
                let x = CGFloat(i % columns) * cell.width, y = CGFloat(i / columns) * (cell.height + label)
                item.1.draw(in: CGRect(x: x + 2, y: y + 2, width: cell.width - 4, height: cell.height - 2))
                (item.0 as NSString).draw(at: CGPoint(x: x + 6, y: y + cell.height + 2), withAttributes: attrs)
            }
        }
    }
}
