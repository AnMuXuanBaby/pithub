//
//  PitHubImagePreview.swift
//  PitHubCore
//
//  浏览器预览用的图片转码：HEIC / HEIF / TIFF 等系统能解码的格式，
//  统一用 ImageIO 生成 JPEG 缩略图，避免 Chrome/Android 打不开。
//  全程使用系统框架，不引入第三方图片库。
//

import Foundation
import ImageIO
import UIKit

public enum PitHubImagePreview {

    public static func jpegData(from url: URL, maxPixel: Int, quality: CGFloat = 0.82) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return jpegData(source: source, maxPixel: maxPixel, quality: quality)
    }

    public static func jpegData(from data: Data, maxPixel: Int, quality: CGFloat = 0.82) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpegData(source: source, maxPixel: maxPixel, quality: quality)
    }

    private static func jpegData(source: CGImageSource, maxPixel: Int, quality: CGFloat) -> Data? {
        let pixel = max(64, min(4096, maxPixel))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let uiImage = UIImage(cgImage: image)
        return uiImage.jpegData(compressionQuality: max(0.1, min(1.0, quality)))
    }
}
