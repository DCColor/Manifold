##Shortcuts Review


Moved keys (each old key should now do nothing)

⌘I: Inspector shows and hides. Bare I: nothing.
ok

⌥⌘T: controls pin and unpin. Tab: nothing to the controls.
ok. But I think we need to color code the pin icon not just fill it white - needs to be more obvious I think

⌘7: scopes tray opens and closes. ⌃⌥T: nothing.
Ok but I don't like this shortcut - nothing about 7 says scopes. Can we find something else?

⌥⌘E: exports the frame to the Desktop. ⌃⌥E: nothing.
ok but the export is exporting not just the frame but a bunch of other files it shouldn't - .v210, .rgba16f, .v210.json

⌥⌘1 / ⌥⌘2 / ⌥⌘3: macOS / Reference / Bypass, and the Color menu checkmark follows.
ok. Should probably add same command with 4 to reveal the chain?

⌃⌥R: still toggles the render layer, which is expected in this build.
I'm not sure this is doing anything.  At first it seemed to have shifted the sizing of the image now it doesn't seem to do anything.  Should investigae


Hold to compare
7. Hold D: shows the other view with the amber badge; release returns.
works. But I'm wondering if D is the right letter.  jsut making the connection D doesn't really mean compare to me.  

8. Hold ⇧D: shows Bypass; release returns.
works

9. ⌘D, ⌥D, ⌃D: no comparison.
correct none work

10. In a text field (e.g. a bookmark name): D types “d”.
works. types as normal

11. Hold D, click another app: the window goes back.
works

12. \ and ⇧: nothing. ⇧⌘: Show All Tabs.
incorrect.  The menu shows this as shift + command + a diagnoal down arrow which I have no idea what that is

Transport
13. Space, J, K, L work as before; L twice speeds up.
works

14. Hold K, tap J or L: one frame back or forward per tap.
works

15. Hold K and hold L: half-speed forward until you let go. Same with J, in reverse.
works

16. ← / →: one frame. ⇧← / ⇧→: one second.
works

17. Home / End, and ⌥← / ⌥→: first and last frame.
both work

18. ⌘L: loop on and off, and the loop button turns green.
works

19. Type digits: timecode entry opens; Space, J/K/L, D and arrows do nothing behind it; Esc cancels, Return goes.
works

20. ⌘F: full screen in and out, same as ⌃⌘F.
cmd+f works, control + cmd + F does not work. I don't think we need control + cmd + F

Menus that lost their keys
21. File ▸ Start / Stop DeckLink Output works.
Both work.  I think we need shortcut for this.  I'd rather use D  for decklink here than D for compare

22. Color ▸ Next Color Interpretation and Reset to Auto work.
Works.  Not sure I like the word interpretation - maybe tagging works better?

23. If you have a live stream handy: ⌥] / ⌥[ move audio 1 ms, with ⇧ 10 ms; File ▸ Disconnect Live Source works. Otherwise skip.
offset works.  Disconnect works too from the menu - shortcut for this would be good. 

The Shortcuts window (Help ▸ Keyboard Shortcuts…)
24. Type in search: the list filters.
works

25. Find by Key, then press ⌘I: it jumps to Inspector.
works

26. Click Inspector’s key, press ⌥⌘I: it changes, the row is marked customised, and the View menu shows ⌥⌘I.
works, but doesn't  show customized - just an orange dot and reset icon

27. Click a key and press one another action already uses (e.g. ⌘7): Replace/Cancel appears. Cancel.
yes correct - shows what its used by and asks to replace or cancel

28. Click a key and press ⌘Q: refused.
works

29. Reset All: everything returns to default and the menu shows ⌘I again.
works

##Other UI  and Shortcuts Comments

We don't need connect to first NDI source in the file menu
I think maybe we should move shortcuts to the app menu below settings?  I don't mind it in help (it logically works there but maybe more discoverable in the app menu?
Show file name in the view menu doesn't have a shortcut listed but in the shortcut editor its listed as N and that works
View menu needs mute options plus volume up/down.  These functions also need keyboard shortcuts as they're really common
As mentioned I really don't like cmd + 7 for scopes. Not obvious at all

Its very easy to when trying to change volume in the control bar for it to get confused with the playbutton - in terms of where the mouse is. It'l do this bouncy/shaky thing. Maybe each button needs a touch more padding

In the colorimetry menu:
I think we should change custom to Override or similar.  its not very clear that choosing these tags is a temporary override.  Custom to me implies more permanance.  I don't know maybe I'm wrong just feels incrrect
With a lut loaded I think we need a compare mode that follows the same logic as the other compare modes.  i find myself wanting to quickly compare with the LUT on/off

I think we have this on the list but we need to scale the control bar at small window sizes
We need to revist the settings window - a tall, skinny window that can't be resized feels wrong.  My feeling is it should match the keybaord shortcuts window

