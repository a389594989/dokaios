import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// 相机帧 (归一化, 左上原点) <-> 屏幕坐标, 与 Shaders.metal 的 aspect-fill 保持一致。
struct AspectFill {
    let buffer: CGFloat   // 帧宽/高
    let view: CGSize

    private var scale: (x: CGFloat, y: CGFloat) {
        let viewA = view.width / max(view.height, 1)
        return viewA > buffer ? (1, buffer / viewA) : (viewA / buffer, 1)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        let s = scale
        return CGPoint(x: ((p.x - 0.5) / s.x + 0.5) * view.width, y: ((p.y - 0.5) / s.y + 0.5) * view.height)
    }

    func toView(_ r: CGRect) -> CGRect {
        let a = toView(CGPoint(x: r.minX, y: r.minY)), b = toView(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    func toBuffer(_ q: CGPoint) -> CGPoint {
        let s = scale
        return CGPoint(x: (q.x / view.width - 0.5) * s.x + 0.5, y: (q.y / view.height - 0.5) * s.y + 0.5)
    }
}

final class ViewfinderViewModel: ObservableObject {
    let camera = CameraService()
    let renderer = PreviewRenderer()
    private let analyzer = VisionAnalyzer()
    private let processor = PhotoProcessor()
    private let luts: LUTStore?
    private let processQueue = DispatchQueue(label: "doka.process", qos: .userInitiated)

    let availableFilms: Set<String>

    @Published var selectedFilm: String = "f_provia" { didSet { applyFilm() } }
    @Published var recommended: [String] = []
    @Published var suggestion: Suggestion?
    @Published var anchor: CGPoint?            // 帧归一化坐标
    @Published var showGrid = true
    @Published var intensity: Double = 1 { didSet { pushParams() } }
    @Published var grain: Double = 0.05 { didSet { pushParams() } }
    @Published var vignette: Double = 0.2 { didSet { pushParams() } }
    @Published var toast: String?
    @Published var bufferAspect: CGFloat = 3.0 / 4.0

    private let anchorLock = NSLock()
    private var anchorForAnalysis: CGPoint?

    init() {
        availableFilms = Set(LUTStore.availableIDs())
        luts = renderer.map { LUTStore(device: $0.device) }
        if !availableFilms.contains(selectedFilm), let first = availableFilms.sorted().first { selectedFilm = first }
        recommended = Array(availableFilms.sorted().prefix(3))

        camera.onFrame = { [weak self] pb in
            guard let self else { return }
            self.renderer?.submit(pb)
            self.anchorLock.lock(); let a = self.anchorForAnalysis; self.anchorLock.unlock()
            self.analyzer.analyze(pb, anchor: a)
            let aspect = CGFloat(CVPixelBufferGetWidth(pb)) / CGFloat(CVPixelBufferGetHeight(pb))
            if abs(aspect - self.bufferAspect) > 0.001 { DispatchQueue.main.async { self.bufferAspect = aspect } }
        }
        analyzer.onResult = { [weak self] analysis in
            guard let self else { return }
            DispatchQueue.main.async {
                let s = CompositionEngine.suggest(analysis, anchor: self.anchor)
                if s != self.suggestion { self.suggestion = s }
                let rec = FilmRecommender.recommend(analysis, available: self.availableFilms)
                if rec != self.recommended { self.recommended = rec }
            }
        }
        camera.onPhoto = { [weak self] data in self?.handlePhoto(data) }
        applyFilm()
        pushParams()
    }

    func start() { camera.start() }

    func setAnchor(_ p: CGPoint?) {
        anchor = p
        anchorLock.lock(); anchorForAnalysis = p; anchorLock.unlock()
    }

    func shutter() { camera.capturePhoto() }

    // MARK: - 内部

    private func applyFilm() {
        renderer?.setLUT(luts?.lut(selectedFilm)?.texture)
    }

    private func pushParams() {
        renderer?.params.intensity = Float(intensity)
        renderer?.params.grain = Float(grain)
        renderer?.params.vignette = Float(vignette)
    }

    private func handlePhoto(_ data: Data) {
        let film = selectedFilm
        let (i, g, v) = (Float(intensity), Float(grain), Float(vignette))
        let paradigm = suggestion?.paradigm.rawValue ?? "无"
        let focal = Int((24 * camera.currentDisplayZoom).rounded())
        processQueue.async { [weak self] in
            guard let self else { return }
            let lut = self.luts?.lut(film)
            let comment = "Doka iOS | 胶片: \(LUTStore.displayName(film)) | 构图: \(paradigm) | 等效焦距: ≈\(focal)mm"
            let result = self.processor.process(jpeg: data, lut: lut, intensity: i, grain: g, vignette: v, comment: comment)
                ?? PhotoProcessor.writeRecipe(jpeg: data, comment: comment)
            PhotoProcessor.saveToLibrary(result) { ok in
                DispatchQueue.main.async {
                    self.toast = ok ? "已保存 · \(LUTStore.displayName(film))" : "保存失败, 请检查相册权限"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.toast = nil }
                }
            }
        }
    }
}
