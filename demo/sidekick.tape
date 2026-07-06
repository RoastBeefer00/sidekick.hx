# sidekick.hx demo
# Requirements: helix-steel with sidekick.hx loaded, claude CLI on PATH and authenticated
# PTY backend is used automatically when not in tmux (which is the case in vhs)
# Run from this directory: vhs sidekick.tape

Output sidekick.gif

Set Shell "bash"
Set FontSize 14
Set Width 1400
Set Height 755
Set Theme "Catppuccin Mocha"
Set TypingSpeed 80ms

# Open helix with the Rust sample file
Type "hx sample.rs"
Enter
Sleep 2s

# ── Open the sidekick panel ─────────────────────────────────────────────────
# Focus moves to the claude PTY — sidekick panel appears on the right
Type " s"
Sleep 4s

# Accept claude's "trust this directory?" prompt on first launch
Enter
Sleep 1500ms

# ── Ask claude about the file ───────────────────────────────────────────────
# We're in the claude panel — type a question and send it
Type "how can I make this fibonacci function more efficient?"
Sleep 300ms
Enter

# ── Let claude respond ──────────────────────────────────────────────────────
Sleep 10s

# Hold on the result
Sleep 2s

Type ":q!"
Enter
