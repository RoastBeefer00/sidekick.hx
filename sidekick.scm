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
;;                          (B ":sidekick-send-buffer!")
;;                          (p ":sidekick-prompt-picker!")
;;                          (ret ":sidekick-unfocus")))
;;           (select (space (S ":sidekick-send-selection!")
;;                          (B ":sidekick-send-buffer!")
;;                          (p ":sidekick-prompt-picker!"))))
;;
;; PTY panel keys (while claude has focus):
;;   Shift+Tab   — return focus to helix (panel stays open)
;;   Ctrl+Esc    — close the panel entirely

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
(require-builtin helix/core/text)

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

;;;; Action picker — minimal self-contained component (no lambdas inside functions)

;; Actions: list of (label . prompt-text). ref-str is prepended on selection.
(define *sidekick-actions*
  '(("Send selection / file" . "")
    ("Explain this code"     . "Explain what this code does, step by step.\n")
    ("Find bugs"             . "Review this code for bugs, edge cases, and potential issues.\n")
    ("Fix this"              . "Fix any bugs or issues in the code above.\n")
    ("Refactor"              . "Suggest how to refactor this for clarity and maintainability.\n")
    ("Write tests"           . "Write unit tests for this code.\n")
    ("Add docs"              . "Write documentation comments for this code.\n")
    ("Optimize"              . "Suggest performance improvements for this code.\n")))

;;@doc
;; Open a helix picker with preconfigured Claude actions for the current
;; selection (or whole file if nothing is selected).
(define (sidekick-prompt-picker!)
  (define doc-id   (editor->doc-id (editor-focus)))
  (define text     (editor->text doc-id))
  (define path     (sidekick-current-path))
  (define path-str (if (string? path) path (path->string path)))
  (define ranges   (selection-char-ranges))
  (define ref-str
    (if (null? ranges)
        (string-append "@" path-str "\n")
        (let* ([range    (car ranges)]
               [from     (car range)]
               [to       (cadr range)]
               [end-char (if (> to from) (- to 1) from)]
               [start-ln (+ 1 (rope-char->line text from))]
               [end-ln   (+ 1 (rope-char->line text end-char))])
          (string-append "@" path-str " L" (int->string start-ln) "-" (int->string end-ln) "\n"))))
  (push-component!
   (#%string-picker
    (map car *sidekick-actions*)
    (lambda (selected)
      (define entry (assoc selected *sidekick-actions*))
      (when entry
        (define prompt (cdr entry))
        (sidekick-send! (if (equal? prompt "")
                            ref-str
                            (string-append ref-str prompt))))))))

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
  ;; Run inside a bash subshell without exec so bash stays alive after the AI
  ;; process exits. This prevents PTY death (and the resulting error) when the
  ;; user closes the AI with Ctrl+C — the panel shows a bash prompt instead.
  (pty-process-send-command
   (Terminal-*pty-process* terminal)
   (string-append "(" (sidekick-tmux-ensure-cmd)
                  " && exec tmux attach-session -t " *sidekick-tmux-session* ")"
                  " || (cd " (helix-find-workspace) " && " *sidekick-cmd* ")\r")))

(define (sidekick-compute-width rect)
  ;; Infer the number of helix splits by comparing the focused view width against
  ;; the available editor width from the previous frame. This converges in 1-2 frames.
  ;; Goal: make the sidekick the same width as one helix split (n+1 equal columns).
  (define W-total (area-width rect))
  (define prev-sidekick-width
    (if *sidekick-terminal-area* (area-width *sidekick-terminal-area*) 0))
  (define view-area (editor-focused-buffer-area))
  (define W-view (if view-area (area-width view-area) 0))
  (define W-avail (- W-total prev-sidekick-width))
  (define n
    (if (> W-view 0)
        (max 1 (inexact->exact (round (/ W-avail W-view))))
        1))
  (max 10 (inexact->exact (round (/ W-total (+ n 1))))))

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
      (let* ([width (sidekick-compute-width rect)])
        (set-editor-clip-right! width)
        ;; Only resize the PTY when dimensions actually change.
        (when (or (not *sidekick-terminal-area*)
                  (not (= width (area-width *sidekick-terminal-area*)))
                  (not (equal? *sidekick-stashed-area* rect)))
          (set! *sidekick-stashed-area* rect)
          (term-resize-from-term state
                                 (max 1 (- (area-height rect) 3))
                                 (max 1 (- width 5))))
        (set! *sidekick-terminal-area*
              (area (+ (area-x rect) (- (area-width rect) width))
                    (area-y rect)
                    width
                    (area-height rect)))
        *sidekick-terminal-area*)))

(define sidekick-render (make-terminal-renderer sidekick-calculate-area))

;; Custom event handler: C-h/j/k/l unfocuses the panel and lets helix handle
;; split/pane navigation instead of forwarding ctrl codes to the AI process.
(define (sidekick-pty-event-handler state event)
  (define char (key-event-char event))
  (if (and (equal? (key-event-modifier event) key-modifier-ctrl)
           (member char '(#\h #\j #\k #\l))
           (unbox (Terminal-focused? state)))
      (begin
        (set-box! (Terminal-focused? state) #f)
        (set-editor-terminal-has-focus! #f)
        ;; Helix already has the adjacent split focused; don't double-navigate.
        ;; For h/l just unfocus and consume. For j/k, move within helix splits.
        (cond
          [(equal? char #\j) (helix.static.jump_view_down)]
          [(equal? char #\k) (helix.static.jump_view_up)])
        event-result/consume)
      (terminal-event-handler state event)))

(define (sidekick-pty-open)
  (sidekick-pty-flush-dead!)
  (cond
    [(not (sidekick-pty-running?))
     (let ([term (make-terminal-custom "sidekick"
                                       "bash"
                                       *default-terminal-rows*
                                       *default-terminal-cols*
                                       sidekick-pty-on-start
                                       vte/advance-bytes
                                       sidekick-render
                                       sidekick-pty-event-handler)])
       (set! *sidekick-pty* term)
       (set-editor-terminal-has-focus! #t)
       (show-term term))]
    ;; Panel is showing and helix has focus (e.g. after Shift+Tab) — toggle it closed.
    [(not (unbox (Terminal-focused? *sidekick-pty*)))
     (sidekick-pty-close)]
    ;; Claude has focus — re-show/focus (no-op in practice, but keeps the call safe).
    [else
     (set-editor-terminal-has-focus! #t)
     (show-term *sidekick-pty*)]))

(define (sidekick-pty-close)
  (sidekick-pty-flush-dead!)
  (when *sidekick-pty*
    (stop-terminal *sidekick-pty*)
    (set! *sidekick-pty* #f)
    (set! *sidekick-stashed-area* #f)
    (set! *sidekick-terminal-area* #f)
    (set-editor-clip-right! 0)
    (set-editor-terminal-has-focus! #f)))

(define (sidekick-pty-send! text)
  (unless (sidekick-pty-running?)
    (sidekick-pty-open))
  (pty-process-send-command (Terminal-*pty-process* *sidekick-pty*) text))

;;@doc
;; Return focus to helix while keeping the sidekick panel open.
;; Equivalent to pressing Shift+Tab inside the PTY panel.
(define (sidekick-unfocus)
  (when (sidekick-pty-running?)
    (set-box! (Terminal-focused? *sidekick-pty*) #f)
    (set-editor-terminal-has-focus! #f)))

;;@doc
;; Focus the sidekick panel if already open, or open it if not running.
;; Intended as the "navigate right" fallback when helix is at its right edge.
(define (sidekick-focus!)
  (case (sidekick-effective-backend)
    [(pty)
     (if (sidekick-pty-running?)
         (begin
           (set-box! (Terminal-focused? *sidekick-pty*) #t)
           (set-editor-terminal-has-focus! #t)
           (show-term *sidekick-pty*))
         (sidekick-pty-open))]
    [(tmux) (sidekick-tmux-open)]))

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
;; Send the current selection as a @file L#-# reference.
;; Works in normal and select (visual) mode.
(define (sidekick-send-selection!)
  (define doc-id  (editor->doc-id (editor-focus)))
  (define text    (editor->text doc-id))
  (define path    (sidekick-current-path))
  (define path-str (if (string? path) path (path->string path)))
  (define ranges  (selection-char-ranges))
  (define msg
    (if (null? ranges)
        (string-append "@" path-str "\n")
        (let* ([range    (car ranges)]
               [from     (car range)]
               [to       (cadr range)]
               [end-char (if (> to from) (- to 1) from)]
               [start-ln (+ 1 (rope-char->line text from))]
               [end-ln   (+ 1 (rope-char->line text end-char))])
          (string-append "@" path-str " L" (int->string start-ln) "-" (int->string end-ln) "\n"))))
  (sidekick-send! msg))

;;@doc
;; Send the current buffer as a @file reference for Claude to read.
(define (sidekick-send-buffer!)
  (define path (sidekick-current-path))
  (define path-str (if (string? path) path (path->string path)))
  (sidekick-send! (string-append "@" path-str "\n")))

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
         sidekick-prompt-picker!
         sidekick-unfocus
         sidekick-focus!
         set-sidekick-cmd!
         set-sidekick-backend!)
