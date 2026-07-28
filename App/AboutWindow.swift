//
//  AboutWindow.swift
//  Manifold
//
//  Manifold ▸ About Manifold. App identity read from the bundle, plus the third-party
//  attributions and the licence texts those components require us to reproduce.
//
//  ── ⚠️ THE LICENCE TEXT IS NOT WRITTEN HERE, AND MUST NEVER BE ─────────────────────────
//
//  Every licence body shown by this window is a VERBATIM COPY of a file that shipped with
//  the component, copied into App/Licenses/ and read back out of the app bundle at runtime.
//  Not one character of it is typed from memory. That is not fastidiousness: a licence
//  paraphrased from recollection is a licence we are not actually complying with, and the
//  difference is invisible until someone with standing reads it.
//
//  ⚠️ NOTHING IS TRIMMED, INCLUDING THE PARTS THAT LOOK IRRELEVANT. FFmpeg's LICENSE.md
//  enumerates GPL filters this build does not enable, and Mbed TLS's LICENSE carries the
//  full GPL-2.0 text next to the Apache-2.0 we actually take. Both stay, whole: reproducing
//  an upstream file unedited is the reading that cannot be argued with, and an edited
//  licence is a licence we have taken a position on.
//
//  `provenance` on each entry records the on-disk path the copy came from, so any claim in
//  this window can be re-checked against the source tree rather than trusted.
//
//  ── THE TWO TIERS, AND WHY THE SPLIT IS PRESENTATION ONLY ──────────────────────────────
//
//  This started as one continuous scroll of ~96 KB. Legally complete, and unreadable: the
//  first thing on screen was FFmpeg's GPL filter list, followed by 26 KB of LGPL, before
//  the reader had learned what FFmpeg is even doing here.
//
//    TIER 1, "Credits" — one line per component: name, version, licence, what it does.
//                        The whole list fits without scrolling. This is what gets read.
//    TIER 2, "Licences" — the verbatim texts, one component at a time from a popup, plus an
//                        "All licences" option that concatenates the lot.
//
//  EXACTLY THE SAME BYTES SHIP EITHER WAY. Tier 2 shows every file in App/Licenses/ in
//  full; tier 1 adds no legal claim it does not also make in tier 2.
//
//  ── WHY A SEGMENTED CONTROL AND NOT A DISCLOSURE GROUP PER COMPONENT ───────────────────
//
//  Both were on the table. The deciding factor is the same NSTextView constraint that put
//  the text in AppKit in the first place:
//
//    * DISCLOSURE PER COMPONENT means N text views nested inside an outer ScrollView, each
//      sized to its own content. An NSTextView has no useful intrinsic height, so every one
//      of them needs manual layout measurement, and an AppKit scroll view inside a SwiftUI
//      ScrollView fights over scroll events. Rendering the big ones as SwiftUI `Text`
//      instead brings back the stutter that AppKit was chosen to avoid.
//    * SEGMENTED CONTROL + A PER-COMPONENT POPUP keeps exactly ONE text view, non-nested,
//      holding at most ~31 KB (FFmpeg's two documents) instead of 96 KB. It is both the
//      simpler code and the faster one, and the popup makes the corpus navigable in a way
//      the single scroll never was.
//
//  ── WHAT IS DELIBERATELY ABSENT ────────────────────────────────────────────────────────
//
//  Two components' full agreements are NOT reproduced, because reproducing them would
//  itself breach the terms:
//
//    * The NDI SDK License Agreement is designated Confidential Information by its own
//      clause 3(a), and clause 2(d) forbids distributing SDK files unless the SDK
//      identifies them as distributable. `licenses/libndi_licenses.txt` IS so identified
//      ("This file should be included with all distribution of the binary files included
//      with the NDI SDK"), so that is what ships, alongside the public licence URL.
//    * The Blackmagic DeckLink SDK EULA governs the SDK, which we do not redistribute.
//      What we compile is one file out of Mac/include, and the licence for THAT is the
//      per-file notice in its own header — which is what is reproduced.
//
//  ⚠️ THOSE TWO ARE ALSO THE ONLY COMPONENTS WITH EXPLICIT ATTRIBUTION REQUIREMENTS, so
//  their trademark and copyright statements sit in TIER 1, in front of the reader, and not
//  only in the licence pane behind a popup. See `requiredNotices`.
//
//  ── LGPL: THIS WINDOW IS NOT THE WHOLE OBLIGATION ──────────────────────────────────────
//
//  FFmpeg is LGPL-2.1-or-later and is DYNAMICALLY linked — five dylibs in
//  Contents/Frameworks, loaded via @rpath. That is not an implementation detail, it is the
//  §6(b) compliance mechanism: §6 requires the user be able to RELINK the application
//  against a modified FFmpeg, which static linking makes impossible.
//
//  ⚠️ THIS FILE IS NOW PART OF THE COMPLIANCE, NOT JUST A CREDIT LIST. The FFmpeg entry
//  carries the §6(c) WRITTEN OFFER and the step-by-step relink instructions, and it is the
//  only place an end user — who has the .app and not this repo — can find either. Do not
//  trim it for length. Two of its facts cannot be checked by the compiler and are asserted
//  instead by scripts/release-mac.sh at preflight:
//
//    * `licensingContact` must not still be the placeholder (an offer naming an unread
//      address is not an offer);
//    * `ffmpegSourceURL` must equal the URL derived from the FFmpeg pin in
//      scripts/build_ffmpeg.sh, so the app cannot offer source at a URL nobody uploaded.
//
//  See docs/THIRD_PARTY_NOTICES.md for the full obligation and how each half is discharged.
//

import AppKit
import SwiftUI

// MARK: - The attribution list

/// One reproduced licence file. `resource` is a basename in App/Licenses/, bundled as a
/// resource and read back at runtime; `title` is the heading shown above it, which matters
/// where a component ships two (FFmpeg's own LICENSE.md *and* the LGPL text it points at).
struct LicenseDoc {
    let title: String
    let resource: String
}

/// One credited component.
///
/// The tier-1 fields (`name`, `version`, `licenseShort`, `role`) are deliberately terse — they
/// have one line between them. The tier-2 fields (`license`, `provenance`, `note`) carry the
/// qualifications that line has no room for, and NOTHING TRUE LIVES ONLY IN TIER 1: the short
/// form never states something the long form contradicts or omits.
struct Attribution {
    /// Where this sits in the credits list. Not cosmetic — a reader scanning for "what is this
    /// app built on" wants the six things we chose, not the four that came along with one of them.
    enum Tier { case primary, transitive }

    /// Tier-1 display name. Short enough for a table column.
    let name: String
    /// Tier-2 heading — the full legal name, with the vendor where that is the credited party.
    let fullName: String
    /// Tier-1 version. "—" when the component ships no version string; `note` says so.
    let version: String
    /// Tier-1 licence, as the bare SPDX-ish identifier. Qualifications go in `license`.
    let licenseShort: String
    /// One clause: what this component does in Manifold. Tier 1's whole point.
    let role: String
    let tier: Tier
    /// Tier-2 licence description, including dual-licence choices and what governs what.
    let license: String
    /// Where the licence text was taken from, as an on-disk path. Shown in the licence pane so
    /// the claim is checkable, and so a future audit knows which tree to diff against.
    let provenance: String
    /// Anything true about this component that the licence name alone does not convey —
    /// how it is linked, which half of a dual licence we take, what is not reproduced.
    let note: String?
    /// The verbatim texts for this component. Empty only if nothing is reproduced.
    let documents: [LicenseDoc]
}

enum Attributions {

    // MARK: LGPL §6 — the two facts the FFmpeg offer depends on

    /// Where the complete corresponding source for the shipped FFmpeg libraries is published.
    ///
    /// ⚠️ THIS STRING AND `scripts/build_ffmpeg.sh` MUST AGREE, and nothing at compile time can
    /// check that. The filename carries the short commit SHA of the FFmpeg pin, so bumping the
    /// pin changes the URL — and a stale copy here would leave the app making a written offer
    /// that points at a URL nobody ever uploaded.
    ///
    /// `scripts/release-mac.sh` therefore asserts, at preflight, that this literal equals the
    /// `SOURCE_URL` that `build_ffmpeg.sh --source-info` derives from the pin. The pin is the
    /// single source of truth; this is a copy that is CHECKED rather than trusted.
    static let ffmpegSourceURL =
        "https://releases.graviton.tools/manifold/source/ffmpeg-n8.1.1-239f2c733de4.tar.xz"

    /// Where a §6(c) request is sent.
    ///
    /// ⚠️ A WRITTEN OFFER NAMING AN ADDRESS NOBODY READS IS NOT AN OFFER. This deliberately
    /// holds an unusable placeholder — `.invalid` is reserved by RFC 2606 and can never be a
    /// real domain — so that it cannot be mistaken for a working address, and
    /// `scripts/release-mac.sh` refuses to build a release while it is still here.
    ///
    /// Replace with a monitored mailbox that will still be monitored in three years. A personal
    /// address is a poor choice for a commitment with that lifetime; an alias is better.
    static let licensingContact = "SET-BEFORE-RELEASE@example.invalid"

    /// ⚠️ EVERY VERSION BELOW WAS READ OUT OF THE BUILD TREE, not off a website. libsrt from
    /// its CMakeLists `SRT_VERSION`, libdatachannel/libjuice/libsrtp2 likewise, Mbed TLS from
    /// `MBEDTLS_VERSION_STRING`, FFmpeg from the source tarball name, NDI from the SDK's own
    /// Version.txt. Where a component ships no version string at all, it says so.
    ///
    /// ORDER IS BY PROMINENCE, NOT ALPHABET. The six `.primary` entries are the dependencies
    /// Manifold chose; the four `.transitive` ones arrived inside libdatachannel and are
    /// credited because they are linked, not because a user would look for them.
    static let all: [Attribution] = [
        Attribution(
            name: "FFmpeg",
            fullName: "FFmpeg — libavformat, libavcodec, libavutil, libswscale, libswresample",
            version: "n8.1.1",
            licenseShort: "LGPL-2.1-or-later",
            role: "Demuxes and decodes files and SRT streams",
            tier: .primary,
            license: "LGPL-2.1-or-later",
            provenance: "git.ffmpeg.org/ffmpeg.git @ n8.1.1 "
                + "(239f2c733de417201d7ad3b3b8b0d9b63285b2b1); LICENSE.md and COPYING.LGPLv2.1",
            note: """
                  DYNAMICALLY LINKED, and deliberately so. The five libraries ship as separate \
                  dylibs in Manifold.app/Contents/Frameworks, loaded at run time through @rpath, \
                  precisely so that you can replace them — see RELINKING below. This is what \
                  LGPL 2.1 §6(b) asks for, and it is why they are not compiled into the \
                  application binary.

                  Built with neither --enable-gpl nor --enable-nonfree nor --enable-version3 \
                  (config.h: CONFIG_GPL 0, CONFIG_NONFREE 0, CONFIG_VERSION3 0), so the LGPL — \
                  not the GPL — applies to this build. The GPL filters and tools enumerated in \
                  LICENSE.md below are NOT enabled here; that file is reproduced unedited rather \
                  than trimmed to the parts that apply.

                  ─────────────────────────────────────────────────────────────────────────
                  COMPLETE CORRESPONDING SOURCE (LGPL 2.1 §6)
                  ─────────────────────────────────────────────────────────────────────────

                  These libraries are UNMODIFIED upstream FFmpeg — no patch of ours is applied \
                  to any file. That was verified by comparing every file tracked at the commit \
                  below against the tree the shipped libraries were built from.

                      Release tag : n8.1.1
                      Commit      : 239f2c733de417201d7ad3b3b8b0d9b63285b2b1
                      Upstream    : https://git.ffmpeg.org/ffmpeg.git
                                    https://github.com/FFmpeg/FFmpeg.git  (official mirror)

                  The exact source these libraries were built from, including a BUILD.txt \
                  recording the configure line, is published at:

                      \(Attributions.ffmpegSourceURL)

                  Configured exactly as follows. ("Corresponding source" means the source AS \
                  BUILT, so the configuration is part of what is being disclosed. The --prefix \
                  argument is omitted: it is a local install path and does not affect the code \
                  produced.)

                      ./configure \\
                        --enable-shared \\
                        --disable-static \\
                        --install-name-dir=@rpath \\
                        --disable-programs \\
                        --disable-doc \\
                        --disable-autodetect \\
                        --disable-network \\
                        --disable-everything \\
                        --enable-decoder=dnxhd \\
                        --enable-decoder=prores \\
                        --enable-decoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_f32le,aac,aac_latm \\
                        --enable-demuxer=mov \\
                        --enable-demuxer=mxf \\
                        --enable-demuxer=mpegts \\
                        --enable-parser=h264 \\
                        --enable-protocol=file \\
                        --enable-swscale \\
                        --disable-x86asm \\
                        --extra-cflags=-mmacosx-version-min=15.0 \\
                        --extra-ldflags=-mmacosx-version-min=15.0

                  WRITTEN OFFER. For three years from the date this build was published, we \
                  will supply the complete corresponding source for these libraries to any \
                  third party, on request, for no more than the cost of physically performing \
                  the distribution. Write to \(Attributions.licensingContact).

                  ─────────────────────────────────────────────────────────────────────────
                  RELINKING MANIFOLD AGAINST YOUR OWN FFmpeg (LGPL 2.1 §6b)
                  ─────────────────────────────────────────────────────────────────────────

                  You may replace the FFmpeg libraries in this application with your own build, \
                  modified or not. These steps are tested and work on a signed, notarized copy.

                  1. Build FFmpeg as shared libraries. The configure line above reproduces ours; \
                     any configuration producing the same library major versions will link. The \
                     bundle expects exactly these names:

                         libavcodec.62.dylib    libavformat.62.dylib   libavutil.60.dylib
                         libswscale.9.dylib     libswresample.6.dylib

                  2. Give each one an @rpath install name, so the app can find it. Building with \
                     --install-name-dir=@rpath does this for you; otherwise:

                         install_name_tool -id @rpath/libavcodec.62.dylib libavcodec.62.dylib

                  3. Copy it into the bundle, replacing ours:

                         cp libavcodec.62.dylib \\
                            /Applications/Manifold.app/Contents/Frameworks/

                  4. Sign the replacement. macOS will not load unsigned code on Apple Silicon, \
                     so an ad-hoc signature is required even for a local build:

                         codesign --force --sign - \\
                            /Applications/Manifold.app/Contents/Frameworks/libavcodec.62.dylib

                  5. Re-sign the application. Your replacement has broken the bundle's signature \
                     seal — codesign will report "nested code is modified or invalid" until you \
                     do this:

                         codesign --force --sign - /Applications/Manifold.app

                  6. Clear the quarantine flag if the copy has one, and launch:

                         xattr -dr com.apple.quarantine /Applications/Manifold.app
                         open /Applications/Manifold.app

                  Step 5 leaves the app ad-hoc signed rather than signed by us, which is \
                  expected and correct for a locally-relinked build: it is no longer the binary \
                  we notarized, and it should not claim to be. Loading a library signed by \
                  someone other than us is permitted because this application is built with the \
                  com.apple.security.cs.disable-library-validation entitlement — that \
                  entitlement is part of what makes this right exercisable, not an oversight.
                  """,
            documents: [
                LicenseDoc(title: "FFmpeg LICENSE.md, as shipped upstream",
                           resource: "FFmpeg-LICENSE.md"),
                LicenseDoc(title: "GNU Lesser General Public License v2.1 — full text",
                           resource: "LGPL-2.1"),
            ]),
        Attribution(
            name: "libsrt",
            fullName: "libsrt (Haivision SRT)",
            version: "1.5.6",
            licenseShort: "MPL-2.0",
            role: "The SRT transport",
            tier: .primary,
            license: "MPL-2.0",
            provenance: "~/manifold-srt-build/srt/LICENSE",
            note: "Statically linked. Its LICENSE file is byte-identical to the MPL-2.0 text "
                + "below (verified by SHA-1), shared with libdatachannel and libjuice — one copy "
                + "ships and all three point at it.",
            documents: [LicenseDoc(title: "Mozilla Public License 2.0 — full text",
                                   resource: "MPL-2.0")]),
        Attribution(
            name: "libdatachannel",
            fullName: "libdatachannel",
            version: "0.24.5",
            licenseShort: "MPL-2.0",
            role: "The WHEP / WebRTC transport",
            tier: .primary,
            license: "MPL-2.0",
            provenance: "~/manifold-webrtc-build/libdatachannel/LICENSE",
            note: "Statically linked. Same MPL-2.0 text as libsrt and libjuice.",
            documents: [LicenseDoc(title: "Mozilla Public License 2.0 — full text",
                                   resource: "MPL-2.0")]),
        Attribution(
            name: "Mbed TLS",
            fullName: "Mbed TLS",
            version: "3.6.7",
            licenseShort: "Apache-2.0",
            role: "DTLS for WHEP; AES for SRT passphrases",
            tier: .primary,
            license: "Apache-2.0 (dual-licensed Apache-2.0 OR GPL-2.0-or-later)",
            provenance: "~/manifold-webrtc-build/mbedtls/LICENSE",
            note: "Statically linked; the DTLS backend for libdatachannel and the AES/PBKDF2 "
                + "provider for libsrt's stream passphrase. Mbed TLS lets the user choose which "
                + "licence to take it under — WE TAKE APACHE-2.0. The upstream LICENSE file "
                + "below carries BOTH texts, including the GPL-2.0 half we are not taking, "
                + "because it is reproduced unedited.",
            documents: [LicenseDoc(title: "Mbed TLS LICENSE — Apache-2.0 and GPL-2.0, as shipped upstream",
                                   resource: "mbedtls-LICENSE")]),
        Attribution(
            name: "NDI® SDK",
            fullName: "NDI® SDK — Vizrt NDI AB",
            version: "6.3.2.0",
            licenseShort: "Proprietary",
            role: "NDI send/receive — runtime-loaded, not linked",
            tier: .primary,
            license: "NDI SDK License Agreement (proprietary)",
            provenance: "/Library/NDI SDK for Apple/licenses/libndi_licenses.txt "
                + "and NDI SDK License Agreement.pdf",
            note: """
                  SDK build NDI 2026-04-13 git-5396c5f1. NOT LINKED — the NDI runtime is loaded \
                  dynamically at run time if the user has installed it; Manifold ships no NDI \
                  binary. The SDK licence itself is at http://ndi.link/ndisdk_license and is not \
                  reproduced here: the agreement designates the SDK confidential and permits \
                  distribution only of files the SDK identifies as distributable. The third-party \
                  notice file below IS one of those ("This file should be included with all \
                  distribution of the binary files included with the NDI SDK"), so it ships \
                  verbatim.
                  """,
            documents: [LicenseDoc(title: "NDI SDK third-party notices (libndi_licenses.txt)",
                                   resource: "NDI-libndi_licenses")]),
        Attribution(
            name: "DeckLink SDK",
            fullName: "Blackmagic DeckLink SDK — Blackmagic Design Pty. Ltd.",
            version: "16.0",
            licenseShort: "Per-file notice",
            role: "SDI output via Desktop Video",
            tier: .primary,
            license: "Per-file permission notice; SDK governed by the Blackmagic SDK EULA",
            provenance: "docs/BlackmagicDeckLinkSDK16.0/Mac/include/DeckLinkAPIDispatch.cpp "
                + "(header notice) and End User License Agreement.pdf",
            note: """
                  Only DeckLinkAPIDispatch.cpp and the Mac/include headers are used, and the EULA's \
                  clause 0.1 excludes exactly those files from its clauses 1, 4.3, 4.4, 5, 7 and 8. \
                  The notice reproduced below is the licence carried in that file's own header. The \
                  runtime is the user's installed Desktop Video driver; no Blackmagic binary is \
                  shipped. The EULA itself is not reproduced — we redistribute no part of the SDK \
                  it governs — and is at https://www.blackmagicdesign.com/EULA/DeckLinkSDK.
                  """,
            documents: [LicenseDoc(title: "DeckLink SDK per-file permission notice",
                                   resource: "DeckLinkSDK-NOTICE")]),

        // ── Transitive: linked, but arrived inside libdatachannel rather than being chosen. ──
        Attribution(
            name: "libjuice",
            fullName: "libjuice (ICE, bundled with libdatachannel)",
            version: "1.7.2",
            licenseShort: "MPL-2.0",
            role: "ICE candidate gathering",
            tier: .transitive,
            license: "MPL-2.0",
            provenance: "~/manifold-webrtc-build/libdatachannel/deps/libjuice/LICENSE",
            note: "Statically linked. Same MPL-2.0 text as libsrt and libdatachannel.",
            documents: [LicenseDoc(title: "Mozilla Public License 2.0 — full text",
                                   resource: "MPL-2.0")]),
        Attribution(
            name: "usrsctp",
            fullName: "usrsctp (SCTP, bundled with libdatachannel)",
            version: "—",
            licenseShort: "BSD-3-Clause",
            role: "SCTP data channels",
            tier: .transitive,
            license: "BSD-3-Clause",
            provenance: "~/manifold-webrtc-build/libdatachannel/deps/usrsctp/LICENSE.md",
            note: "Statically linked. Vendored as a libdatachannel submodule; its CMakeLists "
                + "declares no project version, so NO VERSION IS CLAIMED rather than one guessed.",
            documents: [LicenseDoc(title: "usrsctp LICENSE.md", resource: "usrsctp-LICENSE")]),
        Attribution(
            name: "libsrtp2",
            fullName: "libsrtp2 (SRTP, bundled with libdatachannel)",
            version: "2.8.0",
            licenseShort: "BSD-3-Clause",
            role: "SRTP media encryption",
            tier: .transitive,
            license: "BSD-3-Clause",
            provenance: "~/manifold-webrtc-build/libdatachannel/deps/libsrtp/LICENSE",
            note: "Statically linked.",
            documents: [LicenseDoc(title: "libsrtp LICENSE", resource: "libsrtp-LICENSE")]),
        Attribution(
            name: "plog",
            fullName: "plog (logging, compiled into libdatachannel)",
            version: "bundled 0.24.5",
            licenseShort: "MIT",
            role: "Logging inside libdatachannel",
            tier: .transitive,
            license: "MIT",
            provenance: "~/manifold-webrtc-build/libdatachannel/deps/plog/LICENSE",
            note: "Header-only; confirmed present in the shipped archive (its symbols appear in "
                + "libdatachannel.a). nlohmann/json is vendored alongside it but is NOT compiled "
                + "in — no symbols — so it is not credited.",
            documents: [LicenseDoc(title: "plog LICENSE", resource: "plog-LICENSE")]),
    ]

    static var primary: [Attribution] { all.filter { $0.tier == .primary } }
    static var transitive: [Attribution] { all.filter { $0.tier == .transitive } }

    /// ⚠️ THE TWO STATEMENTS WE ARE CONTRACTUALLY REQUIRED TO MAKE, kept in TIER 1.
    ///
    /// Everything else in this window is attribution we choose to give. These two are terms:
    /// the NDI SDK licence's 3(f) (marks used only to identify compatibility, clearly noted as
    /// NDI's, no implication of sponsorship) and 3(g)/3(d)(vi) (NDI's copyright alongside ours);
    /// and the Blackmagic EULA's 6.2 (the permitted compatibility phrasing). Putting them behind
    /// a popup would satisfy the letter and miss the point — a notice nobody sees is not notice.
    static let requiredNotices: [String] = [
        """
        NDI® is a registered trademark of Vizrt NDI AB, used here solely to identify \
        compatibility. Manifold is not a Vizrt product; Vizrt neither sponsors nor endorses it. \
        Copyright (C) 2023-2026 Vizrt NDI AB. All rights reserved.
        """,
        """
        DeckLink is a trademark of Blackmagic Design Pty. Ltd., used here solely to state that \
        Manifold is compatible with Blackmagic Design DeckLink hardware. Portions of the DeckLink \
        SDK are Copyright (c) 2009 Blackmagic Design, used under the permission notice reproduced \
        under Licences. Manifold is not a Blackmagic Design product.
        """,
    ]

    // MARK: Licence text

    /// What the licence pane is currently showing.
    enum Selection: Hashable {
        case component(Int)
        case everything
    }

    /// The tier-2 body for one selection. Built on demand — at most ~31 KB for a single
    /// component, against 96 KB for `.everything`, which is the whole reason the popup exists.
    static func text(for selection: Selection) -> String {
        switch selection {
        case .component(let index):
            guard all.indices.contains(index) else { return "" }
            return body(for: all[index])
        case .everything:
            return all.map(body(for:)).joined()
        }
    }

    private static func body(for entry: Attribution) -> String {
        var out = String(repeating: "─", count: 78) + "\n"
        out += entry.fullName + "\n"
        out += "Version:    \(entry.version)\n"
        out += "Licence:    \(entry.license)\n"
        out += "Source:     \(entry.provenance)\n"
        if let note = entry.note {
            out += "\n" + note.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        out += "\n"
        for doc in entry.documents {
            out += "── \(doc.title) " + String(repeating: "─", count: max(0, 74 - doc.title.count))
            out += "\n\n" + loadLicense(doc.resource) + "\n\n"
        }
        return out
    }

    /// Read a bundled licence file. A MISSING FILE IS REPORTED IN THE PANEL, not silently
    /// skipped: an attribution window that quietly omits a licence it claims to show is worse
    /// than one that admits the file did not make it into the bundle.
    private static func loadLicense(_ resource: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("[ABOUT] ⚠️ licence resource missing from the bundle: %@.txt", resource)
            return "[ licence text \"\(resource).txt\" is missing from this build — this is a "
                 + "packaging fault, please report it ]"
        }
        return text
    }

    /// Every distinct resource the table declares. Deduplicated — MPL-2.0 is claimed by three
    /// components and is one file.
    static var declaredResources: [String] {
        var seen = Set<String>()
        return all.flatMap(\.documents).map(\.resource).filter { seen.insert($0).inserted }
    }

    /// ⚠️ RUNS ONCE, WHEN THE WINDOW OPENS, AND CHECKS EVERY DECLARED FILE — not just the one
    /// the reader happens to select. Under the old single-document panel every licence was
    /// loaded at launch, so a packaging fault announced itself immediately; loading per
    /// selection would have made a missing file discoverable only by someone who picked that
    /// exact component. This restores the earlier guarantee: the log line and the banner fire
    /// on open regardless of what is selected, and `loadLicense`'s on-screen message still
    /// appears in the text itself if the reader does select it.
    static let missingResources: [String] = {
        declaredResources.filter { Bundle.main.url(forResource: $0, withExtension: "txt") == nil }
    }()
}

// MARK: - The window

/// Scene identity, spelled once. The menu command and the `Window` scene must agree on this
/// string or the menu item opens nothing at all, silently.
enum AboutScene {
    static let windowID = "about"
}

struct AboutView: View {
    private enum Tab: Hashable { case credits, licences }

    @State private var tab: Tab = .credits
    @State private var selection: Attributions.Selection = .component(0)

    /// Bundle-derived, never hardcoded: the version in this window and the version Finder shows
    /// are then the same fact read twice, and cannot drift.
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Manifold"
    }
    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
    private var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appName).font(.title2.weight(.semibold))
                Text("Version \(shortVersion) (build \(buildNumber))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let copyright {
                    Text(copyright).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Picker("", selection: $tab) {
                Text("Credits").tag(Tab.credits)
                Text("Licences").tag(Tab.licences)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            switch tab {
            case .credits:  creditsPane
            case .licences: licencesPane
            }
        }
        .frame(width: 620, height: 620)
        .onAppear {
            // Touching the lazy static is what runs the preflight; the log fires from there.
            let missing = Attributions.missingResources
            if !missing.isEmpty {
                NSLog("[ABOUT] ⚠️ %d licence resource(s) missing from the bundle: %@",
                      missing.count, missing.joined(separator: ", "))
            }
        }
    }

    // MARK: Tier 1 — credits

    private var creditsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !Attributions.missingResources.isEmpty {
                    // The banner half of the missing-file guarantee. Red, at the top, before the
                    // credits — a packaging fault in the licence texts is not a footnote.
                    Text("⚠️ \(Attributions.missingResources.count) licence text(s) failed to "
                       + "bundle in this build: \(Attributions.missingResources.joined(separator: ", ")). "
                       + "This is a packaging fault — please report it.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                creditsTable("Built on", Attributions.primary)
                creditsTable("Bundled with libdatachannel", Attributions.transitive)

                Divider()

                // The contractually required statements. See `Attributions.requiredNotices`.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Attributions.requiredNotices, id: \.self) { notice in
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Full licence texts are under “Licences” above.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One tier-1 block. A `Grid` and not an `HStack` per row so the four columns line up down
    /// the list — the point of a one-line-per-component table is that it can be scanned
    /// vertically, which ragged columns defeat.
    @ViewBuilder
    private func creditsTable(_ title: String, _ entries: [Attribution]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(entries, id: \.fullName) { entry in
                    GridRow {
                        Text(entry.name)
                            .font(.callout.weight(.medium))
                            .gridColumnAlignment(.leading)
                            .frame(width: 116, alignment: .leading)
                        Text(entry.version)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)
                        Text(entry.licenseShort)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 104, alignment: .leading)
                        Text(entry.role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Tier 2 — verbatim licences

    private var licencesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Show:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $selection) {
                    ForEach(Array(Attributions.all.enumerated()), id: \.offset) { index, entry in
                        Text(entry.name).tag(Attributions.Selection.component(index))
                    }
                    Divider()
                    // The escape hatch for anyone who wants the corpus in one selectable block —
                    // the old behaviour, kept, but no longer what the window opens on.
                    Text("All licences").tag(Attributions.Selection.everything)
                }
                .labelsHidden()
                .frame(width: 220)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            LicenseTextView(text: Attributions.text(for: selection),
                            documentID: String(describing: selection))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The licence body: ONE NSTextView, not a SwiftUI `ScrollView` of `Text`s.
///
/// A single component is up to ~31 KB and "All licences" is ~96 KB. A `LazyVStack` of `Text`
/// views measures and lays out every string it has instantiated, and the MPL, LGPL and Apache
/// texts are each long enough that the scroll stutters visibly; `TextEditor` is a text view
/// anyway but brings editing behaviour that has to be switched back off. AppKit's text system is
/// built for exactly this — a long read-only selectable document — so it is used directly.
///
/// Selectable, NOT editable, so a user can copy a licence out. No rich text, no links: the plain
/// panel that was asked for.
private struct LicenseTextView: NSViewRepresentable {
    let text: String
    /// Cheap identity for the current document. Compared instead of the 96 KB string itself, and
    /// it is what stops a re-render from resetting the reader's scroll position mid-licence.
    let documentID: String

    final class Coordinator {
        var documentID: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textColor = .secondaryLabelColor
        // Wrap to the view's width rather than scrolling horizontally — licence texts are
        // hard-wrapped at ~72 columns already, but the notes above them are not.
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        context.coordinator.documentID = documentID
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard context.coordinator.documentID != documentID,
              let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.documentID = documentID
        textView.string = text
        // A new document starts at the top. Without this the view keeps the previous
        // document's scroll offset, which lands the reader in the middle of a licence
        // they did not choose.
        textView.scroll(NSPoint(x: 0, y: 0))
    }
}
