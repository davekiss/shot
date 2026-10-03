# Changelog

What changed in each release of shot, newest first. Tool names and options appear exactly as an agent calls them. Changes to default behavior are listed under **Behavior changes**, so an agent upgrading can check what it relied on.

The format follows [Keep a Changelog](https://keepachangelog.com), and versions follow [Semantic Versioning](https://semver.org). Before 1.0, a minor or patch release may change defaults; when it does, it says so here.

## [Unreleased]

### Changed
- **Claude Code plugin:** new captures and edits appear on a one-row strip above the prompt instead of a toast. It lists the last 3 shots, newest first; clicking one opens it in Preview, `copy` copies the newest path, and `hide` dismisses the strip until the next shot. While the strip is hidden, the prompt's hint line shows a dim `▣ N new shots · /shot history` for 30 minutes.

### Removed
- **Claude Code plugin:** the one-row notice pane and the toast fallback for captures.

## [0.1.7] - 2026-10-03

The first release whose binary is signed with a Developer ID and notarized by Apple, so a browser download opens without a Gatekeeper warning.

### Added
- `capture` and `record` take `ephemeral: true` for quick looks. The file goes to a temp folder instead of `~/Screenshots`, stays out of the library, and is deleted after 10 minutes. Follow-up `ocr`, `compose` and `diff` calls on it still work in that window, and their outputs stay ephemeral unless given an `output` path. Results carry `"ephemeral": true` and `deleted_after_seconds`.
- `SHOT_LIBRARY` moves the screenshot library and its index out of `~/Screenshots`.

### Changed
- `capture`, `record` and `point` check Screen Recording permission first. Without it they return an error with the steps to grant it, instead of a capture with no window contents.
- Release binaries are signed and notarized.

## [0.1.6] - 2026-10-02

### Fixed
- `record`: GIF frames last until the next frame, and a still ending is kept to the real stop time in the GIF, the MP4 and the reported `duration`. macOS only sends frames when the screen changes, so still stretches previously played too fast and endings were cut short.

## [0.1.5] - 2026-10-02

### Added
- `record` films a window, a screen `region` or the main screen for up to 60 `seconds` without taking focus, or stops early on `until` (`{text}`, `{gone}` or `{stable}`). It returns a storyboard: `moments`, the frames where something visibly changed, each with its time, frame path and changed text, plus a grid image. It saves an MP4, and a GIF with `gif: true`.

### Changed
- `diff` reports the whole lines a change touches in `text_before` and `text_after` (`Deploying…` → `Deployed ✓`), not just the changed characters.

### Fixed
- The plugin launcher now uses a `shot` already on `PATH`, such as a Homebrew install, instead of downloading a second copy.

## [0.1.4] - 2026-10-02

### Added
- `diff` compares two captures of the same size and returns each changed region with its text before and after, plus an image with the changes boxed and numbered.
- `capture` takes `wait_for`: `{text: "…"}` waits for text to appear, `{gone: "…"}` for it to disappear, `{stable: 1}` for 1 second with no visible change. `timeout` defaults to 20 seconds, max 120. The result reports `wait_met`, and on a timeout still returns the last frame.
- `point` draws marks (arrow, rect, ellipse, line, text, counter, highlight, spotlight) over the live screen for a few `seconds`, then fades them. Clicks pass through, focus never moves, nothing is saved. If the window is partly covered, the result includes a `note`.
- `style: "sketch"` draws shapes hand-drawn: loops that overshoot, double-stroked boxes, bowed arrows, highlighter swipes. Set it per call, per annotation, or as a default with `SHOT_STYLE`. The default style is `crisp`.

### Changed
- Loops and boxes placed with `target` never touch the text they mark. In tight spots they use a finer pen.
- Mark size scales with the image's text, within a band set by the image size.

## [0.1.3] - 2026-10-02

### Added
- Type styles for labels and counters, set with `font`: `pixel` (Departure Mono, embedded, the default), `clean`, `rounded`, `serif`, `mono`, or an installed font name. `SHOT_FONT` sets the default.
- `crop` accepts a list of targets to frame several lines.

### Changed
- Marks draw in adaptive ink: near-black with a white halo on light areas, near-white with a dark halo on dark areas. An explicit `color` keeps its hue.
- Marks avoid each other as well as the screenshot's text. Callout labels sit at the arrow's tail, and counters sit beside their text.

### Behavior changes
- `compose` redacts sensitive text by default. Pass `redact_sensitive: false` to keep it visible.
- The default mark color changed from purple `#7C5CFF` to adaptive ink.

## [0.1.2] - 2026-10-02

### Fixed
- Redaction covers the password in connection URLs (`scheme://user:password@host`) and leaves the host readable.
- Redaction boxes no longer clip the character before a value.

## [0.1.1] - 2026-10-02

### Added
- Install instructions for Codex, OpenCode and Cursor, and a Homebrew tap: `brew install davekiss/tap/shot`.
- Release archives include the skill, so other agents can install it from `~/.agents/skills`.

### Changed
- The Claude Code marketplace is named `davekiss`. Install with `/plugin install shot@davekiss`.

## [0.1.0] - 2026-10-02

First public release: a macOS MCP server with `capture`, `compose` (with `target`), `ocr`, `find_sensitive`, `find_shots`, `list_windows` and `annotate`, plus a Claude Code plugin with a skill, `/shot` and a history pane.

[Unreleased]: https://github.com/davekiss/shot/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/davekiss/shot/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/davekiss/shot/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/davekiss/shot/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/davekiss/shot/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/davekiss/shot/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/davekiss/shot/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/davekiss/shot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/davekiss/shot/releases/tag/v0.1.0
