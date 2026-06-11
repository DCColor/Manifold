import SwiftUI
import IrisCore

/// A floating, translucent panel showing the loaded clip's technical metadata.
/// Summoned via the info button or the "I" shortcut; matches the HUD aesthetic.
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
                MetadataRow(label: "Container", value: m.container)

                Divider()
                    .overlay(.white.opacity(0.15))
                    .padding(.vertical, 6)

                MetadataRow(label: "Primaries", value: m.labeled(m.colorPrimaries, m.colorPrimariesCode))
                MetadataRow(label: "Transfer", value: m.labeled(m.transferFunction, m.transferFunctionCode))
                MetadataRow(label: "Matrix", value: m.labeled(m.colorMatrix, m.colorMatrixCode))
                MetadataRow(label: "nclc", value: m.nclcTriple)
            } else {
                Text("No media loaded")
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// One label/value row in the inspector.
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
