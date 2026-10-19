//
//  PrivacyLog.swift
//  Manifold — the PrivacyRedaction rules, reachable from Objective-C log sites.
//
//  Privacy stage P1 (docs/PRIVACY_AUDIT.md). DataChannelBridge.m and NDIBridge.mm compose log lines
//  that carry addresses; they import "Manifold-Swift.h" and call these, so there is ONE copy of each
//  rule (Packages/ManifoldCore/Sources/PrivacyRedaction, where `swift test` reaches it), not a Swift
//  copy and an Objective-C copy that drift apart.
//

import Foundation
import PrivacyRedaction

@objc(MFPrivacyLog)
final class PrivacyLog: NSObject {

    /// Every IPv4 / IPv6 address in `text` replaced by `(ip withheld)`.
    @objc static func withholdingIPAddresses(_ text: String) -> String {
        LogRedaction.withholdingIPAddresses(text)
    }

    /// An NDI source name with its sending host withheld: `MACHINE (Source)` → `(host withheld) (Source)`.
    @objc static func ndiSourceName(_ name: String) -> String {
        LogRedaction.ndiSourceName(name)
    }

    /// The fixed token logged in place of an NDI source's address.
    @objc static var addressWithheld: String { LogRedaction.addressWithheld }
}
