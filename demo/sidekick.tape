# sidekick.hx demo
# Requirements: helix-steel with sidekick.hx loaded, claude CLI on PATH and authenticated,
#   keybindings from ../helix-config/init.scm active (set-sidekick-backend! 'pty,
#   Space+a+c → :sidekick, Space+a+p → :sidekick-prompt-picker!)
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
# Space+a+c opens sidekick; PTY appears on the right and takes focus
Type " ac"
Sleep 4s

# Accept claude's "trust this directory?" prompt on first launch
Enter
Sleep 1500ms

# ── Return focus to helix while panel stays open ─────────────────────────────
# Ctrl+h is intercepted by sidekick's PTY event handler: unfocuses the terminal
# and hands control back to the helix split on the left
Ctrl+h
Sleep 500ms

# ── Visually select the fibonacci function ──────────────────────────────────
Type "gg"
Sleep 200ms
Type "V"
Sleep 200ms
Type "6j"
Sleep 500ms

# ── Open the prompt picker with the selection ────────────────────────────────
# Space+a+p builds @sample.rs L1-7 from the selection and opens the action picker
Type " ap"
Sleep 1500ms

# Filter to "Find bugs" and confirm
Type "Find"
Sleep 400ms
Enter
Sleep 500ms

# ── Claude receives @sample.rs L1-7 + prompt and responds in the sidebar ─────
# Helix focus is preserved — claude streams its response in the right panel
Sleep 15s

# Hold on the result
Sleep 2s

Type ":q!"
Enter
