# helix-sidekick

AI assistant sidebar for [helix-steel](https://github.com/mattwparas/helix) — opens your AI CLI as an embedded right-side split panel or a tmux popup, with commands to send selections and buffers as fenced code blocks.

Defaults to `claude` (Claude Code CLI) but works with any interactive CLI tool.

## Requirements

- [mattwparas/helix](https://github.com/mattwparas/helix) built with the `steel` feature
- An AI CLI on your `$PATH` (default: `claude`)
- `steel-pty` (installed automatically via `forge install`)
- `tmux` optional — used automatically when detected

## Installation

```sh
forge pkg install --git https://github.com/RoastBeefer00/helix-sidekick.git
```

Or add to your `cog.scm` dependencies:

```scheme
(#:name helix-sidekick #:git-url "https://github.com/RoastBeefer00/helix-sidekick.git")
```

## Usage

In your `init.scm`:

```scheme
(require "helix-sidekick/sidekick.scm")

(keymap (global)
        (normal (space (s ":sidekick")
                       (S ":sidekick-send-selection!")
                       (B ":sidekick-send-buffer!")))
        ;; Also bind in select (visual) mode
        (select (space (S ":sidekick-send-selection!")
                       (B ":sidekick-send-buffer!"))))
```

## Commands

| Command | Description |
|---|---|
| `:sidekick` | Open the AI assistant |
| `:close-sidekick` | Close the panel/session |
| `:sidekick-send-selection!` | Send selection as a fenced code block |
| `:sidekick-send-buffer!` | Send entire buffer as a fenced code block |
| `:set-sidekick-cmd!` | Override the AI command |
| `:set-sidekick-backend!` | Force a backend (`'auto`, `'tmux`, `'pty`) |

## Backends

| Backend | When used | Behaviour |
|---|---|---|
| `tmux` | Inside tmux (auto-detected) | Persistent named session shown as 80% `display-popup` |
| `pty` | Outside tmux | Embedded right-side split panel (50% of screen width) |

The PTY backend persists the AI process between open/close cycles. Close the panel with `Ctrl-Esc`.

## Configuration

```scheme
;; Use a different AI CLI
(set-sidekick-cmd! "aider")

;; Force the PTY backend even when in tmux
(set-sidekick-backend! 'pty)

;; Change the split width (default: 1/2)
(set! *sidekick-fraction* 2/3)
```
