//
//  ScreenshotDiffDetector.swift
//  claude-cursor
//
//  Fast perceptual-hash comparison for screenshots. Used by the pending-
//  navigation polling loop to cheaply detect "did the screen meaningfully
//  change" without paying for a full Claude call on every tick.
//
//  The hash algorithm is dHash (difference hash) — it downsamples the
//  image to 9x8 grayscale, compares each pixel to its right neighbor, and
//  packs the 64 comparisons into a single UInt64. Two images are considered
//  "meaningfully different" when their Hamming distance exceeds a tunable
//  threshold (default 8 bits out of 64, empirically about a 12.5% change).
//
//  dHash was chosen over aHash because it's more tolerant to minor
//  brightness/contrast shifts (e.g., a menu fading in) while still reliably
//  catching structural changes like a new page loading.
//

import AppKit
import CoreGraphics
import Foundation

/// Computes and compares perceptual hashes for screenshots so the
/// post-action polling loop can skip expensive Claude calls when nothing
/// meaningful has happened on screen.
enum ScreenshotDiffDetector {

    /// The width of the downsampled grayscale image used for hashing.
    /// dHash uses width = hashSideLength + 1 so that each row contributes
    /// `hashSideLength` horizontal comparisons.
    private static let hashSideLength: Int = 8

    /// Downsampled image width (9) — one extra column because dHash
    /// compares each pixel to its right neighbor.
    private static let downsampledImageWidth: Int = hashSideLength + 1

    /// Downsampled image height (8).
    private static let downsampledImageHeight: Int = hashSideLength

    /// Default Hamming-distance threshold above which two hashes are
    /// considered "meaningfully different". 8 out of 64 bits ≈ 12.5% change.
    static let defaultMeaningfulChangeThreshold: Int = 8

    /// Computes a 64-bit dHash for the given JPEG/PNG image data. Returns
    /// nil if the image can't be decoded (caller should treat that as
    /// "unchanged" and skip the tick).
    static func computePerceptualHash(fromImageData imageData: Data) -> UInt64? {
        guard let nsImage = NSImage(data: imageData) else { return nil }
        guard let cgImage = nsImage.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else { return nil }

        return computePerceptualHash(fromCGImage: cgImage)
    }

    /// Computes a 64-bit dHash for the given CGImage.
    static func computePerceptualHash(fromCGImage cgImage: CGImage) -> UInt64? {
        let totalPixelCount = downsampledImageWidth * downsampledImageHeight
        var grayscalePixelBuffer = [UInt8](repeating: 0, count: totalPixelCount)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let graphicsContext = CGContext(
            data: &grayscalePixelBuffer,
            width: downsampledImageWidth,
            height: downsampledImageHeight,
            bitsPerComponent: 8,
            bytesPerRow: downsampledImageWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        graphicsContext.interpolationQuality = .medium
        graphicsContext.draw(
            cgImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: downsampledImageWidth,
                height: downsampledImageHeight
            )
        )

        // Build the 64-bit hash by comparing each pixel to its right
        // neighbor. Set bit = left is brighter than right.
        var perceptualHashBits: UInt64 = 0
        var bitIndex: Int = 0
        for rowIndex in 0..<downsampledImageHeight {
            for columnIndex in 0..<hashSideLength {
                let leftPixelIndex = rowIndex * downsampledImageWidth + columnIndex
                let rightPixelIndex = leftPixelIndex + 1
                let leftPixelBrightness = grayscalePixelBuffer[leftPixelIndex]
                let rightPixelBrightness = grayscalePixelBuffer[rightPixelIndex]
                if leftPixelBrightness > rightPixelBrightness {
                    perceptualHashBits |= (UInt64(1) << bitIndex)
                }
                bitIndex += 1
            }
        }

        return perceptualHashBits
    }

    /// Returns the Hamming distance between two perceptual hashes — the
    /// count of bit positions that differ. Lower = more similar.
    static func hammingDistance(
        betweenHashA hashA: UInt64,
        andHashB hashB: UInt64
    ) -> Int {
        return (hashA ^ hashB).nonzeroBitCount
    }

    /// Convenience: returns true when the two images are meaningfully
    /// different according to the default threshold. Treats a decode
    /// failure on either side as "unchanged" so we don't flood Claude
    /// with calls when the capture pipeline has a transient blip.
    static func didScreenMeaningfullyChange(
        betweenPreviousHash previousHash: UInt64?,
        andCurrentImageData currentImageData: Data,
        withThreshold meaningfulChangeThreshold: Int = defaultMeaningfulChangeThreshold
    ) -> (didChange: Bool, newHash: UInt64?) {
        guard let currentHash = computePerceptualHash(
            fromImageData: currentImageData
        ) else {
            return (false, previousHash)
        }

        guard let previousHash else {
            // First capture — nothing to compare against, report as
            // "changed" so the caller establishes a baseline on the
            // first tick.
            return (true, currentHash)
        }

        let hashDistance = hammingDistance(
            betweenHashA: previousHash,
            andHashB: currentHash
        )
        let didChange = hashDistance >= meaningfulChangeThreshold
        return (didChange, currentHash)
    }
}
