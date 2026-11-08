import CoreGraphics
import Foundation

enum Paradigm: String {
    case eyeLine = "人像眼线"
    case tapAnchor = "点选主体"
    case centerSymmetry = "中轴对称"
    case thirdsHorizon = "三分地平线"
    case goldenDiagonal = "黄金分割"
}

struct Suggestion: Equatable {
    var paradigm: Paradigm
    /// 建议把主体中心移动到的位置 (相机帧归一化坐标, 左上原点)。
    var targetPoint: CGPoint?
    var subjectRect: CGRect?
    /// 地平线倾斜角 (度), 用于「调平」提示。
    var tiltDegrees: Double?
    /// 0...1, 主体离目标点越近越大。
    var alignment: Double
}

/// 5 种构图范式的几何决策。
/// 注意: 阈值 (0.36 / 0.12 / 0.35 等) 是初版经验值, 与安卓 I1/a.java 的精确公式尚未逐项对齐 (见 README TODO)。
enum CompositionEngine {
    private static let thirds: [CGPoint] = [
        CGPoint(x: 1.0 / 3, y: 1.0 / 3), CGPoint(x: 2.0 / 3, y: 1.0 / 3),
        CGPoint(x: 1.0 / 3, y: 2.0 / 3), CGPoint(x: 2.0 / 3, y: 2.0 / 3),
    ]
    private static let golden: [CGPoint] = [
        CGPoint(x: 0.382, y: 0.382), CGPoint(x: 0.618, y: 0.382),
        CGPoint(x: 0.382, y: 0.618), CGPoint(x: 0.618, y: 0.618),
    ]

    static func suggest(_ a: SceneAnalysis, anchor: CGPoint?) -> Suggestion {
        let tilt = a.horizonAngle.map { Double($0) * 180 / .pi }

        // 1) 人像眼线: 眼睛落在约 1/3 高度, 脸偏左/右时落在对应竖三分线
        if let face = a.faceRect, let eyeY = a.eyeLineY {
            let tx: CGFloat = abs(face.midX - 0.5) < 0.1 ? 0.5 : (face.midX < 0.5 ? 1.0 / 3 : 2.0 / 3)
            let ty = min(max(face.midY + (0.36 - eyeY), 0.2), 0.8)
            let target = CGPoint(x: tx, y: ty)
            return Suggestion(paradigm: .eyeLine, targetPoint: target, subjectRect: face, tiltDegrees: tilt,
                              alignment: alignment(CGPoint(x: face.midX, y: face.midY), target))
        }

        // 2) 点选主体: 主体中心靠向最近的三分交点
        if anchor != nil, let s = a.subject {
            let c = CGPoint(x: s.midX, y: s.midY)
            let target = nearest(c, in: thirds)
            return Suggestion(paradigm: .tapAnchor, targetPoint: target, subjectRect: s, tiltDegrees: tilt,
                              alignment: alignment(c, target))
        }

        if let s = a.subject {
            let c = CGPoint(x: s.midX, y: s.midY)
            // 3) 主体已接近中轴: 对称构图
            if abs(c.x - 0.5) < 0.12 {
                let target = CGPoint(x: 0.5, y: 0.5)
                return Suggestion(paradigm: .centerSymmetry, targetPoint: target, subjectRect: s, tiltDegrees: tilt,
                                  alignment: alignment(c, target))
            }
            // 4) 其余: 黄金分割点
            let target = nearest(c, in: golden)
            return Suggestion(paradigm: .goldenDiagonal, targetPoint: target, subjectRect: s, tiltDegrees: tilt,
                              alignment: alignment(c, target))
        }

        // 5) 没有明确主体 (风光): 以调平地平线为主
        return Suggestion(paradigm: .thirdsHorizon, targetPoint: nil, subjectRect: nil, tiltDegrees: tilt,
                          alignment: tilt.map { max(0, 1 - abs($0) / 10) } ?? 0)
    }

    private static func nearest(_ p: CGPoint, in pts: [CGPoint]) -> CGPoint {
        pts.min(by: { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }) ?? p
    }

    private static func alignment(_ p: CGPoint, _ t: CGPoint) -> Double {
        max(0, 1 - Double(hypot(p.x - t.x, p.y - t.y)) / 0.35)
    }
}
