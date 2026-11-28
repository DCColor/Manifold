//
//  ConnectingText.swift
//  Manifold — the words for a live connect that is still in flight (docs/BUGS.md, 0.9.6 UI polish item 30, batch 4).
//
//  No transport said it was connecting: between a click and a picture (or an error) the antenna stayed white and its tooltip
//  still offered to connect. Each client now publishes `isConnecting` from the moment it dials until its transport is up
//  (SRT's handshake, WHEP's DTLS, HLS's readyToPlay, NDI's receiver) or the attempt ends; while it is set the antenna pulses
//  and its tooltip reads this text. What comes after the transport is up is each transport's own business, as before:
//  SRT's "Connected, but …" banners, HLS's "not playing yet".
//

public enum ConnectingText {

    /// The antenna's tooltip while a connect is in flight. `name` is what the user picked: a saved stream's name, an NDI
    /// source's name, or a host for a pasted address. NEVER a URL: a stream path can carry the stream key. nil (or empty)
    /// is NDI's quick connect, which has not found a source yet.
    public static func tooltip(name: String?) -> String {
        guard let name, !name.isEmpty else { return "Connecting to the first NDI source…" }
        return "Connecting to \(name)…"
    }
}
