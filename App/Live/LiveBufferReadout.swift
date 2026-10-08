//
//  LiveBufferReadout.swift — what the chain readout's Buffer row says about the push source driving
//  a renderer (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10, decision 5 and Stage 0b-2a).
//
//  The push routers (SRT, WHEP) publish here when their route activates, when the cushion is raised,
//  when SRT learns its negotiated latency, and when the route is released. The readout reads it per
//  renderer — the same per-window key `DisplayChainModel` already filters its colour events on — and
//  refreshes on `didChange`. Text comes from `LiveCushion.Report`, so the words are unit-tested.
//
//  MAIN THREAD ONLY. The routers hop here; nothing reads it from another thread.
//

import Foundation
import DisplayProviders

enum LiveBufferReadout {

    /// Posted on main after any change, `object` = the renderer. `userInfo[steppedKey]` is true when
    /// the change moved a running clock (a raise after the anchor): calibration restarts on it.
    static let didChange = Notification.Name("ManifoldLiveBufferReadoutDidChange")
    static let steppedKey = "stepped"

    private static var reports: [ObjectIdentifier: LiveCushion.Report] = [:]

    /// The Buffer row for this renderer's push source, or nil (NDI, HLS, a file, nothing connected).
    static func report(for renderer: MetalVideoRenderer?) -> LiveCushion.Report? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let renderer else { return nil }
        return reports[ObjectIdentifier(renderer)]
    }

    /// Set (or, with nil, clear) the report for `renderer`. Logs the row's text when it changes, as
    /// `[<prefix>-BUFFER] readout: Buffer …`, so the readout is checkable from a log.
    static func publish(_ report: LiveCushion.Report?, renderer: MetalVideoRenderer, logPrefix: String,
                        stepped: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = ObjectIdentifier(renderer)
        let old = reports[key]
        guard old != report else { return }
        reports[key] = report
        if let report, report.text != old?.text {
            NSLog("[%@-BUFFER] readout: Buffer %@", logPrefix, report.text)
        }
        NotificationCenter.default.post(name: didChange, object: renderer,
                                        userInfo: [steppedKey: stepped])
    }
}
