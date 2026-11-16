#!/usr/bin/env python3
"""Fail on British spellings in Manifold's user-facing strings.

American English everywhere a user reads (Robbie, 2026-11-15): menus, buttons, tooltips, labels,
alerts, banners, Settings, accessibility labels, export summaries and the files Manifold writes.

Scans STRING LITERALS (never comments) in App/ and Packages/*/Sources, Swift and Objective-C.
Not scanned, on purpose:
  * a literal inside a log call (NSLog, print, os_log, Logger methods, fatalError, assert…), or
    one that starts with a `[TAG]` log prefix. Log text is diagnostics, and soak/report scripts
    and tests match on it, so it changes only deliberately.
  * tests (Packages/*/Tests).
  * Resolve's marker colour names, which are proper names and contain no flagged word anyway.
Log text that is built OUTSIDE a log call (a helper returning a line that is then logged) cannot
be told apart from UI text by syntax, so it is listed in ALLOW below, by file and a snippet of the
literal. Add to ALLOW only for text that never reaches the UI or an exported file.

Usage:  python3 scripts/check-us-spelling.py [repo root]      exit 0 clean, 1 on any finding.
"""
import os
import re
import sys

# British spelling → what to write instead. Word-level; matched case-insensitively.
BRITISH = re.compile(r"""(?ix)\b(
    \w*colour\w* | grey\w* | \w*behaviour\w* | licenc\w* | \w*centr(e|es|ed|ing)\b |
    cancell(ed|ing)\b | \w*favour\w* | \w*honour\w* | \w*labour\w* | \w*neighbour\w* | \w*flavour\w* |
    \w*(label|model|travel|signal|level|dial|total|fuel|channel|cancel|tunnel|pixel)l(ed|ing)\b |
    programmes? | artefacts? | \w*catalogue\w* | analogue | dialogue | analys(e|es|ed|ing) |
    whilst | amongst | judgement | ageing | fulfil | enrol(s|ment)? | aluminium | defence | offence |
    metres? | litres? | fibres? | calibre | manoeuvr\w* |
    \w{2,}is(e|es|ed|ing|ation|ations|er|ers|able)
)\b""")

# -ise words that are American too (or not verbs at all).
ISE_OK = re.compile(r"""(?ix)^(
    \w*wise | \w*noise\w* | \w*poise\w* | \w*rais(e|es|ed|ing|er) | \w*prais\w* | \w*ris(e|es|ing|er|ers) |
    \w*cis(e|es|ed|ing|ion) | \w*vis(e|es|ed|ing|er|ers|able) | \w*guis\w* | \w*pris(e|es|ed|ing) |
    \w*mis(e|es|ed|ing) | advertis\w* | expertis\w* | chastis\w* | exercis\w* | franchis\w* |
    merchandis\w* | cruis\w* | bruis\w* | paradis\w* | treatis\w* | anis(e|ette) | chais\w* |
    \w*tois(e|es) | porpois\w* | valis\w* | turquois\w* | elis(e|es) | louis\w* | denis\w* |
    mortis\w* | precis\w* | concis\w* | excis\w* | incis\w* | dais\w* | appris\w*
)$""")
GREY_OK = re.compile(r"(?i)^(grey(hound|stone)s?)$")
# "Licence" survives only where the text is ABOUT the old spelling (release notes don't live here).
LOG_CALLS = {"NSLog", "print", "debugPrint", "os_log", "log", "trace", "debug", "info", "notice",
             "warning", "error", "fault", "critical", "fatalError", "precondition",
             "preconditionFailure", "assert", "assertionFailure", "dump", "fputs", "printf",
             "fprintf", "NSAssert", "NSCAssert", "emit"}
LOG_TAG = re.compile(r"^\s*(%@\s*)?\[[A-Z0-9][A-Z0-9 _./+-]*\]")

# (path suffix, snippet of the literal): log/diagnostic text built outside a log call.
ALLOW = [
    ("App/Live/StreamColorimetry.swift", "SPS unreadable before the colour fields"),   # spsColorLine → NSLog
    ("App/Live/StreamColorimetry.swift", "absent (no colour description)"),            # spsColorLine → NSLog
    ("App/MetalVideoRenderer.swift", "/\\(colour)"),                                    # [SCRUB-GEOM] dedupe key
    ("App/SRT/SRTFrameRouter.swift", "quantised and cannot tile"),                     # timeBaseVerdict → NSLog
    ("App/HLS/HLSClient.swift", "requested format was not honoured"),                  # first-frame verdict → NSLog
    ("App/WebRTC/DataChannelBridge.m", "synchronisable"),                              # CNAME line → NSLog
    ("Packages/ManifoldCore/Sources/LiveAudioResample/SenderReportLineFit.swift", "synchronisable"),  # → NSLog
    ("Packages/ManifoldCore/Sources/LiveAudioResample/SenderReportLineFit.swift", "RE-LEVELLED"),     # → NSLog; tests match it
    ("Packages/ManifoldCore/Sources/LicenseRecord/LicenseRecordSync.swift", "legacy licence values"), # migration log
    ("Packages/ManifoldCore/Sources/FileChroma/BitstreamColorCheck.swift", "bitstream states no colour"),  # → NSLog
]


def literals(src, objc):
    """Yield (line, text, inLogCall) for every string literal; interpolations are blanked."""
    i, n, line = 0, len(src), 1
    stack = []          # enclosing call names, one per open paren
    ident = ""          # identifier just before the cursor
    line_start = True
    while i < n:
        c = src[i]
        if objc and line_start and c == "#":                    # preprocessor line (#error "…", #import)
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if not c.isspace():
            line_start = False
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            line += src[i:j].count("\n")
            i = j
            continue
        if c == "\n":
            line, line_start = line + 1, True
            i += 1
            continue
        if objc and c == "'":                                   # C character literal
            j = i + 1
            while j < n and src[j] != "'":
                j += 2 if src[j] == "\\" else 1
            i = j + 1
            continue
        m = re.match(r'(#*)("""|")', src[i:i + 12]) if c in '"#' else None
        if m and not (objc and m.group(1)):
            hashes, q = m.group(1), m.group(2)
            start = i + len(m.group(0))
            close = q + hashes
            j, out = start, []
            while j < n and not src.startswith(close, j):
                if src[j] == "\\" and src.startswith("\\" + hashes, j):
                    k = j + 1 + len(hashes)
                    if k < n and src[k] == "(":                 # \( … ) interpolation: skip it
                        depth, k = 1, k + 1
                        while k < n and depth:
                            if src[k] == "(":
                                depth += 1
                            elif src[k] == ")":
                                depth -= 1
                            elif src[k] == '"':
                                k = src.find('"', k + 1)
                            k += 1
                        out.append(" ")
                        j = k
                        continue
                    out.append(src[j:k + 1])
                    j = k + 1
                    continue
                out.append(src[j])
                j += 1
            text = "".join(out)
            yield line, text, any(name in LOG_CALLS for name in stack)
            line += src[i:j].count("\n")
            i = j + len(close)
            ident = ""
            continue
        if c.isalnum() or c == "_":
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            ident = src[i:j]
            i = j
            continue
        if c == "(":
            stack.append(ident)
        elif c == ")" and stack:
            stack.pop()
        if not c.isspace():
            ident = ""
        i += 1


def findings(root):
    roots = [os.path.join(root, "App")]
    pk = os.path.join(root, "Packages")
    if os.path.isdir(pk):
        roots += [os.path.join(pk, p, "Sources") for p in sorted(os.listdir(pk))]
    for top in roots:
        for dp, dn, fn in os.walk(top):
            dn[:] = sorted(d for d in dn if not d.startswith(".") and d != "build")
            for f in sorted(fn):
                objc = f.endswith((".m", ".mm"))
                if not (objc or f.endswith(".swift")):
                    continue
                path = os.path.join(dp, f)
                rel = os.path.relpath(path, root)
                with open(path, encoding="utf-8") as fh:
                    src = fh.read()
                for line, text, in_log in literals(src, objc):
                    if in_log or LOG_TAG.match(text):
                        continue
                    if any(rel.endswith(p) and s in text for p, s in ALLOW):
                        continue
                    for m in BRITISH.finditer(text):
                        word = m.group(0)
                        if ISE_OK.match(word) or GREY_OK.match(word):
                            continue
                        yield rel, line, word, text.strip()


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1
                           else os.path.join(os.path.dirname(__file__), ".."))
    bad = list(findings(root))
    for rel, line, word, text in bad:
        print(f"{rel}:{line}: British spelling '{word}' in user-facing string: {text[:120]!r}")
    if bad:
        print(f"\n{len(bad)} finding(s). Use American spelling, or, for log text built outside a log "
              "call, add it to ALLOW in scripts/check-us-spelling.py.")
        return 1
    print("check-us-spelling: no British spellings in user-facing strings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
