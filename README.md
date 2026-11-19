# Clipbay

A native macOS clipboard manager (Swift + SwiftUI). Everything you copy is saved; press **⇧⌘V** anywhere to open a shelf of cards along the bottom of the screen.

## Install (no build needed)

1. Download `Clipbay.zip` from the latest [Release](../../releases/latest) and unzip it.
2. Move `Clipbay.app` to `/Applications`.
3. The app isn't notarized by Apple, so the first launch is blocked. Either right-click it → **Open** → **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Clipbay.app
   ```
4. Grant **Accessibility** when asked, then press **⇧⌘V**.

Requires macOS 14 or later.

## Build from source

Needs Xcode (or the Xcode command-line tools with Swift 5.9+).

```bash
./scripts/build.sh          # release build → signs → installs /Applications/Clipbay.app → launches
./scripts/build.sh --no-run
```

Grant **Accessibility** when asked (System Settings › Privacy & Security › Accessibility) so Clipbay can paste straight into the active app.

## Features

- **History** of text, rich text (formatting kept), links (title + preview image), images (text inside is OCR'd and searchable), files, and colors (`#RRGGBB`). Same content copied again moves to the front.
- **Shelf UI**: cards with the source app's icon and color, relative time, and size/character count; resizable by dragging the top edge (compact mode when short); opens on the screen with the mouse.
- **Keyboard**: ←/→ select, ⇧←/→ extend, ⌘↑/↓ first/last, ↩ paste, ⇧↩ plain text, ⌘1–9 quick paste, ⌘C copy, Space Quick Look, ⌘O open, ⌘E edit, ⌘R rename, ⌘N new item, ⌫ delete, ⌘Z undo, ⌘F search, ⇥ search/results, ⌘G show in list, ⌘←/→ switch lists, ⇧⌘N new pinboard, ⌘P add to stack, ⌘T pause, ⌘, settings, ⎋ close. Quick-paste and plain-text modifiers are configurable.
- **Pinboards**: named, colored lists that never expire. Pin via context menu or drag a card onto a tab; reorder boards and items by dragging; drop content from other apps onto a board.
- **Search & filters**: live search across history and pinboards with highlighted matches; filter tokens for type, source app, and date (typed suggestions or the filter menu).
- **Quick Look**: full text, images (rotate, copy recognized text), live web page for links, Quick Look for files, HEX/RGB/HSB for colors.
- **Paste Stack** (⇧⌘C): collect items, then each ⌘V pastes the next one. Reorder, reverse, plain-text toggle, undo, and Paste All (⌃⌥⌘V).
- **Suggestions**: ranks items by what you usually paste into the current app.
- **Privacy**: ignore apps, skip confidential (passwords) and transient content, pause for a set time.
- **Retention**: 1 day / week / month / year / forever (pinned items are kept), plus Erase History.
- **Sync**: optional iCloud Drive sync across Macs (merge with tombstones).
- **MCP server** for AI tools: enable in Settings › Intelligence, then `claude mcp add clipbay -- /Applications/Clipbay.app/Contents/MacOS/Clipbay --mcp`. Tools: `search_clipboard`, `list_recent`, `get_item`, `list_pinboards`, `list_pinboard_items`, `save_item`, `copy_to_clipboard`.

Data lives in `~/Library/Application Support/Clipbay` (or `iCloud Drive/Clipbay` when sync is on).

`Clipbay --snapshot <dir>` renders the main views offscreen to PNGs for visual checks.
