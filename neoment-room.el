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

(defvar neoment-room--skip-mark-read nil
  "Non-nil while a render must not mark the room as read.")

(defvar neoment-room-image-function nil
  "Function called to add inline images during a render.
It is called in the room buffer with no argument, after the text is
inserted and before point and window starts are restored.")

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

(defvar-local neoment-room--image-heights nil
  "Alist from message key to the max height of its inline image.
The height is a fraction of the window height; a missing entry means
the default size.")

(defun neoment-room--image-position (key)
  "Return the position of the image character of KEY's inline image, or nil."
  (let ((pos (point-min))
        (found nil))
    (while (and (not found) (< pos (point-max)))
      (let ((next (or (next-single-property-change pos 'neoment-image) (point-max))))
        (when (equal (get-text-property pos 'neoment-image) key)
          (setq found (1- next)))
        (setq pos next)))
    found))

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
  :parent special-mode-map
  "RET" #'neoment-room-compose
  "r" #'neoment-room-reply
  "e" #'neoment-room-edit
  "t" #'neoment-room-open-thread
  "n" #'neoment-room-next-message
  "p" #'neoment-room-previous-message
  "a" #'neoment-room-react-emoji
  "A" #'neoment-room-react-text
  "d" #'neoment-room-redact
  "w" #'neoment-room-forward
  "R" #'neoment-room-goto-replied
  "m" #'neoment-room-set-read-marker
  "V" #'neoment-room-show-event
  "P" #'neoment-room-load-previous
  "L" #'neoment-room-leave
  "o" #'neoment-room-open-attachment
  "s" #'neoment-room-save-attachment
  "u" #'neoment-room-upload
  "U" #'neoment-room-upload-clipboard-image
  "z" #'neoment-room-toggle-image-zoom
  "i" #'neoment-room-show-info
  "N" #'neoment-room-notification-settings
  "f" #'neoment-pick-room
  "F" #'neoment-pick-open-room
  "l" #'neoment-toggle-rooms-list
  "q" #'neoment-room-quit
  "g" #'revert-buffer
  "?" #'describe-mode)

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

(defun neoment-room--text-length (start end)
  "Return the number of characters between START and END outside inline images."
  (let ((count 0)
        (pos start))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'neoment-image nil end)))
        (unless (get-text-property pos 'neoment-image)
          (setq count (+ count (- next pos))))
        (setq pos next)))
    count))

(defun neoment-room--text-line-number (pos)
  "Return the line number of POS, leaving out inline image lines."
  (save-excursion
    (goto-char pos)
    (let ((target (line-beginning-position))
          (line 1))
      (goto-char (point-min))
      (while (and (< (point) target) (zerop (forward-line 1)))
        (unless (get-text-property (point) 'neoment-image)
          (setq line (1+ line))))
      line)))

(defun neoment-room--text-line-position (line)
  "Return the start of LINE, counted as `neoment-room--text-line-number' does."
  (save-excursion
    (goto-char (point-min))
    (let ((remaining (1- line)))
      (while (and (> remaining 0) (zerop (forward-line 1)))
        (unless (get-text-property (point) 'neoment-image)
          (setq remaining (1- remaining)))))
    (point)))

(defun neoment-room--position-anchor (pos)
  "Return (KEY OFFSET IMAGE-P) locating POS by its message, or (nil . LINE).
LINE leaves out inline image lines, see `neoment-room--text-line-number'.
OFFSET counts the characters of the message before POS, leaving out
inline image text.  IMAGE-P is non-nil when POS is on an image line."
  (let ((key (get-text-property pos 'neoment-message)))
    (if key
        (let ((start (or (previous-single-property-change (1+ pos) 'neoment-message)
                         (point-min))))
          (while (and (> start (point-min))
                      (equal (get-text-property (1- start) 'neoment-message) key))
            (setq start (or (previous-single-property-change start 'neoment-message)
                            (point-min))))
          (list key (neoment-room--text-length start pos)
                (save-excursion
                  (goto-char pos)
                  (and (get-text-property (line-beginning-position) 'neoment-image) t))))
      (cons nil (neoment-room--text-line-number pos)))))

(defun neoment-room--anchor-position (anchor)
  "Return the buffer position of ANCHOR, see `neoment-room--position-anchor'.
An anchor on an image line resolves to that image when it is shown."
  (if (car anchor)
      (let* ((key (car anchor))
             (pos (text-property-any (point-min) (point-max) 'neoment-message key)))
        (cond
         ((null pos) (point-max))
         ((and (nth 2 anchor) (neoment-room--image-position key)))
         (t
          (let ((end (or (next-single-property-change pos 'neoment-message) (point-max)))
                (target pos)
                (remaining (nth 1 anchor)))
            (while (and (> remaining 0) (< target end))
              (unless (get-text-property target 'neoment-image)
                (setq remaining (1- remaining)))
              (setq target (1+ target)))
            (min target (max pos (1- end)))))))
    (neoment-room--text-line-position (cdr anchor))))

(defun neoment-room--start-position (anchor)
  "Return the window start position of ANCHOR.
An anchor on an image line starts at a line start, whether the image is
still shown or not."
  (let ((pos (neoment-room--anchor-position anchor)))
    (if (or (get-text-property pos 'neoment-image)
            (and (car anchor) (nth 2 anchor)))
        (save-excursion (goto-char pos) (line-beginning-position))
      pos)))

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
                 (not neoment--thread-root-id)
                 (not neoment-room--skip-mark-read))
        (neoment-room-mark-read neoment--room-id))
      (erase-buffer)
      (insert (neoment-room-render neoment--room-id neoment--thread-root-id))
      ;; Cached images are placed now, so anchors can land on them.
      (when neoment-room-image-function
        (with-demoted-errors "neoment: inline images failed: %S"
          (funcall neoment-room-image-function)))
      (goto-char (neoment-room--anchor-position point-anchor))
      (pcase-dolist (`(,w ,pt ,start) window-anchors)
        (set-window-start w (neoment-room--start-position start) t)
        (set-window-point w (neoment-room--anchor-position pt))))))

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

;;;; Message actions

(defun neoment-room-message-at-point (&optional silent)
  "Return the message owning the current line.
Show `No message under the cursor' and return nil when there is none,
unless SILENT."
  (let* ((key (get-text-property (line-beginning-position) 'neoment-message))
         (room (and neoment--room-id (neoment-has-room neoment--room-id)))
         (message (and key room (neoment-room-get-message room key))))
    (or message
        (progn (unless silent (neoment-notify--message "No message under the cursor"))
               nil))))

(defun neoment-room--move-message (direction)
  "Move to the header of the next message in DIRECTION (1 or -1)."
  (let ((current (get-text-property (line-beginning-position) 'neoment-message))
        (target nil))
    (save-excursion
      (forward-line 0)
      (while (and (not target)
                  (let ((before (point)))
                    (and (zerop (forward-line direction)) (bolp) (/= before (point)))))
        (let ((props (text-properties-at (point))))
          (when (and (plist-get props 'neoment-header)
                     (not (plist-get props 'neoment-state))
                     (not (and (> direction 0)
                               (equal (plist-get props 'neoment-message) current))))
            (setq target (point))))))
    (if target
        (goto-char target)
      (neoment-notify--message "No more messages in this direction"))))

(defun neoment-room-next-message ()
  "Move to the header of the next message."
  (interactive)
  (neoment-room--move-message 1))

(defun neoment-room-previous-message ()
  "Move to the header of the previous message."
  (interactive)
  (neoment-room--move-message -1))

(declare-function neoment-compose-open "neoment-compose")
(declare-function neoment-room-open-attachment "neoment-media")
(declare-function neoment-room-save-attachment "neoment-media")
(declare-function neoment-room-upload "neoment-media")
(declare-function neoment-room-upload-clipboard-image "neoment-media")
(declare-function neoment-room-toggle-image-zoom "neoment-media")

(defun neoment-room-compose ()
  "Write a new message (to the thread, in a thread buffer)."
  (interactive)
  (require 'neoment-compose)
  (neoment-compose-open neoment--room-id :thread-root-id neoment--thread-root-id))

(defun neoment-room-reply ()
  "Reply to the message under the cursor."
  (interactive)
  (let ((message (neoment-room-message-at-point)))
    (when message
      (require 'neoment-compose)
      (neoment-compose-open neoment--room-id
                            :thread-root-id neoment--thread-root-id
                            :relation (list :type 'reply :message message)))))

(defun neoment-room-edit ()
  "Edit the message under the cursor, which must be the user's own."
  (interactive)
  (let ((message (neoment-room-message-at-point)))
    (when message
      (if (not (equal (neoment-message-sender message) (neoment-user-id)))
          (neoment-notify--error "You can only edit your own messages")
        (require 'neoment-compose)
        (neoment-compose-open neoment--room-id
                              :thread-root-id neoment--thread-root-id
                              :relation (list :type 'replace :message message))))))

(defun neoment-room-open-thread-buffer (room-id root-id)
  "Show the thread ROOT-ID of ROOM-ID in a window to the right."
  (let ((existing (neoment-room--find-buffer room-id root-id)))
    (if (and existing (get-buffer-window existing))
        (select-window (get-buffer-window existing))
      (let* ((root (neoment-room-get-message (neoment-get-room room-id) root-id))
             (buffer (or existing
                         (generate-new-buffer
                          (neoment-room-thread-buffer-name
                           root-id (neoment-display-name
                                    (and root (neoment-message-sender root))))))))
        (unless existing
          (neoment-room--setup-buffer
           buffer room-id root-id
           (concat (make-string 28 ?\s) (neoment-room--separator) "Loading thread...")))
        (let ((window (display-buffer buffer '((display-buffer-in-direction)
                                               (direction . right)
                                               (window-width . 50)))))
          (when window (select-window window)))
        (neoment-ui-schedule buffer #'neoment-room-render-buffer)
        buffer))))

(defun neoment-room-open-thread ()
  "Open the thread of the message under the cursor, or start one on it."
  (interactive)
  (let ((message (neoment-room-message-at-point)))
    (when message
      (let ((root-id (if (and (neoment-message-thread-replies-count message)
                              (> (neoment-message-thread-replies-count message) 0))
                         (neoment-message-effective-id message)
                       (neoment-message-thread-root-id message))))
        (if root-id
            (neoment-room-open-thread-buffer neoment--room-id root-id)
          (require 'neoment-compose)
          (neoment-compose-open neoment--room-id
                                :thread-root-id (neoment-message-effective-id message)))))))

(declare-function neoment-emoji-list "neoment-emoji")

(defun neoment-room-react (message key)
  "Toggle the reaction KEY of the user on MESSAGE in the current room."
  (let* ((room-id neoment--room-id)
         (user (neoment-user-id))
         (own (seq-find (lambda (entry) (equal (cdr entry) user))
                        (cdr (assoc key (neoment-message-reactions message))))))
    (if own
        (neoment-api-redact room-id (car own) nil
                            (lambda (result)
                              (if (plist-get result :error)
                                  (neoment-notify--error
                                   (concat "Error removing reaction: "
                                           (neoment-http-error-message (plist-get result :error))))
                                (neoment-room-refresh room-id))))
      (neoment-api-send-event
       room-id "m.reaction"
       `((m.relates_to . ((rel_type . "m.annotation")
                          (event_id . ,(neoment-message-effective-id message))
                          (key . ,key))))
       (lambda (result)
         (if (plist-get result :error)
             (neoment-notify--error
              (concat "Error sending reaction: "
                      (neoment-http-error-message (plist-get result :error))))
           (neoment-room-refresh room-id)))))))

(defun neoment-room-react-emoji ()
  "React to the message under the cursor with an emoji."
  (interactive)
  (let ((message (neoment-room-message-at-point)))
    (when message
      (require 'neoment-emoji)
      (let* ((table (neoment-emoji-list))
             (choice (completing-read "Select reaction: " table nil t))
             (emoji (cdr (assoc choice table))))
        (when emoji
          (neoment-room-react message emoji))))))

(defun neoment-room-react-text ()
  "React to the message under the cursor with free text."
  (interactive)
  (let ((message (neoment-room-message-at-point)))
    (when message
      (let ((text (read-string "Enter reaction: ")))
        (unless (string-empty-p text)
          (neoment-room-react message text))))))

(defun neoment-room-redact ()
  "Redact the message under the cursor."
  (interactive)
  (let ((message (neoment-room-message-at-point))
        (room-id neoment--room-id))
    (when message
      (let ((reason (read-string "Redact message reason: ")))
        (neoment-api-redact room-id (neoment-message-effective-id message) reason
                            (lambda (result)
                              (if (plist-get result :error)
                                  (neoment-notify--error
                                   (concat "Error redacting message: "
                                           (neoment-http-error-message
                                            (plist-get result :error))))
                                (neoment-room-refresh room-id))))))))

(defun neoment-room-set-read-marker ()
  "Move the read marker to the message under the cursor."
  (interactive)
  (let ((message (neoment-room-message-at-point))
        (room-id neoment--room-id))
    (when message
      (let ((id (neoment-message-effective-id message)))
        (neoment-api-set-read-markers room-id (list :read id :fully-read id))
        (let ((neoment-room--skip-mark-read t))
          (neoment-room-render-buffer))))))

(declare-function neoment-compose-send "neoment-compose")

(defun neoment-room-forward ()
  "Forward the message under the cursor to another room."
  (interactive)
  (let ((message (neoment-room-message-at-point)))
    (when message
      (require 'neoment-compose)
      (neoment-rooms-pick
       (mapcar #'neoment-room-id (neoment-rooms--member-rooms))
       "Forward to room: "
       (lambda (target)
         (let* ((attachment (neoment-message-attachment message))
                (mxc (plist-get attachment :mxc-url)))
           (neoment-compose-send
            target (neoment-room--body-text message)
            :attachment (and (neoment-events-mxc-p mxc)
                             (list :filename (plist-get attachment :filename)
                                   :url mxc
                                   :mimetype (plist-get attachment :mimetype)
                                   :size (plist-get attachment :size))))
           (neoment-notify--message
            (format "Message forwarded to %s" (neoment-room-display-name target)))
           (neoment-room-open target)))))))

(defun neoment-room-show-event ()
  "Show the raw event of the message under the cursor."
  (interactive)
  (let ((message (neoment-room-message-at-point)))
    (when message
      (let* ((room (neoment-get-room neoment--room-id))
             (id (neoment-message-effective-id message))
             (event (or (gethash id (neoment-room-events room))
                        (gethash (neoment-message-id message) (neoment-room-events room)))))
        (if (not event)
            (neoment-notify--message "Event not found for this message")
          (let ((buffer (get-buffer-create (format "*Event: %s*" id))))
            (with-current-buffer buffer
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert (neoment-json-encode event))
                (json-pretty-print-buffer)
                (goto-char (point-min)))
              (if (fboundp 'js-json-mode) (js-json-mode) (js-mode))
              (setq header-line-format (format "Event: %s" id))
              (view-mode 1)
              (local-set-key (kbd "q") #'quit-window))
            (pop-to-buffer buffer '((display-buffer-at-bottom)))))))))

;;;; Go to replied message

(defun neoment-room--goto-message (id)
  "Move point to the message ID (or original id ID).  Return non-nil if found."
  (let ((pos (text-property-any (point-min) (point-max) 'neoment-message id)))
    (unless pos
      (let ((room (neoment-get-room neoment--room-id)))
        (maphash (lambda (key m)
                   (when (and (not pos) (equal (neoment-message-id m) id))
                     (setq pos (text-property-any (point-min) (point-max)
                                                  'neoment-message key))))
                 (neoment-room-messages room))))
    (when pos
      (push-mark)
      (goto-char pos)
      (neoment-notify--message "Found replied message")
      t)))

(defun neoment-room--load-and-find (buffer id)
  "Load history in BUFFER until the message ID is found, asking each time."
  (with-current-buffer buffer
    (let ((room-id neoment--room-id))
      (if (eq (neoment-room-prev-batch (neoment-get-room room-id)) 'end)
          (neoment-notify--message "The replied message was not found in the room history" 'warn)
        (neoment-room-load-history
         room-id
         (lambda (result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (if (plist-get result :error)
                   (neoment-notify--error
                    (concat "Error loading more messages: "
                            (neoment-http-error-message (plist-get result :error))))
                 (neoment-room-render-buffer)
                 (unless (neoment-room--goto-message id)
                   (if (eq (neoment-room-prev-batch (neoment-get-room room-id)) 'end)
                       (neoment-notify--message
                        "The replied message was not found in the room history" 'warn)
                     (when (y-or-n-p (concat "The replied message was not found." " Load more messages? "))
                       (neoment-room--load-and-find buffer id)))))))))))))

(defun neoment-room-goto-replied ()
  "Jump to the message replied to by the message under the cursor."
  (interactive)
  (let ((message (neoment-room-message-at-point)))
    (when message
      (let ((replied (neoment-message-replying-to message)))
        (cond
         ((null replied)
          (neoment-notify--error "This message is not replying to another message"))
         ((neoment-room--goto-message (neoment-message-id replied)))
         ((y-or-n-p (concat "The replied message is older than the loaded messages." " Load more messages? "))
          (neoment-room--load-and-find (current-buffer) (neoment-message-id replied))))))))

;;;; Membership

(defun neoment-room-leave ()
  "Leave the current room."
  (interactive)
  (let* ((room-id neoment--room-id)
         (buffer (current-buffer))
         (name (neoment-room-display-name room-id)))
    (when (y-or-n-p (format "Are you sure you want to leave the room %s? " name))
      (neoment-api-leave
       room-id
       (lambda (result)
         (let ((err (plist-get result :error)))
           (cond
            ((null err)
             (neoment-notify--message (concat "Left room " name))
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (neoment-rooms-refresh))
            ((string-search "Not a known room" (neoment-http-error-message err))
             (neoment-remove-room room-id)
             (neoment-notify--message (format "Removed room %s from list" name))
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (neoment-rooms-refresh))
            (t (neoment-notify--error
                (concat "Error leaving room: " (neoment-http-error-message err)))))))))))

(defun neoment--existing-dm (user-id)
  "Return the id of a room with exactly the user and USER-ID, or nil."
  (let ((me (neoment-user-id)))
    (seq-some (lambda (room)
                (let ((members (neoment-room-members-list room)))
                  (and (= (length members) 2)
                       (member me members) (member user-id members)
                       (neoment-room-id room))))
              (neoment-rooms))))

;;;###autoload
(defun neoment-join (target)
  "Join TARGET: a room id, an alias, or a user id (direct message)."
  (interactive (list (read-string "Room id, alias or user: ")))
  (cond
   ((not (neoment-logged-in-p))
    (neoment-notify--error "Not logged in"))
   ((string-prefix-p "@" target)
    (let ((existing (neoment--existing-dm target)))
      (if existing
          (progn (neoment-notify--message (concat "Opening existing DM with " target))
                 (neoment-rooms-open-room existing))
        (neoment-notify--message (format "Creating DM with %s..." target))
        (neoment-api-create-dm
         target
         (lambda (result)
           (if (plist-get result :error)
               (neoment-notify--error
                (concat "Failed to create DM: "
                        (neoment-http-error-message (plist-get result :error))))
             (neoment-notify--message (concat "Created DM with " target))
             (neoment-rooms-open-room (plist-get result :ok))))))))
   (t
    (let ((existing (if (string-prefix-p "!" target)
                        (and (neoment-room-is-member-p target) target)
                      (seq-some (lambda (room)
                                  (and (member target (neoment-room-aliases room))
                                       (neoment-room-is-member-p (neoment-room-id room))
                                       (neoment-room-id room)))
                                (neoment-rooms)))))
      (if existing
          (progn (neoment-notify--message (format "Room %s already joined. Opening..." target))
                 (neoment-rooms-open-room existing))
        (neoment-api-join
         target nil
         (lambda (result)
           (if (plist-get result :error)
               (neoment-notify--error
                (format "Failed to join room %s: %s" target
                        (neoment-http-error-message (plist-get result :error))))
             (neoment-notify--message (concat "Successfully joined room " target))
             (neoment-rooms-open-room (plist-get result :ok))))))))))

;;;; Other windows

(declare-function neoment-room-info-open "neoment-room-info")
(declare-function neoment-notification-settings-room "neoment-notification-settings")

(defun neoment-room-show-info ()
  "Show information about the current room in a window to the right."
  (interactive)
  (let ((room-id neoment--room-id))
    (require 'neoment-room-info)
    (neoment-room-info-open room-id t)))

(defun neoment-room-notification-settings ()
  "Open the notification settings of the current room."
  (interactive)
  (require 'neoment-notification-settings)
  (neoment-notification-settings-room neoment--room-id))

(provide 'neoment-room)
;;; neoment-room.el ends here
