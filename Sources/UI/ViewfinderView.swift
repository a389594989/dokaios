import SwiftUI

struct ViewfinderView: View {
    @ObservedObject var model: ViewfinderViewModel
    @ObservedObject private var camera: CameraService

    init(model: ViewfinderViewModel) {
        self.model = model
        self.camera = model.camera
    }

    var body: some View {
        GeometryReader { geo in
            let fill = AspectFill(buffer: model.bufferAspect, view: geo.size)
            ZStack {
                MetalPreviewView(renderer: model.renderer)
                    .ignoresSafeArea()
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onEnded { value in
                                if case .second(true, let drag?) = value {
                                    model.setAnchor(fill.toBuffer(drag.location))
                                }
                            }
                    )

                if model.showGrid { GridOverlay().allowsHitTesting(false) }
                SuggestionOverlay(suggestion: model.suggestion, anchor: model.anchor, fill: fill)
                    .allowsHitTesting(false)

                VStack {
                    topBar
                    Spacer()
                    filmCarousel
                    zoomBar
                    shutterRow
                }
                .padding(.vertical, 12)

                if let toast = model.toast {
                    Text(toast)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
                if camera.permissionDenied {
                    Text("请在系统设置中允许相机权限")
                        .padding().background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .background(Color.black)
        .onAppear { model.start() }
    }

    private var topBar: some View {
        HStack {
            Button { model.showGrid.toggle() } label: {
                Image(systemName: model.showGrid ? "grid" : "square")
            }
            Spacer()
            if let s = model.suggestion {
                Text(s.paradigm.rawValue + (s.tiltDegrees.map { String(format: "  %+.1f°", $0) } ?? ""))
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            Spacer()
            if model.anchor != nil {
                Button { model.setAnchor(nil) } label: { Image(systemName: "xmark.circle.fill") }
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
    }

    /// 三槽位胶片: 主推 / 备选 / 备选。
    private var filmCarousel: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.recommended.enumerated()), id: \.element) { idx, id in
                Button { model.selectedFilm = id } label: {
                    VStack(spacing: 2) {
                        Text(idx == 0 ? "主推" : "备选").font(.system(size: 9))
                        Text(LUTStore.displayName(id)).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(model.selectedFilm == id ? Color.yellow.opacity(0.9) : Color.black.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(model.selectedFilm == id ? .black : .white)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var zoomBar: some View {
        HStack(spacing: 10) {
            ForEach(camera.zoomStops) { stop in
                Button { camera.setZoom(stop) } label: {
                    Text(stop.label)
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(camera.currentLabel == stop.label ? Color.yellow : Color.black.opacity(0.5), in: Circle())
                        .foregroundStyle(camera.currentLabel == stop.label ? .black : .white)
                }
            }
        }
        .padding(.bottom, 14)
    }

    private var shutterRow: some View {
        Button { model.shutter() } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(.white).frame(width: 60, height: 60)
            }
        }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

/// 构图引导: 主体框 + 目标点 + 连线; 对齐后目标点变绿。
struct SuggestionOverlay: View {
    let suggestion: Suggestion?
    let anchor: CGPoint?
    let fill: AspectFill

    var body: some View {
        ZStack {
            if let s = suggestion {
                let aligned = s.alignment > 0.9
                let color: Color = aligned ? .green : .yellow
                if let r = s.subjectRect {
                    Rectangle().path(in: fill.toView(r))
                        .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
                if let t = s.targetPoint {
                    let tv = fill.toView(t)
                    Circle().stroke(color, lineWidth: 2).frame(width: 28, height: 28).position(tv)
                    if let r = s.subjectRect {
                        let c = fill.toView(CGPoint(x: r.midX, y: r.midY))
                        Path { p in p.move(to: c); p.addLine(to: tv) }
                            .stroke(color.opacity(aligned ? 0 : 0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }
            if let a = anchor {
                Image(systemName: "scope").font(.title)
                    .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.42))
                    .position(fill.toView(a))
            }
        }
    }
}
