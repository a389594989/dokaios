import CoreGraphics
import Foundation
import Metal
import UIKit

struct FilmLUT {
    let id: String
    let name: String
    /// CIColorCube 用: 64^3 RGBA Float32, R 变化最快, 其次 G, 最后 B。
    let cubeData: Data
    /// Metal 预览用 3D 纹理 (rgba8Unorm)。
    let texture: MTLTexture?
}

/// 把 Doka 的 512x512 LUT 图 (8x8 个 64x64 图块, 图块序号=B, 块内 x=R, y=G) 转成 3D LUT。
final class LUTStore {
    static let size = 64
    static let tiles = 8

    private let device: MTLDevice?
    private var cache: [String: FilmLUT] = [:]

    init(device: MTLDevice?) { self.device = device }

    /// Bundle 内所有可用 LUT 的 id (如 "f_provia")。
    static func availableIDs() -> [String] {
        let paths = Bundle.main.paths(forResourcesOfType: "png", inDirectory: "luts")
        return paths.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .filter { $0.hasPrefix("lut_") }
            .map { String($0.dropFirst(4)) }
            .sorted()
    }

    static func displayName(_ id: String) -> String {
        id.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    func lut(_ id: String) -> FilmLUT? {
        if let c = cache[id] { return c }
        guard let url = Bundle.main.url(forResource: "lut_\(id)", withExtension: "png", subdirectory: "luts"),
              let image = UIImage(contentsOfFile: url.path)?.cgImage,
              let built = build(id: id, image: image) else { return nil }
        cache[id] = built
        return built
    }

    private func build(id: String, image: CGImage) -> FilmLUT? {
        let n = Self.size, t = Self.tiles, side = n * t // 512
        guard image.width == side, image.height == side else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var bytes = [UInt8](repeating: 255, count: n * n * n * 4)
        var floats = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            let tx = b % t, ty = b / t
            for g in 0..<n {
                for r in 0..<n {
                    let src = ((ty * n + g) * side + (tx * n + r)) * 4
                    let dst = ((b * n + g) * n + r) * 4
                    for c in 0..<3 {
                        bytes[dst + c] = pixels[src + c]
                        floats[dst + c] = Float(pixels[src + c]) / 255
                    }
                }
            }
        }

        var tex: MTLTexture?
        if let device {
            let desc = MTLTextureDescriptor()
            desc.textureType = .type3D
            desc.pixelFormat = .rgba8Unorm
            desc.width = n; desc.height = n; desc.depth = n
            desc.usage = .shaderRead
            tex = device.makeTexture(descriptor: desc)
            tex?.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                         withBytes: bytes, bytesPerRow: n * 4, bytesPerImage: n * n * 4)
        }

        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return FilmLUT(id: id, name: Self.displayName(id), cubeData: data, texture: tex)
    }
}
