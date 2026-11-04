# Testing Export and Import Settings

> ## ⚠️ Read this first: your real streams
>
> You'll run this on your normal Manifold, with your real shortcuts and real saved streams, so please take these seriously:
>
> - **Do Step 0 before anything else.** It makes a safety copy of your settings.
> - **The trash button in Stream Sources deletes a stream at once, with no "Are you sure?".** Only ever delete streams named
>   "Fixture …".
> - **Your own settings file holds your real stream addresses and passphrases.** Never send it to anyone, including us, and never
>   tell anyone its password.
> - **If you forget that password, nobody can open the file.** Not even Graviton can recover it.
>
> Importing can't change or remove a stream you already have. It only ever adds.

**You need:** a Manifold tester build with Export and Import, 0.9.2 or later. To check, open **Settings ▸ General**: there should be
a section called **Export and Import**. If there isn't, stop and tell us.

**macOS:** written against macOS 26.7.1. Manifold also supports macOS 15, but this hasn't been tried there. If you're on macOS 15,
please run it anyway and tell us.

**Time:** about 30 minutes, or 45 with the optional two-Mac part.

**How this works:** do the steps in order. Each one says what you should see. Tick **Pass** if it matches. If it doesn't, tick
**Fail**, write down what you saw, and carry on unless the step says to stop.

**About Undo Import:** it's only available on the summary that appears after an import. Once you click **Done**, it's gone. So
when a step says to click Undo Import, do it before Done.

## Getting ready

Download `manifold-settings-test-fixtures-v1.zip` and double-click it. You'll get a folder of test files, numbered 1 to 9. Leave it on
your Desktop.

**Password for the test files: `manifold-test-fixture`**. This is a public test password, so never use it for your own settings.

Every stream in these files is fake. Their addresses end in `.invalid`, which can never connect to anything.

---

## Step 0: Make your safety copy

Do this even if you think you have nothing to lose.

1. Open **Settings ▸ General**. Under **Export and Import**, click **Export Settings…**.
2. Tick **Keyboard shortcuts** and **Saved streams**, if they aren't greyed out.
   - If both are greyed out, you have nothing to protect. Click **Cancel** and go to Part A.
   - If only Saved streams is greyed out, you have no saved streams. No password is needed, so skip step 3.
3. Type a password you'll remember in **Password**, and the same one in **Confirm password**. It needs at least 12 characters. Write it
   down somewhere safe.
4. Click **Export…**. If macOS asks for permission to use your Keychain, click **Allow**, and note that it asked: we want to know.
5. Name the file `My Manifold Safety Copy` and save it somewhere you'll find it. Don't save it in the test folder.

**You should see:** the sheet closes and the file is where you saved it, with a name ending in one `.manifoldsettings`.

If Manifold says a stream couldn't be read, click **Try Again**. If it still can't, click **Export Without Them**, and write down which
streams were left out, because your safety copy won't include them. Tell us this happened, but not their addresses.

☐ Pass  ☐ Fail  Notes:

**To restore from your safety copy at any time:** see [If something goes wrong](#if-something-goes-wrong).

---

## Part A: Keyboard shortcuts

Open **Manifold ▸ Keyboard Shortcuts…** and keep that window open for all of Part A.

### A1. Change a shortcut

1. Type `Loop` in the search box. Write down the key shown for **Loop Playback** (normally ⌘L).
2. Click that key. It changes to "Type a shortcut…". Press ⌥⌘J (Option, Command and J).
3. If Manifold says that key is already used, cancel, and choose another key you don't use. Write it down and use it instead of ⌥⌘J
   below.
4. Clear the search box.

**You should see:** Loop Playback shows ⌥⌘J, with a small dot beside it.

☐ Pass  ☐ Fail  Notes:

### A2. Export shortcuts

1. In **Settings ▸ General**, click **Export Settings…**.
2. Leave **Keyboard shortcuts** ticked and **Saved streams** unticked.
3. Click **Export…**. Name the file `Test Shortcuts`, and save it to your Desktop.

**You should see:** a note that a shortcuts file is plain text, no password fields, and a saved file ending in one `.manifoldsettings`.

☐ Pass  ☐ Fail  Notes:

### A3. Import with Merge

1. Click **Import Settings…** and choose `1 Shortcuts Valid`.
2. Check the preview, with **Merge** selected.

**You should see**, under **Will change (2)**: Show/Hide Inspector changing to ⌥⌘Y, and Show/Hide File Name changing to ⌥⌘U. If you've
already changed these yourself, the "from" keys will differ, which is fine. If you see **Key already in use**, leave the box unticked
and note it.

3. Click **Import**.

**You should see:** "2 shortcuts changed." In the Keyboard Shortcuts window, the two new keys appear, and Loop Playback still shows
⌥⌘J.

4. Click **Undo Import**, then **Done**.

**You should see:** "Everything is back as it was." In the Keyboard Shortcuts window, those two actions have their old keys again.

☐ Pass  ☐ Fail  Notes:

### A4. Import with Replace All

1. Click **Import Settings…** and choose `1 Shortcuts Valid`.
2. Click **Replace All**.

**You should see:** the same two changes, plus Loop Playback going from ⌥⌘J back to its default. Anything else you've customized also
appears, going back to its default. That's correct, and the next steps undo it.

3. Click **Import**.

**You should see:** in the Keyboard Shortcuts window, Loop Playback is back on its default.

4. Click **Undo Import**, then **Done**.

**You should see:** "Everything is back as it was." Loop Playback shows ⌥⌘J again, and all your own shortcuts are back.

☐ Pass  ☐ Fail  Notes:

### A5. Restore from Backup

Manifold saves a backup of your shortcuts before every import.

1. Click **Import Settings…**, choose `1 Shortcuts Valid`, leave **Merge** selected, and click **Import**.
2. Click **Done**. Don't use Undo this time.
3. Open the **View** menu.

**You should see:** Show/Hide Inspector showing ⌥⌘Y, with no restart needed.

4. In **Settings ▸ General**, click **Restore from Backup…**. A folder of backups opens.
5. Choose the newest file (the names start with `Shortcuts` and the date and time), and click **Choose**.
6. Check the preview, then click **Restore**, then **Done**.

**You should see:** the preview shows the two actions going back. In the Keyboard Shortcuts window, Show/Hide Inspector and Show/Hide
File Name have their old keys, and Loop Playback still shows ⌥⌘J.

☐ Pass  ☐ Fail  Notes:

### A6. A file with bad shortcuts

1. Click **Import Settings…** and choose `2 Shortcuts Reserved Key`.

**You should see:**
- **Will change (1):** Show/Hide File Name.
- **Not imported (2):** Always Show Controls, "The file’s key for this action isn’t valid."; and Show/Hide Inspector, "⌘Q is used by
  macOS (Quit)."

2. Click **Import**, then **Undo Import**, then **Done**.

**You should see:** "Everything is back as it was."

☐ Pass  ☐ Fail  Notes:

### A7. A file with an unknown action

1. Click **Import Settings…** and choose `3 Shortcuts Unknown Action`.

**You should see:** Show/Hide File Name under **Will change (1)**. Under **Not imported (1)**, `future.nonsense` with "This action isn’t in
this version of Manifold."

2. Click **Import**, then **Undo Import**, then **Done**.

☐ Pass  ☐ Fail  Notes:

### A8. Put your shortcut back

In the Keyboard Shortcuts window, find **Loop Playback**. If it was ⌘L before, click the small reset arrow on its row. If you had your own
key, click the key and press it again. Delete `Test Shortcuts` from your Desktop.

**You should see:** Loop Playback shows the key you wrote down in A1.

☐ Pass  ☐ Fail  Notes:

---

## Part B: Streams

All of Part B uses fake streams named "Fixture …". There's no need to connect to them, and they couldn't connect if you tried.

### B1. Import the first fake streams

1. Click **Import Settings…** and choose `4 Streams Seed`.
2. Type `manifold-test-fixture` and click **Open**.

**You should see** under **Added (3)**: Fixture Alpha, Fixture Bravo, Fixture Charlie. If you see any of your own streams listed, or a
Keychain prompt, note it.

3. Click **Import**, then **Done**. These three stay for now, and B8 removes them.

**You should see:** "3 streams added."

☐ Pass  ☐ Fail  Notes:

### B2. Repeat import

1. Click **Import Settings…**, choose `4 Streams Seed` again, and enter the password.

**You should see:** **Already here (3)**, "Nothing to change.", and a greyed-out **Import** button.

2. Click **Cancel**.

☐ Pass  ☐ Fail  Notes:

### B3. Wrong password

1. Click **Import Settings…** and choose `5 Streams Outcomes`.
2. Type `this-is-the-wrong-password` and click **Open**.

**You should see:** "Wrong password, or the file has been changed." You stay on the password prompt.

3. Click **Cancel**.

☐ Pass  ☐ Fail  Notes:

### B4. A changed file

1. Click **Import Settings…**, choose `6 Streams Changed Payload`, type `manifold-test-fixture`, and click **Open**.

**You should see:** "Wrong password, or the file has been changed." The password is right here, and the message is the same on purpose.

2. Click **Cancel**. Do the same with `7 Streams Changed Header`.

**You should see:** the same message. Click **Cancel**.

☐ Pass  ☐ Fail  Notes:

### B5. A damaged file

1. Click **Import Settings…** and choose `8 Streams Truncated`.

**You should see:** "This file is damaged, or it isn’t a Manifold settings file." You're **not** asked for a password.

☐ Pass  ☐ Fail  Notes:

### B6. A file from a newer Manifold

1. Click **Import Settings…** and choose `9 Streams Newer Format`.

**You should see:** "This file was made by Manifold 9.9. Update Manifold to import it." You're **not** asked for a password.

☐ Pass  ☐ Fail  Notes:

### B7. Each import result, then Undo

1. Click **Import Settings…**, choose `5 Streams Outcomes`, type `manifold-test-fixture`, and click **Open**.

**You should see:**
- **Added (1):** Fixture Delta
- **Renamed (2):** Fixture Alpha → Fixture Alpha (copy), with "Passphrase differs."; and Fixture Bravo → Fixture Bravo (copy)
- **Already here (1):** Fixture Alpha
- **Not imported (1):** Fixture Echo, with a message about an unsupported URL scheme

2. Click **Import**.

**You should see:** "3 streams added." and a note that 1 stream kept its saved A/V offset.

3. Click **Undo Import**, then **Done**.

**You should see:** "Everything is back as it was."

☐ Pass  ☐ Fail  Notes:

### B8. Remove the fake streams

1. In a player window, open the stream menu (the **Connect Stream…** button, or the arrow beside the stream button in the toolbar), and
   choose **Manage…**. The **Stream Sources** sheet opens.
2. Check the list: Fixture Alpha, Fixture Bravo and Fixture Charlie, with **no** "(copy)" entries and no Fixture Delta.
3. **Carefully**, click the trash button on those three rows only. There's no confirmation.
4. Click **Done**.

**You should see:** only your own streams, all still there.

☐ Pass  ☐ Fail  Notes:

---

## Part C: Optional, if you have two Macs

This uses your real streams, so the file you make holds your real addresses and passphrases. Move it by AirDrop or a USB drive, not by
email, chat or a shared folder, and delete it from both Macs when you've finished.

1. On the first Mac, export **Saved streams** with a password, as in Step 0. You can use your safety copy.
2. Move the file to the second Mac.
3. On the second Mac, click **Import Settings…**, choose the file, enter the password, and check the preview.

**You should see:** your streams under **Added**. Any already on that Mac show under **Already here**, or as a "(copy)" if they differ.
Nothing there is changed.

4. Click **Import**, then **Done**. These streams stay on the second Mac, which is the point. To remove one later, use its trash button in
   **Stream Sources**. To back out straight away, click **Undo Import** instead of Done.
5. Connect to one real stream from the stream menu.

**You should see:** it connects, and you're **not** asked for a URL, a passphrase or Keychain access. If you are, note exactly what appeared.

☐ Pass  ☐ Fail  ☐ Didn't do this  Notes:

---

## If something goes wrong

**Your shortcuts are wrong.** Use **Restore from Backup…**, or restore from your safety copy below.

**A stream is missing.** Restore from your safety copy below.

**To restore from your safety copy:**

1. Click **Import Settings…**, choose `My Manifold Safety Copy`, and enter your password.
2. If shortcuts are listed, click **Replace All**, so they go back exactly as they were.
3. Click **Import**, then **Done**.

Streams you still have show as **Already here** and are left alone. Missing ones come back. A safety copy never removes anything, so if a
"Fixture …" stream is left over, delete it in **Stream Sources**.

---

## What to send us

1. Choose **Help ▸ Export Diagnostics…** and save the file.
2. Send us that file, and a list of the steps you marked **Fail** with your notes. Please include your Mac model, your macOS version,
   and the Manifold version from **Manifold ▸ About Manifold**. A screenshot helps, if it shows no real stream address.

> **Never send us your own settings file or its password.** That means `My Manifold Safety Copy` and anything you exported in Part C. We
> don't need them, and they hold your real stream addresses and passphrases.

Keep your safety copy for as long as you like, somewhere private. You can delete the test folder and the zip.

Thank you for testing.
