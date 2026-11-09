import CoreGraphics
import Foundation

/// 构图范式枚举（全面升级为 @秋秋脾气好 16部高赞教程 50+条量化公式体系）
enum Paradigm: String, CaseIterable {
    case bottomTwoCells = "中下两格（显腿长/仰拍）"
    case rightSixCells = "右边六格（景左人右故事感）"
    case cornerFourCells = "四角四格（远山/古建对角线）"
    case diningIndoor = "室内探店（1.5x撑桌压眉）"
    case selfieCute = "前置可爱自拍（阴阳光/正中格）"
    case crowdAntiPeople = "景区避人群（3x大蹲姿仰拍）"
    case goldenSilhouette = "夕阳蓝调（中下两格压暗剪影）"
    case centerSymmetry = "中轴对称（正中间一格）"
    case eyeLine = "人像眼线"
    case tapAnchor = "点选主体"
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
    /// 秋秋全焦段总纲推荐原生倍数: 0.5, 1.0, 1.5, 2.0, 3.0, 5.0
    var recommendedZoom: Double = 1.0
    /// 摄影师与模特姿态实战口诀
    var postureTip: String = ""
    /// 推荐曝光补偿 (EV)，如逆光晚霞或室内压暗
    var exposureBiasEV: Double? = nil
}

/// 基于 @秋秋脾气好 16部千万赞教程蒸馏结果的专业构图与全焦段智能决策引擎。
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

        // ==========================================
        // 1. 点选强制主体优先
        // ==========================================
        if anchor != nil, let s = a.subject {
            let c = CGPoint(x: s.midX, y: s.midY)
            let target = nearest(c, in: thirds)
            return Suggestion(
                paradigm: .tapAnchor,
                targetPoint: target,
                subjectRect: s,
                tiltDegrees: tilt,
                alignment: alignment(c, target),
                recommendedZoom: 1.5,
                postureTip: "已锁定主体：移动机位将主体对齐黄色锚点"
            )
        }

        // ==========================================
        // 2. 人像检测：应用秋秋 14 大特定场景决策状态机
        // ==========================================
        if let face = a.faceRect {
            let faceRatio = Double(face.height) // 人脸占画面高比，对应拍摄距离
            let faceMidX = Double(face.midX)
            let faceMidY = Double(face.midY)
            let isWarm = a.stats.warmth > 0.15
            let isBright = a.stats.luma > 0.60

            // 2.1 逆光/夕阳场景：高饱和暖色 + 强光 -> 压暗剪影
            if isWarm && a.stats.saturation > 0.40 && (faceMidY > 0.4) {
                let target = CGPoint(x: 0.50, y: 0.67) // 中下两格
                return Suggestion(
                    paradigm: .goldenSilhouette,
                    targetPoint: target,
                    subjectRect: face,
                    tiltDegrees: tilt,
                    alignment: alignment(CGPoint(x: faceMidX, y: faceMidY), target),
                    recommendedZoom: 2.0,
                    postureTip: "秋秋夕阳公式：后退蹲下放中下两格，点击天空晚霞下拉压暗曝光拍立体侧脸剪影",
                    exposureBiasEV: -1.2
                )
            }

            // 2.2 前置可爱自拍特写 (faceRatio > 0.32，一掌距离)
            if faceRatio > 0.32 {
                let target = CGPoint(x: 0.50, y: 0.33) // 眼睛卡第一横线
                return Suggestion(
                    paradigm: .selfieCute,
                    targetPoint: target,
                    subjectRect: face,
                    tiltDegrees: tilt,
                    alignment: alignment(CGPoint(x: faceMidX, y: faceMidY), target),
                    recommendedZoom: 1.0,
                    postureTip: "秋秋自拍公式：一掌距离，侧光打半边脸立体五官，双眼卡第一横线，鼻嘴锁正中间第5格",
                    exposureBiasEV: 0.2
                )
            }

            // 2.3 室内餐厅探店 / 约会坐姿 (0.18 <= faceRatio <= 0.32，退后1米双手前撑)
            if faceRatio >= 0.18 {
                let target = CGPoint(x: 0.50, y: 0.35)
                return Suggestion(
                    paradigm: .diningIndoor,
                    targetPoint: target,
                    subjectRect: face,
                    tiltDegrees: tilt,
                    alignment: alignment(CGPoint(x: faceMidX, y: faceMidY), target),
                    recommendedZoom: 1.5,
                    postureTip: "秋秋约会公式：退后1米双手前撑桌显脸小，切1.5x手机微抬高，眉眼卡第一条横线，点击面部压暗曝光",
                    exposureBiasEV: -0.7
                )
            }

            // 2.4 七分身叙事感 (0.09 <= faceRatio < 0.18，距离约 2.5 米)
            if faceRatio >= 0.09 {
                // 景在左，人在右（右边六格）
                let target = CGPoint(x: 0.67, y: 0.50)
                return Suggestion(
                    paradigm: .rightSixCells,
                    targetPoint: target,
                    subjectRect: face,
                    tiltDegrees: tilt,
                    alignment: alignment(CGPoint(x: faceMidX, y: faceMidY), target),
                    recommendedZoom: 2.0,
                    postureTip: "秋秋故事感公式：后退2.5米切2x，人物锁在右边六格（景左人右），左侧留白展现风景延伸"
                )
            }

            // 2.5 全身大长腿 / 远景地标 (faceRatio < 0.09)
            // 默认人放中下两格（第5、8格），脚贴底边
            let target = CGPoint(x: 0.50, y: 0.67)
            return Suggestion(
                paradigm: .bottomTwoCells,
                targetPoint: target,
                subjectRect: face,
                tiltDegrees: tilt,
                alignment: alignment(CGPoint(x: faceMidX, y: faceMidY), target),
                recommendedZoom: 1.0,
                postureTip: "秋秋大长腿公式：手机齐腰平视，人物锁在中下两格（第5、8格），脚贴底边，头顶留空满屏"
            )
        }

        // ==========================================
        // 3. 静物 / 风景主体
        // ==========================================
        if let s = a.subject {
            let c = CGPoint(x: s.midX, y: s.midY)
            // 3.1 接近中轴 -> 正中间第5格对称
            if abs(c.x - 0.5) < 0.12 {
                let target = CGPoint(x: 0.5, y: 0.5)
                return Suggestion(
                    paradigm: .centerSymmetry,
                    targetPoint: target,
                    subjectRect: s,
                    tiltDegrees: tilt,
                    alignment: alignment(c, target),
                    recommendedZoom: 2.0,
                    postureTip: "秋秋三明治公式：正中间一格居中构图，上天、中人、下景三层均衡"
                )
            }
            // 3.2 偏角 -> 黄金分割 / 远山对角线留白
            let target = nearest(c, in: golden)
            return Suggestion(
                paradigm: .cornerFourCells,
                targetPoint: target,
                subjectRect: s,
                tiltDegrees: tilt,
                alignment: alignment(c, target),
                recommendedZoom: 3.0,
                postureTip: "秋秋远山压缩公式：后退4米切3x长焦，主体锁角下四格，对角线留给壮阔背景"
            )
        }

        // ==========================================
        // 4. 纯风光（无明确主体）：以调平地平线为主
        // ==========================================
        return Suggestion(
            paradigm: .thirdsHorizon,
            targetPoint: nil,
            subjectRect: nil,
            tiltDegrees: tilt,
            alignment: tilt.map { max(0, 1 - abs($0) / 10) } ?? 0,
            recommendedZoom: 1.0,
            postureTip: "秋秋风光法则：天空两排草地一排(2:1黄金分割)，保持地平线调平"
        )
    }

    private static func nearest(_ p: CGPoint, in pts: [CGPoint]) -> CGPoint {
        pts.min(by: { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }) ?? p
    }

    private static func alignment(_ p: CGPoint, _ t: CGPoint) -> Double {
        max(0, 1 - Double(hypot(p.x - t.x, p.y - t.y)) / 0.35)
    }
}
