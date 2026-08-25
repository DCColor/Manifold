//
//  RTCPNack.c
//  Manifold
//
//  RFC 4585 §6.2.1:
//
//      0                   1                   2                   3
//      |V=2|P|  FMT=1   |    PT=205     |            length             |
//      |                      SSRC of packet sender                     |
//      |                      SSRC of media source                      |
//      |             PID               |             BLP               |  × N
//
//  One FCI field carries a sequence number (PID) plus a bitmask (BLP) of the SIXTEEN sequence
//  numbers after it. That is the whole reason a burst is cheap to ask for: seventeen consecutive
//  missing packets cost one four-byte field, so the measured worst second on the Wi-Fi path —
//  48 packets gone at once — is three fields in one small packet rather than 48 packets of
//  feedback aimed at a link that is already failing. See BURSTS AND STORMS in H264Depacketizer.c.
//

#include "RTCPNack.h"

size_t ManifoldRTCPBuildNack(uint8_t *out, size_t capacity, uint32_t ssrc,
                             const uint16_t *seqs, unsigned int count) {
    if (!out || !seqs || count == 0) return 0;
    if (capacity < MANIFOLD_RTCP_NACK_HEADER_BYTES + 4u) return 0;

    uint8_t *fields = out + MANIFOLD_RTCP_NACK_HEADER_BYTES;
    unsigned int fieldCount = 0;
    uint16_t pid = 0;

    for (unsigned int i = 0; i < count; i++) {
        const uint16_t seq = seqs[i];

        // ⚠️ THE BITMASK IS DELIBERATELY NOT CONTINUED ACROSS THE SEQUENCE-NUMBER WRAP.
        //
        // `seq > pid` is a PLAIN comparison, not modular arithmetic, so a list running
        // 65534, 65535, 0, 1 starts a fresh field at 0 instead of packing 0 and 1 into the
        // bitmask of 65534. Four extra bytes, once every 65536 packets — about every three
        // minutes at the measured packet rate.
        //
        // Reading RFC 4585 §6.2.1 alone, continuing the mask would be CORRECT: sequence numbers
        // are modulo 2^16, so the sixteen packets "immediately following" 65534 genuinely are
        // 65535, 0, 1, … But correct-per-spec is not the property that matters in a request
        // aimed at somebody else's parser. libdatachannel's own builder splits here — its
        // addMissingPacket compares `missingPacket < *fciPID` without wrapping — and a receiver
        // that reconstructs PID+i+1 the same non-modular way would read a continued mask as
        // asking for sequence numbers 65536 and 65537, which exist nowhere.
        //
        // The failure that buys is small (a handful of packets across each wrap are never asked
        // for) and the failure it avoids is not (the server retransmits nothing useful, spending
        // the exact bandwidth this feature exists to conserve). Four bytes is the right price.
        // A differential test pins this to libdatachannel's output byte for byte.
        const uint16_t offset = (uint16_t)(seq - pid);
        if (fieldCount > 0 && seq > pid && offset <= 16u) {
            // BLP bit i means "PID + i + 1 is also missing", so an offset of 1 is bit 0.
            uint8_t *blp = fields + 4u * (fieldCount - 1u) + 2u;
            const uint16_t bits = (uint16_t)(((uint16_t)blp[0] << 8 | (uint16_t)blp[1]) |
                                             (uint16_t)(1u << (offset - 1u)));
            blp[0] = (uint8_t)(bits >> 8);
            blp[1] = (uint8_t)bits;
            continue;
        }
        if (fieldCount >= MANIFOLD_RTCP_NACK_MAX_FIELDS) break;
        if (MANIFOLD_RTCP_NACK_HEADER_BYTES + 4u * (fieldCount + 1u) > capacity) break;
        uint8_t *field = fields + 4u * fieldCount;
        field[0] = (uint8_t)(seq >> 8);
        field[1] = (uint8_t)seq;
        field[2] = 0;
        field[3] = 0;
        pid = seq;
        fieldCount++;
    }
    if (fieldCount == 0) return 0;

    const size_t size = MANIFOLD_RTCP_NACK_HEADER_BYTES + 4u * (size_t)fieldCount;
    out[0] = (uint8_t)(0x80u | 1u);                        // V=2, P=0, FMT=1 (Generic NACK)
    out[1] = 205u;                                         // PT = RTPFB (RFC 4585 §6.1)
    const uint16_t words = (uint16_t)(size / 4u - 1u);     // length is 32-bit words MINUS ONE
    out[2] = (uint8_t)(words >> 8);
    out[3] = (uint8_t)words;
    for (unsigned int i = 0; i < 2u; i++) {                // packet sender, then media source
        uint8_t *f = out + 4u + 4u * i;
        f[0] = (uint8_t)(ssrc >> 24);
        f[1] = (uint8_t)(ssrc >> 16);
        f[2] = (uint8_t)(ssrc >> 8);
        f[3] = (uint8_t)ssrc;
    }
    return size;
}
