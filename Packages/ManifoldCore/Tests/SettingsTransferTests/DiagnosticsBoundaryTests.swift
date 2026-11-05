//
//  DiagnosticsBoundaryTests.swift
//  SettingsTransferTests
//
//  docs/SETTINGS_EXPORT_PLAN.md §7: diagnostics never include an export or a backup. The report is app code and a
//  test bundle can't link the app, so this reads the app's source: `DiagnosticsExport.swift` may not name a settings
//  file or the backup folder, and may not list a directory or read a file at all. It only ever writes the report. No
//  other app file may name the backups except the settings UI, so nothing the report calls can reach them either.
//

import XCTest
@testable import SettingsTransfer

final class DiagnosticsBoundaryTests: XCTestCase {
    private static let appFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")

    /// Naming the settings file, its readers or the folder the backups live in.
    private static let settingsTokens = ["Settings Backups", "SettingsBackups", "SettingsFile", "SealedFile",
                                         "manifoldsettings", "applicationSupportDirectory", "Application Support"]
    /// Any way to list a directory or read a file.
    private static let fileAccessTokens = ["FileManager", "contentsOfDirectory", "enumerator(at", "subpaths", "opendir",
                                           "Data(contentsOf", "String(contentsOf", "NSData(contentsOf", "FileHandle",
                                           "InputStream", "fopen", "NSOpenPanel"]

    private func hits(_ tokens: [String], in source: String) -> [String] {
        tokens.filter(source.contains)
    }

    private func appSource(_ name: String) throws -> String {
        try String(contentsOf: Self.appFolder.appendingPathComponent(name), encoding: .utf8)
    }

    func testDiagnosticsNeverNamesASettingsFileOrTheBackups() throws {
        XCTAssertEqual(hits(Self.settingsTokens, in: try appSource("DiagnosticsExport.swift")), [])
    }

    func testDiagnosticsNeverListsADirectoryOrReadsAFile() throws {
        XCTAssertEqual(hits(Self.fileAccessTokens, in: try appSource("DiagnosticsExport.swift")), [])
    }

    func testOnlyTheSettingsUIReachesTheBackups() throws {
        let files = FileManager.default.enumerator(at: Self.appFolder, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the scan must have found the app's source")
        let reaching = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("SettingsBackups") }
            .map(\.lastPathComponent)
        XCTAssertEqual(reaching, ["SettingsTransferUI.swift"])
    }

    /// The scan itself: a line that would break the rule is caught.
    func testTheScanCatchesAViolation() {
        XCTAssertEqual(hits(Self.settingsTokens, in: "SettingsBackups().list()"), ["SettingsBackups"])
        XCTAssertEqual(hits(Self.fileAccessTokens, in: "try FileManager.default.contentsOfDirectory(at: u)"),
                       ["FileManager", "contentsOfDirectory"])
    }
}
