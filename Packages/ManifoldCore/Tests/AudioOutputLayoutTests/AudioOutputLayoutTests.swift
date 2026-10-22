import XCTest
import CoreAudioTypes
@testable import AudioOutputLayout

final class AudioOutputLayoutTests: XCTestCase {

    /// An `AudioChannelLayout` as the bytes a track would carry: header, `descriptions` labels, then `padding` zero bytes.
    private func layout(tag: UInt32, bitmap: UInt32 = 0, count: UInt32? = nil, labels: [UInt32] = [], padding: Int = 0) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        u32(tag); u32(bitmap); u32(count ?? UInt32(labels.count))
        for label in labels { u32(label); u32(0); u32(0); u32(0); u32(0) }
        d.append(Data(count: padding))
        return d
    }

    private func decide(_ data: Data?, channels: Int) -> AudioOutputLayout.Decision {
        guard let data else { return AudioOutputLayout.decide(source: nil, size: 0, channels: channels) }
        return data.withUnsafeBytes { AudioOutputLayout.decide(source: $0.baseAddress!, size: data.count, channels: channels) }
    }

    private func tag(of layout: Data) -> UInt32 { layout.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) } }

    // MARK: - The measured shapes

    /// TCMOP_NSS_Oriental_MKE_REF.mov: the Stereo tag, zero descriptions, 52 bytes. Trusted after trimming to 12.
    func testTCMOPOversizedStereoIsTrimmedToItsDeclaredSize() {
        let d = decide(layout(tag: kAudioChannelLayoutTag_Stereo, padding: 40), channels: 2)
        XCTAssertEqual(d.source, .oversized(size: 52, used: 12))
        XCTAssertEqual(d.layout, layout(tag: kAudioChannelLayoutTag_Stereo))
        XCTAssertNotNil(d.note)
    }

    /// The August ARRI ALEXA Mini case: Unknown with a channel count of zero on a 5-channel track.
    func testARRIUnknownLayoutFallsBackToDiscreteInOrder() {
        let d = decide(layout(tag: 0xFFFF_0000), channels: 5)
        XCTAssertEqual(d.source, .unknownTag(0xFFFF_0000))
        XCTAssertEqual(tag(of: d.layout), kAudioChannelLayoutTag_DiscreteInOrder | 5)
        XCTAssertEqual(d.layout.count, 12)
    }

    /// Measured: forcing Stereo onto a valid 2-channel DiscreteInOrder track decodes to silence. The source is kept.
    func testValidDiscreteInOrderStereoKeepsItsOwnLayout() {
        let src = layout(tag: kAudioChannelLayoutTag_DiscreteInOrder | 2)
        let d = decide(src, channels: 2)
        XCTAssertEqual(d.source, .valid)
        XCTAssertEqual(d.layout, src)
        XCTAssertNil(d.note)
    }

    /// Measured: a 6-channel track whose layout says Stereo made HEAD throw NSInvalidArgumentException.
    func testCountMismatchIsNotTrusted() {
        let d = decide(layout(tag: kAudioChannelLayoutTag_Stereo), channels: 6)
        XCTAssertEqual(d.source, .countMismatch(layoutChannels: 2))
        XCTAssertEqual(tag(of: d.layout), kAudioChannelLayoutTag_DiscreteInOrder | 6)
    }

    // MARK: - Validation

    func testWellFormedTagOnlyIsValidAndKeptByteForByte() {
        let src = layout(tag: kAudioChannelLayoutTag_MPEG_5_1_A)
        let d = decide(src, channels: 6)
        XCTAssertEqual(d.source, .valid)
        XCTAssertEqual(d.layout, src)
    }

    func testDescriptionsAreCountedAndSized() {
        let two = layout(tag: kAudioChannelLayoutTag_UseChannelDescriptions, labels: [1, 2])
        XCTAssertEqual(two.count, 52)
        XCTAssertEqual(decide(two, channels: 2).source, .valid)
        XCTAssertEqual(decide(two, channels: 2).layout, two)
        let padded = layout(tag: kAudioChannelLayoutTag_UseChannelDescriptions, labels: [1, 2], padding: 20)
        let d = decide(padded, channels: 2)
        XCTAssertEqual(d.source, .oversized(size: 72, used: 52))
        XCTAssertEqual(d.layout, two)
    }

    func testTruncatedDescriptionsAreNotTrusted() {
        // Six descriptions declared in a 12-byte box.
        let d = decide(layout(tag: kAudioChannelLayoutTag_UseChannelDescriptions, count: 6), channels: 6)
        XCTAssertEqual(d.source, .truncated(size: 12, needed: 132))
        XCTAssertEqual(tag(of: d.layout), kAudioChannelLayoutTag_DiscreteInOrder | 6)
    }

    func testShorterThanAHeaderIsTruncated() {
        let short = Data(count: 8)
        let v = short.withUnsafeBytes { AudioOutputLayout.validate($0.baseAddress!, size: 8, channels: 2) }
        XCTAssertEqual(v, .truncated(size: 8, needed: 12))
    }

    func testAbsurdDescriptionCountDoesNotOverflow() {
        let d = decide(layout(tag: kAudioChannelLayoutTag_UseChannelDescriptions, count: .max), channels: 2)
        XCTAssertFalse(d.source.isTrusted)
        XCTAssertEqual(tag(of: d.layout), kAudioChannelLayoutTag_Stereo)
    }

    func testBitmapCountsItsBits() {
        let lr = layout(tag: kAudioChannelLayoutTag_UseChannelBitmap, bitmap: 0b11)
        XCTAssertEqual(decide(lr, channels: 2).source, .valid)
        XCTAssertEqual(decide(lr, channels: 3).source, .countMismatch(layoutChannels: 2))
    }

    func testUnknownWithTheRightCountIsStillNotTrusted() {
        // Unknown claims nothing about roles, whatever its count says.
        XCTAssertEqual(decide(layout(tag: 0xFFFF_0002), channels: 2).source, .unknownTag(0xFFFF_0002))
    }

    // MARK: - Fallbacks: there is always a layout

    func testNoSourceLayoutFallsBackByCount() {
        XCTAssertEqual(tag(of: decide(nil, channels: 1).layout), kAudioChannelLayoutTag_Mono)
        XCTAssertEqual(tag(of: decide(nil, channels: 2).layout), kAudioChannelLayoutTag_Stereo)
        XCTAssertEqual(tag(of: decide(nil, channels: 8).layout), kAudioChannelLayoutTag_DiscreteInOrder | 8)
        XCTAssertEqual(decide(nil, channels: 2).source, .none)
        XCTAssertNil(decide(nil, channels: 2).note)
    }

    func testUntrustedOneAndTwoChannelLayoutsFallBackToMonoAndStereo() {
        XCTAssertEqual(tag(of: decide(layout(tag: 0xFFFF_0000), channels: 1).layout), kAudioChannelLayoutTag_Mono)
        XCTAssertEqual(tag(of: decide(layout(tag: 0xFFFF_0000), channels: 2).layout), kAudioChannelLayoutTag_Stereo)
    }

    func testEveryDecisionIsExactlyAsLongAsItsDescriptionsNeed() {
        let cases: [(Data?, Int)] = [
            (nil, 1), (nil, 2), (nil, 6),
            (layout(tag: kAudioChannelLayoutTag_Stereo, padding: 40), 2),
            (layout(tag: kAudioChannelLayoutTag_UseChannelDescriptions, labels: [1, 2, 3], padding: 7), 3),
            (layout(tag: 0xFFFF_0000), 5),
        ]
        for (src, ch) in cases {
            let out = decide(src, channels: ch).layout
            let count = out.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
            XCTAssertEqual(out.count, AudioOutputLayout.headerSize + count * AudioOutputLayout.descriptionSize)
        }
    }
}
