/// What a refused DeckLink output start says to the operator (docs/BUGS.md, "output start at 2160p23.98 failed with
/// `EnableVideoOutput failed`": DaVinci Resolve was holding the output, and nothing on screen said so).
///
/// ONE REFUSAL HAS A MESSAGE: another application holding the card. Every other failure keeps its log line, which now
/// carries the call and its HRESULT. A code is mapped only once it has been measured from the real case, never from the
/// SDK's list alone: `E_FAIL` is also what a dozen unrelated failures return, and a message naming another app on one of
/// those would send the operator looking for an app that is not there.
///
/// ⚠️ NO RETRY. A busy card is freed only by the operator, in the other app. Output stays off and the message says to
/// start it again; nothing here re-attempts it.
public enum DeckLinkRefusal {
    /// EnableVideoOutput's answer while another application's video output holds the card: `E_ACCESSDENIED` on macOS
    /// (`CFPlugInCOM.h`), the SDK's "Unable to access the hardware" (DeckLink SDK 16.0 manual, §2.5.3.6).
    public static let busyHResult: UInt32 = 0x8000_0009

    /// The call whose busy answer is mapped. The same code from another call is left alone: it has not been measured.
    public static let busyCall = "EnableVideoOutput"

    public static let busyMessage =
        "DeckLink output is in use by another application (for example DaVinci Resolve). Start output again when it is free."

    /// The operator-facing message for a failed start, or nil when the failure keeps its log line only. `call` and
    /// `hresult` are the bridge's `failedCall` and `failureHResult`.
    public static func message(call: String?, hresult: Int32) -> String? {
        guard call == busyCall, UInt32(bitPattern: hresult) == busyHResult else { return nil }
        return busyMessage
    }
}
