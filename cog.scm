(define package-name 'helix-sidekick)
(define version "0.1.0")

;; steel-pty must export: make-terminal-renderer, make-terminal-with-renderer,
;; term-resize-from-term, Terminal-*pty-process*, Terminal-kill-switch,
;; Terminal-active, Terminal-focused?, show-term, stop-terminal
(define dependencies
  '((#:name steel-pty #:git-url "https://github.com/mattwparas/steel-pty.git")))

(define dylibs '())
