//
//  H264AnnexBScanner.c
//  Manifold
//
//  See H264AnnexBScanner.h for the contract and for why this is stateless.
//

#include "H264AnnexBScanner.h"

/// Index of the next 00 00 01 at or after `from`, or `size` if there is none.
///
/// THIS IS THE WHOLE PARSER, and it is a plain byte search rather than anything
/// cleverer because emulation prevention makes it exact: 00 00 01 cannot occur
/// inside a NAL payload, so a match is always a real start code and never a
/// fragment of slice data. That guarantee is the reason nothing upstream in
/// Manifold removes emulation prevention bytes — see the block comment in
/// H264AccessUnitBuilder.c, which owes this function its correctness.
///
/// Searching for the THREE-byte core also handles the four-byte form for free:
/// 00 00 00 01 simply matches at its second byte, and the leading zero is left
/// behind as trailing padding on the previous NAL, where the caller strips it.
static size_t MDFindStartCode(const uint8_t *data, size_t size, size_t from) {
    if (size < 3) return size;
    for (size_t i = from; i + 3 <= size; i++) {
        if (data[i] == 0x00 && data[i + 1] == 0x00 && data[i + 2] == 0x01) return i;
    }
    return size;
}

ManifoldH264AnnexBScanResult ManifoldH264AnnexBScan(const uint8_t *data, size_t size,
                                                    ManifoldH264NALHandler handler,
                                                    void *context) {
    ManifoldH264AnnexBScanResult result = { 0, 0, 0, false };
    if (!data || size < 4) {
        // Fewer than four bytes cannot hold a start code plus one NAL header byte.
        result.bytesBeforeFirstStartCode = data ? size : 0;
        return result;
    }

    size_t startCode = MDFindStartCode(data, size, 0);
    if (startCode == size) {
        // No start code anywhere: not Annex-B, or pure junk. The whole run is garbage.
        result.bytesBeforeFirstStartCode = size;
        return result;
    }
    result.foundStartCode = true;

    // Zeros immediately preceding the start code ARE part of it — Annex-B's
    // leading_zero_8bits, of which a four-byte start code is the one-byte case.
    // Counting them as garbage would report 1 discarded byte per packet on a
    // perfectly healthy stream and make this counter useless for spotting the
    // thing it exists for: a genuine mid-stream join or a corrupt payload.
    size_t firstRealByte = startCode;
    while (firstRealByte > 0 && data[firstRealByte - 1] == 0x00) firstRealByte--;
    result.bytesBeforeFirstStartCode = firstRealByte;

    while (startCode < size) {
        const size_t nalStart = startCode + 3;
        // The NAL runs to the next start code, or to the end of the run.
        const size_t next = (nalStart < size) ? MDFindStartCode(data, size, nalStart) : size;

        // TRAILING ZEROS ARE NOT PART OF THE NAL. Two different things put them
        // here and stripping serves both: the extra 00 of a four-byte start code
        // (which the search above deliberately left on this NAL's tail), and
        // Annex-B's own trailing_zero_8bits padding at the end of a run.
        //
        // This also strips cabac_zero_words — 16-bit zero words an encoder may
        // append to a slice to meet a bitrate conformance floor. That is
        // harmless: they carry no picture data, every decoder ignores them, and
        // there is no way to tell them apart from start-code padding anyway
        // without parsing the slice.
        size_t nalEnd = next;
        while (nalEnd > nalStart && data[nalEnd - 1] == 0x00) nalEnd--;

        if (nalEnd > nalStart) {
            result.nalCount++;
            if (handler) handler(data + nalStart, nalEnd - nalStart, context);
        } else {
            // Back-to-back start codes. Malformed, but the rest of the run is
            // still readable, so count it and carry on rather than bailing out.
            result.emptyNALs++;
        }

        if (next == size) break;
        startCode = next;
    }

    return result;
}
