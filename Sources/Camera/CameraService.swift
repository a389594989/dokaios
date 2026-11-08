import AVFoundation
import UIKit

struct ZoomStop: Identifiable, Equatable {
    var id: String { label }
    let label: String      // 显示文字, 如 "0.5" "1x" "3"
    let display: CGFloat   // 显示倍率 (以主摄为 1x)
    let factor: CGFloat    // AVCaptureDevice.videoZoomFactor
}

/// 相机采集: 预览帧 (BGRA) + 拍照 (JPEG) + 多焦段变焦条。
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var zoomStops: [ZoomStop] = []
    @Published var currentLabel = "1x"
    @Published var currentDisplayZoom: CGFloat = 1
    @Published var permissionDenied = false

    /// 在视频队列上回调。
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// 在任意后台队列回调。
    var onPhoto: ((Data) -> Void)?

    private let sessionQueue = DispatchQueue(label: "doka.camera.session")
    private let videoQueue = DispatchQueue(label: "doka.camera.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                if ok { self?.run() } else { DispatchQueue.main.async { self?.permissionDenied = true } }
            }
        default:
            DispatchQueue.main.async { self.permissionDenied = true }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            if self?.session.isRunning == true { self?.session.stopRunning() }
        }
    }

    private func run() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured { self.configure() }
            if self.configured, !self.session.isRunning { self.session.startRunning() }
        }
    }

    // MARK: - 配置

    private func pickBackDevice() -> AVCaptureDevice? {
        // 优先虚拟多摄设备, 由系统在超广角/主摄/长焦之间无缝切换。
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        for type in preferred {
            if let d = AVCaptureDevice.default(type, for: .video, position: .back) { return d }
        }
        return nil
    }

    private func configure() {
        guard let dev = pickBackDevice(), let input = try? AVCaptureDeviceInput(device: dev) else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { session.commitConfiguration(); return }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if let dim = dev.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = dim
        }

        for output in [videoOutput as AVCaptureOutput, photoOutput] {
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) {
                c.videoRotationAngle = 90 // 竖屏
            }
        }
        session.commitConfiguration()

        device = dev
        configured = true
        let stops = Self.buildStops(for: dev)
        DispatchQueue.main.async {
            self.zoomStops = stops
        }
        if let main = stops.first(where: { $0.display == 1 }) { setZoom(main) }
    }

    /// 由虚拟设备的切换倍率推导变焦按钮, 例如 iPhone 16 Pro: 0.5 / 1x / 2 / 5。
    static func buildStops(for d: AVCaptureDevice) -> [ZoomStop] {
        let switchOvers = d.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltra = d.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let base: CGFloat = hasUltra ? (switchOvers.first ?? 1) : 1

        var raw: [(display: CGFloat, factor: CGFloat)] = []
        if hasUltra { raw.append((1 / base, 1)) }
        raw.append((1, base))
        for f in switchOvers.dropFirst() { raw.append((f / base, f)) }
        // 主摄 2x 传感器裁切 (新机型) 或数码变焦
        if !raw.contains(where: { abs($0.display - 2) < 0.1 }), d.maxAvailableVideoZoomFactor >= base * 2 {
            raw.append((2, base * 2))
        }
        raw.sort { $0.display < $1.display }
        return raw.map { item in
            let rounded = (item.display * 10).rounded() / 10
            let label = abs(rounded - 1) < 0.05 ? "1x" : (rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded))
            return ZoomStop(label: label, display: rounded, factor: item.factor)
        }
    }

    // MARK: - 控制

    func setZoom(_ stop: ZoomStop) {
        sessionQueue.async { [weak self] in
            guard let self, let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                d.ramp(toVideoZoomFactor: min(stop.factor, d.maxAvailableVideoZoomFactor), withRate: 6)
                d.unlockForConfiguration()
            } catch { return }
            DispatchQueue.main.async {
                self.currentLabel = stop.label
                self.currentDisplayZoom = stop.display
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb)
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        onPhoto?(data)
    }
}
