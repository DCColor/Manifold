## Live streams

Manifold plays live sources as well as files:

- **NDI** sources on your network.
- **SRT** streams (addresses that start with srt://).
- **Web streams** (https:// addresses): low-delay streams over the web. The standard they use is called WHEP; in OBS,
  the matching output is called WHIP.
- **HLS** streams (addresses that contain .m3u8).

A live stream has no scrubber, and markers aren't available on it.

### Connect an NDI source

1. Click the arrow beside **Streaming** (the antenna button) in the controls. In an empty window, click **Connect
   Stream…**.
2. Choose **NDI**, then the source.

While Manifold connects, the antenna pulses and its tooltip says "Connecting to …" with the source's name. It turns
green once the source is connected, and the NDI menu puts a checkmark beside it. "Searching for NDI sources…" means
Manifold is still looking.

The first time, macOS asks whether Manifold can find devices on your local network. Click **Allow**: Manifold uses it
only to find NDI sources. If you clicked Don't Allow, turn it on in macOS System Settings ▸ Privacy & Security ▸
Local Network.

**NDI needs the NDI runtime.** If the menu says "NDI runtime not installed", choose **Manifold ▸ Settings…**, click
**Sources**, click **Install NDI Runtime…**, install it and open Manifold again.

### Connect an SRT, web or HLS stream

**To save a stream so you can connect with one click:**

1. Click the arrow beside **Streaming** and choose **Stream URL…** (or **Manage…** once you have saved streams).
2. Under **Add a stream**, paste the stream's address in **Stream URL**. Manifold tells the type from the address.
3. Give it a **Name** if you like. Without one, it's named after the server.
4. For an SRT stream with a passphrase, type it in **Passphrase**.
5. Click **Save**, then **Connect**.

Saved streams then appear in the Streaming menu, under **Streams**. Click one to connect. While it connects, the
antenna pulses and its tooltip says "Connecting to …" with the stream's name; it turns green once the connection is
made.

**To connect once without saving,** paste the address under **Connect without saving** and click **Paste & Connect**.

**To edit or delete a saved stream,** choose **Manage…** in the Streaming menu and use the buttons beside it. Saved
addresses and passphrases are kept in your Mac's keychain.

**To disconnect,** choose **Disconnect** in the Streaming menu, or press **⌥⌘⌫** (**File ▸ Disconnect Live Source**).

#### When a stream doesn't play

An orange message at the top of the picture says what went wrong, for example:

- "Nothing answered at …" (SRT): the sender isn't running, or a firewall is in the way. Check the address and port,
  and that the sender is on.
- "Connected, but no video is arriving from the sender.": the connection works, but the sender isn't sending yet.
- "The stream server refused the connection (HTTP …)." (web stream): the server turned Manifold away. When the server
  gave a reason, it follows in quotes, shortened, for example “Live broadcast not started yet.”
- "The stream stopped sending video (the broadcaster may have ended it).": the stream ended at the sender.
- "That stream is not playing yet — it connected, but no video has started after … seconds. Still trying." (HLS).
- "No NDI source found on this network within 5 seconds." or "Couldn't connect to “…”." (NDI): check that the NDI
  sender is running and on the same network.
- "The NDI source “…” stopped sending (it may have been closed or left the network)." (NDI): the source went away
  after it connected. Manifold disconnects after 5 seconds without it, as it does for a stream that stops. Connect to
  it again when it's back.

An error stays until you close it or try again. See *Troubleshooting* for more.

### Sound and picture sync

A live stream can arrive with its sound slightly early or late. Manifold plays sound and picture exactly as the stream
stamps them, and doesn't guess at a correction. If a stream is out of sync, measure it and set the **audio offset**.

The sender (OBS, an encoder, an NDI source) decides how far apart sound and picture are. You measure and correct it
in Manifold; nothing on the sender changes.

*Detail: the Sync and Color Guide's "Why a live stream can be out of sync" and "Two sides: the sender and Manifold".*

#### Set the audio offset

While a stream plays, the controls have an **A/V** menu:

- **Sound later** and **Sound earlier** move the sound by 1 ms or 10 ms.
- **Reset to 0 ms** removes the offset.
- **Save … to “stream name”** stores the offset with a saved stream, so it's used every time you connect. **Revert to
  Saved** goes back to the stored value.

From the keyboard: **⌥]** moves the sound 1 ms later and **⌥[** 1 ms earlier. Add **⇧** to move 10 ms.

- **Positive means later.** +40 ms plays the sound 40 ms later.
- **The range is −250 to +500 ms.** A change takes effect at once.
- When an offset is on, the A/V menu and the window title show it, for example "A/V +40 ms".

You can also type an offset in **Audio offset** when you edit a saved stream. On an NDI source or a stream you didn't
save, the offset lasts until you disconnect.

Sound can always be made later. Making it earlier is limited by how much of the stream Manifold has received, so on
some streams you'll see "Can move sound earlier by at most … ms on this stream right now." If the sound needs to be
earlier than that, correct it at the sender. *Detail: the guide's "Why sound can only be made a little earlier on some
streams".*

**HLS streams have no audio offset.** macOS plays their sound, so Manifold can't move it.

#### Calibrate a stream

Calibration measures the offset for you, from a sync clip played through the sender.

1. With the stream connected, choose **A/V ▸ Save Sync Clip…** and save the clip for the stream's frame rate.
2. On the sender, play the clip on a loop as part of the stream, with every other sound muted.
3. Wait about a minute, then choose **A/V ▸ Calibrate…** and click **Start**.
4. When it shows a result, such as "Sound is heard 40 ms late", click **Apply and Save** (or **Apply for Session**).
5. Click **Start** again to check. It should read close to 0 ms.
6. Stop the clip on the sender.

Manifold never applies a result by itself. On NDI and streams you didn't save, a result lasts for the session only.
Calibrate again whenever anything changes on the sender. Calibration isn't available on HLS.

**Help ▸ Download Sync Clips…** downloads the full set of sync clips, including ProRes masters.

*Detail: the guide's "Calibrating, step by step", "The sync clips", and how to play a clip from OBS or DaVinci Resolve.*

#### When sync was right and now it isn't

Calibrate again after any change on the sender: a new frame rate, new encoder settings, a restarted encoder, or a
different sender. *Detail: the guide's "When sync was right and now it isn't".*

### Color on a live stream

A stream that doesn't say what its color is is shown as Rec. 709, and the Transform chain panel says so. To correct
it, see *Color and display modes*. On a saved stream, the correction can be saved with the stream.
