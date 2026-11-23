;;; neoment-room-info.el --- Room information buffer  -*- lexical-binding: t; -*-

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

;; A buffer with information about a room: type, topic, space, status
;; toggles, links, members and avatar.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'neoment-config)
(require 'neoment-faces)
(require 'neoment-client)
(require 'neoment-events)
(require 'neoment-notify)
(require 'neoment-rooms)
(require 'neoment-media)

(defvar-local neoment-room-info--members-expanded nil
  "Non-nil when the member list is expanded.")

(defvar-local neoment-room-info--avatar-zoomed nil
  "Non-nil when the avatar is shown at window size.")

(defvar-local neoment-room-info--avatar-shown nil
  "Non-nil when the avatar image is displayed.")

;;;; Rendering

(defun neoment-room-info--room (room-id)
  "Return the joined or invited room ROOM-ID."
  (or (neoment-has-room room-id) (neoment-has-invited-room room-id)))

(defun neoment-room-info--title (name width)
  "Return NAME centred in a rule WIDTH columns wide."
  (let* ((n (max 0 (- width (string-width name) 2)))
         (deco 'neoment-header-decoration))
    (concat (propertize (concat (make-string (floor n 2) ?─) " ") 'face deco)
            (propertize name 'face 'neoment-rooms-title)
            (propertize (concat " " (make-string (- n (floor n 2)) ?─)) 'face deco))))

(defun neoment-room-info--status (active icon label key)
  "Return a status line for LABEL with ICON, toggled by KEY, ACTIVE or not."
  (let ((hint (propertize (format "  [%s] toggle" key) 'face 'neoment-comment)))
    (concat (if active
                (neoment-faces-bubble (format " %s %s " icon label) t)
              (propertize (format "  %s %s " icon label) 'face 'neoment-comment))
            hint)))

(defun neoment-room-info--members (room)
  "Return (ID . NAME-OR-NIL) for the members of ROOM, sorted by name."
  (let ((members (mapcar (lambda (id)
                           (cons id (and (neoment-has-display-name id)
                                         (neoment-display-name id))))
                         (if (neoment-room-p room) (neoment-room-members-list room) nil))))
    (sort members (lambda (a b)
                    (string< (downcase (or (cdr a) (car a)))
                             (downcase (or (cdr b) (car b))))))))

(cl-defun neoment-room-info-render (room-id &key (width 50) expanded)
  "Return the room information text of ROOM-ID.
WIDTH is the window width.  EXPANDED shows the member list."
  (let* ((room (neoment-room-info--room room-id))
         (invited (neoment-invited-room-p room))
         (topic (if invited (neoment-invited-room-topic room) (neoment-room-topic room)))
         (avatar (if invited (neoment-invited-room-avatar-url room) (neoment-room-avatar-url room)))
         (space (and (not invited) (neoment-room-space-name room-id)))
         (aliases (and (not invited) (neoment-room-aliases room)))
         (members (neoment-room-info--members room))
         (lines nil))
    (cl-flet ((add (&rest strings) (dolist (s strings) (push s lines))))
      (add (neoment-room-info--title (neoment-room-display-name room-id) width))
      (add (propertize (if (neoment-events-mxc-p avatar)
                           "Room avatar [o] open with attachment handler"
                         "No image")
                       'face 'neoment-comment 'neoment-avatar t))
      (add (concat "Room Type: "
                   (cond ((and (not invited) (neoment-room-space-rooms room)) "Space")
                         ((and (not invited) (neoment-room-is-direct room)) "Direct Message")
                         (t "Room")))
           "")
      (when (and topic (not (string-empty-p topic)))
        (add "Topic:")
        (dolist (line (split-string topic "\n"))
          (when (string-match-p "[^[:space:]]" line) (add line)))
        (add ""))
      (when space
        (add (concat "Space: " space) ""))
      (add "Status:"
           (neoment-room-info--status (and (not invited) (neoment-room-is-favorite room))
                                      (neoment-icon 'favorite) "Favorite" "a")
           (neoment-room-info--status (and (not invited) (neoment-room-is-lowpriority room))
                                      (neoment-icon 'low_priority) "Low Priority" "l"))
      (unless invited
        (add (neoment-room-info--status (neoment-room-is-direct room)
                                        (neoment-icon 'people) "Direct Message" "d")))
      (add ""
           (propertize "── Links ──" 'face 'neoment-section-title)
           (concat "Room ID: " room-id))
      (when aliases
        (add "Aliases:")
        (dolist (alias aliases) (add (concat "  - " alias))))
      (add "")
      (if (not expanded)
          (add (propertize (format "── Members (%d) ── [Tab to expand]" (length members))
                           'face 'neoment-section-title))
        (add (propertize (format "── Members (%d) ──" (length members))
                         'face 'neoment-section-title))
        (dolist (member members)
          (add (if (cdr member)
                   (concat "  - " (cdr member) " "
                           (propertize (format "(%s)" (car member)) 'face 'neoment-comment))
                 (concat "  - " (car member)))))))
    (string-join (nreverse lines) "\n")))

;;;; Buffer

(defvar-keymap neoment-room-info-mode-map
  :doc "Keymap of `neoment-room-info-mode'."
  :parent special-mode-map
  "TAB" #'neoment-room-info-toggle-members
  "<tab>" #'neoment-room-info-toggle-members
  "a" #'neoment-room-info-toggle-favorite
  "l" #'neoment-room-info-toggle-low-priority
  "d" #'neoment-room-info-toggle-direct
  "o" #'neoment-room-info-open-avatar
  "z" #'neoment-room-info-toggle-avatar-zoom
  "q" #'neoment-room-info-quit
  "g" #'revert-buffer
  "f" #'neoment-pick-room
  "F" #'neoment-pick-open-room
  "?" #'describe-mode)

(define-derived-mode neoment-room-info-mode special-mode "Neoment Info"
  "Major mode for Neoment room information buffers.

\\{neoment-room-info-mode-map}"
  (setq-local buffer-undo-list t
              revert-buffer-function (lambda (&rest _) (neoment-room-info-render-buffer)))
  (visual-line-mode 1))

(defun neoment-room-info--show-avatar (file)
  "Display the avatar FILE under the title of the current buffer."
  (let* ((window (get-buffer-window (current-buffer)))
         (image (and window
                     (ignore-errors
                       (create-image file nil nil
                                     :max-width (if neoment-room-info--avatar-zoomed
                                                    (window-body-width window t)
                                                  (* 16 (frame-char-width)))
                                     :max-height (if neoment-room-info--avatar-zoomed
                                                     (window-body-height window t)
                                                   (* 8 (frame-char-height))))))))
    (when image
      (let ((pos (text-property-any (point-min) (point-max) 'neoment-avatar t))
            (inhibit-read-only t))
        (when pos
          (save-excursion
            (goto-char pos)
            (insert (propertize " " 'display image) "\n"))
          (setq neoment-room-info--avatar-shown t))))))

(defun neoment-room-info-render-buffer ()
  "Re-render the current room information buffer."
  (let* ((window (get-buffer-window (current-buffer)))
         (line (line-number-at-pos))
         (inhibit-read-only t)
         (neoment--bubble-edges (neoment-faces-bubble-edges)))
    (when (neoment-room-info--room neoment--room-id)
      (erase-buffer)
      (insert (neoment-room-info-render neoment--room-id
                                        :width (if window (window-width window) 50)
                                        :expanded neoment-room-info--members-expanded))
      (goto-char (point-min))
      (forward-line (1- line))
      (setq neoment-room-info--avatar-shown nil)
      (let ((avatar (let ((room (neoment-room-info--room neoment--room-id)))
                      (if (neoment-invited-room-p room)
                          (neoment-invited-room-avatar-url room)
                        (neoment-room-avatar-url room))))
            (buffer (current-buffer)))
        (when (and window (display-graphic-p (window-frame window))
                   (neoment-events-mxc-p avatar))
          (neoment-media-image-file
           avatar (lambda (result)
                    (when (and (plist-get result :ok) (buffer-live-p buffer))
                      (with-current-buffer buffer
                        (neoment-room-info--show-avatar (plist-get result :ok)))))))))))

(defun neoment-room-info-buffer-name (room-id)
  "Return the room information buffer name of ROOM-ID."
  (format "neoment://room/info/%s/%s" room-id (neoment-room-display-name-with-space room-id)))

(defun neoment-room-info-open (room-id &optional beside)
  "Show information about ROOM-ID.
With BESIDE, use a 50-column window to the right."
  (let ((buffer (seq-find (lambda (b)
                            (and (eq (buffer-local-value 'major-mode b) 'neoment-room-info-mode)
                                 (equal (buffer-local-value 'neoment--room-id b) room-id)))
                          (buffer-list))))
    (unless buffer
      (setq buffer (generate-new-buffer (neoment-room-info-buffer-name room-id)))
      (with-current-buffer buffer
        (neoment-room-info-mode)
        (setq neoment--room-id room-id)))
    (if beside
        (let ((window (or (get-buffer-window buffer)
                          (display-buffer buffer '((display-buffer-in-direction)
                                                   (direction . right)
                                                   (window-width . 50))))))
          (when window (select-window window)))
      (switch-to-buffer buffer))
    (with-current-buffer buffer (neoment-room-info-render-buffer))
    buffer))

;;;; Actions

(defun neoment-room-info-toggle-members ()
  "Expand or collapse the member list."
  (interactive)
  (setq neoment-room-info--members-expanded (not neoment-room-info--members-expanded))
  (neoment-room-info-render-buffer))

(defun neoment-room-info--toggle (tag)
  "Toggle TAG (a tag name or `direct') on the room of the current buffer."
  (let ((room-id neoment--room-id)
        (buffer (current-buffer)))
    (cond
     ((neoment-has-invited-room room-id)
      (neoment-notify--message "Cannot modify status for invited rooms"))
     ((eq tag 'direct)
      (neoment-rooms-toggle-direct-on room-id)
      (neoment-room-info-render-buffer))
     (t (neoment-rooms-toggle-tag
         tag room-id
         (lambda ()
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (neoment-room-info-render-buffer)))))))))

(defun neoment-room-info-toggle-favorite ()
  "Toggle whether the room is a favourite."
  (interactive)
  (neoment-room-info--toggle "m.favourite"))

(defun neoment-room-info-toggle-low-priority ()
  "Toggle whether the room is low priority."
  (interactive)
  (neoment-room-info--toggle "m.lowpriority"))

(defun neoment-room-info-toggle-direct ()
  "Toggle, locally, whether the room is a direct message."
  (interactive)
  (neoment-room-info--toggle 'direct))

(defun neoment-room-info-open-avatar ()
  "Open the room avatar with the attachment handler."
  (interactive)
  (let* ((room (neoment-room-info--room neoment--room-id))
         (avatar (if (neoment-invited-room-p room)
                     (neoment-invited-room-avatar-url room)
                   (neoment-room-avatar-url room))))
    (if (not (neoment-events-mxc-p avatar))
        (neoment-notify--message "No avatar image to open")
      (let ((name (concat (neoment-media-sanitize (neoment-room-display-name neoment--room-id))
                          ".png")))
        (neoment-media-download
         avatar name
         (lambda (result)
           (if (plist-get result :error)
               (neoment-notify--error
                (concat "Error fetching attachment: "
                        (neoment-http-error-message (plist-get result :error))))
             (funcall neoment-on-open-attachment-function (plist-get result :ok)
                      (list :type 'image :mimetype "image/png"
                            :url (neoment-events-mxc-to-url avatar) :mxc-url avatar
                            :filename name :origin 'avatar)))))))))

(defun neoment-room-info-toggle-avatar-zoom ()
  "Toggle the avatar between 16x8 and the window size."
  (interactive)
  (if (not neoment-room-info--avatar-shown)
      (neoment-notify--message "No avatar image to zoom")
    (setq neoment-room-info--avatar-zoomed (not neoment-room-info--avatar-zoomed))
    (neoment-room-info-render-buffer)))

(defun neoment-room-info-quit ()
  "Kill the room information buffer."
  (interactive)
  (kill-buffer (current-buffer)))

(provide 'neoment-room-info)
;;; neoment-room-info.el ends here
