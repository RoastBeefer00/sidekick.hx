# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A [Steel](https://github.com/mattwparas/steel) (Scheme) plugin for [helix-steel](https://github.com/mattwparas/helix) that embeds an AI CLI (defaulting to `claude`) as a sidebar. There is no build step — the entire project is a single Scheme source file (`sidekick.scm`) plus package metadata (`cog.scm`).

## Package Management

This package is managed by `forge` (the helix-steel package manager):

```sh
# Install from git
forge pkg install --git https://github.com/RoastBeefer00/helix-sidekick.git

# Users add this to their cog.scm dependencies instead:
(#:name helix-sidekick #:git-url "https://github.com/RoastBeefer00/helix-sidekick.git")
```

`cog.scm` declares the package name, version, and the single dependency: `steel-pty`.

## Architecture

All logic lives in `sidekick.scm`. The design is a two-backend dispatcher:

- **PTY backend** — creates an embedded right-side vertical split inside helix using `steel-pty` / `libsteel_pty`. The PTY process persists between open/close cycles. Uses `set-editor-clip-right!` to shrink the editor area and `make-terminal-with-renderer` to render the terminal widget. The panel fraction is controlled by `*sidekick-fraction*` (default `1/2`).

- **tmux backend** — shells out to `tmux` commands, keeping the AI session in a detached named session (`helix-sidekick`) and displaying it via `tmux display-popup`. Text is sent via a temp file (`/tmp/.helix-sidekick-paste`) loaded as a tmux buffer.

Backend selection (`*sidekick-backend*`) defaults to `'auto`, which checks the `TMUX` env var via `maybe-get-env-var`.

The public API (`sidekick`, `close-sidekick`, `sidekick-send!`, `sidekick-send-selection!`, `sidekick-send-buffer!`, `set-sidekick-cmd!`, `set-sidekick-backend!`) dispatches to the active backend via `case`.

Fenced code blocks are constructed by `sidekick-code-block`, which detects the file extension of the current buffer to set the language tag.

## Key Globals

| Variable | Default | Purpose |
|---|---|---|
| `*sidekick-cmd*` | `"claude"` | AI CLI command to run |
| `*sidekick-backend*` | `'auto` | Backend selector |
| `*sidekick-fraction*` | `1/2` | PTY panel width fraction |
| `*sidekick-pty*` | `#f` | Live PTY terminal handle |
| `*sidekick-tmux-session*` | `"helix-sidekick"` | tmux session name |
| `*sidekick-tmux-buf*` | `"/tmp/.helix-sidekick-paste"` | tmux paste buffer path |

## Steel/helix-steel Conventions

- `(#%require-dylib ...)` loads native Rust extensions (here: `libsteel_pty`)
- `(require-builtin helix/components)` loads built-in helix component bindings
- `(provide ...)` at the end of the file exports the public symbols
- `;;@doc` comments on `define` forms populate helix's `:doc` command
- Commands registered with `define` become helix typed commands (`:sidekick`, etc.) when the file is required in `init.scm`
