# Manifold settings test fixtures, v1

These files go with the procedure `SETTINGS_TRANSFER_TEST_PROCEDURE.md`. Follow that procedure, and use them in the order it says.

**Password for every encrypted file here: `manifold-test-fixture`**

This password is public on purpose. Never use it for your own settings.

**Everything here is fake.** Every stream host ends in `.invalid`, a name reserved by RFC 2606 that can never connect to anything.
No file here holds a real address, passphrase or key.

| File | Kind | Password? | What it is for | What it should do |
|---|---|---|---|---|
| `1 Shortcuts Valid` | Plain | No | A normal shortcuts file: Show/Hide Inspector ⌥⌘Y, Show/Hide File Name ⌥⌘U | Imports. Used for Merge, Replace All and Restore from Backup |
| `2 Shortcuts Reserved Key` | Plain | No | ⌘Q on Show/Hide Inspector, a key that doesn't exist on Always Show Controls, and one good entry | Only Show/Hide File Name imports. The other two are listed with a reason |
| `3 Shortcuts Unknown Action` | Plain | No | An action Manifold doesn't have (`future.nonsense`), and one good entry | Only Show/Hide File Name imports. The unknown action is listed |
| `4 Streams Seed` | Encrypted | Yes | Three fake streams: Fixture Alpha, Fixture Bravo, Fixture Charlie | Adds all three. Imported again, all three are Already here |
| `5 Streams Outcomes` | Encrypted | Yes | Five entries that give each result once file 4 is imported | Already here, Passphrase differs, a plain (copy), Added, and Not imported |
| `6 Streams Changed Payload` | Encrypted | Yes | File 5 with one bit changed in the encrypted part | "Wrong password, or the file has been changed." |
| `7 Streams Changed Header` | Encrypted | Yes | File 5 with a count changed in the readable part | "Wrong password, or the file has been changed." |
| `8 Streams Truncated` | Damaged | Never asked | File 5 cut in half | Refused before any password prompt |
| `9 Streams Newer Format` | Encrypted | Never asked | File 5 marked as made by a future Manifold 9.9 | Refused before any password prompt, and says to update |

All these files have the extension `.manifoldsettings`. They say they were made by "Manifold 0.9.2-fixture".

## Rebuilding (Graviton only)

`python3 scripts/settings-fixtures/make_fixtures.py --zip`, from the Manifold repo. It needs Python 3.9 or later and the `cryptography`
package (49.0.0 was used). The standard library has PBKDF2 but no AES-GCM. Rebuilds are byte-identical, so the SHA-256 tells you
whether a zip matches the script.
