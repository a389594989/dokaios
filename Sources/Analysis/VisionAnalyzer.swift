import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// 所有矩形/点均为「相机帧归一化坐标, 原点在左上」。
struct SceneStats {
    var luma: CGFloat = 0.5
    var saturation: CGFloat = 0.3
    var warmth: CGFloat = 0      // R-B, -1...1
}

struct SceneAnalysis {
    var subject: CGRect?
    var faceRect: CGRect?
    var eyeLineY: CGFloat?
    var horizonAngle: CGFloat?   // 弧度
    var stats = SceneStats()
}

/// 端侧场景分析: 全部使用 iOS 系统内置 Vision (运行于 Neural Engine / GPU), 不联网、不带模型文件。
final class VisionAnalyzer {
    var onResult: ((SceneAnalysis) -> Void)?

    private let queue = DispatchQueue(label: "doka.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastRun: CFTimeInterval = 0
    private let interval: CFTimeInterval = 0.2

    /// 可在任意线程调用; 内部节流 (约 5fps) 并丢弃重叠请求。
    func analyze(_ pb: CVPixelBuffer, anchor: CGPoint?) {
        let now = CACurrentMediaTime()
        lock.lock()
        if busy || now - lastRun < interval { lock.unlock(); return }
        busy = true; lastRun = now
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let result = self.run(pb, anchor: anchor)
            self.lock.lock(); self.busy = false; self.lock.unlock()
            self.onResult?(result)
        }
    }

    private func run(_ pb: CVPixelBuffer, anchor: CGPoint?) -> SceneAnalysis {
        var out = SceneAnalysis()
        out.stats = Self.stats(pb)

        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        let faces = VNDetectFaceLandmarksRequest()
        let horizon = VNDetectHorizonRequest()
        // 点选主体时用物体显著性 (可返回多个物体), 否则用人眼注意力显著性。
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let saliency: VNImageBasedRequest = anchor == nil ? attention : objectness
        try? handler.perform([faces, horizon, saliency])

        // 人脸 + 眼线
        if let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            let bb = face.boundingBox // 左下原点
            out.faceRect = Self.flip(bb)
            if let l = face.landmarks?.leftEye?.normalizedPoints, let r = face.landmarks?.rightEye?.normalizedPoints,
               !l.isEmpty, !r.isEmpty {
                let ly = l.map(\.y).reduce(0, +) / CGFloat(l.count)
                let ry = r.map(\.y).reduce(0, +) / CGFloat(r.count)
                let eyeYBottomLeft = bb.minY + (ly + ry) / 2 * bb.height
                out.eyeLineY = 1 - eyeYBottomLeft
            }
        }

        // 地平线
        out.horizonAngle = horizon.results?.first?.angle

        // 主体
        let objects = (saliency.results?.first as? VNSaliencyImageObservation)?.salientObjects?.map { Self.flip($0.boundingBox) } ?? []
        if let a = anchor {
            out.subject = objects.first(where: { $0.contains(a) })
                ?? objects.min(by: { Self.dist($0, a) < Self.dist($1, a) })
                ?? CGRect(x: a.x - 0.15, y: a.y - 0.15, width: 0.3, height: 0.3)
        } else {
            out.subject = objects.first
        }
        return out
    }

    private static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    private static func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        hypot(r.midX - p.x, r.midY - p.y)
    }

    /// 抽样 24x24 个像素估算亮度 / 饱和度 / 色温 (BGRA)。
    private static func stats(_ pb: CVPixelBuffer) -> SceneStats {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return SceneStats() }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var l: CGFloat = 0, s: CGFloat = 0, warm: CGFloat = 0, n: CGFloat = 0
        let grid = 24
        for gy in 0..<grid {
            for gx in 0..<grid {
                let x = (gx * 2 + 1) * w / (grid * 2), y = (gy * 2 + 1) * h / (grid * 2)
                let o = y * bpr + x * 4
                let b = CGFloat(ptr[o]) / 255, g = CGFloat(ptr[o + 1]) / 255, r = CGFloat(ptr[o + 2]) / 255
                let mx = max(r, g, b), mn = min(r, g, b)
                l += 0.2126 * r + 0.7152 * g + 0.0722 * b
                s += mx > 0 ? (mx - mn) / mx : 0
                warm += r - b
                n += 1
            }
        }
        return SceneStats(luma: l / n, saturation: s / n, warmth: warm / n)
    }
}
