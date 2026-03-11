import CoreGraphics
import Foundation
import Vision

/// A single recognized text run in the guest framebuffer.
struct TextObservation: Equatable {
    let string: String
    /// Bounding box in framebuffer pixels, top-left origin.
    let rectInPixels: CGRect
    let confidence: Float

    var center: CGPoint {
        CGPoint(x: rectInPixels.midX, y: rectInPixels.midY)
    }
}

/// The result of locating on-screen text, in framebuffer pixel coordinates.
public struct GuestTextMatch: Sendable, Equatable {
    public let text: String
    public let x: Int
    public let y: Int
    public let confidence: Float
}

/// Text recognition over a captured framebuffer using the Vision framework, plus
/// the matching used to find a labelled UI element to wait for or click.
enum OCRService {
    /// Run OCR over `image`. UI labels are literal (no dictionary words), so language
    /// correction is disabled; accurate recognition trades speed for correctness.
    static func recognizeText(in image: CGImage, minimumConfidence: Float = 0.3) -> [TextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            DebugLog.log("OCR perform failed: \(error.localizedDescription)")
            return []
        }

        let width = image.width
        let height = image.height
        let rawResults = request.results ?? []
        DebugLog.log("OCR on \(width)x\(height): \(rawResults.count) raw results")
        var observations: [TextObservation] = []
        for result in rawResults {
            guard let candidate = result.topCandidates(1).first, candidate.confidence >= minimumConfidence else {
                continue
            }
            observations.append(TextObservation(
                string: candidate.string,
                rectInPixels: pixelRect(fromNormalized: result.boundingBox, width: width, height: height),
                confidence: candidate.confidence
            ))
        }
        return observations
    }

    /// Convert a Vision bounding box (normalized, bottom-left origin) to framebuffer
    /// pixels with a top-left origin — the coordinate space RFB pointer events use.
    static func pixelRect(fromNormalized normalized: CGRect, width: Int, height: Int) -> CGRect {
        let w = Double(width)
        let h = Double(height)
        return CGRect(
            x: normalized.minX * w,
            y: (1 - normalized.maxY) * h,
            width: normalized.width * w,
            height: normalized.height * h
        )
    }

    /// Find the `occurrence`-th match for `query` among `observations`, searching
    /// top-to-bottom then left-to-right. Tries exact (case-insensitive), then
    /// substring, then regex — so a specific label wins over incidental mentions.
    static func find(_ query: String, in observations: [TextObservation], occurrence: Int = 0) -> TextObservation? {
        let sorted = observations.sorted { lhs, rhs in
            if abs(lhs.rectInPixels.minY - rhs.rectInPixels.minY) > 8 {
                return lhs.rectInPixels.minY < rhs.rectInPixels.minY
            }
            return lhs.rectInPixels.minX < rhs.rectInPixels.minX
        }

        let lowerQuery = query.lowercased()
        let exact = sorted.filter { $0.string.lowercased() == lowerQuery }
        if occurrence < exact.count { return exact[occurrence] }

        let substring = sorted.filter { $0.string.lowercased().contains(lowerQuery) }
        if occurrence < substring.count { return substring[occurrence] }

        if let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) {
            let regexMatches = sorted.filter { observation in
                let range = NSRange(observation.string.startIndex..., in: observation.string)
                return regex.firstMatch(in: observation.string, options: [], range: range) != nil
            }
            if occurrence < regexMatches.count { return regexMatches[occurrence] }
        }

        return nil
    }

    /// Whether `candidate` satisfies `query` under the same semantics as `find`:
    /// case-insensitive exact, substring, or regex.
    static func queryMatches(_ query: String, candidate: String) -> Bool {
        let lowerQuery = query.lowercased()
        let lowerCandidate = candidate.lowercased()
        if lowerCandidate == lowerQuery || lowerCandidate.contains(lowerQuery) {
            return true
        }
        guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(candidate.startIndex..., in: candidate)
        return regex.firstMatch(in: candidate, options: [], range: range) != nil
    }

    /// All recognized text in a framebuffer, with rects in native framebuffer
    /// pixels (recognition may run on an upscaled copy; results are mapped back).
    static func observations(in framebuffer: Framebuffer) -> [TextObservation] {
        guard let image = framebuffer.cgImage() else { return [] }
        let (recognitionImage, scale) = upscaledForRecognition(image)
        let raw = recognizeText(in: recognitionImage)
        guard scale > 1 else { return raw }
        let factor = CGFloat(scale)
        return raw.map { observation in
            TextObservation(
                string: observation.string,
                rectInPixels: CGRect(
                    x: observation.rectInPixels.minX / factor,
                    y: observation.rectInPixels.minY / factor,
                    width: observation.rectInPixels.width / factor,
                    height: observation.rectInPixels.height / factor
                ),
                confidence: observation.confidence
            )
        }
    }

    /// Locate `query` in a captured framebuffer, returning its center in pixels.
    static func match(_ query: String, in framebuffer: Framebuffer, occurrence: Int = 0) -> GuestTextMatch? {
        let observations = observations(in: framebuffer)
        return match(query, in: observations, occurrence: occurrence)
    }

    /// Locate `query` in a precomputed OCR observation set.
    static func match(_ query: String, in observations: [TextObservation], occurrence: Int = 0) -> GuestTextMatch? {
        guard let found = find(query, in: observations, occurrence: occurrence) else { return nil }
        return GuestTextMatch(
            text: found.string,
            x: Int(found.center.x.rounded()),
            y: Int(found.center.y.rounded()),
            confidence: found.confidence
        )
    }

    /// Guests configured at 110 ppi render 1x, so at 1080p a button label is only
    /// ~12 px tall — the edge of Vision's reliable range. Upscaling small
    /// framebuffers 2x before recognition markedly improves small-label hits.
    static let recognitionUpscaleThresholdWidth = 2560

    static func upscaledForRecognition(_ image: CGImage) -> (image: CGImage, scale: Int) {
        guard image.width > 0, image.height > 0, image.width < recognitionUpscaleThresholdWidth else {
            return (image, 1)
        }
        let scale = 2
        let width = image.width * scale
        let height = image.height * scale
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return (image, 1)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            return (image, 1)
        }
        return (scaled, scale)
    }
}
