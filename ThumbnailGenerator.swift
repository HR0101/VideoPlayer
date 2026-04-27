import Foundation
import AVFoundation
import UIKit
import CoreImage

class ThumbnailGenerator {
    

    static func generateThumbnail(for asset: AVAsset, at time: CMTime) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let maxAttempts = 5
        let retryTimeOffset: Double = 2.0
        
        for attempt in 0..<maxAttempts {
            let attemptTime = CMTimeAdd(time, CMTime(seconds: Double(attempt) * retryTimeOffset, preferredTimescale: 600))
            
            do {
                let cgImage = try await generator.image(at: attemptTime).image
                
                if !isImagePredominantlyBlack(image: cgImage) {
                    return UIImage(cgImage: cgImage)
                }
                print("Attempt \(attempt + 1) at \(attemptTime.seconds)s resulted in a black frame. Retrying...")
                
            } catch {
                print("Thumbnail generation failed at \(attemptTime.seconds)s: \(error.localizedDescription)")
                continue
            }
        }

        if let cgImage = try? await generator.image(at: time).image {
            return UIImage(cgImage: cgImage)
        }
        
        return nil
    }

    private static func isImagePredominantlyBlack(
        image: CGImage,
        darknessThreshold: UInt8 = 30,
        percentageThreshold: Double = 0.95
    ) -> Bool {
        guard let pixelData = image.dataProvider?.data,
              let data = CFDataGetBytePtr(pixelData) else {
            return false
        }

        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        
        guard bytesPerPixel >= 3 else { return false }
        
        var darkPixelCount = 0
        let totalPixels = width * height
        let step = max(1, totalPixels / 10000)
        let sampleTotal = totalPixels / step

        for i in stride(from: 0, to: totalPixels, by: step) {
            let offset = (i / width * image.bytesPerRow) + (i % width * bytesPerPixel)
            
            let red = data[offset]
            let green = data[offset + 1]
            let blue = data[offset + 2]

            if red < darknessThreshold && green < darknessThreshold && blue < darknessThreshold {
                darkPixelCount += 1
            }
        }

        return Double(darkPixelCount) / Double(sampleTotal) >= percentageThreshold
    }
}

