;;; neoment-compose.el --- The compose buffer  -*- lexical-binding: t; -*-

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

;; A temporary buffer, 10 lines high below the room, where messages are
;; written in markdown.  `C-c C-c' sends and `C-c C-k' cancels.  It
;; also builds the outgoing message events: text, replies, threads,
;; edits and attachments.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'neoment-faces)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-notify)
(require 'neoment-markdown)

(defvar-local neoment-compose--thread-root-id nil
  "Thread the message goes to, if any.")

(defvar-local neoment-compose--relation nil
  "Plist (:type reply|replace :message MESSAGE), or nil.")

(defvar-local neoment-compose--attachment nil
  "Attachment plist (:filename :url :mimetype :size), or nil.")

(defvar-local neoment-compose--room-window nil
  "The window of the room the compose buffer belongs to.")

;;;; Message content

(defun neoment-compose-msgtype (mimetype)
  "Return the msgtype of an attachment with MIMETYPE."
  (cond
   ((null mimetype) "m.file")
   ((string-prefix-p "image/" mimetype) "m.image")
   ((string-prefix-p "video/" mimetype) "m.video")
   ((string-prefix-p "audio/" mimetype) "m.audio")
   (t "m.file")))

(defun neoment-compose--html-with-mentions (body)
  "Return (HTML . MENTIONS) for the markdown BODY.
Mentions of users with a known display name become links."
  (let ((mentions nil))
    (cons (neoment-markdown--gsub
           neoment-markdown-mention-regexp (neoment-markdown-to-html body)
           (lambda (g)
             (let* ((user (nth 0 g))
                    (name (and (neoment-has-display-name user)
                               (neoment-display-name user))))
               (if (or (null name) (equal name user))
                   user
                 (cl-pushnew user mentions :test #'equal)
                 (format "<a href=\"https://matrix.to/#/%s\">%s</a>" user name)))))
          (nreverse mentions))))

(cl-defun neoment-compose-message-content (body &key reply-to reply-sender
                                                thread-root-id replace attachment)
  "Return the `m.room.message' content for the markdown BODY.
REPLY-TO is the event id replied to and REPLY-SENDER the user id of its
sender, THREAD-ROOT-ID the thread, REPLACE the event id being edited
and ATTACHMENT a plist.
`m.mentions' lists the body mentions, then REPLY-SENDER unless it is
already listed or is the current user.  With REPLACE, `m.mentions'
goes only in `m.new_content'.  A thread message is marked `is_falling_back' only
when it is not a real reply."
  (let* ((html (neoment-compose--html-with-mentions body))
         (mentions (cdr html))
         (content `((msgtype . "m.text")
                    (body . ,body)
                    (format . "org.matrix.custom.html")
                    (formatted_body . ,(car html)))))
    (when (and reply-sender
               (not (equal reply-sender (neoment-user-id)))
               (not (member reply-sender mentions)))
      (setq mentions (append mentions (list reply-sender))))
    (when mentions
      (setq content (append content `((m.mentions . ((user_ids . ,(vconcat mentions))))))))
    (let ((relates nil))
      (when thread-root-id
        (setq relates `((rel_type . "m.thread") (event_id . ,thread-root-id)
                        ,@(unless reply-to '((is_falling_back . t))))))
      (when reply-to
        (setq relates (append relates `((m.in_reply_to . ((event_id . ,reply-to)))))))
      (when relates
        (setq content (append content `((m.relates_to . ,relates))))))
    (when replace
      (setq content `((msgtype . "m.text")
                      (body . ,(concat "* " body))
                      (m.new_content . ,content)
                      (m.relates_to . ((rel_type . "m.replace") (event_id . ,replace))))))
    (when attachment
      ;; Copy first: the pairs above may be shared backquote constants.
      (setq content (copy-alist content))
      (setf (alist-get 'msgtype content)
            (neoment-compose-msgtype (plist-get attachment :mimetype)))
      (setq content (append content
                            `((filename . ,(plist-get attachment :filename))
                              (url . ,(plist-get attachment :url))
                              (info . ((mimetype . ,(or (plist-get attachment :mimetype) :null))
                                       (size . ,(or (plist-get attachment :size) :null))))))))
    content))

(cl-defun neoment-compose-send (room-id body &key reply-to reply-sender
                                        thread-root-id replace attachment
                                        callback)
  "Send BODY to ROOM-ID, see `neoment-compose-message-content'.
REPLY-TO, REPLY-SENDER, THREAD-ROOT-ID, REPLACE and ATTACHMENT are
passed to it unchanged.
On success the room's fully read marker moves to the new event, so
the user's own message never shows as new.  CALLBACK, if non-nil,
receives the result."
  (neoment-api-send-event
   room-id "m.room.message"
   (neoment-compose-message-content body :reply-to reply-to
                                    :reply-sender reply-sender
                                    :thread-root-id thread-root-id
                                    :replace replace :attachment attachment)
   (lambda (result)
     (if (plist-get result :error)
         (neoment-notify--error
          (concat "Error sending message: "
                  (neoment-http-error-message (plist-get result :error))))
       (let ((room (neoment-has-room room-id)))
         (when (and room (plist-get result :ok))
           (setf (neoment-room-fully-read room) (plist-get result :ok)))))
     (when callback (funcall callback result)))))

;;;; Mention completion

(defun neoment-compose--mention-candidates (prefix)
  "Return the member ids of the room whose id or name matches PREFIX."
  (let ((prefix (downcase (string-remove-prefix "@" prefix)))
        (room (neoment-has-room neoment--room-id)))
    (when room
      (delq nil
            (mapcar (lambda (pair)
                      (when (or (string-search prefix (downcase (car pair)))
                                (string-search prefix (downcase (cdr pair))))
                        (car pair)))
                    (neoment-room-other-members room))))))

(defun neoment-compose-mention-capf ()
  "Complete the user mention before point."
  (when (looking-back "@[^[:space:]@]*" (line-beginning-position))
    (let* ((start (match-beginning 0))
           (end (point))
           (candidates (neoment-compose--mention-candidates
                        (buffer-substring-no-properties start end))))
      (list start end
            (lambda (_string pred action)
              (if (eq action 'metadata)
                  '(metadata (category . neoment-user))
                (complete-with-action action candidates "" pred)))
            :annotation-function
            (lambda (id) (concat " " (neoment-display-name id)))
            :exclusive 'no))))

;;;; Mode

(defconst neoment-compose-font-lock-keywords
  `(("^#\\{1,3\\} .*$" . 'bold)
    ("\\*\\*[^*\n]+\\*\\*" . 'bold)
    ("__[^_\n]+__" . 'bold)
    ("\\(?:^\\|[^*]\\)\\(\\*[^*\n]+\\*\\)" 1 'italic)
    ("`[^`\n]+`" . 'font-lock-constant-face)
    ("^```.*$" . 'font-lock-constant-face)
    ("\\[[^]\n]*\\]([^)\n]*)" . 'link)
    ("^>.*$" . 'font-lock-comment-face)
    (,neoment-markdown-mention-regexp . 'neoment-mention))
  "Markdown highlighting of the compose buffer.")

(defvar-keymap neoment-compose-mode-map
  :doc "Keymap of `neoment-compose-mode'."
  "C-c C-c" #'neoment-compose-send-and-close
  "C-c C-k" #'neoment-compose-cancel)

(define-derived-mode neoment-compose-mode text-mode "Neoment Compose"
  "Major mode for writing a Neoment message.
\\<neoment-compose-mode-map>Send with \\[neoment-compose-send-and-close], \
cancel with \\[neoment-compose-cancel].

\\{neoment-compose-mode-map}"
  (setq-local font-lock-defaults '(neoment-compose-font-lock-keywords)
              window-size-fixed 'height)
  (when (fboundp 'display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (visual-line-mode 1)
  (hl-line-mode 1)
  (add-hook 'completion-at-point-functions #'neoment-compose-mention-capf nil t))

(defun neoment-compose-buffer-name (room-id &optional thread-root-id relation attachment)
  "Return the compose buffer name for ROOM-ID.
THREAD-ROOT-ID, RELATION and ATTACHMENT are as in `neoment-compose-open'."
  (let* ((room (neoment-room-display-name room-id))
         (name (pcase (plist-get relation :type)
                 ('reply (concat "Replying to "
                                 (neoment-display-name
                                  (neoment-message-sender (plist-get relation :message)))))
                 ('replace (concat "Editing message on " room))
                 (_ (if thread-root-id
                        (concat "Sending to thread in " room)
                      (concat "Sending to " room))))))
    (concat "*neoment-compose: " name
            (if attachment
                (concat " with the attachment " (plist-get attachment :filename))
              "")
            "*")))

(cl-defun neoment-compose-open (room-id &key thread-root-id relation attachment)
  "Open a compose buffer for ROOM-ID below the selected window.
THREAD-ROOT-ID sends to a thread.  RELATION is a plist (:type reply or
replace, :message MESSAGE).  ATTACHMENT is an uploaded file plist."
  (let* ((room-window (selected-window))
         (buffer (generate-new-buffer
                  (neoment-compose-buffer-name room-id thread-root-id relation attachment)))
         (editing (eq (plist-get relation :type) 'replace)))
    (with-current-buffer buffer
      (neoment-compose-mode)
      (setq neoment--room-id room-id
            neoment-compose--thread-root-id thread-root-id
            neoment-compose--relation relation
            neoment-compose--attachment attachment
            neoment-compose--room-window room-window)
      (when editing
        (insert (string-join (split-string (or (neoment-message-content
                                                (plist-get relation :message))
                                               "")
                                           "\n" t)
                             "\n"))))
    (let ((window (display-buffer buffer '((display-buffer-below-selected)
                                           (window-height . 10)))))
      (when window
        (select-window window)
        (goto-char (point-max))))
    buffer))

(defun neoment-compose--close ()
  "Close the current compose buffer and return to its room."
  (let ((buffer (current-buffer))
        (room-window neoment-compose--room-window)
        (window (get-buffer-window (current-buffer))))
    (when (and window (window-live-p window) (not (one-window-p t window)))
      (delete-window window))
    (kill-buffer buffer)
    (when (window-live-p room-window)
      (select-window room-window))))

(defun neoment-compose-cancel ()
  "Discard the message and close the compose buffer."
  (interactive)
  (neoment-compose--close))

(defun neoment-compose-send-and-close ()
  "Send the message and close the compose buffer.
Nothing happens when the message is empty and there is no attachment."
  (interactive)
  (let ((body (string-join (split-string (buffer-string) "\n") "\n"))
        (attachment neoment-compose--attachment))
    (unless (and (null attachment) (string-blank-p body))
      (let* ((relation neoment-compose--relation)
             (message (plist-get relation :message))
             (replied (and message (neoment-message-replying-to message))))
        (neoment-compose-send
         neoment--room-id body
         :reply-to (and (eq (plist-get relation :type) 'reply)
                        (neoment-message-effective-id message))
         ;; An edit of a reply keeps mentioning the replied-to sender
         ;; in `m.new_content'.
         :reply-sender (pcase (plist-get relation :type)
                         ('reply (neoment-message-sender message))
                         ('replace (and replied
                                        (not (neoment-message-placeholder replied))
                                        (neoment-message-sender replied))))
         :replace (and (eq (plist-get relation :type) 'replace)
                       (neoment-message-effective-id message))
         :thread-root-id neoment-compose--thread-root-id
         :attachment attachment))
      (neoment-compose--close))))

(provide 'neoment-compose)
;;; neoment-compose.el ends here
