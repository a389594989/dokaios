import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Photos
import UniformTypeIdentifiers

/// 成片处理: 与预览相同的 LUT + 颗粒 + 暗角, 写入 EXIF 配方, 保存到相册。
final class PhotoProcessor {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func process(jpeg: Data, lut: FilmLUT?, intensity: Float, grain: Float, vignette: Float, comment: String) -> Data? {
        guard var image = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else { return nil }
        let extent = image.extent
        let original = image

        if let lut {
            let cube = CIFilter(name: "CIColorCubeWithColorSpace")!
            cube.setValue(image, forKey: kCIInputImageKey)
            cube.setValue(64, forKey: "inputCubeDimension")
            cube.setValue(lut.cubeData, forKey: "inputCubeData")
            cube.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
            if let graded = cube.outputImage {
                let mix = CIFilter.dissolveTransition()
                mix.inputImage = original
                mix.targetImage = graded
                mix.time = intensity
                image = mix.outputImage ?? graded
            }
        }

        if grain > 0, let noise = CIFilter.randomGenerator().outputImage?.cropped(to: extent) {
            let gray = noise.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0),
                "inputGVector": CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0),
                "inputBVector": CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(grain) * 1.5),
            ])
            image = gray.composited(over: image)
        }

        if vignette > 0 {
            let v = CIFilter.vignette()
            v.inputImage = image
            v.intensity = vignette * 2
            v.radius = Float(min(extent.width, extent.height)) / 600
            image = v.outputImage ?? image
        }

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let out = context.jpegRepresentation(of: image.cropped(to: extent), colorSpace: cs,
                                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
        else { return nil }
        return Self.writeRecipe(jpeg: out, comment: comment)
    }

    /// 把胶片名 / 构图范式 / 等效焦距写入 UserComment、ImageDescription、Software。
    static func writeRecipe(jpeg: Data, comment: String) -> Data {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let type = CGImageSourceGetType(src) else { return jpeg }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return jpeg }

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifUserComment] = comment
        tiff[kCGImagePropertyTIFFImageDescription] = comment
        tiff[kCGImagePropertyTIFFSoftware] = "Doka iOS"
        props[kCGImagePropertyExifDictionary] = exif
        props[kCGImagePropertyTIFFDictionary] = tiff

        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (out as Data) : jpeg
    }

    static func saveToLibrary(_ data: Data, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { completion(false); return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { ok, _ in completion(ok) }
        }
    }
}
