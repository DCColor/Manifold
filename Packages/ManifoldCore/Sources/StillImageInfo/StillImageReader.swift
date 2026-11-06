//
//  StillImageReader.swift
//  StillImageInfo
//
//  Opens a still: the vet, the decode and the facts (docs/STILLS_AND_AUDIO_ONLY_PLAN.md §3.1, B0 result). Writes nothing and
//  touches no engine state, which is what lets `FrameEngine.loadAsset` call it from phase 1: a file that fails here
//  is refused with the current file left playing.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded still and what is said about it.
public struct StillImage: @unchecked Sendable {   // CGImage is immutable
    public let info: StillImageInfo
    /// For the window, route C: what macOS shows.
    public let picture: CGImage
    /// For the scopes: the file's stored values. Nil for what has no RGB values to show (CMYK, Lab).
    public let scopeFrame: StillScopeFrame?

    public init(info: StillImageInfo, picture: CGImage, scopeFrame: StillScopeFrame?) {
        self.info = info
        self.picture = picture
        self.scopeFrame = scopeFrame
    }
}

public enum StillReadResult: Sendable {
    case image(StillImage)
    /// `notice` is the banner; `reason` is for the log.
    case refused(notice: String, reason: String)
}

public enum StillImageReader {
    /// DPX has its own sentence: it conforms to `public.image` and no reader here opens it (§4.2), so "this image couldn't
    /// be opened" would suggest a damaged file.
    static func isDPX(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: UTType("org.smpte.dpx") ?? .image) == true
            && url.pathExtension.lowercased() == "dpx"
    }

    public static func read(url: URL) -> StillReadResult {
        if isDPX(url) {
            return .refused(notice: "DPX isn’t supported yet.", reason: "DPX has no reader here")
        }
        let unreadable = "This image couldn’t be opened."
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .refused(notice: unreadable, reason: "no image source")
        }
        // ⚠️ THE TYPE IS READ FIRST, BEFORE ANY PROPERTY. On an Ultra HDR JPEG `CGImageSourceGetType` answers `public.jpeg`
        // until properties have been read and `public.heic` afterwards (measured, B0). Cause unknown; the order is the fix.
        guard let type = CGImageSourceGetType(source) as String? else {
            return .refused(notice: unreadable, reason: "ImageIO names no type")
        }
        // Asked at runtime, so the list is right on every macOS (§3.1).
        let readable = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        guard readable.contains(type), CGImageSourceGetCount(source) > 0 else {
            return .refused(notice: "macOS can’t open this image format.", reason: "\(type) is not readable here")
        }
        // First frame only for a GIF, a multi-page TIFF or a HEIC sequence (§4.1); the primary is 0 for those.
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int, width > 0, height > 0 else {
            return .refused(notice: unreadable, reason: "no size in its properties")
        }
        // Decoded here, in the vet, so a file with a good header and bad data is refused rather than committed.
        guard let picture = decode(source, index: index, largestSide: max(width, height)) else {
            return .refused(notice: unreadable, reason: "the decode failed")
        }

        let facts = StillFileScan.scan(url: url)
        let hdr = hdrKind(source, index: index, facts: facts)
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let captured = (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime as String] as? String)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        let info = StillImageInfo(
            fileName: url.lastPathComponent,
            format: UTType(type)?.localizedDescription ?? type,
            displayWidth: picture.width,
            displayHeight: picture.height,
            rotated: StillText.orientationSwapsAxes(orientation),
            colorProfile: properties[kCGImagePropertyProfileName as String] as? String,
            bitDepth: properties[kCGImagePropertyDepth as String] as? Int,
            hdr: hdr,
            headroomRow: StillText.headroomRow(
                kind: hdr, gainMapHeadroom: gainMapHeadroom(source, index: index), light: facts.light,
                // No public constant names this key. It is the number ImageIO reports for the file.
                reportedHeadroom: (properties["Headroom"] as? NSNumber)?.doubleValue,
                defaultHeadroom: Double(kCGDefaultHDRImageContentHeadroom)),
            captureDate: captured.map(StillText.captureDate),
            fileCreated: attributes?[.creationDate] as? Date,
            fileModified: attributes?[.modificationDate] as? Date)
        let color = scopeColor(source, index: index, facts: facts, hdr: hdr,
                               profileName: properties[kCGImagePropertyProfileName as String] as? String)
        return .image(StillImage(info: info, picture: picture,
                                 scopeFrame: StillScopeDecode.frame(source, index: index, orientation: orientation, color: color)))
    }

    /// Route C's decode (B0): the gain map applied, and EXIF orientation with it.
    ///
    /// ⚠️ NOT `NSImage(contentsOf:)`. On an EXIF-rotated gain-map file its image is 8-bit at headroom 1.0, so the HDR is lost
    /// (measured, B0: `IMG_0026`). The thumbnail call at full size is the route that both applies the map and turns the
    /// picture. ImageIO decodes a gain map for a target headroom of 8, and no public option changes that.
    private static func decode(_ source: CGImageSource, index: Int, largestSide: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: largestSide]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func auxiliary(_ source: CGImageSource, index: Int, _ type: CFString) -> [String: Any]? {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) as? [String: Any]
    }

    private static func hdrKind(_ source: CGImageSource, index: Int, facts: StillFileFacts) -> StillHDRKind {
        // Either key says a gain map exists. Which kind comes from the file's bytes.
        if auxiliary(source, index: index, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || auxiliary(source, index: index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return .gainMap(facts.gainMaps)
        }
        guard let space = CGImageSourceCreateImageAtIndex(source, index, nil)?.colorSpace else { return .sdr }
        if CGColorSpaceIsPQBased(space) { return .pq }
        if CGColorSpaceIsHLGBased(space) { return .hlg }
        return .sdr
    }

    private static func scopeColor(_ source: CGImageSource, index: Int, facts: StillFileFacts, hdr: StillHDRKind,
                                   profileName: String?) -> StillScopeColor {
        let space = CGImageSourceCreateImageAtIndex(source, index, nil)?.colorSpace
        let hasGainMap: Bool
        if case .gainMap = hdr { hasGainMap = true } else { hasGainMap = false }
        // A file with no profile still decodes into some colour space. Only a stated profile is the file's.
        let stated = profileName != nil
        return StillScopeTags.resolve(cicp: facts.cicp,
                                      profile: stated ? (space?.copyICCData() as Data?).flatMap(ICCProfileFacts.init(icc:)) : nil,
                                      spaceName: stated ? space?.name as String? : nil, profileName: profileName,
                                      hasGainMap: hasGainMap)
    }

    /// The file's HDR capacity as a linear ratio to SDR white, from the gain map's metadata.
    private static func gainMapHeadroom(_ source: CGImageSource, index: Int) -> Double? {
        // ISO 21496-1 states it as a log2 pair; ImageIO reports an Adobe `hdrgm:HDRCapacityMax` the same way.
        if let tags = tags(auxiliary(source, index: index, kCGImageAuxiliaryDataTypeISOGainMap)) {
            let stops = [tags["AlternateHeadroom"], tags["BaseHeadroom"]].compactMap { $0 }.max()
            if let stops { return pow(2, stops) }
        }
        return tags(auxiliary(source, index: index, kCGImageAuxiliaryDataTypeHDRGainMap))?["HDRGainMapHeadroom"]
    }

    private static func tags(_ info: [String: Any]?) -> [String: Double]? {
        guard let value = info?[kCGImageAuxiliaryDataInfoMetadata as String],
              CFGetTypeID(value as CFTypeRef) == CGImageMetadataGetTypeID() else { return nil }
        let metadata = value as! CGImageMetadata
        var out: [String: Double] = [:]
        for tag in (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]) ?? [] {
            guard let name = CGImageMetadataTagCopyName(tag) as String?,
                  let raw = CGImageMetadataTagCopyValue(tag) else { continue }
            if let number = raw as? NSNumber {
                out[name] = number.doubleValue
            } else if let text = raw as? String, let number = Double(text) {
                out[name] = number
            }
        }
        return out
    }
}
