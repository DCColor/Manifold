#!/usr/bin/env python3
"""Find orphaned SRT stream passphrases in the login keychain.

    python3 scripts/orphan_check.py

Exit status 0 when clean, 1 when at least one orphan is found, so it can gate a check if that is
ever wanted. Developer tool only — deliberately NOT referenced from project.yml, because it is not a
build input and nothing in the app should depend on it existing.

── WHAT AN ORPHAN IS ───────────────────────────────────────────────────────────────────────────

Manifold stores one SRT passphrase per saved bookmark in the Keychain under service
`tools.graviton.manifold.streams`, with the ACCOUNT NAME set to the bookmark's UUID (see
KeychainStore and StreamBookmarkStore in App/). That UUID is the only key there is: if the bookmark
disappears from the `streamBookmarks` preference while its Keychain item does not, no code path in
the app can ever name that account again. The secret becomes unreachable from the UI that created
it, survives reinstalls, and sits in the keychain indefinitely.

This script reports exactly that set: accounts under the streams service with no matching bookmark.

── TWO KNOWN WAYS ONE ARISES ───────────────────────────────────────────────────────────────────

Neither is a bug in the edit/delete paths — `delete` removes the Keychain item with the bookmark and
`update` mutates in place under the existing UUID — so a non-empty result here points at one of:

1. A RESTORED PREFERENCES BACKUP. The bookmark list lives in
   ~/Library/Preferences/com.graviton.manifold.plist; the passphrases do not. Restoring that plist
   from Time Machine, a migration, or a sync service rolls the list back to an older set of UUIDs
   while the keychain keeps every item ever written. Every bookmark that existed only in the newer
   list is now an orphan. The reverse also bites: restoring an OLDER plist can resurrect a bookmark
   whose passphrase was legitimately deleted, which shows up here as an SRT bookmark with no stored
   passphrase rather than as an orphan.

2. A DECODE FAILURE FOLLOWED BY A SAVE. `StreamBookmarkStore.init` falls back to `bookmarks = []`
   when the stored JSON will not decode — a truncated write, a hand-edited plist, a future schema
   this build does not understand. Nothing is lost at that moment, because nothing is written. But
   the first subsequent add or delete calls `persist()`, which overwrites the key with the in-memory
   list, and every previously saved bookmark is gone while its Keychain item remains.

── SAFETY ──────────────────────────────────────────────────────────────────────────────────────

READ-ONLY, AND IT DECRYPTS NOTHING. `security dump-keychain` is invoked WITHOUT `-d`, so it returns
item attributes only and never the password data; the counting query likewise asks for
kSecReturnAttributes and never kSecReturnData. Because no item's data is read, this cannot trigger
the ACL authorization prompt that a genuine passphrase read can raise on the file-based keychain —
running it is not an event the user has to approve or even notice.

It prints no passphrase, and no bookmark URL either: the URL path can carry a stream key, so only
the name, the type, and the UUID are shown. Output is filtered to the one service, so no unrelated
keychain item of the user's is ever printed.

Nothing here deletes anything. Removing a confirmed orphan is a deliberate manual act:

    security delete-generic-password -s tools.graviton.manifold.streams -a <UUID>
"""
import json
import plistlib
import re
import subprocess
import sys

SERVICE = "tools.graviton.manifold.streams"
DOMAIN = "com.graviton.manifold"


def bookmark_entries():
    """Every saved bookmark, read from the real preferences domain.

    Via `defaults export`, NOT `defaults read`: the latter renders a Data value as an abbreviated hex
    dump with a literal '...' in the middle, which silently truncates the JSON and makes this script
    cheerfully report zero bookmarks and therefore zero orphans.
    """
    raw = subprocess.run(["defaults", "export", DOMAIN, "-"],
                         capture_output=True, check=True).stdout
    blob = plistlib.loads(raw).get("streamBookmarks")
    if blob is None:
        return []
    return json.loads(bytes(blob))


def keychain_accounts():
    """Accounts of every item under SERVICE. Records in the dump are delimited by 'keychain:' lines."""
    out = subprocess.run(["security", "dump-keychain"],
                         capture_output=True, text=True).stdout
    accounts = set()
    for record in out.split("\nkeychain:"):
        if SERVICE not in record:
            continue
        m = re.search(r'"acct"<blob>="([^"]*)"', record)
        if m:
            accounts.add(m.group(1).upper())
    return accounts


def main():
    entries = bookmark_entries()
    ids = {e["id"].upper() for e in entries}
    accounts = keychain_accounts()

    print(f"── {len(entries)} saved bookmark(s) ─────────────────────────────")
    for e in entries:
        print(f"  {e['id'].upper()}  type={e['type']:<4} name={e['name']!r}")
    if not entries:
        print("  (none)")

    print(f"\n── {len(accounts)} keychain item(s) under {SERVICE} ──")
    for a in sorted(accounts):
        print(f"  {a}  {'→ bookmark exists' if a in ids else '→ NO BOOKMARK'}")
    if not accounts:
        print("  (none)")

    orphans = accounts - ids
    print("\n── ORPHANS ───────────────────────────────────────────────")
    if orphans:
        for o in sorted(orphans):
            print(f"  ❌ {o}")
        print(f"{len(orphans)} orphaned secret(s). See the header for how one arises and how to remove it.")
    else:
        print("  none ✅")

    # Not a fault — an unencrypted SRT stream is legitimate — but the counterpart symptom of case 1
    # above, so it is worth surfacing next to the orphan list rather than leaving it invisible.
    missing = sorted(e["id"].upper() for e in entries
                     if e["type"] == "srt" and e["id"].upper() not in accounts)
    print("\n── SRT bookmarks with no stored passphrase (legal: unencrypted stream) ──")
    print("  " + (", ".join(missing) if missing else "none"))

    return 1 if orphans else 0


if __name__ == "__main__":
    sys.exit(main())
