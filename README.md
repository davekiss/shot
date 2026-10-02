<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.png">
    <img src="assets/logo-light.png" alt="shot" width="160">
  </picture>
</p>

<h1 align="center">shot</h1>

<p align="center"><b>Your agent takes the screenshot. You keep working.</b></p>

<p align="center">
  Capture, mark up, redact and find screenshots on macOS, from any MCP agent.<br>
  No app window. No stolen focus. No API keys in your bug reports.
</p>

<p align="center">
  <a href="https://github.com/davekiss/shot/releases"><img src="https://img.shields.io/github/v/release/davekiss/shot?color=000&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-000" alt="macOS 13+">
  <img src="https://img.shields.io/badge/MCP-stdio-000" alt="MCP">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-000" alt="MIT"></a>
</p>

---

You're deep in a bug with your agent, and it needs to see the window. So you stop typing, hit ⌘⇧4, drag a box, find the file, drag it into the chat. Later you want to share it, so you open an editor, draw an arrow, and squint at the corner to make sure your Stripe key isn't in it.

With shot, you say *"screenshot the checkout page and circle the error."* The agent finds the window, even if it's buried under six others or minimized to the Dock. It captures it without moving your cursor, points the arrow at the words "Payment failed", blacks out the API key it spotted in the console, and saves it where you'll find it next week.

You never left your keyboard.

<p align="center">
  <img src="assets/hero.png" alt="A terminal showing a .env file. Every key, password, email and phone number is covered by a black box, while the variable names stay readable." width="820">
  <br>
  <sub>Made by shot with one flag: <code>redact_sensitive: true</code>. The variable names stay readable, and so does the database host.</sub>
</p>

## Get started

**Claude Code**: one install gets you the server, a skill that teaches Claude to use it well, and a `/shot` command.

```
/plugin marketplace add davekiss/shot
/plugin install shot@davekiss
```

**Codex, OpenCode, Cursor and every other MCP client**:

```sh
brew install davekiss/tap/shot
codex mcp add shot -- shot        # or see the configs below
```

Then grant your terminal **Screen Recording** permission (System Settings → Privacy & Security), and ask your agent for a screenshot.

## What it's good at

### It never takes your screen

shot captures in the background through macOS's own `screencapture`. Windows are found by app or title and captured whole, even when they're covered by other windows or minimized to the Dock. Your cursor, your focus and your typing are left alone.

> *"Grab the Simulator window."* · *"Screenshot every Chrome window."* · *"Capture the minimized Slack window."*

### It points at words, not pixels

Agents are bad at guessing coordinates from a downscaled preview. So shot lets them name the thing instead. Any annotation can take a `target`, and shot finds that text in the image and places the mark the way a person would: boxes around it, numbered steps on its corner, labels underneath, arrows coming in from open space instead of through the paragraph next to it.

```json
{"input": "settings.png",
 "annotations": [
   {"type": "counter", "target": "Create project"},
   {"type": "arrow",   "target": "Billing"},
   {"type": "text",    "target": "Billing", "text": "Moved here in v2", "background": true}
 ],
 "background": {"preset": "violet"}}
```

When the UI changes, re-run the same call and the marks follow the text. If a target isn't on screen, the error lists the text that is, so the agent corrects itself instead of guessing.

### It covers secrets before you share

`redact_sensitive: true` reads the image and covers API keys (Anthropic, OpenAI, GitHub, AWS, Stripe, Slack, Google), JWTs, bearer tokens, private keys, passwords in `KEY=value` pairs and connection URLs, random-looking tokens, emails, card numbers and phone numbers. Solid boxes only, because blur can be reversed. Faces are opt-in with `redact_faces`, since product screenshots are full of avatars you want to keep.

The agent gets back what was covered and where, as masked previews like `ghp_…(36 chars)`. The secret itself never enters its context.

### It remembers every screenshot

Every screenshot in `~/Screenshots` is indexed with the app and window it came from, its text, and a description. Your agent searches that instead of opening images one by one:

> *"Find the screenshot of the Mux dashboard error from last week."*

### It makes them look good

Backgrounds (gradients, your wallpaper, a blurred copy), padding, shadow, rounded corners, aspect ratios, and trimming of uneven margins. A CleanShot-style editor your agent drives with one call.

## Tools

| Tool | What it does |
| --- | --- |
| `capture` | A screen, a window (by app, title or id; covered and minimized windows work) or a region |
| `compose` | Annotations, `target`, `redact_sensitive`, crop, auto-balance, backgrounds |
| `find_sensitive` | Report secrets and personal data in an image, masked, without editing it |
| `find_shots` | Search the screenshot library by words, app and date |
| `ocr` | Every line of text with its box in image pixels |
| `list_windows` | Open windows with id, app, title and bounds (`all: true` includes minimized) |
| `annotate` | Save a description of a screenshot so it can be found later |

Annotation types: `arrow`, `line`, `rect`, `ellipse`, `text`, `counter`, `highlight`, `spotlight`, `redact`, `pixelate`, `blur`. Coordinates are always pixels of the original image, top-left origin.

## Install in detail

### Claude Code plugin

```
/plugin marketplace add davekiss/shot
/plugin install shot@davekiss
```

Adds the MCP server, the skill, a `/shot` command that captures your terminal window, and a screenshot history pane. On first run it downloads the prebuilt binary matching its version from this repo's releases. Prefer the bare server? `claude mcp add --scope user shot -- shot`.

### The binary

```sh
brew install davekiss/tap/shot
```

Or download `shot-macos-universal.tar.gz` from [Releases](https://github.com/davekiss/shot/releases), or build it with `swift build -c release`. One universal binary runs on Apple Silicon and Intel.

### Register it with your agent

shot speaks MCP over stdio.

**Codex**: `codex mcp add shot -- shot`, or in `~/.codex/config.toml`:

```toml
[mcp_servers.shot]
command = "shot"
```

**OpenCode**: in `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "shot": { "type": "local", "command": ["shot"] }
  }
}
```

**Cursor**: in `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "shot": { "command": "shot" }
  }
}
```

### The skill

The skill teaches an agent when to reach for each tool, to point at text with `target`, and to redact before sharing. Codex and OpenCode read skills from `~/.agents/skills`, and Homebrew installs a copy you can link there:

```sh
mkdir -p ~/.agents/skills
ln -s "$(brew --prefix)/share/shot/skills/screenshots" ~/.agents/skills/screenshots
```

Without Homebrew, copy `claude-mod/skills/screenshots` from this repo or the release archive into `~/.agents/skills/`.

### Permissions

Capturing needs **Screen Recording** permission for the app that runs your agent: your terminal, or a desktop app like Claude or Cursor. Without it, captures show the desktop but not window contents. Editing, OCR and redaction need no permissions at all.

## The screenshot library

Every PNG in `~/Screenshots`, and every file shot writes anywhere, gets a record in `~/Screenshots/.shot-index.json`: when it was taken, the app and window it came from, its OCR text, and a description. Screenshots from CleanShot or macOS are indexed too, and never modified.

Descriptions come from the agent that took the screenshot. You can also turn on a background describer, which has Claude Haiku describe each screenshot that doesn't have one yet, using `claude -p` and your own Claude Code login. It's off by default because it sends those screenshots to Claude, including ones shot didn't take. Set `SHOT_DESCRIBE` in your environment or your client's MCP config:

| Value | Describes |
| --- | --- |
| `off` (default) | nothing |
| `new` | screenshots taken after it was turned on |
| `all` | every screenshot in the library |

## Command line

Every tool runs from the shell too, which is handy for scripts:

```sh
shot capture '{"mode":"window","app":"Safari"}'
shot compose '{"input":"in.png","redact_sensitive":true,"background":{"preset":"sunset"}}'
shot find_shots '{"query":"stripe error","since":"3d"}'
shot find_sensitive '{"input":"in.png"}'
```

## Development

```sh
swift build
swift test
CLAUDE_CODE_PLUGIN_DIRS="$PWD/claude-mod" claude   # load the plugin from this checkout
```

Inside a checkout, the plugin uses your local `.build/release/shot` instead of downloading a release. To release, bump the version in `claude-mod/bin/shot`, `claude-mod/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, then push a `v<version>` tag. The release workflow tests, builds a universal binary, publishes it, and updates the Homebrew formula when the `HOMEBREW_TAP_TOKEN` secret is set.

## License

MIT
