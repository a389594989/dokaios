import Foundation

/// 场景 -> 胶片推荐 (主推 + 2 个备选)。
/// 规则是初版经验映射, 后续应按安卓 I1/a.java 的「场景色彩→胶片」矩阵校准。
enum FilmRecommender {
    static func recommend(_ a: SceneAnalysis, available: Set<String>) -> [String] {
        var picks: [String] = []
        let s = a.stats

        if a.faceRect != nil {
            picks += ["k_portra_400", "f_pro_neg", "k_portra_160"]
        } else if s.luma < 0.25 {
            picks += ["agfa_vista_800", "f_400h", "f_s400"]
        } else if s.saturation > 0.5 {
            picks += ["f_velvia", "f_provia", "k_gold_200"]
        } else if s.warmth > 0.08 {
            picks += ["k_gold_200", "f_classic_chrome", "f_c200"]
        } else if s.warmth < -0.05 {
            picks += ["f_classic_chrome", "f_cn", "f_provia"]
        } else {
            picks += ["f_provia", "f_classic_neg", "k_portra_400"]
        }
        let filtered = picks.filter { available.contains($0) }
        let result = Array(filtered.prefix(3))
        return result.isEmpty ? Array(available.sorted().prefix(3)) : result
    }
}
