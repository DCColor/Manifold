//
//  MarkerFileIO.swift — File ▸ Export Markers… and File ▸ Import Markers… (docs/MARKERS_PLAN.md §6, §7 v1).
//
//  Export: Resolve marker EDL, CSV or plain text, chosen in the save panel. Import: a Resolve marker EDL, merged into
//  the window's markers (D9), with the whole-hour shift offered and never applied unasked (§6.4).
//
//  ⚠️ Logs through `MarkerLog` only (counts). The panels and alerts show the user's own words to the user; nothing
//  here writes them anywhere else.
//

import AppKit
import Markers
import UniformTypeIdentifiers

@MainActor
enum MarkerFileIO {

    enum Format: Int, CaseIterable {
        case resolveEDL, csv, text
        var title: String {
            switch self {
            case .resolveEDL: return "DaVinci Resolve Marker EDL (.edl)"
            case .csv: return "CSV (.csv)"
            case .text: return "Plain Text (.txt)"
            }
        }
        var ext: String { ["edl", "csv", "txt"][rawValue] }
        var type: UTType { UTType(filenameExtension: ext) ?? .plainText }
    }

    private static let formatKey = "manifold.markers.exportFormat"
    private static let keywordsKey = "manifold.markers.edlKeywordsInNotes"

    // MARK: Export

    static func export(from model: MarkerModel, window: NSWindow?) {
        guard model.isActive, let basis = model.basis else { NSSound.beep(); return }
        guard !model.markers.isEmpty else {
            model.show("No markers to export.")
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Markers"
        panel.prompt = "Export"
        let accessory = ExportAccessory(format: Format(rawValue: UserDefaults.standard.integer(forKey: formatKey)) ?? .resolveEDL,
                                        keywords: UserDefaults.standard.bool(forKey: keywordsKey))
        panel.accessoryView = accessory.view
        panel.isExtensionHidden = false
        func applyFormat() {
            panel.allowedContentTypes = [accessory.format.type]
            panel.nameFieldStringValue = "\(model.clipName) markers.\(accessory.format.ext)"
        }
        accessory.onChange = { applyFormat() }
        applyFormat()

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                UserDefaults.standard.set(accessory.format.rawValue, forKey: formatKey)
                UserDefaults.standard.set(accessory.keywords, forKey: keywordsKey)
                write(model: model, basis: basis, format: accessory.format, keywordsInNotes: accessory.keywords, to: url)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static func write(model: MarkerModel, basis: TimecodeBasis, format: Format, keywordsInNotes: Bool, to url: URL) {
        let markers = model.markers
        do {
            switch format {
            case .resolveEDL:
                let out = ResolveEDL.export(markers: markers, title: model.clipName, basis: basis,
                                            options: .init(appendKeywordsToNotes: keywordsInNotes))
                try Data(out.text.utf8).write(to: url, options: .atomic)
                NSLog("%@", MarkerLog.exported(.edl, report: out.report))
                var parts = ["Exported \(out.report.markers) marker\(out.report.markers == 1 ? "" : "s") to a Resolve EDL."]
                if out.report.multiLineNotes > 0 {
                    parts.append("\(out.report.multiLineNotes) multi-line note\(out.report.multiLineNotes == 1 ? " keeps its" : "s keep their") line breaks (Resolve’s own EDL export flattens them).")
                }
                if out.report.droppedBlankLines > 0 {
                    parts.append("\(out.report.droppedBlankLines) blank line\(out.report.droppedBlankLines == 1 ? " was" : "s were") left out of notes: an EDL cannot hold one.")
                }
                if out.report.droppedKeywords > 0 {
                    parts.append("\(out.report.droppedKeywords) marker\(out.report.droppedKeywords == 1 ? " has" : "s have") keywords; the EDL has no field for them (CSV and text keep them).")
                }
                if out.report.appendedKeywords > 0 { parts.append("Keywords were added to the notes.") }
                if out.report.replacedBars > 0 { parts.append("“|” became “/” in \(out.report.replacedBars).") }
                model.show(parts.joined(separator: " "))
            case .csv:
                try MarkerCSV.export(markers: markers, basis: basis).write(to: url, options: .atomic)
                NSLog("%@", MarkerLog.exported(.csv, count: markers.count))
                model.show("Exported \(markers.count) markers to CSV.")
            case .text:
                try Data(MarkerPlainText.export(markers: markers, fileName: model.fileName, basis: basis).utf8)
                    .write(to: url, options: .atomic)
                NSLog("%@", MarkerLog.exported(.text, count: markers.count))
                model.show("Exported \(markers.count) markers to text.")
            }
        } catch {
            model.show("The markers could not be written there.")
            NSSound.beep()
        }
    }

    // MARK: Import

    static func importEDL(into model: MarkerModel, window: NSWindow?) {
        guard model.isActive else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.title = "Import Markers"
        panel.prompt = "Import"
        panel.message = "Choose a DaVinci Resolve marker EDL (Timeline ▸ Export ▸ Timeline Markers to EDL)."
        // ⚠️ NO `allowedContentTypes`: the panel enables files by EXTENSION through its delegate (`.edl`, any case), whatever
        // type macOS has given the file. With content types, Frame.io's EDL was greyed out while Resolve's own could be
        // chosen (Robbie, 2026-11-15; docs/MARKERS_PLAN.md §16). The parser decides whether it holds markers.
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let filter = EDLPanelFilter()
        panel.delegate = filter
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(filter) {}   // the panel holds its delegate weakly
                guard response == .OK, let url = panel.url else { return }
                // After the panel has gone, so an alert can take the window.
                DispatchQueue.main.async { MainActor.assumeIsolated { read(url, into: model, window: window) } }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static func read(_ url: URL, into model: MarkerModel, window: NSWindow?) {
        guard let basis = model.basis else { return }
        let parsed: ResolveEDL.Parsed
        do {
            parsed = try ResolveEDL.parse(try Data(contentsOf: url))
        } catch {
            NSLog("%@", MarkerLog.importFailed())
            alert(window, "No markers in that file.",
                  "Manifold imports Resolve marker EDLs: each event followed by a line with “|C:ResolveColor…”.")
            return
        }
        var placement = ResolveEDL.place(parsed, basis: basis, lastFrame: model.lastFrame)
        var shift = 0
        if let h = placement.suggestedShiftHours {
            let sign = h < 0 ? "−" : "+"
            let amount = String(format: "%02d:00:00:00", abs(h))
            let a = NSAlert()
            a.messageText = "\(placement.outside.count) of \(parsed.entries.count) markers fall outside this file."
            a.informativeText = "This file starts at \(basis.label(0)). Shifted by \(sign)\(amount), every marker fits: "
                + "the EDL was probably made on a timeline starting at a different hour (Frame.io assumes 01:00:00:00)."
            a.addButton(withTitle: "Shift by \(sign)\(amount)")
            a.addButton(withTitle: "Import As Is")
            a.addButton(withTitle: "Cancel")
            let r = a.runModal()
            if r == .alertThirdButtonReturn { return }
            if r == .alertFirstButtonReturn {
                shift = h
                placement = ResolveEDL.place(parsed, basis: basis, lastFrame: model.lastFrame, shiftHours: h)
            }
        }
        let result = model.importMarkers(placement.markers)
        NSLog("%@", MarkerLog.imported(added: result.added.count, duplicates: result.identical, occupied: result.occupied,
                                       outside: placement.outside.count,
                                       unknownColors: placement.unknownColors, shiftHours: shift,
                                       dropFrameMismatch: placement.dropFrameMismatch))
        let added = result.added.count
        var lines = ["Imported \(added) marker\(added == 1 ? "" : "s")."]
        if result.identical > 0 { lines.append("\(result.identical) already here, skipped.") }
        if result.occupied > 0 { lines.append("\(result.occupied) skipped: frame already has a marker.") }
        if !placement.outside.isEmpty {
            let list = placement.outside.prefix(12).map { String(format: "%03d", $0) }.joined(separator: ", ")
            lines.append("\(placement.outside.count) outside this file, skipped (event\(placement.outside.count == 1 ? "" : "s") \(list)\(placement.outside.count > 12 ? ", …" : "")).")
        }
        if placement.unknownColors > 0 { lines.append("\(placement.unknownColors) with an unknown color are Blue.") }
        if placement.dropFrameMismatch {
            lines.append("The EDL says \(parsed.dropFrame == true ? "drop" : "non-drop") frame and this file is \(basis.dropFrame ? "drop" : "non-drop") frame; timecodes were read as the EDL states them.")
        }
        if let title = parsed.title, !title.isEmpty, title != model.clipName, title != model.fileName {
            lines.append("The EDL is titled “\(title)”, not this file’s name.")
        }
        if lines.count > 1 {
            alert(window, lines[0], lines.dropFirst().joined(separator: "\n"))
        } else {
            model.show(lines[0])
        }
    }

    private static func alert(_ window: NSWindow?, _ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }
}

/// The save panel's format pop-up and the EDL's keywords checkbox.
@MainActor
private final class ExportAccessory: NSObject {
    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let checkbox = NSButton(checkboxWithTitle: "Add keywords to notes", target: nil, action: nil)
    var onChange: (() -> Void)?

    var format: MarkerFileIO.Format { MarkerFileIO.Format(rawValue: popup.indexOfSelectedItem) ?? .resolveEDL }
    var keywords: Bool { checkbox.state == .on }

    init(format: MarkerFileIO.Format, keywords: Bool) {
        let label = NSTextField(labelWithString: "Format:")
        popup.addItems(withTitles: MarkerFileIO.Format.allCases.map(\.title))
        popup.selectItem(at: format.rawValue)
        checkbox.state = keywords ? .on : .off
        checkbox.toolTip = "An EDL has no keyword field. On: keywords are added to the end of the note as [a, b]."
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        let stack = NSStackView(views: [row, checkbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(changed)
        changed()
    }

    @objc private func changed() {
        checkbox.isEnabled = format == .resolveEDL
        onChange?()
    }
}

/// Enables `.edl` files (any case) and folders in Import Markers…'s panel, by extension alone (`ResolveEDL.isImportCandidate`).
private final class EDLPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            // A folder can be opened; a package (an .app, a library) is a file here, and not an EDL.
            return !((try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false)
        }
        return ResolveEDL.isImportCandidate(url)
    }
}

