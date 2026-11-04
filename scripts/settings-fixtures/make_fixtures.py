#!/usr/bin/env python3
"""Fixtures for docs/testing/SETTINGS_TRANSFER_TEST_PROCEDURE.md: every file an outside tester imports.

    python3 scripts/settings-fixtures/make_fixtures.py            # writes build/settings-fixtures/ and checks it
    python3 scripts/settings-fixtures/make_fixtures.py --zip      # and writes the zip to ~/Code/Manifold/Builds/Manifold/
    python3 scripts/settings-fixtures/make_fixtures.py --zip --force   # replaces an existing zip

NEEDS: Python 3.9 or later and the `cryptography` package (`pip install cryptography`; 49.0.0 was used). The standard
library has PBKDF2 but no AES-GCM. This is the same pair that made the frozen vector in SettingsEncryptionTests.swift, so
the format here is a second implementation of docs/SETTINGS_EXPORT_PLAN.md §2.4-§2.5, not a copy of the Swift code.

REBUILDS ARE BYTE-IDENTICAL. Salts and nonces come from each file's name and every date is fixed, so the same script gives
the same zip and the same SHA-256. That is safe only because nothing here is secret: the password is printed in the
procedure, and every stream is fake. Never copy that shortcut into the app, which draws fresh random values for each export.

Every stream host ends in .invalid, which RFC 2606 reserves so that it can never resolve. `check` refuses anything else.
"""
import argparse
import base64
import copy
import hashlib
import json
import pathlib
import sys
import zipfile

try:
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    sys.exit("make_fixtures.py needs the cryptography package: pip install cryptography")

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT = REPO / "build" / "settings-fixtures"
ZIP = pathlib.Path.home() / "Builds" / "Manifold" / "manifold-settings-test-fixtures-v1.zip"
FOLDER = "manifold-settings-test-fixtures-v1"

PASSWORD = "manifold-test-fixture"
ITERATIONS = 1_000_000
KIND = "com.graviton.manifold.settings"
PROVENANCE = {"appVersion": "0.9.2-fixture", "appBuild": "fixture", "exportedAt": "2026-11-03T12:00:00Z"}

KEY_Y = {"key": "y", "modifiers": ["command", "option"]}
KEY_U = {"key": "u", "modifiers": ["command", "option"]}

ALPHA_URL = "srt://alpha.fixture.invalid:9000?streamid=alpha"
ALPHA_PASSPHRASE = "alpha-fixture-passphrase"
BRAVO_URL = "https://bravo.fixture.invalid/whep/seed"
CHARLIE_URL = "https://charlie.fixture.invalid/live/index.m3u8"

SEED = [
    {"name": "Fixture Alpha", "type": "srt", "url": ALPHA_URL, "passphrase": ALPHA_PASSPHRASE},
    {"name": "Fixture Bravo", "type": "web", "url": BRAVO_URL},
    {"name": "Fixture Charlie", "type": "hls", "url": CHARLIE_URL},
]

# Against the seed, one entry for each outcome (docs/SETTINGS_EXPORT_PLAN.md §4.2).
OUTCOMES = [
    {"name": "Fixture Alpha", "type": "srt", "url": ALPHA_URL, "passphrase": ALPHA_PASSPHRASE},       # Already here
    {"name": "Fixture Alpha", "type": "srt", "url": ALPHA_URL, "passphrase": "other-fixture-passphrase"},  # Passphrase differs
    {"name": "Fixture Bravo", "type": "web", "url": "https://bravo.fixture.invalid/whep/different"},  # Renamed
    {"name": "Fixture Delta", "type": "srt", "url": "srt://delta.fixture.invalid:9000?streamid=delta",
     "audioOffsetMs": 40},                                                                            # Added
    {"name": "Fixture Echo", "type": "web", "url": "ftp://echo.fixture.invalid/x"},                   # Not imported
]


def text(root):
    return json.dumps(root, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def compact(value):
    """The app's authenticated bytes: sorted keys, no spaces, slashes as they are."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def plain(overrides):
    return {"kind": KIND, "formatVersion": 1, **PROVENANCE, "sections": {"shortcuts": {"version": 1, "overrides": overrides}}}


def derived(label, name, size):
    return hashlib.sha256(f"{label}:{name}".encode()).digest()[:size]


def key_for(salt, iterations):
    return hashlib.pbkdf2_hmac("sha256", PASSWORD.encode(), salt, iterations, 32)


def sealed(name, entries):
    salt, nonce = derived("salt", name, 16), derived("nonce", name, 12)
    root = {
        "kind": KIND, "formatVersion": 1, **PROVENANCE,
        "encryption": {"cipher": "AES-GCM-256", "kdf": "PBKDF2-HMAC-SHA256", "iterations": ITERATIONS,
                       "salt": base64.b64encode(salt).decode(), "nonce": base64.b64encode(nonce).decode()},
        "sections": {"streams": {"version": 1, "count": len(entries)}},
    }
    payload = compact({"sections": {"streams": {"version": 1, "entries": entries}}})
    root["payload"] = base64.b64encode(AESGCM(key_for(salt, ITERATIONS)).encrypt(nonce, payload, compact(root))).decode()
    return root


def opened(root):
    """The payload, as the app would read it. Raises InvalidTag when the file has been changed."""
    e = root["encryption"]
    header = {k: v for k, v in root.items() if k != "payload"}
    key = key_for(base64.b64decode(e["salt"]), e["iterations"])
    return json.loads(AESGCM(key).decrypt(base64.b64decode(e["nonce"]), base64.b64decode(root["payload"]), compact(header)))


def build():
    """File name to bytes, in the order the procedure uses them."""
    seed = sealed("seed", SEED)
    outcomes = sealed("outcomes", OUTCOMES)

    payload = bytearray(base64.b64decode(outcomes["payload"]))
    payload[len(payload) // 2] ^= 0x01
    changed_payload = copy.deepcopy(outcomes)
    changed_payload["payload"] = base64.b64encode(bytes(payload)).decode()

    changed_header = copy.deepcopy(outcomes)
    changed_header["sections"]["streams"]["count"] = 99

    newer = copy.deepcopy(outcomes)
    newer["formatVersion"] = 2
    newer["appVersion"] = "9.9"

    whole = text(outcomes).encode()
    return {
        "1 Shortcuts Valid.manifoldsettings": text(plain({"view.inspector": KEY_Y, "view.fileName": KEY_U})).encode(),
        "2 Shortcuts Reserved Key.manifoldsettings": text(plain({
            "view.inspector": {"key": "q", "modifiers": ["command"]},   # ⌘Q belongs to macOS
            "view.alwaysShowControls": {"key": "ab", "modifiers": ["command"]},   # not a key
            "view.fileName": KEY_U,
        })).encode(),
        "3 Shortcuts Unknown Action.manifoldsettings": text(plain({"future.nonsense": KEY_Y, "view.fileName": KEY_U})).encode(),
        "4 Streams Seed.manifoldsettings": text(seed).encode(),
        "5 Streams Outcomes.manifoldsettings": whole,
        "6 Streams Changed Payload.manifoldsettings": text(changed_payload).encode(),
        "7 Streams Changed Header.manifoldsettings": text(changed_header).encode(),
        "8 Streams Truncated.manifoldsettings": whole[: len(whole) // 2],
        "9 Streams Newer Format.manifoldsettings": text(newer).encode(),
    }


def check(files):
    """Each file is what its name says, and no stream can reach anything."""
    def load(name):
        return json.loads(files[name])

    for name, entries in (("4 Streams Seed.manifoldsettings", SEED), ("5 Streams Outcomes.manifoldsettings", OUTCOMES)):
        got = opened(load(name))["sections"]["streams"]["entries"]
        assert got == entries, name
        raw = files[name]
        for entry in entries:
            host = entry["url"].split("/")[2].split(":")[0]
            assert host.endswith(".invalid"), f"{host} is not under .invalid"
            assert host.encode() not in raw and entry["name"].encode() not in raw, f"{name} holds plain text"
            if "passphrase" in entry:
                assert 10 <= len(entry["passphrase"]) <= 79, entry["name"]
    for name in ("6 Streams Changed Payload.manifoldsettings", "7 Streams Changed Header.manifoldsettings"):
        try:
            opened(load(name))
        except InvalidTag:
            continue
        raise AssertionError(f"{name} opened")
    try:
        json.loads(files["8 Streams Truncated.manifoldsettings"])
    except json.JSONDecodeError:
        pass
    else:
        raise AssertionError("the truncated file is still JSON")
    assert load("9 Streams Newer Format.manifoldsettings")["formatVersion"] == 2


def write_zip(path, files, force):
    if path.exists() and not force:
        sys.exit(f"{path} exists. Pass --force to replace it.")
    path.parent.mkdir(parents=True, exist_ok=True)
    members = {"README.md": (HERE / "README.md").read_bytes(), **files}
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(members):
            info = zipfile.ZipInfo(f"{FOLDER}/{name}", date_time=(2026, 11, 3, 12, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o644 << 16
            z.writestr(info, members[name])
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"{path}\n{path.stat().st_size} bytes\nSHA-256 {digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--zip", action="store_true", help=f"also write {ZIP}")
    parser.add_argument("--force", action="store_true", help="replace an existing zip")
    args = parser.parse_args()
    files = build()
    check(files)
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (OUT / name).write_bytes(data)
    print(f"{len(files)} fixtures checked and written to {OUT}")
    if args.zip:
        write_zip(ZIP, files, args.force)


if __name__ == "__main__":
    main()
