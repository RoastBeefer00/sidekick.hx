;; helix-sidekick — AI assistant sidebar for helix-steel
;;
;; Opens your AI CLI (default: `claude`) either as an embedded PTY split panel
;; within helix or in a tmux popup (auto-detected). Supports sending the current
;; selection or entire buffer as a fenced code block.
;;
;; Usage in init.scm:
;;   (require "helix-sidekick/sidekick.scm")
;;   (keymap (global)
;;           (normal (space (s ":sidekick")
;;                          (S ":sidekick-send-selection!")
;;                          (B ":sidekick-send-buffer!")))
;;           (select (space (S ":sidekick-send-selection!")
;;                          (B ":sidekick-send-buffer!"))))

(#%require-dylib "libsteel_pty"
                 (only-in pty-process-send-command
                          vte/advance-bytes))

(require (prefix-in helix. "helix/commands.scm"))
(require "helix/misc.scm")
(require "helix/editor.scm")
(require (prefix-in helix.static. "helix/static.scm"))
(require "steel/result")
(require-builtin helix/components)
(require "steel-pty/term.scm")

;;;; Configuration

(define *sidekick-cmd* "claude")
(define *sidekick-backend* 'auto) ; 'auto | 'tmux | 'pty

;;;; Backend selection

(define (sidekick-in-tmux?)
  (Ok? (maybe-get-env-var "TMUX")))

(define (sidekick-effective-backend)
  (case *sidekick-backend*
    [(tmux) 'tmux]
    [(pty)  'pty]
    [(auto) (if (sidekick-in-tmux?) 'tmux 'pty)]
    [else   'pty]))

;;;; Helpers

(define (sidekick-current-path)
  (let* ([focus  (editor-focus)]
         [doc-id (editor->doc-id focus)])
    (editor-document->path doc-id)))

(define (sidekick-path->extension path)
  (define str (if (string? path) path (path->string path)))
  (define dot-pos
    (let loop ([i (- (string-length str) 1)])
      (cond
        [(< i 0) #f]
        [(char=? #\. (string-ref str i)) i]
        [else (loop (- i 1))])))
  (if dot-pos
      (substring str (+ dot-pos 1) (string-length str))
      #f))

(define (sidekick-code-block text)
  (define ext (sidekick-path->extension (sidekick-current-path)))
  (define lang (if ext ext ""))
  (string-append "```" lang "\n" text "\n```\n"))

;;;; PTY backend — rendered as a right-side vertical split

(define *sidekick-pty* #f)
(define *sidekick-dead-pty* #f) ; exit-detected handle awaiting stop-terminal
(define *sidekick-fraction* 1/2)
(define *sidekick-stashed-area* #f)
(define *sidekick-terminal-area* #f)

(define (sidekick-pty-running?)
  (and *sidekick-pty* (not (unbox (Terminal-kill-switch *sidekick-pty*)))))

(define (sidekick-pty-flush-dead!)
  (when *sidekick-dead-pty*
    (stop-terminal *sidekick-dead-pty*)
    (set! *sidekick-dead-pty* #f)))

(define (sidekick-pty-on-start terminal)
  ;; Prefer tmux as the backing process: closing the panel detaches the tmux
  ;; client rather than killing the AI session, so the conversation persists.
  ;; Falls back to a direct exec when tmux is not available.
  (pty-process-send-command
   (Terminal-*pty-process* terminal)
   (string-append "(" (sidekick-tmux-ensure-cmd)
                  " && exec tmux attach-session -t " *sidekick-tmux-session* ")"
                  " || (cd " (helix-find-workspace) " && exec " *sidekick-cmd* ")\r")))

(define (sidekick-calculate-area state rect)
  ;; Detect process exit: save handle for lazy stop, reset editor clip immediately.
  (when (and *sidekick-pty* (unbox (Terminal-kill-switch *sidekick-pty*)))
    (set! *sidekick-dead-pty* *sidekick-pty*)
    (set! *sidekick-pty* #f)
    (set! *sidekick-stashed-area* #f)
    (set! *sidekick-terminal-area* #f)
    (set-editor-clip-right! 0))
  (if (not *sidekick-pty*)
      ;; No live terminal — render zero-size so the phantom component is invisible.
      (area (area-x rect) (area-y rect) 0 0)
      (if (and *sidekick-terminal-area* (equal? *sidekick-stashed-area* rect))
          *sidekick-terminal-area*
          (begin
            (set! *sidekick-stashed-area* rect)
            (let* ([width (round (* *sidekick-fraction* (area-width rect)))])
              (set-editor-clip-right! width)
              (term-resize-from-term state
                                     (- (area-height rect) 3)
                                     (- width 5))
              (set! *sidekick-terminal-area*
                    (area (+ (area-x rect) (- (area-width rect) width))
                          (area-y rect)
                          width
                          (- (area-height rect) 1)))
              *sidekick-terminal-area*)))))

(define sidekick-render (make-terminal-renderer sidekick-calculate-area))

(define (sidekick-pty-open)
  (sidekick-pty-flush-dead!)
  (cond
    [(not (sidekick-pty-running?))
     (let ([term (make-terminal-with-renderer "sidekick"
                                              *default-shell*
                                              *default-terminal-rows*
                                              *default-terminal-cols*
                                              sidekick-pty-on-start
                                              vte/advance-bytes
                                              sidekick-render)])
       (set! *sidekick-pty* term)
       (show-term term))]
    ;; Panel is showing and helix has focus (e.g. after Ctrl-Esc) — toggle it closed.
    [(not (Terminal-focused? *sidekick-pty*))
     (sidekick-pty-close)]
    ;; Claude has focus — re-show/focus (no-op in practice, but keeps the call safe).
    [else
     (show-term *sidekick-pty*)]))

(define (sidekick-pty-close)
  (sidekick-pty-flush-dead!)
  (when *sidekick-pty*
    (stop-terminal *sidekick-pty*)
    (set! *sidekick-pty* #f)
    (set! *sidekick-stashed-area* #f)
    (set! *sidekick-terminal-area* #f)
    (set-editor-clip-right! 0)))

(define (sidekick-pty-send! text)
  (unless (sidekick-pty-running?)
    (sidekick-pty-open))
  (pty-process-send-command (Terminal-*pty-process* *sidekick-pty*) text))

;;;; tmux backend
;;
;; Opens sidekick in a persistent detached tmux session shown via
;; `tmux display-popup`. Floats over helix without touching the layout.
;; Conversation is preserved between open/close.

(define *sidekick-tmux-session* "helix-sidekick")
(define *sidekick-tmux-buf*     "/tmp/.helix-sidekick-paste")

(define (sidekick-tmux-ensure-cmd)
  (string-append "tmux has-session -t " *sidekick-tmux-session*
                 " 2>/dev/null"
                 " || tmux new-session -d -s " *sidekick-tmux-session*
                 " 'exec " *sidekick-cmd* "'"))

(define (sidekick-tmux-open)
  (helix.run-shell-command
    (string-append (sidekick-tmux-ensure-cmd)
                   " && tmux display-popup -E -w 80% -h 80%"
                   " 'tmux attach-session -t " *sidekick-tmux-session* "'")))

(define (sidekick-tmux-close)
  (helix.run-shell-command
    (string-append "tmux kill-session -t " *sidekick-tmux-session* " 2>/dev/null || true")))

(define (sidekick-tmux-send! text)
  (define port (open-output-file *sidekick-tmux-buf*))
  (display text port)
  (close-output-port port)
  (helix.run-shell-command
    (string-append (sidekick-tmux-ensure-cmd)
                   " && tmux load-buffer " *sidekick-tmux-buf*
                   " && tmux paste-buffer -d -t " *sidekick-tmux-session*)))

;;;; Public API — dispatches to the active backend

;;@doc
;; Open the sidekick AI assistant. Uses tmux display-popup when inside tmux,
;; otherwise opens as an embedded right-side split panel.
(define (sidekick)
  (case (sidekick-effective-backend)
    [(tmux) (sidekick-tmux-open)]
    [(pty)  (sidekick-pty-open)]))

;;@doc
;; Close the sidekick panel/session.
(define (close-sidekick)
  (case (sidekick-effective-backend)
    [(tmux) (sidekick-tmux-close)]
    [(pty)  (sidekick-pty-close)]))

;;@doc
;; Send raw text to the sidekick process. Opens it first if not running.
(define (sidekick-send! text)
  (case (sidekick-effective-backend)
    [(tmux) (sidekick-tmux-send! text)]
    [(pty)  (sidekick-pty-send! text)]))

;;@doc
;; Send the current selection as a fenced code block.
;; Works in normal and select (visual) mode.
(define (sidekick-send-selection!)
  (sidekick-send! (sidekick-code-block (helix.static.current-highlighted-text!))))

;;@doc
;; Send the entire current buffer as a fenced code block.
(define (sidekick-send-buffer!)
  (define doc-id (editor->doc-id (editor-focus)))
  (sidekick-send! (sidekick-code-block (to-string (editor->text doc-id)))))

;;@doc
;; Override the default AI command (default: "claude").
(define (set-sidekick-cmd! cmd)
  (set! *sidekick-cmd* cmd))

;;@doc
;; Force a specific backend: 'auto | 'tmux | 'pty
(define (set-sidekick-backend! backend)
  (set! *sidekick-backend* backend))

(provide sidekick
         close-sidekick
         sidekick-send!
         sidekick-send-selection!
         sidekick-send-buffer!
         set-sidekick-cmd!
         set-sidekick-backend!)
