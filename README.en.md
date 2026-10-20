# EdgeShelf

[日本語](README.md)

A shelf at the edge of your screen, in the menu bar.
Drag files, images, text or links to any edge of the screen, and a shelf slides out.
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

The EdgeShelf icon appears in the menu bar. If you install a new version from the zip, repeat steps 2-4. This is not needed when you use "Update" in the menu.

## How to use

- **Add:** Drag something to any edge of the screen and hold for a moment.
  When the shelf opens, move the mouse a little and drop.
  You can also paste with Command-V, or right-click in other apps > Services > "Send to EdgeShelf".
- **Take out:** Drag an item from the shelf to where you want it. The item leaves the shelf.
- The shelf shrinks to a thin tab when the mouse moves away. To open it again, rest the mouse on the tab for a moment, or point to it while holding Option. Clicks go through the tab to the app below, so it doesn't get in the way of scroll bars or the menu bar.
  Can't find a tab? Click the menu bar icon. The tabs light up.
- To move a shelf along the edge, drag the bar at the top of the shelf. Shelves at the top or bottom edge are wide and short.
- You can have as many shelves as you like. Drag to an empty part of the edge to make a new one.
- A shelf starts small and grows along the edge as you add more.
- Hover over an item to see where it is, plus pixel size and file size for images, or number of characters for text.
- Right-click an item: Open, Quick Look, Show in Finder, Copy, Remove. Space opens Quick Look.
- Right-click an image > "Convert to JPEG" to replace it on the shelf with a JPEG.
  The original file is kept. The date, location and other photo info are kept too.
- Command-click or Shift-click to select more than one item.
- The trash button removes all items (original files are kept).
- Menu bar icon menu: tab color, highlight color, open delays (when adding and when viewing), Widen Tab When Mouse Is Near, Open at Login, About EdgeShelf. "Reset All Settings…" puts them back to their defaults.
- "Tab Stripes" adds moving stripes to the tab, like a barber pole. It is set to "Always" at first. You can change it to "When the Mouse Is Near" or "Off". Use "Color 1…" and "Color 2…" to change the two stripe colors and their opacity (blue and white at first).
- "Tile Size" sets the size of items in an open shelf: Extra Small, Small, Medium, Large or Extra Large.
- When a new version is out, a small dot appears on the menu bar icon. Choose "Update to Version …" at the top of the menu to install it and restart.

## About files and data

- Files on the shelf are links to the original files, not copies.
  Dragging a file from the shelf to Finder moves it (on the same disk), just like dragging it in Finder.
- Photos from the Photos app keep their original names and full size. Edited photos are saved as edited.
  The first time, macOS asks if EdgeShelf can access your photos.
- Photos and images from web pages are saved as files in `~/Library/Application Support/EdgeShelf`.
- Privacy: Once a day, the app asks GitHub for the latest version. You can turn this off with "Check for Updates Automatically" in the menu. The app sends no other data.

## Uninstall

1. Menu bar icon > Quit
2. Move EdgeShelf.app to the Trash.
3. To delete the shelf data too, move `~/Library/Application Support/EdgeShelf` to the Trash.

## Build from source

Requires Xcode (swiftc).

```bash
./build.sh   # builds and installs to ~/Applications/EdgeShelf.app
./dist.sh    # makes the zips in dist/
```

## Questions and Problems

Please use [GitHub Issues](https://github.com/guribow/edge-shelf/issues).

## License

MIT ([LICENSE](LICENSE)). No warranty.
