# EdgeShelf

[日本語](README.md)

A shelf at the edge of your screen, in the menu bar.
Drag files, images, text or links to the left or right edge of the screen, and a shelf slides out.
Drop them there to keep them for later, or to move them between windows, tabs, full-screen apps and Spaces.

- Requires macOS 13 or later (Apple silicon or Intel). On macOS 26 or later, the shelf uses Liquid Glass.
- English and Japanese. The app follows your Mac's language.

## Download and install

Download the zip from [Releases](https://github.com/guribow/edge-shelf/releases/latest).
`EdgeShelf-<version>-en.zip` has an English guide, `-ja.zip` has a Japanese guide. The app is the same.

1. Open the zip and move EdgeShelf.app to the Applications folder.
2. Double-click it. If macOS says it can't open the app, click "Done".
   (This happens only the first time, because the app is not from the App Store.)
3. Open System Settings > Privacy & Security, scroll down, click "Open Anyway" and enter your password.
4. Double-click the app again and click "Open".

A tray icon appears in the menu bar. After you install a new version, repeat steps 2-4.

## How to use

- **Add:** Drag something to the left or right edge of the screen and hold for a moment.
  When the shelf opens, move the mouse a little and drop.
  You can also paste with Command-V, or right-click in other apps > Services > "Send to EdgeShelf".
- **Take out:** Drag an item from the shelf to where you want it. The item leaves the shelf.
- The shelf shrinks to a thin tab when the mouse moves away. Point to the tab to open it again.
  Can't find a tab? Click the tray icon. The tabs light up.
- Right-click an item: Open, Quick Look, Show in Finder, Copy, Remove. Space opens Quick Look.
- Command-click or Shift-click to select more than one item.
- The trash button removes all items (original files are kept).
- Tray icon menu: tab color, highlight color, open delay, Open at Login, About EdgeShelf.

## Notes

- Files on the shelf are links to the original files, not copies.
  Dragging a file from the shelf to Finder moves it (on the same disk), just like dragging it in Finder.
- Images from Photos or web pages are saved as files in `~/Library/Application Support/EdgeShelf`.
- Privacy: the app sends no data anywhere.

## Uninstall

1. Tray icon > Quit
2. Move EdgeShelf.app to the Trash.
3. To delete the shelf data too, move `~/Library/Application Support/EdgeShelf` to the Trash.

## Build from source

Requires Xcode (swiftc).

```bash
./build.sh   # builds and installs to ~/Applications/EdgeShelf.app
./dist.sh    # makes the zips in dist/
```

## License

MIT ([LICENSE](LICENSE)). You may use, change and share it. Keep the copyright notice and the license text when you share it. No warranty.
