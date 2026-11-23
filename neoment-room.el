;;; neoment-room.el --- Room and thread buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Douglas M.

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Room and thread buffers: a read-only timeline with a fixed 31-column
;; gutter (time and sender), date separators, rich replies, reactions,
;; the "New messages" marker, typing and tombstone notices.
;;
;; `neoment-room-render' is a pure function of the model.  Every
;; message line carries the `neoment-message' property (the message's
;; effective id); time, sender, gutters, separators and bubbles carry
;; `neoment-decoration' and are left out when copying.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hl-line)
(require 'neoment-config)
(require 'neoment-faces)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-events)
(require 'neoment-notify)
(require 'neoment-markdown)
(require 'neoment-rooms)

(defconst neoment-room-name-width 19
  "Width of the sender name in the gutter.")

(defconst neoment-room-header-width 31
  "Width of the message gutter.")

(defconst neoment-room-separator-width 60
  "Width of date separators and the unread marker.")

(defvar neoment-room-time-zone nil
  "Time zone used for message times, as for `format-time-string'.
nil means local time.")

(defvar neoment-room-image-function nil
  "Function called to add inline images after a render.
It is called in the room buffer with no argument.")

;;;; Formatting helpers

(defun neoment-room-format-bytes (bytes)
  "Return BYTES as a human readable size."
  (if (or (not (numberp bytes)) (< bytes 0))
      "?.? B"
    (let ((units '("B" "KB" "MB" "GB" "TB"))
          (value (float bytes)))
      (while (and (>= value 1024) (cdr units))
        (setq value (/ value 1024) units (cdr units)))
      (format "%.2f %s" value (car units)))))

(defun neoment-room-format-duration (ms)
  "Return the duration MS (milliseconds) as mm:ss or hh:mm:ss."
  (if (or (not (numberp ms)) (< ms 0))
      "--:--"
    (let* ((seconds (floor ms 1000))
           (hours (floor seconds 3600))
           (minutes (% (floor seconds 60) 60))
           (seconds (% seconds 60)))
      (if (> hours 0)
          (format "%02d:%02d:%02d" hours minutes seconds)
        (format "%02d:%02d" minutes seconds)))))

(defun neoment-room-filename-p (mimetype text)
  "Return non-nil when TEXT looks like a file name matching MIMETYPE."
  (and (stringp mimetype) (stringp text)
       (string-match "\\`[^/]+/\\(.+\\)\\'" mimetype)
       (let ((subtype (match-string 1 mimetype))
             (parts (split-string text "\\.")))
         (and (> (length parts) 1)
              (not (string-empty-p (car (last parts))))
              (string-search (car (last parts)) subtype)
              t))))

(defun neoment-room--separator ()
  "Return the gutter separator \" │ \"."
  (concat " " (neoment-icon 'vertical_bar) " "))

(defun neoment-room--gutter ()
  "Return the decoration that starts continuation lines."
  (propertize (concat (make-string 28 ?\s) (neoment-room--separator))
              'face 'neoment-separator 'neoment-decoration t))

(defun neoment-room--wrap-prefix ()
  "Return the `wrap-prefix' of message lines."
  (concat (make-string 29 ?\s)
          (propertize (concat (neoment-icon 'vertical_bar) " ") 'face 'neoment-separator)))

(defun neoment-room--rule (text)
  "Return TEXT centred in a rule of `─' as wide as the separators."
  (let* ((half (/ (- neoment-room-separator-width (string-width text) 2) 2.0)))
    (concat (make-string (max 0 (floor half)) ?─) text
            (make-string (max 0 (ceiling half)) ?─))))

(defun neoment-room--date (timestamp)
  "Return the date line text of TIMESTAMP (ms)."
  (format-time-string "%A %B %d, %Y" (/ timestamp 1000) neoment-room-time-zone))

(defun neoment-room--date-separator (timestamp)
  "Return the date separator for TIMESTAMP (ms), without newline."
  (concat (propertize (concat (make-string 28 ?\s) " " (neoment-icon 'tree_branch))
                      'face 'neoment-separator)
          (propertize (neoment-room--rule (concat " " (neoment-room--date timestamp) " "))
                      'face 'neoment-comment)))

(defun neoment-room--unread-marker ()
  "Return the \"New messages\" line, without newline."
  (let ((icon (neoment-icon 'down_arrow_circle)))
    (propertize (concat (make-string 28 ?\s) " " (neoment-icon 'tree_branch)
                        (neoment-room--rule (concat icon "  New messages " icon " ")))
                'face 'neoment-separator)))

(defun neoment-room--sender-face (room sender)
  "Return the name face of SENDER in ROOM, assigning the next one."
  (let* ((table (neoment-room-sender-faces room))
         (index (or (gethash sender table)
                    (puthash sender (hash-table-count table) table))))
    (neoment-faces-user-face index)))

(defun neoment-room--pad-name (name)
  "Return NAME truncated and right-aligned in the name column."
  (let ((name (truncate-string-to-width name neoment-room-name-width)))
    (concat (make-string (- neoment-room-name-width (string-width name)) ?\s) name)))

(defun neoment-room--header (room message)
  "Return the gutter of the first line of MESSAGE in ROOM."
  (if (neoment-message-is-state message)
      (neoment-room--gutter)
    (propertize
     (concat (format-time-string "%H:%M:%S" (/ (or (neoment-message-timestamp message) 0) 1000)
                                 neoment-room-time-zone)
             " "
             (propertize (neoment-room--pad-name
                          (neoment-display-name (neoment-message-sender message)))
                         'face (neoment-room--sender-face room (neoment-message-sender message)))
             (propertize (neoment-room--separator) 'face 'neoment-separator))
     'neoment-decoration t)))

(defun neoment-room--body-text (message)
  "Return the markdown body of MESSAGE."
  (string-replace
   "\0" ""
   (if (neoment-message-formatted-content message)
       (neoment-markdown-from-html (neoment-message-formatted-content message))
     (or (neoment-message-content message) ""))))

(defun neoment-room--attachment-bubble (attachment body)
  "Return (BUBBLE . CAPTION) for ATTACHMENT with message BODY.
CAPTION is nil when there is none."
  (let* ((filename (plist-get attachment :filename))
         (name-part "")
         (caption body))
    (cond
     (filename
      (setq name-part (concat ": " filename))
      (when (equal filename body) (setq caption nil)))
     ((neoment-room-filename-p (plist-get attachment :mimetype) body)
      (setq name-part (concat ": " body) caption nil)))
    (let* ((sep (neoment-room--separator))
           (size (neoment-room-format-bytes (plist-get attachment :size)))
           (duration (neoment-room-format-duration (plist-get attachment :duration)))
           (text
            (pcase (plist-get attachment :type)
              ('image (concat (neoment-icon 'image) "  Image" name-part))
              ('file (concat (neoment-icon 'file) "  File" name-part sep size))
              ('audio (concat (neoment-icon 'audio) "  Audio" name-part sep duration sep size))
              ('video (concat (neoment-icon 'video) "  Video" name-part sep duration sep size))
              ('location (setq caption nil)
                         (concat (neoment-icon 'location) "  Location"))
              (_ (concat (neoment-icon 'file) "  File" name-part)))))
      (cons (propertize (neoment-faces-bubble text) 'neoment-decoration t
                        'neoment-attachment t)
            (and caption (not (string-empty-p caption)) caption)))))

(defconst neoment-room--link-regexp "\\[\\([^]\n]*\\)\\](\\([^)[:space:]]+\\))"
  "Regexp matching a markdown link.")

(defun neoment-room--style-line (line)
  "Return the body LINE with quote, mention and emoticon faces."
  (let ((line (copy-sequence line))
        (user (neoment-user-id))
        (start 0))
    (when (string-prefix-p (neoment-icon 'vertical_bar_thick) line)
      (add-face-text-property 0 (length line) 'neoment-comment t line))
    (while (string-match neoment-room--link-regexp line start)
      (let ((mb (match-beginning 0)) (me (match-end 0))
            (text (match-string 1 line)) (url (match-string 2 line)))
        (cond
         ((string-match-p "\\`https://matrix\\.to/#/@[^[:space:]]+:[^[:space:]]+\\'" url)
          (add-face-text-property mb me (if (and user (string-search user url))
                                            'neoment-mention-user
                                          'neoment-mention)
                                  nil line))
         ((and (string-prefix-p "img:" text) (neoment-events-mxc-p url))
          (add-face-text-property mb me 'neoment-emoticon nil line)
          (put-text-property mb me 'neoment-emoticon
                             (list :title (string-trim (substring text 4)) :url url)
                             line)))
        (setq start me)))
    line))

(defun neoment-room--reaction-line (message)
  "Return the reaction bubbles of MESSAGE, or nil."
  (let ((user (neoment-user-id)))
    (when (neoment-message-reactions message)
      (mapconcat
       (lambda (pair)
         (let* ((key (car pair))
                (entries (cdr pair))
                (senders (mapcar #'cdr entries))
                (bubble (neoment-faces-bubble
                         (if (> (length entries) 1)
                             (format "%s %d" key (length entries))
                           key)
                         (member user senders))))
           (propertize bubble 'neoment-decoration t
                       'neoment-reaction (list :key key :senders senders))))
       (neoment-message-reactions message) ""))))

(defun neoment-room--thread-bubble (count)
  "Return the thread indicator bubble for COUNT replies."
  (propertize (neoment-faces-bubble
               (format "%s %d %s" (neoment-icon 'reply) count
                       (if (= count 1) "reply" "replies")))
              'neoment-decoration t 'neoment-thread-indicator t))

;;;; Rendering

(defun neoment-room--visible-messages (room thread-root-id)
  "Return the messages of ROOM shown in the buffer.
With THREAD-ROOT-ID, the root and the replies of that thread."
  (let ((messages (neoment-room-sorted-messages room)))
    (if thread-root-id
        (let ((root (neoment-room-get-message room thread-root-id)))
          (append (and root (list root))
                  (seq-filter (lambda (m) (equal (neoment-message-thread-root-id m)
                                                 thread-root-id))
                              messages)))
      (seq-remove #'neoment-message-thread-root-id messages))))

(defun neoment-room--more-after-p (messages)
  "Return non-nil when MESSAGES has a visible non-state, non-redacted message."
  (seq-some (lambda (m) (not (or (neoment-message-was-redacted m)
                                 (neoment-message-is-state m))))
            messages))

(defun neoment-room--message-lines (room message thread-root-id)
  "Return the lines of MESSAGE in ROOM as (TEXT . PROPERTIES) pairs.
THREAD-ROOT-ID is the thread of the buffer, if any."
  (let* ((key (neoment-message-effective-id message))
         (props (list 'neoment-message key))
         (body (neoment-room--body-text message))
         (attachment (neoment-message-attachment message))
         (content-lines nil))
    ;; Reply quote
    (let ((replied (neoment-message-replying-to message))
          (bar (neoment-icon 'vertical_bar_thick)))
      (when replied
        (if (neoment-message-placeholder replied)
            (push (concat bar " …") content-lines)
          (push (concat bar " " (neoment-display-name (neoment-message-sender replied)) ":")
                content-lines)
          (dolist (line (split-string (neoment-room--body-text replied) "\n" t))
            (push (concat bar " " line) content-lines)))))
    ;; Attachment bubble and caption, or the body
    (if attachment
        (let ((bubble (neoment-room--attachment-bubble attachment body)))
          (push (car bubble) content-lines)
          (when (cdr bubble)
            (dolist (line (split-string (cdr bubble) "\n"))
              (push line content-lines))))
      (dolist (line (split-string body "\n"))
        (push line content-lines)))
    (setq content-lines (nreverse content-lines))
    (let* ((first t)
           (lines
            (mapcar
             (lambda (line)
               (let* ((line (if (string-blank-p line) "" line))
                      (styled (neoment-room--style-line line))
                      (text (concat (if first
                                        (neoment-room--header room message)
                                      (neoment-room--gutter))
                                    styled)))
                 (when (and first (or (neoment-message-is-state message)
                                      (neoment-message-was-redacted message)))
                   (add-face-text-property 0 (length text) 'neoment-comment t text))
                 (prog1 (cons text (append (and first (list 'neoment-header t
                                                            'neoment-state
                                                            (neoment-message-is-state message)))
                                           props))
                   (setq first nil))))
             content-lines)))
      ;; "(edited)" at the end of the last line
      (when (neoment-message-edit-data message)
        (let ((last (car (last lines))))
          (setcar last (concat (car last)
                               (propertize " (edited)" 'face 'neoment-comment
                                           'neoment-decoration t)))))
      ;; Reactions
      (let ((reactions (neoment-room--reaction-line message)))
        (when reactions
          (setq lines (append lines (list (cons (concat (neoment-room--gutter) reactions)
                                                props))))))
      ;; Thread indicator
      (let ((count (neoment-message-thread-replies-count message)))
        (when (and (not thread-root-id) count (> count 0))
          (setq lines (append lines
                              (list (cons (concat (neoment-room--gutter)
                                                  (neoment-room--thread-bubble count))
                                          props))))))
      lines)))

(defun neoment-room--join-lines (lines)
  "Join LINES, a list of (TEXT . PROPERTIES), into the buffer text."
  (let ((prefix (neoment-room--wrap-prefix)))
    (mapconcat
     (lambda (line)
       (let ((text (concat (car line) "\n")))
         (add-text-properties 0 (length text) (cdr line) text)
         (add-text-properties 0 (length text) (list 'wrap-prefix prefix) text)
         text))
     lines "")))

(defun neoment-room-render (room-id &optional thread-root-id)
  "Return the timeline text of ROOM-ID.
With THREAD-ROOT-ID, render that thread instead."
  (let* ((room (neoment-get-room room-id))
         (messages (neoment-room--visible-messages room thread-root-id))
         (fully-read (neoment-room-fully-read room))
         (last-date nil)
         (lines nil))
    (when messages
      ;; Line 1 holds the date of the first message.
      (push (cons "" '(neoment-decoration t)) lines)
      (cl-loop
       for (message . rest) on messages
       do (let ((date (neoment-room--date (or (neoment-message-timestamp message) 0))))
            (unless (equal date last-date)
              (let ((separator (neoment-room--date-separator
                                (or (neoment-message-timestamp message) 0))))
                (if (null last-date)
                    (setcar (car lines) separator)
                  (push (cons separator '(neoment-decoration t)) lines))))
            (setq last-date date)
            (dolist (line (neoment-room--message-lines room message thread-root-id))
              (push line lines))
            (when (and fully-read
                       (equal (neoment-message-effective-id message) fully-read)
                       (neoment-room--more-after-p rest))
              (push (cons (neoment-room--unread-marker) '(neoment-decoration t)) lines)))))
    ;; Tombstone
    (let ((tombstone (neoment-room-tombstone room)))
      (when tombstone
        (push (cons (neoment-room--gutter) '(neoment-tombstone t)) lines)
        (let* ((replacement (plist-get tombstone :replacement-room))
               (text (if replacement
                         (format "%s\nNew room: %s\nUse M-x neoment-join %s to join the new room."
                                 (plist-get tombstone :body) replacement replacement)
                       (plist-get tombstone :body))))
          (dolist (line (split-string text "\n" t))
            (push (cons (concat (neoment-room--gutter)
                                (propertize line 'face 'neoment-tombstone))
                        '(neoment-tombstone t))
                  lines)))))
    ;; Typing
    (let ((typing (neoment-room-typing room)))
      (when typing
        (push (cons (concat (neoment-room--gutter)
                            (propertize (concat "Typing: "
                                                (mapconcat #'neoment-display-name typing ", "))
                                        'face 'neoment-comment))
                    '(neoment-decoration t))
              lines)))
    (string-remove-suffix "\n" (neoment-room--join-lines (nreverse lines)))))

;;;; Buffer

(defvar-local neoment-room--zoomed nil
  "Message ids whose inline image is zoomed.")

(defun neoment-room-buffer-name (room-id)
  "Return the buffer name of ROOM-ID."
  (format "neoment://room/%s/%s" room-id (neoment-room-display-name-with-space room-id)))

(defun neoment-room-thread-buffer-name (root-id author)
  "Return the buffer name of the thread ROOT-ID started by AUTHOR."
  (format "neoment://thread/%s/sender/%s" root-id author))

(defun neoment-room-buffers (room-id)
  "Return the live room and thread buffers of ROOM-ID."
  (seq-filter (lambda (buffer)
                (and (eq (buffer-local-value 'major-mode buffer) 'neoment-room-mode)
                     (equal (buffer-local-value 'neoment--room-id buffer) room-id)))
              (buffer-list)))

(defun neoment-room--find-buffer (room-id &optional thread-root-id)
  "Return the buffer of ROOM-ID (or its thread THREAD-ROOT-ID), or nil."
  (seq-find (lambda (buffer)
              (equal (buffer-local-value 'neoment--thread-root-id buffer) thread-root-id))
            (neoment-room-buffers room-id)))

(defun neoment-room--filter-substring (beg end &optional delete)
  "Return the text between BEG and END without decoration.
DELETE is passed on to `buffer-substring--filter'."
  (let ((text (buffer-substring--filter beg end delete))
        (result nil)
        (pos 0))
    (while (< pos (length text))
      (let ((next (or (next-single-property-change pos 'neoment-decoration text)
                      (length text))))
        (unless (get-text-property pos 'neoment-decoration text)
          (push (substring text pos next) result))
        (setq pos next)))
    (apply #'concat (nreverse result))))

(defun neoment-room--header-line ()
  "Return the header line of the current room buffer."
  (let ((name (neoment-room-display-name neoment--room-id)))
    (if neoment--thread-root-id
        (concat "🧵 Thread in " name)
      (let ((topic (neoment-room-topic (neoment-get-room neoment--room-id))))
        (if (and topic (not (string-empty-p topic)))
            (concat name " - " (replace-regexp-in-string "\n" " " topic))
          name)))))

(defvar-keymap neoment-room-mode-map
  :doc "Keymap of `neoment-room-mode'."
  :parent special-mode-map)

(define-derived-mode neoment-room-mode special-mode "Neoment Room"
  "Major mode for Neoment room and thread buffers.

\\{neoment-room-mode-map}"
  (setq-local buffer-undo-list t
              truncate-lines nil
              filter-buffer-substring-function #'neoment-room--filter-substring
              revert-buffer-function (lambda (&rest _) (neoment-room-render-buffer))
              header-line-format '(:eval (neoment-room--header-line)))
  (when (fboundp 'display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (visual-line-mode 1)
  (hl-line-mode 1)
  (add-hook 'kill-buffer-hook #'neoment-room--on-kill nil t))

(defun neoment-room--on-kill ()
  "Stop tracking the room when its buffer is killed."
  (when (and neoment--room-id (not neoment--thread-root-id)
             (neoment-has-room neoment--room-id))
    (neoment-room-set-tracked (neoment-get-room neoment--room-id) nil)
    (let ((buffer (current-buffer)))
      (run-at-time 0 nil (lambda ()
                           (unless (buffer-live-p buffer)
                             (neoment-rooms-refresh)))))))

;;;; Position-preserving render

(defun neoment-room--position-anchor (pos)
  "Return (KEY . OFFSET) locating POS by its message, or (nil . LINE)."
  (let ((key (get-text-property pos 'neoment-message)))
    (if key
        (let ((start (or (previous-single-property-change (1+ pos) 'neoment-message)
                         (point-min))))
          (while (and (> start (point-min))
                      (equal (get-text-property (1- start) 'neoment-message) key))
            (setq start (or (previous-single-property-change start 'neoment-message)
                            (point-min))))
          (cons key (- pos start)))
      (cons nil (save-excursion (goto-char pos) (line-number-at-pos))))))

(defun neoment-room--anchor-position (anchor)
  "Return the buffer position of ANCHOR, see `neoment-room--position-anchor'."
  (if (car anchor)
      (let ((pos (text-property-any (point-min) (point-max) 'neoment-message (car anchor))))
        (if pos
            (let ((end (or (next-single-property-change pos 'neoment-message) (point-max))))
              (min (+ pos (cdr anchor)) (max pos (1- end))))
          (point-max)))
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- (cdr anchor)))
      (point))))

(defun neoment-room-render-buffer ()
  "Re-render the current room buffer, keeping point and window starts."
  (when (and neoment--room-id (neoment-has-room neoment--room-id))
    (let* ((windows (get-buffer-window-list (current-buffer) nil t))
           (point-anchor (neoment-room--position-anchor (point)))
           (window-anchors
            (mapcar (lambda (w)
                      (list w (neoment-room--position-anchor (window-point w))
                            (neoment-room--position-anchor (window-start w))))
                    windows))
           (inhibit-read-only t)
           (neoment--bubble-edges (neoment-faces-bubble-edges
                                   (and windows (window-frame (car windows))))))
      (when (and (eq (current-buffer) (window-buffer (selected-window)))
                 (not neoment--thread-root-id))
        (neoment-room-mark-read neoment--room-id))
      (erase-buffer)
      (insert (neoment-room-render neoment--room-id neoment--thread-root-id))
      (goto-char (neoment-room--anchor-position point-anchor))
      (pcase-dolist (`(,w ,pt ,start) window-anchors)
        (set-window-start w (neoment-room--anchor-position start) t)
        (set-window-point w (neoment-room--anchor-position pt)))
      (when neoment-room-image-function
        (funcall neoment-room-image-function)))))

(defun neoment-room-refresh (room-id)
  "Schedule a re-render of every buffer of ROOM-ID."
  (dolist (buffer (neoment-room-buffers room-id))
    (neoment-ui-schedule buffer #'neoment-room-render-buffer)))

(defun neoment-room-refresh-all ()
  "Schedule a re-render of every room buffer and the room list."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'major-mode buffer) 'neoment-room-mode)
      (neoment-ui-schedule buffer #'neoment-room-render-buffer)))
  (neoment-rooms-schedule-refresh))

;;;; Read marking

(defun neoment-room-mark-read (room-id)
  "Mark ROOM-ID as read, updating the local state before the server."
  (let ((room (neoment-has-room room-id)))
    (when room
      (when (eq (neoment-room-unread room) t)
        (setf (neoment-room-unread room) nil)
        (neoment-api-send-event room-id "m.marked_unread" '((unread . :false))
                                (lambda (_) (neoment-rooms-schedule-refresh))))
      (let ((event-id (plist-get (neoment-room-last-activity room) :event-id)))
        (when (and event-id (neoment-room-unread-p room))
          (neoment-api-set-read-markers
           room-id (list :read event-id :fully-read event-id)
           (lambda (_) (neoment-room-refresh room-id)))
          (neoment-rooms-schedule-refresh))))))

(defun neoment-room--on-window-change (&optional _frame)
  "Mark the room of the selected window as read."
  (let ((buffer (window-buffer (selected-window))))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'neoment-room-mode)
               (buffer-local-value 'neoment--room-id buffer))
      (with-current-buffer buffer
        (unless neoment--thread-root-id
          (neoment-room-mark-read neoment--room-id))))))

(add-hook 'window-selection-change-functions #'neoment-room--on-window-change)
(add-hook 'window-buffer-change-functions #'neoment-room--on-window-change)

;;;; History

(defun neoment-room-load-history (room-id &optional callback)
  "Load the previous page of ROOM-ID's history.
CALLBACK, if non-nil, is called with (:ok nil) or (:error ERR)."
  (let ((room (neoment-get-room room-id)))
    (if (eq (neoment-room-prev-batch room) 'end)
        (progn
          (neoment-notify--message "No more messages to load")
          (when callback (funcall callback (list :error (list :error "No more messages to load")))))
      (let ((client neoment--client))
        (neoment-api-request
         'get (neoment-api-room-path room-id "messages")
         :query `((limit . "20") (dir . "b")
                  (from . ,(or (neoment-room-prev-batch room)
                               (neoment-client-sync-token client))))
         :callback
         (lambda (result)
           (let ((data (plist-get result :ok)))
             (cond
              ((plist-get result :error)
               (when callback (funcall callback result)))
              (t
               (setf (neoment-room-prev-batch room) (or (alist-get 'end data) 'end))
               (let ((chunk (alist-get 'chunk data))
                     (state (let ((s (alist-get 'state data)))
                              (if (and (consp s) (assq 'events s)) (alist-get 'events s) s))))
                 (if (and (null chunk) (alist-get 'end data))
                     (neoment-room-load-history room-id callback)
                   (when chunk
                     (neoment-events-handle-multiple room (append chunk state) t))
                   (when callback (funcall callback (list :ok nil))))))))))))))

(defun neoment-room-load-more (room-id &optional buffer)
  "Load more history for ROOM-ID, showing progress, and re-render BUFFER."
  (let* ((room (neoment-get-room room-id))
         (first-page (null (neoment-room-prev-batch room))))
    (unless (eq (neoment-room-prev-batch room) 'end)
      (neoment-notify--message "Loading more messages..."))
    (neoment-room-load-history
     room-id
     (lambda (result)
       (let ((err (plist-get result :error)))
         (cond
          ((and err (equal (plist-get err :error) "No more messages to load")))
          (err
           (neoment-notify--error
            (concat "Error loading more messages: " (neoment-http-error-message err))))
          (t
           (neoment-notify--message "Messages loaded")
           (dolist (buf (if buffer (list buffer) (neoment-room-buffers room-id)))
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (neoment-room-render-buffer)
                 (when first-page
                   (let ((window (get-buffer-window buf)))
                     (when window
                       (set-window-point window (point-max))
                       (goto-char (point-max)))))))))))))))

;;;; Opening

(defun neoment-room--fetch-members (room-id)
  "Fetch the joined members of ROOM-ID and re-render its buffers."
  (neoment-api-request
   'get (neoment-api-room-path room-id "joined_members")
   :callback
   (lambda (result)
     (let ((room (neoment-has-room room-id)))
       (when (and room (plist-get result :ok))
         (dolist (pair (alist-get 'joined (plist-get result :ok)))
           (let ((user (symbol-name (car pair)))
                 (name (alist-get 'display_name (cdr pair))))
             (puthash user t (neoment-room-members room))
             (when (stringp name)
               (unless (neoment-has-display-name user)
                 (neoment-set-display-name user name 0)))))
         (neoment-room-refresh room-id))))))

(defun neoment-room--setup-buffer (buffer room-id &optional thread-root-id initial)
  "Prepare BUFFER for ROOM-ID (or its THREAD-ROOT-ID) with INITIAL text."
  (with-current-buffer buffer
    (neoment-room-mode)
    (setq neoment--room-id room-id
          neoment--thread-root-id thread-root-id)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (or initial
                  (concat (make-string 28 ?\s) (neoment-room--separator) "Loading..."))))))

(defun neoment-room-open (room-id)
  "Show the buffer of ROOM-ID in the selected window, creating it."
  (let ((existing (neoment-room--find-buffer room-id)))
    (if existing
        (progn
          (switch-to-buffer existing)
          (with-current-buffer existing (neoment-room-render-buffer))
          existing)
      (let ((buffer (generate-new-buffer (neoment-room-buffer-name room-id))))
        (neoment-room--setup-buffer buffer room-id)
        (switch-to-buffer buffer)
        (neoment-room-set-tracked (neoment-get-room room-id) t)
        (neoment-room-load-more room-id buffer)
        (neoment-room--fetch-members room-id)
        (neoment-rooms-schedule-refresh)
        buffer))))

(defun neoment-room-quit ()
  "Kill the current room buffer."
  (interactive)
  (kill-buffer (current-buffer)))

(defun neoment-room-load-previous ()
  "Load more history in the current room."
  (interactive)
  (neoment-room-load-more neoment--room-id))

(provide 'neoment-room)
;;; neoment-room.el ends here
