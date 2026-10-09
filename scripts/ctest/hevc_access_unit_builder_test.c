//
//  hevc_access_unit_builder_test.c
//  Manifold — C harness for App/H264/HEVCAccessUnitBuilder (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10,
//  Stage 3, decision 9). Run by scripts/ctest/run.sh, which compiles it with the real scanner, both
//  builders and the SRT reader, under ASan and UBSan.
//
//  Synthetic NAL units, built header-first, so every case states exactly what it feeds. Everything
//  goes through the path the app uses: Annex-B bytes → ManifoldSRTAccessUnitReaderSubmitPacket →
//  the HEVC builder → the reader's access unit. The random-access gate is the C state machine the
//  decoder calls.
//

#include "SRTAccessUnitReader.h"
#include "HEVCAccessUnitBuilder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    fprintf(stderr, "FAIL %s:%d: ", __func__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

// ── NAL construction ───────────────────────────────────────────────────────────────────────

typedef struct { uint8_t bytes[4096]; size_t size; } Buf;

static void put(Buf *b, const uint8_t *p, size_t n) { memcpy(b->bytes + b->size, p, n); b->size += n; }

/// Appends a 4-byte start code, then a NAL: the two-byte header for `type` at `layer`, temporal id 0,
/// then `payload`.
static void nal(Buf *b, uint8_t type, uint8_t layer, const uint8_t *payload, size_t n) {
    static const uint8_t sc[4] = { 0, 0, 0, 1 };
    put(b, sc, 4);
    const uint8_t header[2] = { (uint8_t)((type << 1) | (layer >> 5)), (uint8_t)(((layer & 0x1F) << 3) | 1) };
    put(b, header, 2);
    put(b, payload, n);
}

/// The same with a 3-byte start code.
static void nal3(Buf *b, uint8_t type, const uint8_t *payload, size_t n) {
    static const uint8_t sc[3] = { 0, 0, 1 };
    put(b, sc, 3);
    const uint8_t header[2] = { (uint8_t)(type << 1), 1 };
    put(b, header, 2);
    put(b, payload, n);
}

// A slice payload: first_slice_segment_in_pic_flag set, then filler bits. Contents beyond the flag
// do not matter to the builder.
static const uint8_t SLICE[]  = { 0xAF, 0x11, 0x22, 0x33 };
static const uint8_t SLICE2[] = { 0x2F, 0x44, 0x55 };                 // a second slice segment
static const uint8_t ESCAPED[] = { 0xAF, 0x00, 0x00, 0x03, 0x01, 0x7E }; // 00 00 03 inside
static const uint8_t VPS_A[] = { 0x0C, 0x01, 0xFF, 0xFF };
static const uint8_t SPS_A[] = { 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90 };
static const uint8_t SPS_B[] = { 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x91 };
static const uint8_t PPS_0[] = { 0xC1, 0x72, 0xB4 };                  // ue(0) = '1' → id 0
static const uint8_t PPS_0b[] = { 0xC1, 0x72, 0xB5 };                 // id 0, different bytes
static const uint8_t PPS_1[] = { 0x41, 0x72 };                        // ue '010' → id 1
static const uint8_t PPS_5[] = { 0x31, 0x72 };                        // ue '00110' → id 5
static const uint8_t PPS_64[] = { 0x01, 0x04, 0x80 };                 // ue '0000001000001' → 64: out of range
static const uint8_t SEI[]   = { 0x89, 0x04, 0x01, 0x02, 0x03, 0x04, 0x80 };

// ── The reader under test, and what it handed out ──────────────────────────────────────────

typedef struct {
    int count;
    ManifoldSRTAccessUnit last;
    uint8_t data[4096]; size_t dataSize;
    uint8_t ppsList[4096]; size_t ppsListSize;
    uint8_t sps[1024]; size_t spsSize;
} Sink;

static void handler(const ManifoldSRTAccessUnit *au, void *context) {
    Sink *sink = context;
    sink->count++;
    sink->last = *au;
    memcpy(sink->data, au->data, au->size); sink->dataSize = au->size;
    sink->ppsListSize = au->ppsListSize;
    if (au->ppsList) memcpy(sink->ppsList, au->ppsList, au->ppsListSize);
    sink->spsSize = au->spsSize;
    if (au->sps) memcpy(sink->sps, au->sps, au->spsSize);
}

static ManifoldSRTAccessUnitReader *make(Sink *sink) {
    memset(sink, 0, sizeof(*sink));
    ManifoldSRTAccessUnitReader *r = ManifoldSRTAccessUnitReaderCreate(ManifoldSRTVideoCodecHEVC);
    ManifoldSRTAccessUnitReaderSetHandler(r, handler, sink);
    return r;
}

static void submit(ManifoldSRTAccessUnitReader *r, const Buf *b, int64_t pts) {
    ManifoldSRTAccessUnitReaderSubmitPacket(r, b->bytes, b->size, pts, pts - 3600);
}

/// The n-th length-prefixed NAL of a run: its type and size, or -1.
static int nth(const uint8_t *run, size_t size, int n, size_t *outSize, const uint8_t **outNal) {
    size_t at = 0;
    for (int i = 0; at + 4 <= size; i++) {
        const size_t len = ((size_t)run[at] << 24) | ((size_t)run[at+1] << 16) | ((size_t)run[at+2] << 8) | run[at+3];
        if (at + 4 + len > size) return -1;
        if (i == n) { if (outSize) *outSize = len; if (outNal) *outNal = run + at + 4; return (run[at+4] >> 1) & 0x3F; }
        at += 4 + len;
    }
    return -1;
}

static int count(const uint8_t *run, size_t size) { int n = 0; while (nth(run, size, n, NULL, NULL) >= 0) n++; return n; }

// ── Cases ──────────────────────────────────────────────────────────────────────────────────

/// NAL splitting: 3- and 4-byte start codes mixed, AUD dropped, both SEI kept, parameter sets out of
/// band, lengths exact, emulation prevention untouched.
static void testSplitting(void) {
    Sink s; ManifoldSRTAccessUnitReader *r = make(&s);
    Buf b = {0};
    const uint8_t aud[] = { 0x50 };
    nal(&b, 35, 0, aud, 1);                    // AUD
    nal(&b, 32, 0, VPS_A, sizeof VPS_A);
    nal3(&b, 33, SPS_A, sizeof SPS_A);
    nal(&b, 34, 0, PPS_0, sizeof PPS_0);
    nal3(&b, 39, SEI, sizeof SEI);             // prefix SEI
    nal(&b, 19, 0, ESCAPED, sizeof ESCAPED);   // IDR_W_RADL, first segment, escaped payload
    nal3(&b, 19, SLICE2, sizeof SLICE2);       // second segment
    nal(&b, 40, 0, SEI, sizeof SEI);           // suffix SEI
    const uint8_t pad[2] = { 0, 0 }; put(&b, pad, 2);   // trailing zero padding
    submit(r, &b, 90000);

    CHECK(s.count == 1, "one access unit, got %d", s.count);
    CHECK(s.last.codec == ManifoldSRTVideoCodecHEVC, "codec");
    CHECK(count(s.data, s.dataSize) == 4, "4 NALs in the AU (SEI, slice, slice, SEI), got %d", count(s.data, s.dataSize));
    size_t n; const uint8_t *p;
    CHECK(nth(s.data, s.dataSize, 0, &n, NULL) == 39 && n == 2 + sizeof SEI, "prefix SEI first, length %zu", n);
    CHECK(nth(s.data, s.dataSize, 1, &n, &p) == 19 && n == 2 + sizeof ESCAPED, "IDR slice, length %zu", n);
    CHECK(memcmp(p + 2, ESCAPED, sizeof ESCAPED) == 0, "emulation prevention left in");
    CHECK(nth(s.data, s.dataSize, 2, &n, NULL) == 19 && n == 2 + sizeof SLICE2, "second segment");
    CHECK(nth(s.data, s.dataSize, 3, &n, NULL) == 40, "suffix SEI last");
    CHECK(s.last.keyframe && s.last.randomAccessType == 19, "IDR is random access (type %d)", s.last.randomAccessType);
    CHECK(!s.last.rasl, "not RASL");
    CHECK(s.last.vpsSize == 2 + sizeof VPS_A && s.last.spsSize == 2 + sizeof SPS_A, "VPS and SPS out of band");
    CHECK(s.last.ppsCount == 1 && s.last.ppsListSize == 4 + 2 + sizeof PPS_0, "one PPS, packed");
    CHECK(s.last.pps == NULL && s.last.ppsSize == 0, "H.264's pps field unused on HEVC");
    CHECK(s.last.parameterSetsChanged, "first parameter sets are a change");
    CHECK(s.last.pts == 90000 && s.last.dts == 90000 - 3600, "timestamps through");
    ManifoldHEVCAccessUnitBuilderStats st; ManifoldSRTAccessUnitReaderCopyHEVCBuilderStats(r, &st);
    CHECK(st.nalAUD == 1 && st.nalVPS == 1 && st.nalSPS == 1 && st.nalPPS == 1 && st.nalSEI == 2 && st.nalIDR == 2,
          "NAL counts AUD %llu VPS %llu SPS %llu PPS %llu SEI %llu IDR %llu",
          st.nalAUD, st.nalVPS, st.nalSPS, st.nalPPS, st.nalSEI, st.nalIDR);
    ManifoldH264AccessUnitBuilderStats h264; ManifoldSRTAccessUnitReaderCopyBuilderStats(r, &h264);
    CHECK(h264.accessUnits == 0 && h264.nalSPS == 0, "no H.264 builder on an HEVC reader");
    ManifoldSRTAccessUnitReaderDestroy(r);
}

/// The two-byte header: a TRAIL_R (type 1) is 0x02 0x01, which H.264's one-byte read would call type
/// 2. And every random-access type is a keyframe; nothing else is.
static void testTwoByteHeader(void) {
    Sink s; ManifoldSRTAccessUnitReader *r = make(&s);
    for (int type = 0; type <= 31; type++) {
        Buf b = {0};
        nal(&b, (uint8_t)type, 0, SLICE, sizeof SLICE);
        submit(r, &b, 1000 * type);
        const bool irap = type >= 16 && type <= 23;
        CHECK(s.last.keyframe == irap, "type %d keyframe %d", type, s.last.keyframe);
        CHECK(s.last.randomAccessType == (irap ? type : 0), "type %d randomAccessType %d", type, s.last.randomAccessType);
        CHECK(s.last.rasl == (type == 8 || type == 9), "type %d rasl %d", type, s.last.rasl);
    }
    CHECK(s.count == 32, "32 access units, got %d", s.count);
    ManifoldHEVCAccessUnitBuilderStats st; ManifoldSRTAccessUnitReaderCopyHEVCBuilderStats(r, &st);
    CHECK(st.nalBLA == 3 && st.nalIDR == 2 && st.nalCRA == 1 && st.nalReservedIRAP == 2 && st.nalRASL == 2 &&
          st.nalRADL == 2 && st.nalTrailing == 20, "VCL classes BLA %llu IDR %llu CRA %llu rsv %llu RASL %llu RADL %llu trail %llu",
          st.nalBLA, st.nalIDR, st.nalCRA, st.nalReservedIRAP, st.nalRASL, st.nalRADL, st.nalTrailing);
    CHECK(st.randomAccessUnits == 8 && st.raslAccessUnits == 2, "AU classes");
    ManifoldSRTAccessUnitReaderDestroy(r);
}

/// Parameter sets: repeats are not a change; a changed PPS is; two ids are both held in id order; a
/// new SPS clears the PPS table; an out-of-range id is ignored, counted.
static void testParameterSets(void) {
    Sink s; ManifoldSRTAccessUnitReader *r = make(&s);
    Buf b = {0};
    nal(&b, 32, 0, VPS_A, sizeof VPS_A); nal(&b, 33, 0, SPS_A, sizeof SPS_A); nal(&b, 34, 0, PPS_0, sizeof PPS_0);
    nal(&b, 21, 0, SLICE, sizeof SLICE);
    submit(r, &b, 0);
    CHECK(s.last.parameterSetsChanged, "first: changed");

    submit(r, &b, 3600);                       // the same parameter sets again (every IRAP)
    CHECK(!s.last.parameterSetsChanged, "repeat: not a change");

    Buf c = {0};
    nal(&c, 34, 0, PPS_0b, sizeof PPS_0b); nal(&c, 1, 0, SLICE, sizeof SLICE);
    submit(r, &c, 7200);
    CHECK(s.last.parameterSetsChanged, "changed PPS bytes: a change");
    CHECK(s.last.ppsCount == 1, "still one id");

    Buf d = {0};
    nal(&d, 34, 0, PPS_5, sizeof PPS_5); nal(&d, 34, 0, PPS_1, sizeof PPS_1); nal(&d, 1, 0, SLICE, sizeof SLICE);
    submit(r, &d, 10800);
    CHECK(s.last.parameterSetsChanged && s.last.ppsCount == 3, "ids 0, 1, 5 held: %u", s.last.ppsCount);
    // In id order: 0 (PPS_0b), 1, 5.
    size_t n; const uint8_t *p;
    nth(s.ppsList, s.ppsListSize, 0, &n, &p); CHECK(n == 2 + sizeof PPS_0b && memcmp(p + 2, PPS_0b, sizeof PPS_0b) == 0, "id 0 first");
    nth(s.ppsList, s.ppsListSize, 1, &n, &p); CHECK(n == 2 + sizeof PPS_1 && memcmp(p + 2, PPS_1, sizeof PPS_1) == 0, "id 1 second");
    nth(s.ppsList, s.ppsListSize, 2, &n, &p); CHECK(n == 2 + sizeof PPS_5 && memcmp(p + 2, PPS_5, sizeof PPS_5) == 0, "id 5 third");

    Buf e = {0};
    nal(&e, 34, 0, PPS_64, sizeof PPS_64); nal(&e, 1, 0, SLICE, sizeof SLICE);
    submit(r, &e, 14400);
    CHECK(!s.last.parameterSetsChanged && s.last.ppsCount == 3, "id 64 ignored");

    // A new SPS: the old PPS go; the encoder's re-sent one comes straight after.
    Buf f = {0};
    nal(&f, 33, 0, SPS_B, sizeof SPS_B); nal(&f, 34, 0, PPS_0, sizeof PPS_0); nal(&f, 21, 0, SLICE, sizeof SLICE);
    submit(r, &f, 18000);
    CHECK(s.last.parameterSetsChanged && s.last.ppsCount == 1, "new SPS clears the PPS table: %u", s.last.ppsCount);
    CHECK(s.spsSize == 2 + sizeof SPS_B && memcmp(s.sps + 2, SPS_B, sizeof SPS_B) == 0, "new SPS held");

    ManifoldHEVCAccessUnitBuilderStats st; ManifoldSRTAccessUnitReaderCopyHEVCBuilderStats(r, &st);
    CHECK(st.ppsIdUnreadable == 1 && st.ppsIdsMax == 3 && st.ppsIdsHeld == 1 && st.spsChanges == 1,
          "unreadable %llu max %u held %u spsChanges %llu", st.ppsIdUnreadable, st.ppsIdsMax, st.ppsIdsHeld, st.spsChanges);

    // A packet of parameter sets alone is no access unit, and the change rides on the next one.
    Buf g = {0};
    nal(&g, 34, 0, PPS_0b, sizeof PPS_0b);
    const int before = s.count;
    submit(r, &g, 21600);
    CHECK(s.count == before, "parameter sets alone: nothing emitted");
    Buf h = {0}; nal(&h, 1, 0, SLICE, sizeof SLICE);
    submit(r, &h, 25200);
    CHECK(s.last.parameterSetsChanged, "the change survives to the next access unit");
    ManifoldSRTAccessUnitReaderDestroy(r);
}

/// Decision 8: nuh_layer_id > 0 is dropped — a layer-1 SPS does not replace the base one, a layer-1
/// slice is not in the access unit, and a layer-1 IRAP does not make a keyframe.
static void testBaseLayerOnly(void) {
    Sink s; ManifoldSRTAccessUnitReader *r = make(&s);
    Buf b = {0};
    nal(&b, 32, 0, VPS_A, sizeof VPS_A); nal(&b, 33, 0, SPS_A, sizeof SPS_A); nal(&b, 34, 0, PPS_0, sizeof PPS_0);
    nal(&b, 33, 1, SPS_B, sizeof SPS_B);       // layer 1 SPS
    nal(&b, 34, 1, PPS_1, sizeof PPS_1);       // layer 1 PPS
    nal(&b, 1, 0, SLICE, sizeof SLICE);        // base-layer trailing picture
    nal(&b, 21, 1, SLICE, sizeof SLICE);       // layer-1 CRA
    nal(&b, 1, 63, SLICE, sizeof SLICE);       // the largest layer id
    submit(r, &b, 0);
    CHECK(s.count == 1, "one AU");
    CHECK(count(s.data, s.dataSize) == 1, "only the base slice, got %d NALs", count(s.data, s.dataSize));
    CHECK(!s.last.keyframe, "a layer-1 CRA is not a keyframe");
    CHECK(s.spsSize == 2 + sizeof SPS_A && memcmp(s.sps + 2, SPS_A, sizeof SPS_A) == 0, "base SPS kept");
    CHECK(s.last.ppsCount == 1, "layer-1 PPS not held");
    ManifoldHEVCAccessUnitBuilderStats st; ManifoldSRTAccessUnitReaderCopyHEVCBuilderStats(r, &st);
    CHECK(st.nalHigherLayer == 4, "4 higher-layer NALs dropped, got %llu", st.nalHigherLayer);

    // A packet of only higher-layer NALs is no access unit.
    Buf c = {0}; nal(&c, 1, 1, SLICE, sizeof SLICE);
    submit(r, &c, 3600);
    CHECK(s.count == 1, "layer-1-only packet: nothing emitted");
    ManifoldSRTAccessUnitReaderDestroy(r);
}

/// Malformed and dropped NALs, and SEI-only packets.
static void testMalformedAndDropped(void) {
    Sink s; ManifoldSRTAccessUnitReader *r = make(&s);
    ManifoldHEVCAccessUnitBuilder *direct = ManifoldHEVCAccessUnitBuilderCreate();
    const uint8_t one[1] = { 0x02 };
    ManifoldHEVCAccessUnitBuilderAppendNAL(direct, one, 1);                     // 1-byte header
    const uint8_t forbidden[4] = { 0x82, 0x01, 0xAF, 0x00 };
    ManifoldHEVCAccessUnitBuilderAppendNAL(direct, forbidden, 4);               // forbidden_zero_bit
    ManifoldHEVCAccessUnitBuilderAppendNAL(direct, one, 0);                     // empty
    ManifoldHEVCAccessUnitContents contents;
    CHECK(!ManifoldHEVCAccessUnitBuilderCopyAccessUnitContents(direct, &contents), "malformed opens no AU");
    ManifoldHEVCAccessUnitBuilderStats st; ManifoldHEVCAccessUnitBuilderCopyStats(direct, &st);
    CHECK(st.nalMalformed == 2 && st.nalEmpty == 1, "malformed %llu empty %llu", st.nalMalformed, st.nalEmpty);
    ManifoldHEVCAccessUnitBuilderDestroy(direct);

    Buf b = {0};
    nal(&b, 39, 0, SEI, sizeof SEI);
    submit(r, &b, 0);
    CHECK(s.count == 0, "SEI alone is no access unit");
    Buf c = {0};
    nal(&c, 38, 0, SLICE, sizeof SLICE);   // filler
    nal(&c, 41, 0, SLICE, sizeof SLICE);   // reserved
    nal(&c, 62, 0, SLICE, sizeof SLICE);   // unspecified
    nal(&c, 1, 0, SLICE, sizeof SLICE);
    nal(&c, 36, 0, SLICE, sizeof SLICE);   // EOS — kept
    submit(r, &c, 3600);
    CHECK(s.count == 1 && count(s.data, s.dataSize) == 2, "slice and EOS only, got %d", count(s.data, s.dataSize));
    ManifoldHEVCAccessUnitBuilderStats rs; ManifoldSRTAccessUnitReaderCopyHEVCBuilderStats(r, &rs);
    CHECK(rs.nalDroppedReserved == 2, "reserved/unspecified dropped %llu", rs.nalDroppedReserved);
    ManifoldSRTAccessUnitReaderDestroy(r);
}

/// The 8 MB cap: an oversize AU is discarded and counted, and the next one is fine.
static void testOversize(void) {
    ManifoldHEVCAccessUnitBuilder *ab = ManifoldHEVCAccessUnitBuilderCreate();
    const size_t big = 3u * 1024u * 1024u;
    uint8_t *slice = calloc(1, big);
    slice[0] = 0x02; slice[1] = 0x01; slice[2] = 0xAF;
    for (int i = 0; i < 3; i++) ManifoldHEVCAccessUnitBuilderAppendNAL(ab, slice, big);   // 9 MB
    ManifoldHEVCAccessUnitContents c;
    CHECK(!ManifoldHEVCAccessUnitBuilderCopyAccessUnitContents(ab, &c), "oversize: no contents");
    ManifoldHEVCAccessUnitBuilderFlush(ab);
    ManifoldHEVCAccessUnitBuilderAppendNAL(ab, slice, 64);
    CHECK(ManifoldHEVCAccessUnitBuilderCopyAccessUnitContents(ab, &c) && c.size == 68, "next AU fine");
    ManifoldHEVCAccessUnitBuilderFlush(ab);
    ManifoldHEVCAccessUnitBuilderStats st; ManifoldHEVCAccessUnitBuilderCopyStats(ab, &st);
    CHECK(st.accessUnitsOversize == 1 && st.accessUnits == 1, "oversize %llu, emitted %llu", st.accessUnitsOversize, st.accessUnits);
    free(slice);
    ManifoldHEVCAccessUnitBuilderDestroy(ab);
}

// ── The random-access gate (decision 5) ────────────────────────────────────────────────────

typedef struct { uint8_t type; bool rasl; ManifoldHEVCGateVerdict expect; } Step;

static void run(const char *name, const Step *steps, size_t n) {
    ManifoldHEVCRandomAccessGate g = {0};
    for (size_t i = 0; i < n; i++) {
        if (steps[i].type == 255) { ManifoldHEVCRandomAccessGateClose(&g); continue; }   // loss
        const ManifoldHEVCGateVerdict v = ManifoldHEVCRandomAccessGateAdmit(&g, steps[i].type, steps[i].rasl);
        CHECK(v == steps[i].expect, "%s step %zu (type %u rasl %d): verdict %d, expected %d",
              name, i, steps[i].type, steps[i].rasl, v, steps[i].expect);
    }
}
#define RUN(name, ...) do { const Step s[] = { __VA_ARGS__ }; run(name, s, sizeof s / sizeof s[0]); } while (0)
#define D ManifoldHEVCGateDecode
#define W ManifoldHEVCGateDropAwaitingRandomAccess
#define R ManifoldHEVCGateDropRASL
#define LOSS { 255, false, D }

static void testGate(void) {
    // x265's shape joined mid-GOP: trailing pictures, then a CRA and its 4 RASL, then trailing; the
    // next CRA's RASL are decodable because decoding did not start there.
    RUN("join at CRA",
        { 1, false, W }, { 0, false, W }, { 1, false, W },
        { 21, false, D }, { 8, true, R }, { 8, true, R }, { 9, true, R }, { 8, true, R },
        { 1, false, D }, { 0, false, D },
        { 21, false, D }, { 8, true, D }, { 9, true, D }, { 1, false, D });
    // Starting on an IDR: no RASL can follow it; a later CRA's RASL decode.
    RUN("start at IDR", { 19, false, D }, { 1, false, D }, { 21, false, D }, { 8, true, D }, { 20, false, D });
    // RADL pictures are decodable from their IRAP, always.
    RUN("RADL kept", { 21, false, D }, { 7, false, D }, { 6, false, D }, { 8, true, R }, { 1, false, D });
    // A BLA's RASL are dropped even with the gate open.
    RUN("BLA", { 19, false, D }, { 1, false, D }, { 16, false, D }, { 8, true, R }, { 1, false, D },
        { 17, false, D }, { 9, true, R }, { 18, false, D }, { 1, false, D });
    // The next random-access picture ends the skipping, whatever it is.
    RUN("skip ends", { 21, false, D }, { 8, true, R }, { 19, false, D }, { 8, true, D });
    // Loss re-closes the gate; the rule starts over (the same rule after loss).
    RUN("after loss", { 19, false, D }, { 1, false, D }, LOSS, { 1, false, W }, { 8, true, W },
        { 21, false, D }, { 8, true, R }, { 1, false, D });
    // Reserved IRAP types read as a CRA.
    RUN("reserved IRAP", { 22, false, D }, { 8, true, R }, { 23, false, D }, { 8, true, D });
    // Closed: a RASL before any random access is "awaiting", not "RASL".
    RUN("closed RASL", { 8, true, W }, { 9, true, W });

    CHECK(strcmp(ManifoldHEVCRandomAccessName(21), "CRA") == 0 && strcmp(ManifoldHEVCRandomAccessName(19), "IDR") == 0 &&
          strcmp(ManifoldHEVCRandomAccessName(17), "BLA") == 0 && strcmp(ManifoldHEVCRandomAccessName(0), "none") == 0,
          "names");
}

/// The H.264 reader is unchanged: one IDR access unit through a reader created for H.264.
static void testH264Unchanged(void) {
    Sink s; memset(&s, 0, sizeof s);
    ManifoldSRTAccessUnitReader *r = ManifoldSRTAccessUnitReaderCreate(ManifoldSRTVideoCodecH264);
    ManifoldSRTAccessUnitReaderSetHandler(r, handler, &s);
    const uint8_t annexB[] = { 0,0,0,1, 0x67, 0x64, 0x00, 0x1F,   0,0,0,1, 0x68, 0xEE, 0x3C,
                               0,0,0,1, 0x09, 0xF0,               0,0,1, 0x65, 0x88, 0x84 };
    ManifoldSRTAccessUnitReaderSubmitPacket(r, annexB, sizeof annexB, 9000, 9000);
    CHECK(s.count == 1 && s.last.codec == ManifoldSRTVideoCodecH264 && s.last.keyframe, "H.264 IDR AU");
    CHECK(s.last.spsSize == 4 && s.last.ppsSize == 3 && s.last.vps == NULL && s.last.ppsList == NULL && s.last.ppsCount == 0,
          "H.264 parameter sets in sps/pps, HEVC fields empty");
    CHECK(s.dataSize == 4 + 3, "AUD dropped, IDR kept");
    ManifoldHEVCAccessUnitBuilderStats st; ManifoldSRTAccessUnitReaderCopyHEVCBuilderStats(r, &st);
    CHECK(st.accessUnits == 0, "no HEVC builder on an H.264 reader");
    ManifoldSRTAccessUnitReaderDestroy(r);
}

int main(void) {
    testSplitting();
    testTwoByteHeader();
    testParameterSets();
    testBaseLayerOnly();
    testMalformedAndDropped();
    testOversize();
    testGate();
    testH264Unchanged();
    printf("hevc_access_unit_builder_test: %d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
