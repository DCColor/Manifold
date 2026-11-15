//
//  ShareLabel.swift
//  FrameShareFormat — what Share Frame is called, and what its file is called, for an HDR picture (Robbie, 2026-11-15).
//
//  A PQ or HLG PICTURE (the picture codes: the source's, or a LUT's stated output, CLAUDE.md colour-codes rule) is
//  tone-mapped to SDR for sharing (`ShareJPEG`), so the menu items and the button's tooltip read "Share Frame (SDR)…" and
//  the shared file's name ends in " SDR", e.g. "MyClip 01-02-14-05 SDR.jpg". An SDR picture is unchanged.
//

import Foundation

public enum ShareLabel {

    /// PQ (16) or HLG (18): the transfers Share tone-maps.
    public static func isHDR(transfer: Int?) -> Bool { transfer == 16 || transfer == 18 }

    /// The menu items' and the Share button tooltip's words.
    public static func title(pictureIsHDR: Bool) -> String { pictureIsHDR ? "Share Frame (SDR)…" : "Share Frame…" }

    /// The shared JPEG's file name: the base, the pixel-aspect tag when there is one, " SDR" for an HDR picture, ".jpg".
    public static func fileName(base: String, parTag: String?, pictureIsHDR: Bool) -> String {
        base + (parTag.map { "_\($0)" } ?? "") + (pictureIsHDR ? " SDR" : "") + ".jpg"
    }
}
