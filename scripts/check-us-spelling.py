#!/usr/bin/env python3
"""Fail on British spellings in Manifold's user-facing strings.

American English everywhere a user reads (Robbie, 2026-11-15): menus, buttons, tooltips, labels,
alerts, banners, Settings, accessibility labels, export summaries and the files Manifold writes.

Scans STRING LITERALS (never comments) in App/ and Packages/*/Sources, Swift and Objective-C, and the
release notes as text: RELEASE_NOTES.md and docs/release-notes/*.md (Robbie, 2026-11-16).
Also flags day-month-year dates ("16 November 2026"): write "November 16, 2026".
Not scanned, on purpose:
  * a literal inside a log call (NSLog, print, os_log, Logger methods, fatalError, assert…), or
    one that starts with a `[TAG]` log prefix. Log text is diagnostics, and soak/report scripts
    and tests match on it, so it changes only deliberately.
  * tests (Packages/*/Tests).
  * Resolve's marker colour names, which are proper names and contain no flagged word anyway.
Log text that is built OUTSIDE a log call (a helper returning a line that is then logged) cannot
be told apart from UI text by syntax, so it is listed in ALLOW below, by file and a snippet of the
literal. Add to ALLOW only for text that never reaches the UI or an exported file.

--logs scans exactly the text the default run skips: log-call literals, `[TAG]` literals and the ALLOW
entries (American since 2026-11-20, docs/BUGS.md *American English in log lines*). Soak/report scripts and tests match on log text: before changing a line, grep
Packages/*/Tests, scripts/ and the soak folders for it and change every matcher with it.

"tick" is flagged only in its British checkbox sense (TICK_UI); a clock tick passes everywhere. Every run first
checks the rules against SELF_CHECK, strings that must pass and must fail, and exits 2 if any does not.

Usage:  python3 scripts/check-us-spelling.py [--logs] [repo root]
        exit 0 clean, 1 on any finding, 2 if the self-check fails.
"""
import os
import re
import sys

# British spelling → what to write instead. Word-level; matched case-insensitively.
BRITISH = re.compile(r"""(?ix)\b(
    \w*colour\w* | grey\w* | \w*behaviour\w* | licenc\w* | \w*centr(e|es|ed|ing)\b |
    cancell(ed|ing)\b | \w*favour\w* | \w*honour\w* | \w*labour\w* | \w*neighbour\w* | \w*flavour\w* |
    \w*(label|model|travel|signal|level|dial|total|fuel|channel|cancel|tunnel|pixel)l(ed|ing)\b |
    programmes? | artefacts? | \w*catalogue\w* | analogue | analys(e|es|ed|ing) |
    untick\w* |
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
# "dialogue" is allowed (Robbie, 2026-11-16).
# "tick" is British only as a checkbox verb or state ("tick the box", "tick only if", "is ticked"); "untick*" is
# always flagged (BRITISH above). A clock tick ("display link tick", "no tick in 500 ms", "has not ticked",
# "tick=%.4f", "heartbeat tick(s)") is American too and passes. Write check / select / uncheck / checked instead.
_TICK_OBJ = r"(box|boxes|checkbox|checkboxes|option|options|setting|settings|item|items|button|toggle)"
TICK_UI = re.compile(r"""(?ix)
    \btick(s|ed|ing)?[\s-]?box(es)?\b                                         # tick box, tickbox, tick-box
  | \btick(s|ing)?\s+(the|this|that|a|an|each|every|both|any|one|it|them)\s+(\S+\s+){0,3}?""" + _TICK_OBJ + r"""\b
  | \btick\s+only\s+(if|when)\b                                               # "tick only if"
  | (^|[.!?;:]\s+|[(“"‘']\s*)tick\s+(to|here|it|this|the|a|an|each|every|both|any|one|only|if|when|once)\b
                                                                               # sentence-initial imperative
  | \b(is|are|was|were|be|been|being|stays?|remains?|left|keep|kept|box|checkbox|option|setting|item|when|if
        |while|once|unless)\s+ticked\b                                          # checkbox state
  | \bticked\s+by\s+default\b
""")
# Day-month-year dates, in any scanned text.
DMY = re.compile(r"(?i)\b\d{1,2} (January|February|March|April|May|June|July|August|September|October|November|"
                 r"December) \d{4}\b")
GREY_OK = re.compile(r"(?i)^(grey(hound|stone)s?)$")
# "Licence" survives only where the text is ABOUT the old spelling (release notes don't live here).
LOG_CALLS = {"NSLog", "print", "debugPrint", "os_log", "log", "trace", "debug", "info", "notice",
             "warning", "error", "fault", "critical", "fatalError", "precondition",
             "preconditionFailure", "assert", "assertionFailure", "dump", "fputs", "printf",
             "fprintf", "NSAssert", "NSCAssert", "emit"}
LOG_TAG = re.compile(r"^\s*(%@\s*)?\[[A-Z0-9][A-Z0-9 _./+-]*\]")

# (path suffix, snippet of the literal): log/diagnostic text built outside a log call.
ALLOW = [
    ("App/MetalVideoRenderer.swift", "/\\(colour)"),                                    # [SCRUB-GEOM] dedupe key
]

# (file, snippet of the line): release-note text that is ABOUT a British spelling, so must keep it.
NOTES_ALLOW = [
    ("RELEASE_NOTES.md", 'some text read "licence" where it should have read "license"'),   # a fix note
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


def findings(root, logs=False):
    """logs=False: user-facing literals (log text skipped). logs=True: only the log text the default skips."""
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
                    skipped = bool(in_log or LOG_TAG.match(text)
                                   or any(rel.endswith(p) and s in text for p, s in ALLOW))
                    if skipped != logs:
                        continue
                    for word, why in check_text(text):
                        where = " in log text" if logs else " in user-facing string"
                        yield rel, line, word, why + where, text.strip()


def check_text(text):
    """Yield (word, why) for every finding in one piece of text."""
    for m in BRITISH.finditer(text):
        word = m.group(0)
        if not (ISE_OK.match(word) or GREY_OK.match(word)):
            yield word, "British spelling"
    for m in TICK_UI.finditer(text):
        yield m.group(0).strip(" .!?;:(“\"‘'"), "British 'tick' (checkbox sense: check / select / checked)"
    for m in DMY.finditer(text):
        yield m.group(0), "day-month-year date"


# Strings the rules must FAIL and must PASS. Checked at the start of every run.
SELF_CHECK_FAIL = [
    "Tick the box to include file names", "tick the box", "Tick the “Include file names” box",
    "tick only if you need it", "Tick to enable", "Untick it to stop", "untick", "unticked",
    "Unticking the option hides it", "the box is ticked", "When ticked, Manifold logs it",
    "stays ticked after relaunch", "ticked by default", "a tick box", "the tickbox", "tick-box",
    "ticking each option", "colour", "16 November 2026",
]
SELF_CHECK_PASS = [
    # the clock-tick strings that failed the old word rule (2026-11-20), and the old ALLOW entries:
    "tick-x", "Pacer missed deadlines :   (output pacer deadlines skipped because a tick ran past them, since launch)",
    "tick", "repeat tick serving a present", "ticks   (new-frame  , repeat  ) · presents    (new-frame tick",
    ", same tick 2nd  , repeat tick  ) · held in flight  ,", "· next interval   ms (P   ms) ·   tick",
    "(the tick ended inside P: the deadline was missed outside the tick)",
    "meter.tick", "the decode-rate tick", "%@ input axis %@ %.2f ms at in-tick %lld — %@; output axis",
    # more clock ticks:
    "[IDLE] ⚠️ display link meant to run has not ticked for   ms — restarting it",
    "[IDLE] ⚠️ WATCHDOG: no tick in 500 ms after a wake · last tick began %.3f s before the wake",
    "%@ mirror — %d mapping change(s) + %d heartbeat tick(s) → %d setRate call(s)",
    "[AV-LAG] tick=%.4f pts=%.5f", "on every tick the pacer presents the frame", "skip the tick if it is late",
    "one tick only", "video on the display tick, audio on a dedicated pump", "timeBase=%d/%d (%.6f s/tick — %@)",
    "tickMs", "ticks", "Check the box to include file names", "checked by default", "color", "November 16, 2026",
]


def self_check():
    """Return the SELF_CHECK strings the rules get wrong."""
    wrong = [f"should FAIL but passes: {t!r}" for t in SELF_CHECK_FAIL if not list(check_text(t))]
    wrong += [f"should PASS but fails ({[w for w, _ in check_text(t)]}): {t!r}" for t in SELF_CHECK_PASS
              if list(check_text(t))]
    return wrong


def note_findings(root):
    """The release notes, line by line, as text (they are all user-facing)."""
    paths = [os.path.join(root, "RELEASE_NOTES.md")]
    rn = os.path.join(root, "docs", "release-notes")
    if os.path.isdir(rn):
        # *-changelog.md is skipped: changelogs copy commit titles word for word, and those can't change.
        paths += [os.path.join(rn, f) for f in sorted(os.listdir(rn))
                  if f.endswith(".md") and not f.endswith("-changelog.md")]
    for path in paths:
        if not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, root)
        with open(path, encoding="utf-8") as fh:
            for line, text in enumerate(fh, 1):
                if any(rel == p and s in text for p, s in NOTES_ALLOW):
                    continue
                for word, why in check_text(text):
                    yield rel, line, word, why, text.strip()


def main():
    wrong = self_check()
    if wrong:
        print("check-us-spelling: SELF-CHECK FAILED, the rules are wrong:\n  " + "\n  ".join(wrong))
        return 2
    args = sys.argv[1:]
    logs = "--logs" in args
    args = [a for a in args if a != "--logs"]
    root = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(__file__), ".."))
    if logs:
        bad = list(findings(root, logs=True))
        for rel, line, word, why, text in bad:
            print(f"{rel}:{line}: {why} '{word}': {text[:120]!r}")
        if bad:
            print(f"\n{len(bad)} finding(s) in log text. Use American spelling, and change every test and soak/report "
                  "script that matches the old text in the same change.")
            return 1
        print("check-us-spelling --logs: no British spellings or day-month-year dates in log text.")
        return 0
    bad = list(findings(root)) + list(note_findings(root))
    for rel, line, word, why, text in bad:
        print(f"{rel}:{line}: {why} '{word}': {text[:120]!r}")
    if bad:
        print(f"\n{len(bad)} finding(s). Use American spelling, or, for log text built outside a log "
              "call, add it to ALLOW in scripts/check-us-spelling.py.")
        return 1
    print("check-us-spelling: no British spellings or day-month-year dates in user-facing strings or release notes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
