import SwiftUI
import ManifoldCore

/// A floating, translucent panel showing the loaded clip's technical metadata.
struct InspectorPanel: View {
    let metadata: VideoMetadata?
    @ObservedObject var engine: FrameEngine

    /// Range as displayed: the file's tag, annotated when the user is asserting
    /// an override (honest that it's an assertion, not read from the file).
    private func rangeValue(_ m: VideoMetadata) -> String {
        switch engine.rangeOverride {
        case .auto:  return m.colorRange
        case .full:  return "\(m.colorRange) → Full (override)"
        case .legal: return "\(m.colorRange) → Legal (override)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inspector")
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 8)

            if let m = metadata {
                SectionHeader("File Name")
                Text(m.fileName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                Divider().overlay(.white.opacity(0.15)).padding(.bottom, 6)

                MetadataRow(label: "Codec", value: m.codecName)
                // ⚠️ WHAT THE FILE DECLARES FIRST, THEN WHAT IS BEING DONE ABOUT IT. "Resolution" is
                // the ENCODED raster; the two rows below are the transforms, each shown only where
                // it says something. This used to be one `naturalSize` number that was neither —
                // clean aperture applied, pixel aspect ignored — which is ambiguous the moment a
                // desqueeze exists, because the reader cannot tell which of the three it is.
                MetadataRow(label: "Resolution", value: m.resolutionString)
                // Only when it actually crops: a `clap` equal to the encoded raster declares that
                // nothing is cropped, which is not news.
                if m.cleanApertureCrops {
                    MetadataRow(label: "Clean Aperture", value: m.cleanAperture.displayString)
                    // ⚠️ WHERE AN INEXACT CROP BECOMES VISIBLE. The renderer crops the offscreen to
                    // the aperture, and the rect has to sit on the 2-px chroma grid to stay
                    // bit-exact — so a declaration that does not already sit there is ROUNDED onto
                    // it (see `CleanApertureCrop`). This row is the promise that the rounding is
                    // never silent: it appears only when the applied rect differs from what the
                    // file declared, and it states what was actually used.
                    if let crop = m.activeCrop, !crop.isExact {
                        MetadataRow(label: "Crop Applied", value: crop.displayString + " (rounded)")
                    }
                }
                // ALWAYS SHOWN, three-state. "Not declared" and "1:1 (square, declared)" are
                // different facts and this is the row where that distinction lives — see
                // `DeclaredPixelAspect`. It is the one row a squeezed picture sends you to, so it
                // does not hide on the files where the answer is boring.
                MetadataRow(label: "Pixel Aspect", value: m.pixelAspect.displayString)
                // What is on screen, once both transforms are applied — shown only when it differs
                // from the encoded raster, i.e. when there is a second number to reconcile.
                if m.displayDiffersFromEncoded {
                    MetadataRow(label: "Display Size", value: m.displaySizeString)
                }
                MetadataRow(label: "Frame Rate", value: m.frameRateString)
                if let tc = m.startTimecode {
                    MetadataRow(label: "Start TC", value: tc)
                }
                MetadataRow(label: "Data Rate", value: m.videoDataRateString)
                MetadataRow(label: "Container", value: m.container)

                Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)

                MetadataRow(label: "Primaries", value: m.labeled(m.colorPrimaries, m.colorPrimariesCode))
                MetadataRow(label: "Transfer", value: m.labeled(m.transferFunction, m.transferFunctionCode))
                MetadataRow(label: "Matrix", value: m.labeled(m.colorMatrix, m.colorMatrixCode))
                MetadataRow(label: "Range", value: rangeValue(m))
                RangeOverrideRow(
                    selection: Binding(
                        get: { engine.rangeOverride },
                        set: { engine.setRangeOverride($0) }
                    )
                )
                // Active full-range chroma convention — readout only (no control).
                // Only meaningful when the effective range is Full; "—" otherwise.
                MetadataRow(label: "Full Chroma",
                            value: engine.effectiveIsFullRange ? engine.fullRangeChromaConvention.label : "—")
                MetadataRow(label: "nclc", value: m.nclcTriple)

                // HDR10 static metadata. Shown when the clip is HDR (PQ/HLG) — where the
                // presence OR absence of this metadata is a fact worth reporting — or
                // whenever a file carries it regardless of transfer (an SDR-tagged file
                // with an MDCV box is itself worth seeing). Hidden on plain SDR clips,
                // where "no HDR10 metadata" is not news.
                if m.isHDRTransfer || m.hdr10.hasAny {
                    Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)
                    SectionHeader("HDR10 Static Metadata")
                    MasteringDisplaySection(hdr10: m.hdr10, transferCode: m.transferFunctionCode)
                    ContentLightSection(hdr10: m.hdr10, transferCode: m.transferFunctionCode)
                }

                if !m.audioTracks.isEmpty {
                    Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)
                    SectionHeader(m.audioTracks.count == 1 ? "Audio" : "Audio (\(m.audioTracks.count))")
                    ForEach(Array(m.audioTracks.enumerated()), id: \.offset) { index, track in
                        // Second entry point for the SAME state the control bar's selector drives —
                        // the tracks are already described here, so making the description clickable
                        // is a shorter path than reading it here and then going to the toolbar.
                        // `selectable` is gated on the ENGINE's count, not the inspector's: the
                        // inspector enumerates the asset and is complete even on paths where the
                        // engine cannot honour a switch, and a row that looks clickable and does
                        // nothing is worse than one that plainly isn't.
                        AudioTrackRow(index: index, track: track,
                                      showIndex: m.audioTracks.count > 1,
                                      isMonitored: engine.audioTrackCount > 0
                                                   && index == engine.selectedAudioTrackIndex,
                                      selectable: engine.audioTrackCount > 1,
                                      select: { engine.selectAudioTrack(index) })
                    }
                }

                if !m.textTracks.isEmpty {
                    Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)
                    SectionHeader(m.textTracks.count == 1 ? "Timed Text" : "Timed Text (\(m.textTracks.count))")
                    ForEach(Array(m.textTracks.enumerated()), id: \.offset) { _, track in
                        TextTrackRow(track: track)
                    }
                }

                if !m.chapters.isEmpty {
                    Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)
                    MetadataRow(label: "Markers", value: "\(m.chapters.count)")
                }

                if hasFileInfo(m) {
                    Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)
                    SectionHeader("File")
                    if let s = m.software { MetadataRow(label: "Software", value: s) }
                    if let c = m.creator { MetadataRow(label: "Creator", value: c) }
                    if m.creationDate != nil {
                        MetadataRow(label: "Encoded", value: VideoMetadata.dateString(m.creationDate))
                    }
                    if m.fileCreatedDate != nil {
                        MetadataRow(label: "Added to Disk", value: VideoMetadata.dateString(m.fileCreatedDate))
                    }
                    if m.fileModifiedDate != nil {
                        MetadataRow(label: "Modified", value: VideoMetadata.dateString(m.fileModifiedDate))
                    }
                }
            } else {
                Text("No media loaded")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func hasFileInfo(_ m: VideoMetadata) -> Bool {
        m.software != nil || m.creator != nil || m.creationDate != nil
            || m.fileCreatedDate != nil || m.fileModifiedDate != nil
    }
}

private struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .default).weight(.semibold))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.bottom, 4)
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String
    /// False when the value is not a declared fact but a statement ABOUT its absence
    /// ("Not declared", "Not applicable (HLG)"). Rendered muted + italic — the same
    /// convention `AudioTrackRow` uses for inferred/undeclared layouts — so a non-value
    /// can never be misread as something the file actually said.
    var isFact: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(.caption, design: .default))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 16)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(isFact ? 0.92 : 0.5))
                .italic(!isFact)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }
}

/// One caption or subtitle service: what it is, which service, in what language — and, where
/// something counted, whether it is actually carrying anything.
///
/// ⚠️ A PLAIN READOUT, AND NOT A BUTTON — deliberately unlike `AudioTrackRow`. Nothing in the app
/// can select or display an embedded caption service: the Aa control and `CaptionController` are
/// an SRT-sidecar feature and know nothing about these rows. `AudioTrackRow` only grows an
/// affordance where the engine can honour one, and here it cannot honour any, so this row stays
/// inert. A clickable caption row would promise a feature that does not exist.
private struct TextTrackRow: View {
    let track: TextTrackInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(track.kind)
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 16)
                Text(track.summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.trailing)
            }
            // Absent when nothing was measured — a row that cannot speak to data presence says
            // nothing about it, rather than implying health by staying quiet in the same shape a
            // healthy row uses.
            if let statement = track.dataPresence.statement {
                HStack(alignment: .firstTextBaseline) {
                    Spacer(minLength: 0)
                    Text(statement)
                        .font(.system(.caption2, design: .monospaced))
                        // A DECLARED SERVICE CARRYING NOTHING IS THE FINDING THIS ROW EXISTS FOR,
                        // so it is the state that gets colour; a healthy service stays as quiet as
                        // the audio rows' second line. Amber, not red: the file is not malformed —
                        // every packet is valid and correctly timed — it is a question for whoever
                        // cut it, which is exactly the register QC wants.
                        .foregroundStyle(track.dataPresence.carriesData
                                         ? Color.white.opacity(0.5)
                                         : Color.orange.opacity(0.9))
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Mastering Display Color Volume (ST 2086) — the display the content was graded on.
/// Read-only: Manifold shows what the file declares and does not tone-map from it.
private struct MasteringDisplaySection: View {
    let hdr10: HDR10StaticMetadata
    let transferCode: Int?

    var body: some View {
        let presence = hdr10.mdcvPresence(transferCode: transferCode)
        let m = hdr10.mastering

        // Absent (or declared-but-empty): one honest row saying so, and nothing that
        // could pass for a value.
        if let m, m.hasPrimaries || m.hasLuminance {
            if m.hasPrimaries {
                MetadataRow(label: "Mastering", value: m.primariesName)
                // The coordinates themselves — the only way "Custom" means anything, and
                // the receipt behind the named case.
                PrimaryRow(channel: "R", xy: m.red)
                PrimaryRow(channel: "G", xy: m.green)
                PrimaryRow(channel: "B", xy: m.blue)
                MetadataRow(label: "White Point", value: whitePointValue(m))
            } else {
                MetadataRow(label: "Mastering", value: "Primaries not declared", isFact: false)
            }

            if m.hasLuminance {
                MetadataRow(label: "Max Luminance",
                            value: HDR10StaticMetadata.nitsString(m.maxLuminance))
                MetadataRow(label: "Min Luminance",
                            value: HDR10StaticMetadata.nitsString(m.minLuminance))
            } else {
                MetadataRow(label: "Luminance", value: "Not declared", isFact: false)
            }
        } else {
            MetadataRow(label: "Mastering", value: presence.label, isFact: presence.isFact)
        }
    }

    private func whitePointValue(_ m: MasteringDisplayInfo) -> String {
        guard let name = m.whitePointName else { return m.whitePoint.string }
        return "\(m.whitePoint.string) · \(name)"
    }
}

/// Content Light Level (CTA-861.3) — MaxCLL/MaxFALL, plain nits. A separate block from
/// the mastering display, in different units, about a different subject: kept apart.
private struct ContentLightSection: View {
    let hdr10: HDR10StaticMetadata
    let transferCode: Int?

    var body: some View {
        let presence = hdr10.clliPresence(transferCode: transferCode)

        if let c = hdr10.contentLight {
            MetadataRow(label: "MaxCLL",
                        value: lightValue(c.maxCLL, unspecified: c.maxCLLIsUnspecified),
                        isFact: !c.maxCLLIsUnspecified)
            MetadataRow(label: "MaxFALL",
                        value: lightValue(c.maxFALL, unspecified: c.maxFALLIsUnspecified),
                        isFact: !c.maxFALLIsUnspecified)
        } else {
            MetadataRow(label: "Content Light", value: presence.label, isFact: presence.isFact)
        }
    }

    /// CTA-861.3 defines 0 as "unknown", not as zero nits — so a 0 is reported as the
    /// non-declaration it is rather than printed as a measurement.
    private func lightValue(_ v: Int, unspecified: Bool) -> String {
        unspecified ? "Unspecified (0)" : "\(v) nits"
    }
}

/// One mastering-display primary's xy coordinate — the small monospaced detail line,
/// styled like `AudioTrackRow`'s secondary row.
private struct PrimaryRow: View {
    let channel: String
    let xy: CIExy

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(channel)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            Spacer(minLength: 16)
            Text(xy.string)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 1)
    }
}

/// Segmented Auto / Full / Legal control for asserting a clip's color range,
/// placed under the Range row so the user can correct an untagged/mistagged file
/// right where its tag state is shown.
private struct RangeOverrideRow: View {
    @Binding var selection: RangeOverride

    var body: some View {
        HStack(alignment: .center) {
            Text("Override")
                .font(.system(.caption, design: .default))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 16)
            Picker("", selection: $selection) {
                ForEach(RangeOverride.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }
}

private struct AudioTrackRow: View {
    let index: Int
    let track: AudioTrackInfo
    let showIndex: Bool
    /// This is the track feeding the speakers, the meters and SDI right now.
    var isMonitored: Bool = false
    /// The engine can actually honour a switch (more than one selectable track).
    var selectable: Bool = false
    var select: () -> Void = {}

    /// Declared layouts read at full confidence; inferred/undeclared are muted
    /// so a guess never looks like a fact.
    private var layoutOpacity: Double {
        track.layoutConfidence == .declared ? 0.92 : 0.5
    }

    var body: some View {
        // The row stays a plain readout unless a switch is genuinely available — the inspector's
        // job is to report what things ARE, and it should only grow an affordance where that
        // affordance works.
        if selectable {
            Button(action: select) { rowBody }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help(isMonitored ? "Monitoring this track"
                                  : "Monitor this track — speakers, meters and SDI all follow")
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                // The monitored track is marked rather than merely highlighted: with three rows of
                // near-identical shape, a brightness difference alone is not a reliable read. Only
                // drawn where a choice exists — a single-track file has nothing to distinguish, and
                // the marker would just indent a row that reads fine as it is.
                if selectable {
                    Image(systemName: isMonitored ? "speaker.wave.2.fill" : "speaker")
                        .font(.system(size: 9))
                        .foregroundStyle(isMonitored ? Color.green : .white.opacity(0.3))
                }
                Text(showIndex ? "Track \(index + 1)" : "Track")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 16)
                (
                    Text("\(track.codecName) · ")
                        .foregroundStyle(.white.opacity(0.92))
                    + Text(track.layoutName)
                        .foregroundStyle(.white.opacity(layoutOpacity))
                        .italic(track.layoutConfidence != .declared)
                )
                .font(.system(.caption, design: .monospaced))
            }
            HStack(alignment: .firstTextBaseline) {
                Spacer(minLength: 0)
                Text("\(track.sampleRateString) · \(track.bitDepthString) · \(track.dataRateString)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.vertical, 3)
    }
}
