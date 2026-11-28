import Foundation
import XCTest
@testable import FrameShareFormat

/// Export Frame's and Share Frame's banner (docs/BUGS.md, 0.9.6 UI polish item 3; batch 3: the name on its own line, D7).
final class FrameSaveNoticeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameSaveNoticeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The saved banner

    func testSavedNamesTheFileOnItsOwnPart() {
        let n = FrameSaveNotice.saved(url: URL(fileURLWithPath: "/Users/x/Desktop/MyClip 01-02-14-05.png"), note: nil)
        XCTAssertEqual(n.headline, "Saved")
        XCTAssertEqual(n.fileName, "MyClip 01-02-14-05.png")
        XCTAssertNil(n.detail)
        XCTAssertEqual(n.text, "Saved “MyClip 01-02-14-05.png”.")
        XCTAssertFalse(n.text.contains("/"))
        XCTAssertEqual(n.fileURL?.lastPathComponent, "MyClip 01-02-14-05.png")
        XCTAssertFalse(n.isFailure)
        XCTAssertEqual(n.autoHideSeconds, 6)
    }

    /// The per-clip folder's fallback arrives before the save and becomes the banner's detail. It names no folder: a name
    /// inside a sentence can wrap and be hyphenated (Robbie, 2026-11-27).
    func testFallbackNoteIsTheDetailAndNamesNoFolder() {
        for reason in [FrameFileName.FallbackReason.fileInTheWay, .couldNotCreate] {
            let note = FrameFileName.fallbackNotice(folder: "MyClip", reason: reason)
            XCTAssertFalse(note.contains("MyClip"), note)
            let n = FrameSaveNotice.saved(url: URL(fileURLWithPath: "/tmp/MyClip 01.png"), note: nil).adding(note: note)
            XCTAssertEqual(n.detail, note)
            XCTAssertEqual(n.fileName, "MyClip 01.png")
        }
    }

    func testAddingNilNoteChangesNothing() {
        let n = FrameSaveNotice.saved(url: URL(fileURLWithPath: "/tmp/a.png"), note: nil)
        XCTAssertEqual(n.adding(note: nil), n)
    }

    /// D7: a failure is an error, and errors stand until closed or replaced.
    func testAFailureStandsAndIgnoresANote() {
        let n = FrameSaveFailure.unknown.notice(fileName: "a.png")
        XCTAssertEqual(n.adding(note: "It’s in the export folder."), n)
        XCTAssertTrue(n.isFailure)
        XCTAssertNil(n.fileURL)
        XCTAssertNil(n.autoHideSeconds)
    }

    /// The renderer's call, `.failed(failure.message(fileName:folderName:))`, still produces the structured notice.
    func testRendererSpellingProducesTheStructuredNotice() {
        let n = FrameSaveNotice.failed(FrameSaveFailure.diskFull.message(fileName: "a.png", folderName: "Stills"))
        XCTAssertEqual(n, .failed(headline: "Couldn’t save", fileName: "a.png", detail: FrameSaveFailure.diskFull.detail))
    }

    // MARK: Why a save failed

    func testDiagnoseOrder() {
        XCTAssertEqual(FrameSaveFailure.diagnose(folderExists: false, folderWritable: false, freeBytes: 0, neededBytes: 10), .folderMissing)
        XCTAssertEqual(FrameSaveFailure.diagnose(folderExists: true, folderWritable: false, freeBytes: 0, neededBytes: 10), .folderNotWritable)
        XCTAssertEqual(FrameSaveFailure.diagnose(folderExists: true, folderWritable: true, freeBytes: 9, neededBytes: 10), .diskFull)
        XCTAssertEqual(FrameSaveFailure.diagnose(folderExists: true, folderWritable: true, freeBytes: 10, neededBytes: 10), .unknown)
        // A volume that does not report its free space is not blamed.
        XCTAssertEqual(FrameSaveFailure.diagnose(folderExists: true, folderWritable: true, freeBytes: nil, neededBytes: 10), .unknown)
    }

    func testDiagnoseAMissingFolder() {
        XCTAssertEqual(FrameSaveFailure.diagnose(folder: root.appendingPathComponent("gone"), neededBytes: 1), .folderMissing)
    }

    func testDiagnoseAFileWhereTheFolderShouldBe() throws {
        let file = root.appendingPathComponent("notAFolder")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(FrameSaveFailure.diagnose(folder: file, neededBytes: 1), .folderMissing)
    }

    func testDiagnoseAReadOnlyFolder() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertEqual(FrameSaveFailure.diagnose(folder: root, neededBytes: 1), .folderNotWritable)
    }

    func testDiagnoseAWritableFolderWithRoomIsUnknown() {
        XCTAssertEqual(FrameSaveFailure.diagnose(folder: root, neededBytes: 1), .unknown)
    }

    func testEveryFailureKeepsTheNameOutOfTheSentence() {
        for f in [FrameSaveFailure.folderMissing, .folderNotWritable, .diskFull, .unknown] {
            let n = f.notice(fileName: "MyClip 01.png")
            XCTAssertEqual(n.headline, "Couldn’t save")
            XCTAssertEqual(n.fileName, "MyClip 01.png")
            XCTAssertFalse(f.detail.contains("MyClip"), f.detail)
            XCTAssertFalse(f.detail.contains("/"), f.detail)
            XCTAssertFalse(f.logLabel.contains("/"))
        }
        // The two folder problems and the unknown one say where to choose another folder.
        for f in [FrameSaveFailure.folderMissing, .folderNotWritable, .unknown] {
            XCTAssertTrue(f.detail.contains("Settings ▸ Files ▸ Frame Export"), f.detail)
        }
    }

    // MARK: Share Frame

    func testUserCancelIsNotAFailure() {
        XCTAssertTrue(ShareFailure.isCancel(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        XCTAssertFalse(ShareFailure.isCancel(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError))
        XCTAssertFalse(ShareFailure.isCancel(domain: NSURLErrorDomain, code: NSUserCancelledError))
    }

    func testShareFailureCarriesTheSystemDetail() {
        let n = ShareFailure.couldNotShare(detail: " The network is offline. ")
        XCTAssertEqual(n.headline, "Couldn’t share the frame")
        XCTAssertNil(n.fileName)
        XCTAssertEqual(n.detail, "The network is offline.")
        XCTAssertTrue(ShareFailure.couldNotShare(detail: "").detail?.contains("Export Frame…") ?? false)
        XCTAssertTrue(ShareFailure.couldNotPrepare.isFailure)
    }
}
