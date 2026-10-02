# shot

Headless screenshots for Claude on macOS. shot is a native Swift MCP server that captures windows, marks them up, covers secrets and finds old screenshots, without opening an app window or taking focus. You keep working while an agent captures.

- **capture**: a screen, a window (by app or title, even when it's covered or minimized) or a region
- **compose**: annotate (arrows, boxes, counters, labels, highlights, spotlight, blur, redact), crop, auto-balance margins, and place on a background with padding, shadow, rounded corners and an aspect ratio
- **target**: point any annotation or crop at text in the image (`"target": "Save"`) instead of pixel coordinates; arrows find open space, labels sit under what they describe
- **redact_sensitive** / **find_sensitive**: find API keys, tokens, passwords, JWTs, private keys, emails, card numbers and phone numbers, and cover them with solid boxes (faces too, with `redact_faces`); agents only ever see masked previews
- **find_shots**: search every screenshot you've taken by app, window title, OCR text and description, without opening images
- **ocr**, **list_windows**, **annotate**

```json
{"input": "shot.png",
 "redact_sensitive": true,
 "annotations": [
   {"type": "counter", "target": "Create project"},
   {"type": "arrow", "target": "Billing"},
   {"type": "text", "target": "Billing", "text": "Moved here in v2", "background": true}
 ],
 "background": {"preset": "violet"}}
```

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add davekiss/shot
/plugin install shot@shot
```

This adds the MCP server, a skill that teaches Claude how to use it well, a `/shot` command that captures your terminal window, and a screenshot history pane. The first time it runs, it downloads the prebuilt binary for its version from this repo's releases.

### Just the MCP server

Download `shot-macos-universal.tar.gz` from [Releases](https://github.com/davekiss/shot/releases), or build it:

```sh
swift build -c release
claude mcp add --scope user shot -- "$PWD/.build/release/shot"
```

Any MCP client works; shot speaks MCP over stdio.

### Permissions

Capturing needs **Screen Recording** permission for the app that launches Claude Code (your terminal, or the Claude app): System Settings → Privacy & Security → Screen Recording. Without it, captures show the desktop but not window contents. Editing, OCR and redaction need no permissions.

## The screenshot library

Every PNG in `~/Screenshots`, and every file shot writes anywhere, gets a record in `~/Screenshots/.shot-index.json`: when it was taken, the app and window it came from, its OCR text, and a description. Files shot didn't write (from CleanShot or macOS) are indexed but never modified.

Descriptions come from the agent that took the screenshot (`annotate`, or `description` on `compose`). You can also turn on a background describer: while the MCP server runs, it has Claude Haiku describe each screenshot that still has none, a minute after it was taken, using `claude -p` with your own Claude Code login. It's off by default because it sends those screenshots, including ones shot didn't take, to Claude. Set `SHOT_DESCRIBE` in your environment (the plugin passes it through) or with `claude mcp add -e`:

| value | describes |
| --- | --- |
| `off` (default) | nothing |
| `new` | screenshots taken after it was turned on |
| `all` | every screenshot in the library, including old ones |

## Command line

Every tool also runs from the command line, which is handy for scripts and testing:

```sh
shot capture '{"mode":"window","app":"Safari"}'
shot compose '{"input":"in.png","redact_sensitive":true,"background":{"preset":"sunset"}}'
shot find_shots '{"query":"stripe error","since":"3d"}'
shot find_sensitive '{"input":"in.png"}'
```

Coordinates are always pixels of the original image, with the origin at the top left. Previews returned to agents are downscaled; divide preview positions by `preview_scale`.

## Development

```sh
swift build
swift test
CLAUDE_CODE_PLUGIN_DIRS="$PWD/claude-mod" claude   # load the plugin from this checkout
```

Inside a checkout, the plugin's launcher uses your local `.build/release/shot` over the downloaded release. To release, bump the version in `claude-mod/bin/shot`, `claude-mod/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, then push a `v<version>` tag; the release workflow builds a universal binary and publishes it.

## License

MIT
