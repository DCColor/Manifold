/// A DeckLink sub-device's state under the card's current connector mapping (its active profile), and what Manifold says
/// and does about it (Robbie, 2026-11-15).
///
/// The SDK (Desktop Video SDK 16.0 manual):
///   - §2.4.11 (p.31–33): a profile change "may change duplex mode or [make sub-devices] become inactive. An application can
///     check the duplex mode with attribute BMDDeckLinkDuplex". On a change, `IDeckLinkProfileCallback::ProfileChanging` is
///     called first, then `ProfileActivated`, after which "the application should rescan any attributes".
///   - §2.5.48.1 (p.192): `ProfileChanging(profileToBeActivated, streamsWillBeForcedToStop)`: when true, "the DeckLink
///     hardware will forcibly stop any current streams" on return.
///   - BMDDeckLinkDuplex (IDeckLinkProfileAttributes integer attribute, p.274): "The duplex mode for the corresponding
///     profile. See BMDDuplexMode".
///   - §3.60 BMDDuplexMode (p.299): full, half, simplex, and `bmdDuplexInactive`: "Device is inactive for this profile".
///
/// ⚠️ NEVER SWITCHES DEVICE. A selected device that becomes inactive stops the output with a message; choosing another
/// device is the operator's decision.
public enum DeckLinkDuplex: Equatable, Sendable {
    case full, half, simplex, inactive
    /// The attribute could not be read, or held a value this build does not know. Treated as usable: greying a device
    /// out is a claim, and only the driver's own `bmdDuplexInactive` makes it.
    case unknown

    /// BMDDuplexMode's four-character codes (DeckLinkAPI.h, SDK 16.0).
    public static let fullCode: UInt32 = 0x6478_6675      // 'dxfu'
    public static let halfCode: UInt32 = 0x6478_6861      // 'dxha'
    public static let simplexCode: UInt32 = 0x6478_7370   // 'dxsp'
    public static let inactiveCode: UInt32 = 0x6478_696E  // 'dxin'

    /// From GetInt(BMDDeckLinkDuplex); nil when the call failed.
    public init(code: UInt32?) {
        switch code {
        case Self.fullCode?: self = .full
        case Self.halfCode?: self = .half
        case Self.simplexCode?: self = .simplex
        case Self.inactiveCode?: self = .inactive
        default: self = .unknown
        }
    }

    public var isInactive: Bool { self == .inactive }

    /// For the log.
    public var logName: String {
        switch self {
        case .full: return "full duplex"
        case .half: return "half duplex"
        case .simplex: return "simplex"
        case .inactive: return "inactive"
        case .unknown: return "duplex unknown"
        }
    }
}

public enum DeckLinkConnectorMapping {
    /// Beside the greyed devices, in the DeckLink menu and in Settings.
    public static let inactiveNote = "Inactive in the card's current connector mapping"

    /// A start refused because the selected device is inactive. Output stays off.
    public static func startRefusedMessage(device: String) -> String {
        "\(device) is inactive in the card's current connector mapping. Choose an active device, or change the mapping in Desktop Video Setup, then start output again."
    }

    /// Output stopped because the selected device became inactive.
    public static func becameInactiveMessage(device: String) -> String {
        "DeckLink output stopped: \(device) became inactive when the card's connector mapping changed. Choose an active device, or change the mapping back in Desktop Video Setup, then start output again."
    }

    /// Output stopped because the driver stopped it for a mapping change, the device itself still active.
    public static let mappingChangedMessage =
        "DeckLink output stopped: the card's connector mapping changed, and the driver stops running output when it does. Start output again."

    /// What a connector-mapping change does to running output, decided once the new mapping is active (`ProfileActivated`,
    /// devices re-read). nil: nothing; output (if any) carries on. Otherwise the message, and output stops.
    ///
    /// - `selected`: the selected device's state under the NEW mapping; nil when it is no longer listed.
    /// - `forcedStop`: `ProfileChanging` said `streamsWillBeForcedToStop` for the selected device, so the driver has already
    ///   stopped the stream whatever the new state.
    public static func verdictAfterChange(outputting: Bool, selected: DeckLinkDuplex?, deviceName: String,
                                          forcedStop: Bool) -> String? {
        guard outputting else { return nil }
        if selected == nil || selected == .inactive { return becameInactiveMessage(device: deviceName) }
        if forcedStop { return mappingChangedMessage }
        return nil
    }
}
