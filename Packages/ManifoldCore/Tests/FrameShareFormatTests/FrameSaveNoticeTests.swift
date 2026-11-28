import Foundation
import XCTest
@testable import FrameShareFormat

/// Export Frame's and Share Frame's banner (docs/BUGS.md, 0.9.6 UI polish item 3).
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

    func testSavedNamesTheFileNotThePath() {
        let n = FrameSaveNotice.saved(url: URL(fileURLWithPath: "/Users/x/Desktop/MyClip 01-02-14-05.png"), note: nil)
        XCTAssertEqual(n.text, "Saved “MyClip 01-02-14-05.png”.")
        XCTAssertFalse(n.text.contains("/"))
        XCTAssertEqual(n.fileURL?.lastPathComponent, "MyClip 01-02-14-05.png")
        XCTAssertFalse(n.isFailure)
        XCTAssertEqual(n.autoHideSeconds, 6)
    }

    /// The per-clip folder's fallback arrives before the save and becomes the banner's second sentence.
    func testFallbackNoteFollowsTheSavedLine() {
        let note = FrameFileName.fallbackNotice(folder: "MyClip", reason: .fileInTheWay)
        let n = FrameSaveNotice.saved(url: URL(fileURLWithPath: "/tmp/MyClip 01.png"), note: nil).adding(note: note)
        XCTAssertEqual(n.text, "Saved “MyClip 01.png”. It’s in the export folder, not in “MyClip”: a file with that name is in the way.")
    }

    func testAddingNilNoteChangesNothing() {
        let n = FrameSaveNotice.saved(url: URL(fileURLWithPath: "/tmp/a.png"), note: nil)
        XCTAssertEqual(n.adding(note: nil), n)
    }

    func testAFailureIgnoresANote() {
        let n = FrameSaveNotice.failed("Couldn’t save.")
        XCTAssertEqual(n.adding(note: "It’s in the export folder."), n)
        XCTAssertTrue(n.isFailure)
        XCTAssertNil(n.fileURL)
        XCTAssertEqual(n.autoHideSeconds, 9)
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

    func testEveryMessageNamesTheFileAndNeverAPath() {
        for f in [FrameSaveFailure.folderMissing, .folderNotWritable, .diskFull, .unknown] {
            let m = f.message(fileName: "MyClip 01.png", folderName: "Stills")
            XCTAssertTrue(m.hasPrefix("Couldn’t save “MyClip 01.png”"), m)
            XCTAssertFalse(m.contains("/"), m)
            XCTAssertFalse(f.logLabel.contains("/"))
        }
        // The two folder problems and the unknown one say where to choose another folder.
        for f in [FrameSaveFailure.folderMissing, .folderNotWritable, .unknown] {
            let m = f.message(fileName: "a.png", folderName: "Stills")
            XCTAssertTrue(m.contains("“Stills”"), m)
            XCTAssertTrue(m.contains("Settings ▸ Files ▸ Frame Export"), m)
        }
    }

    // MARK: Share Frame

    func testUserCancelIsNotAFailure() {
        XCTAssertTrue(ShareFailure.isCancel(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        XCTAssertFalse(ShareFailure.isCancel(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError))
        XCTAssertFalse(ShareFailure.isCancel(domain: NSURLErrorDomain, code: NSUserCancelledError))
    }

    func testShareFailureCarriesTheSystemDetail() {
        XCTAssertEqual(ShareFailure.couldNotShare(detail: " The network is offline. "), "Couldn’t share the frame: The network is offline.")
        XCTAssertTrue(ShareFailure.couldNotShare(detail: "").contains("Export Frame…"))
    }
}
