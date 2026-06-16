import Foundation

/// Reads start timecode from a MOV/MP4 by walking the atom tree to the `tmcd`
/// (timecode) track — the approach proven in Flip. Reads the start frame count
/// from the timecode sample and the rate/drop-frame from the sample description,
/// then formats with correct SMPTE notation (";" before frames = drop-frame).
///
/// MOV/MP4 only. MXF timecode (KLV) arrives with the ffmpeg backend later.
public enum TimecodeReader {

    public struct Result: Equatable, Sendable {
        public var timecode: String   // "01:00:00:00" or "01:00:00;00"
        public var dropFrame: Bool
        public var startFrame: Int     // raw start frame count
        public var nfr: Int            // integer frames per second (e.g. 24, 30)
        public var fps: Double         // exact rate (e.g. 23.976)
    }

    public static func readStartTimecode(url: URL) -> Result? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        guard let moov = findTopLevelAtom(fh, type: "moov") else { return nil }

        // Walk each trak; find the one whose hdlr subtype is 'tmcd'.
        for trak in childAtoms(fh, parent: moov, type: "trak") {
            guard let mdia = firstChild(fh, parent: trak, type: "mdia") else { continue }
            guard isTimecodeHandler(fh, mdia: mdia) else { continue }
            guard let minf = firstChild(fh, parent: mdia, type: "minf"),
                  let stbl = firstChild(fh, parent: minf, type: "stbl") else { continue }

            // Sample description (stsd) holds rate + drop-frame flag.
            guard let stsd = firstChild(fh, parent: stbl, type: "stsd"),
                  let tmcdInfo = parseTmcd(fh, stsd: stsd) else { continue }

            // Chunk offset (stco/co64) points at the timecode sample in the file.
            guard let frameCount = readStartFrameCount(fh, stbl: stbl) else { continue }

            let tc = format(frameCount: Int(frameCount),
                            nfr: tmcdInfo.numberOfFrames,
                            fps: tmcdInfo.fps,
                            dropFrame: tmcdInfo.dropFrame)
            return Result(timecode: tc, dropFrame: tmcdInfo.dropFrame,
                          startFrame: Int(frameCount), nfr: tmcdInfo.numberOfFrames, fps: tmcdInfo.fps)
        }
        return nil
    }

    // MARK: - Atom walking

    private struct Atom { var offset: UInt64; var size: UInt64; var dataOffset: UInt64; var dataSize: UInt64 }

    private static func readU32(_ fh: FileHandle, at offset: UInt64) -> UInt32? {
        try? fh.seek(toOffset: offset)
        guard let d = try? fh.read(upToCount: 4), d.count == 4 else { return nil }
        return d.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
    private static func readU64(_ fh: FileHandle, at offset: UInt64) -> UInt64? {
        try? fh.seek(toOffset: offset)
        guard let d = try? fh.read(upToCount: 8), d.count == 8 else { return nil }
        return d.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }
    private static func readType(_ fh: FileHandle, at offset: UInt64) -> String? {
        try? fh.seek(toOffset: offset)
        guard let d = try? fh.read(upToCount: 4), d.count == 4 else { return nil }
        return String(bytes: d, encoding: .ascii)
    }

    /// Parse an atom header at `offset`, returning its bounds.
    private static func atom(_ fh: FileHandle, at offset: UInt64) -> Atom? {
        guard let size32 = readU32(fh, at: offset), let _ = readType(fh, at: offset + 4) else { return nil }
        var size = UInt64(size32)
        var dataOffset = offset + 8
        if size32 == 1 {              // 64-bit extended size
            guard let big = readU64(fh, at: offset + 8) else { return nil }
            size = big
            dataOffset = offset + 16
        }
        guard size >= 8 else { return nil }
        return Atom(offset: offset, size: size, dataOffset: dataOffset, dataSize: offset + size - dataOffset)
    }

    private static func fileLength(_ fh: FileHandle) -> UInt64 {
        (try? fh.seekToEnd()) ?? 0
    }

    private static func findTopLevelAtom(_ fh: FileHandle, type: String) -> Atom? {
        var offset: UInt64 = 0
        let end = fileLength(fh)
        while offset + 8 <= end {
            guard let a = atom(fh, at: offset), let t = readType(fh, at: offset + 4) else { return nil }
            if t == type { return a }
            offset += a.size
            if a.size == 0 { break }
        }
        return nil
    }

    /// All direct child atoms of `parent` with the given type.
    private static func childAtoms(_ fh: FileHandle, parent: Atom, type: String) -> [Atom] {
        var result: [Atom] = []
        var offset = parent.dataOffset
        let end = parent.dataOffset + parent.dataSize
        while offset + 8 <= end {
            guard let a = atom(fh, at: offset), let t = readType(fh, at: offset + 4) else { break }
            if t == type { result.append(a) }
            if a.size == 0 { break }
            offset += a.size
        }
        return result
    }

    private static func firstChild(_ fh: FileHandle, parent: Atom, type: String) -> Atom? {
        childAtoms(fh, parent: parent, type: type).first
    }

    /// Is this mdia's handler a timecode ('tmcd') handler?
    private static func isTimecodeHandler(_ fh: FileHandle, mdia: Atom) -> Bool {
        guard let hdlr = firstChild(fh, parent: mdia, type: "hdlr") else { return false }
        // hdlr layout: 4 version/flags, 4 predefined, 4 handler subtype @ dataOffset+8
        guard let subtype = readType(fh, at: hdlr.dataOffset + 8) else { return false }
        return subtype == "tmcd"
    }

    // MARK: - tmcd sample description

    private struct TmcdInfo { var fps: Double; var numberOfFrames: Int; var dropFrame: Bool }

    private static func parseTmcd(_ fh: FileHandle, stsd: Atom) -> TmcdInfo? {
        // stsd: 4 version/flags, 4 entry count, then the first sample entry.
        // Sample entry: 4 size, 4 format('tmcd'), 6 reserved, 2 data-ref-index,
        // then tmcd payload: 4 reserved, 4 flags, 4 timeScale, 4 frameDuration, 1 numberOfFrames.
        let entryStart = stsd.dataOffset + 8
        guard let entrySize = readU32(fh, at: entryStart),
              let fmt = readType(fh, at: entryStart + 4), fmt == "tmcd",
              entrySize >= 34 else { return nil }
        let payload = entryStart + 16
        guard let flags = readU32(fh, at: payload + 4),
              let timeScale = readU32(fh, at: payload + 8),
              let frameDuration = readU32(fh, at: payload + 12) else { return nil }
        // numberOfFrames is 1 byte at payload+16
        try? fh.seek(toOffset: payload + 16)
        guard let nfrData = try? fh.read(upToCount: 1), let nfrByte = nfrData.first else { return nil }
        let fps = frameDuration > 0 ? Double(timeScale) / Double(frameDuration) : 0
        let dropFrame = (flags & 0x0001) != 0
        return TmcdInfo(fps: fps, numberOfFrames: Int(nfrByte), dropFrame: dropFrame)
    }

    /// Read the start frame count from the timecode sample (stco/co64 first offset).
    private static func readStartFrameCount(_ fh: FileHandle, stbl: Atom) -> UInt32? {
        if let stco = firstChild(fh, parent: stbl, type: "stco") {
            // stco: 4 version/flags, 4 entry count, then 4-byte offsets.
            guard let firstOffset = readU32(fh, at: stco.dataOffset + 8) else { return nil }
            return readU32(fh, at: UInt64(firstOffset))
        } else if let co64 = firstChild(fh, parent: stbl, type: "co64") {
            guard let firstOffset = readU64(fh, at: co64.dataOffset + 8) else { return nil }
            return readU32(fh, at: firstOffset)
        }
        return nil
    }

    // MARK: - Formatting (Flip's proven math, correct SMPTE ; notation)

    public static func format(frameCount: Int, nfr: Int, fps: Double, dropFrame: Bool) -> String {
        guard nfr > 0 else { return "—" }
        let nfrI = Int(nfr)
        var fc = frameCount
        let hh: Int, mm: Int, ss: Int, ff: Int

        if dropFrame {
            let dropFrames = Int((fps * 0.066666).rounded())   // 2 for 29.97, 4 for 59.94
            let framesPer10Min = 10 * 60 * nfrI - 9 * dropFrames
            let framesPerMin = 60 * nfrI - dropFrames
            let d = fc / framesPer10Min
            var m = fc % framesPer10Min
            if m < dropFrames { m = dropFrames }
            let adjusted = fc + dropFrames * 9 * d + dropFrames * ((m - dropFrames) / framesPerMin)
            fc = adjusted
        }

        ff = fc % nfrI
        let totalSecs = fc / nfrI
        ss = totalSecs % 60
        let totalMins = totalSecs / 60
        mm = totalMins % 60
        hh = totalMins / 60

        // Correct SMPTE: ";" before frames denotes drop-frame; ":" non-drop.
        let sep = dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
    }
}
