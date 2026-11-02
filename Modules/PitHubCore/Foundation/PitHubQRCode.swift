//
//  PitHubQRCode.swift
//  PitHubCore
//
//  使用 CoreImage 的 CIQRCodeGenerator 生成二维码，无第三方依赖。
//

import Foundation
import UIKit
import CoreImage

public enum PitHubQRCode {

    /// 生成 PNG 数据（黑码白底）
    public static func pngData(for content: String, pixelSize: CGFloat = 512) -> Data? {
        guard !content.isEmpty else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent
        let scale = pixelSize / max(extent.width, extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = UIImage(cgImage: cgImage)
        return image.pngData()
    }

    /// 生成带圆角、深色背景的二维码图片（用于 App 内展示）
    public static func styledImage(for content: String, size: CGFloat = 260) -> UIImage? {
        guard let png = pngData(for: content, pixelSize: size * 2),
              let qr = UIImage(data: png) else { return nil }

        let canvasSize = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let image = renderer.image { ctx in
            UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            let inset: CGFloat = 12
            qr.draw(in: CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2))
        }
        return image
    }
}
