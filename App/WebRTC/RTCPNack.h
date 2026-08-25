//
//  RTCPNack.h
//  Manifold
//
//  RFC 4585 §6.2.1 Generic NACK — the wire encoding for a receive-side retransmission request.
//
//  PURE C, NO DEPENDENCIES, and split out of DataChannelBridge.m for one reason: a wrong bit in
//  a BLP bitmask is a SILENT failure. The server either ignores the request or retransmits a
//  packet nobody asked for; nothing in this app would notice either. Byte-laying that cannot be
//  observed at runtime has to be observable at test time instead, and a `.m` full of Foundation
//  and libdatachannel is not testable in isolation. This is.
//
//  ⚠️ libdatachannel HAS these builders — RtcpNack::preparePacket and RtcpNack::addMissingPacket
//  are real, exported symbols in the vendored archive. They are not used because they are C++
//  and DataChannelBridge.m is a `.m`; reaching them would mean compiling the whole bridge as
//  Objective-C++ to save the fifty lines below. The output here is byte-identical to theirs,
//  which is asserted by a differential test rather than asserted by this comment.
//

#ifndef MANIFOLD_RTCP_NACK_H
#define MANIFOLD_RTCP_NACK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bytes in the fixed part: the RTCP header, the packet-sender SSRC, and the media-source SSRC.
#define MANIFOLD_RTCP_NACK_HEADER_BYTES 12u

/// The most FCI fields one packet will carry — one per sequence number in the worst case, where
/// none of them are close enough together to share a bitmask. Matches MD_NACK_SEQS_PER_SERVICE
/// in H264Depacketizer.c, which is what bounds the list handed to the sink.
#define MANIFOLD_RTCP_NACK_MAX_FIELDS 64u

/// Worst-case packet size: 268 bytes, comfortably inside any path MTU, so no caller ever has to
/// cap the field count to avoid fragmentation.
#define MANIFOLD_RTCP_NACK_MAX_BYTES \
    (MANIFOLD_RTCP_NACK_HEADER_BYTES + 4u * MANIFOLD_RTCP_NACK_MAX_FIELDS)

/// Encodes a Generic NACK for `seqs` into `out`, returning the byte count (0 if nothing fits).
///
/// `seqs` MUST be in ascending sequence order, wrap included — that is what lets consecutive
/// sequence numbers share one field's bitmask, and it is guaranteed by the depacketizer's sink
/// contract. Out-of-order or duplicate input still produces a VALID packet, just a larger one.
/// A run that crosses the 16-bit wrap starts a new field rather than continuing the bitmask;
/// the .c explains why that is deliberate and what it costs.
///
/// Both SSRC fields carry `ssrc`, the media source. A recvonly receiver has no SSRC of its own,
/// and this is what libdatachannel itself puts in both fields for NACK and for the PLI that is
/// known to work against this server.
size_t ManifoldRTCPBuildNack(uint8_t *out, size_t capacity, uint32_t ssrc,
                             const uint16_t *seqs, unsigned int count);

#ifdef __cplusplus
}
#endif

#endif /* MANIFOLD_RTCP_NACK_H */
