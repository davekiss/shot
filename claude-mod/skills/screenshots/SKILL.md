---
name: screenshots
description: Capture, mark up and find screenshots on macOS with the shot MCP server, silently and without taking focus. Use when the user wants a screenshot of a window, app, screen or region (including windows that are covered or minimized), wants to see what something on their screen looks like, wants an image annotated, redacted or made share-ready on a background, or wants to find a screenshot they took earlier.
---

# shot

shot is an MCP server, usually registered as `shot`, that takes and edits screenshots headlessly. It never opens a window or steals focus, so you can capture while the user keeps working. The tool schemas list every argument. This skill covers how to use them well.

## Finding an earlier screenshot

Call `find_shots` before opening any images. Every PNG in `~/Screenshots` and every file shot writes is indexed with its app, window title, OCR text and a description, so `find_shots {"query": "stripe checkout error", "since": "3d"}` usually lands on the right file without you looking at a single image. Narrow with `app`, `since` and `until` rather than paging through results.

## Capturing

Prefer `mode: "window"`. It captures one window with no desktop clutter, and works when the window is covered by others or minimized to the Dock. A minimized window comes back at full size with its current contents, as long as the app keeps drawing while minimized.

Picking the window:

- `app` and `title` are case-insensitive substrings, and spaces don't matter ("GrokBot" matches "Grok Bot"). Visible windows are matched first, frontmost first. Minimized windows are only considered when no visible window matches.
- When an app has several windows, or a match could be wrong, call `list_windows` (with `all: true` to include minimized windows), pick the window yourself, and pass its `window_id`.
- With no `app`, `title` or `window_id`, you get the frontmost window, which is usually the user's terminal rather than what they meant.

`mode: "region"` takes a rectangle in screen **points** (the units `list_windows` bounds use), not image pixels. `mode: "screen"` captures the main display, or another one with `display`.

After you look at the preview, call `annotate` with a sentence or two on what it shows: the app or page, its state, anything notable. That description is what lets you, or a later agent, find this screenshot with `find_shots`.

## Pointing at things

Coordinates in `compose` and `ocr` are pixels of the full-size image, with the origin at the top left. Previews are downscaled, so a position you read off a preview has to be divided by `preview_scale`.

To point at something with visible text, skip coordinates entirely: give the annotation `target: "the text"` and shot finds it. Boxes (rect, ellipse, highlight, spotlight, redact, blur) surround it, a counter sits on its top-left corner, an arrow points at it through empty space, a text label goes below it, and a line underlines it. Use `nth` when the text appears more than once. `crop: {"target": "Billing", "pad": 120}` crops around text the same way. The result's `targets` list says what matched where; if nothing matches, the error lists the text that is in the image, so pick from that rather than guessing.

```json
{"input": "shot.png", "annotations": [
  {"type": "counter", "target": "Create primary Bot"},
  {"type": "arrow", "target": "Open"},
  {"type": "text", "target": "Choose an existing Bot", "text": "Use one you have", "background": true}
]}
```

For things without text (icons, images), work out coordinates yourself: `ocr` gives nearby text boxes to measure from.

## Editing with compose

`compose` writes a new PNG and leaves the original alone. It runs crop → auto_balance → annotations → background, and annotation coordinates always refer to the original input, even when you also crop.

- **Share-ready image:** `auto_balance: true` plus a `background` (a gradient `preset`, `wallpaper`, or `blurred`). Add `ratio: "16:9"` for slides or social posts.
- **Before sharing anything:** pass `redact_sensitive: true` to cover API keys, tokens, passwords, JWTs, private keys, emails, card numbers and phone numbers with solid boxes, leaving labels like `GITHUB_TOKEN=` readable. Add `redact_faces: true` when real people's faces shouldn't be shown; leave it off when avatars are the point. `find_sensitive` reports the same findings without editing. Results show masked previews only; never try to recover the values. Detection works from OCR, so it can't judge personal content like private messages: blur those yourself.
- **Hiding by hand:** use `redact`, a solid box, for anything that must not be readable. `pixelate` and `blur` are for de-emphasizing; short text under them can sometimes still be made out.
- **Walkthroughs:** `counter` annotations auto-number 1, 2, 3 in the order you list them. Pair them with `text` labels or a `spotlight` to focus on one area.
- `copy: true` also puts the result on the clipboard, ready to paste into Slack or a doc.

## When a capture fails

- If an image has the desktop but not the window contents, or capture errors with a permission message, the app that launched the agent (the terminal, or a desktop app) needs Screen Recording permission in System Settings → Privacy & Security.
- "No window matches" means nothing open matched `app` or `title`. Call `list_windows` with `all: true` and pick by id.
- If the shot tools aren't loaded, the same tools run from the binary: `shot capture '{"mode":"window","app":"Chrome"}'`, `shot find_shots '{"query":"invoice"}'`. If `shot` isn't on PATH, the Claude Code plugin's copy is at `bin/shot` inside the plugin folder.
