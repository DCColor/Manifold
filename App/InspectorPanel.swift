import SwiftUI
import ManifoldCore

/// A floating, translucent panel showing the loaded clip's technical metadata.
struct InspectorPanel: View {
    let metadata: VideoMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inspector")
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 8)

            if let m = metadata {
                MetadataRow(label: "Codec", value: m.codecName)
                MetadataRow(label: "Resolution", value: m.resolutionString)
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
                MetadataRow(label: "nclc", value: m.nclcTriple)

                if !m.audioTracks.isEmpty {
                    Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)
                    SectionHeader(m.audioTracks.count == 1 ? "Audio" : "Audio (\(m.audioTracks.count))")
                    ForEach(Array(m.audioTracks.enumerated()), id: \.offset) { index, track in
                        AudioTrackRow(index: index, track: track, showIndex: m.audioTracks.count > 1)
                    }
                }

                if !m.textTracks.isEmpty {
                    Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)
                    SectionHeader(m.textTracks.count == 1 ? "Timed Text" : "Timed Text (\(m.textTracks.count))")
                    ForEach(Array(m.textTracks.enumerated()), id: \.offset) { index, track in
                        MetadataRow(label: track.kind, value: track.summary)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(.caption, design: .default))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 16)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 3)
    }
}

private struct AudioTrackRow: View {
    let index: Int
    let track: AudioTrackInfo
    let showIndex: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(showIndex ? "Track \(index + 1)" : "Track")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 16)
                Text("\(track.codecName) · \(track.layoutName)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
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
