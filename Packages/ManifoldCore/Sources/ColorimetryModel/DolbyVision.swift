//
//  DolbyVision.swift
//  ColorimetryModel
//
//  The Inspector's Dolby Vision row (0.9.1): what a file's DOVI configuration record (`dvcC`/`dvvC`) declares,
//  and what Manifold shows of it. Manifold applies no Dolby Vision processing: it shows the base layer, decoded and
//  colour-managed from its own tags, and nothing else. A readout only.
//

/// The fields of a DOVI decoder configuration record that the row needs, as libav parses them
/// (`AVDOVIDecoderConfigurationRecord`). A plain value so the wording can be unit-tested without a file.
public struct DolbyVisionConfig: Equatable, Sendable {
    public var profile: Int
    public var level: Int
    public var rpuPresent: Bool
    public var enhancementLayerPresent: Bool
    public var baseLayerPresent: Bool
    /// `dv_bl_signal_compatibility_id`: what a non-Dolby decoder sees in the base layer. 0 = nothing it can show
    /// (profile 5's IPTPQc2), 1 = HDR10, 2 = SDR, 4 = HLG, 6 = HDR10 (Ultra HD Blu-ray, profile 7).
    public var compatibilityID: Int

    public init(profile: Int, level: Int, rpuPresent: Bool = true, enhancementLayerPresent: Bool = false,
                baseLayerPresent: Bool = true, compatibilityID: Int) {
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
        self.enhancementLayerPresent = enhancementLayerPresent
        self.baseLayerPresent = baseLayerPresent
        self.compatibilityID = compatibilityID
    }

    /// False when the base layer is absent or declares no compatible signal: the picture Manifold decodes is then
    /// not a picture any standard transfer describes.
    public var hasCompatibleBaseLayer: Bool { baseLayerPresent && compatibilityID != 0 }

    /// The player window's warning banner (0.9.1, Robbie 2026-10-31), or nil. Profile 5, or any profile with no
    /// compatible base layer: the picture on screen is not the file's. Never for a valid 8.x or 7, whose base layer is
    /// shown correctly and which the Inspector row alone describes.
    public var bannerText: String? {
        guard profile == 5 || !hasCompatibleBaseLayer else { return nil }
        return "Dolby Vision Profile \(profile): this file has no compatible base layer, so Manifold can't display it correctly."
    }

    /// The Inspector row: the profile (with the base layer's compatibility for profile 8), the level, and what is shown.
    /// `isWarning` rows are drawn in the caveat colour.
    public var inspectorText: (text: String, isWarning: Bool) {
        let lv = "(level \(level))"
        if !hasCompatibleBaseLayer {
            return ("Profile \(profile) \(lv) · no compatible base layer; picture will not display correctly", true)
        }
        switch (profile, compatibilityID) {
        case (8, 1): return ("Profile 8.1 \(lv) · HDR10 base layer shown; DV metadata not applied", false)
        case (8, 2): return ("Profile 8.2 \(lv) · SDR base layer shown; DV metadata not applied", false)
        case (8, 4): return ("Profile 8.4 \(lv) · HLG base layer shown; DV metadata not applied", false)
        case (7, _): return ("Profile 7 \(lv) · HDR10 base layer shown; enhancement layer and DV metadata not applied", false)
        default:     return ("Profile \(profile).\(compatibilityID) \(lv) · not applied", false)
        }
    }
}
