;;; neoment-space.el --- Space buffers  -*- lexical-binding: t; -*-

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

;; A buffer showing the hierarchy of a space (from /hierarchy), from
;; which rooms can be joined and opened.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'neoment-config)
(require 'neoment-faces)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-notify)
(require 'neoment-rooms)

(defvar-local neoment-space--id nil
  "Id of the space shown in the current buffer.")

(defvar-local neoment-space--hierarchy nil
  "The rooms of the last fetched hierarchy.")

;;;; Rendering

(defun neoment-space--room-line (room level)
  "Return the line of the hierarchy ROOM at indentation LEVEL."
  (let* ((id (alist-get 'room_id room))
         (is-space (equal (alist-get 'room_type room) "m.space"))
         (icon (neoment-icon (if is-space 'space 'room)))
         (name (let ((n (alist-get 'name room)))
                 (cond ((and (stringp n) (not (string-empty-p n))) n)
                       ((neoment-has-room id) (neoment-room-display-name id))
                       (t "(No Name)"))))
         (topic (alist-get 'topic room))
         (head (concat (make-string (* 2 level) ?\s) icon "  "))
         (title (format "%s (%d members)" name (or (alist-get 'num_joined_members room) 0)))
         (joined (and (neoment-room-is-member-p id)
                      (concat (neoment-faces-bubble "Joined") " "))))
    (when is-space
      (setq head (propertize head 'face 'neoment-section-title)
            title (propertize title 'face 'neoment-section-title)))
    (concat head (or joined "") title
            (if (and (stringp topic) (not (string-empty-p topic)))
                (propertize (concat " - " (replace-regexp-in-string "\n\\(?:.\\|\n\\)*" "..." topic))
                            'face 'neoment-comment)
              ""))))

(defun neoment-space--tree (space-id rooms)
  "Return the tree lines of SPACE-ID from the hierarchy ROOMS.
Each line carries the `neoment-space-item' property."
  (let ((seen (make-hash-table :test 'equal))
        (lines nil))
    (cl-labels
        ((find (id) (seq-find (lambda (r) (equal (alist-get 'room_id r) id)) rooms))
         (add (room level via)
           (let ((id (alist-get 'room_id room)))
             (unless (gethash id seen)
               (puthash id t seen)
               (push (propertize (neoment-space--room-line room level)
                                 'neoment-space-item
                                 (list :room-id id :via via
                                       :is-space (equal (alist-get 'room_type room) "m.space")))
                     lines)
               (dolist (child (alist-get 'children_state room))
                 (let ((child-room (find (alist-get 'state_key child))))
                   (when child-room
                     (add child-room (1+ level)
                          (neoment-json-get child 'content 'via)))))))))
      (let ((root (or (find space-id) (car rooms))))
        (when root (add root 0 nil))))
    (nreverse lines)))

(defun neoment-space-render (space-id rooms)
  "Return the text of the space buffer of SPACE-ID with hierarchy ROOMS."
  (let* ((space (neoment-has-room space-id))
         (topic (and space (neoment-room-topic space)))
         (topic-lines (and topic (seq-filter (lambda (l) (string-match-p "[^[:space:]]" l))
                                             (split-string topic "\n"))))
         (tree (neoment-space--tree space-id rooms)))
    (concat
     (propertize (neoment-room-display-name space-id) 'face 'neoment-rooms-title) "\n"
     "\n"
     (propertize "Topic:" 'face 'bold) "\n"
     (if topic-lines (mapconcat #'identity topic-lines "\n") "No topic") "\n"
     "\n"
     (propertize "Rooms:" 'face 'bold) "\n"
     (if (cdr tree)
         (mapconcat #'identity tree "\n")
       (concat (or (car tree) "") (if tree "\n" "") "  No rooms in this space")))))

;;;; Buffer

(defvar-keymap neoment-space-mode-map
  :doc "Keymap of `neoment-space-mode'."
  :parent special-mode-map
  "RET" #'neoment-space-enter
  "q" #'neoment-space-quit
  "g" #'revert-buffer
  "f" #'neoment-pick-room
  "F" #'neoment-pick-open-room
  "l" #'neoment-toggle-rooms-list
  "?" #'describe-mode)

(define-derived-mode neoment-space-mode special-mode "Neoment Space"
  "Major mode for Neoment space buffers.

\\{neoment-space-mode-map}"
  (setq-local buffer-undo-list t
              revert-buffer-function (lambda (&rest _) (neoment-space-reload)))
  (hl-line-mode 1))

(defun neoment-space--insert (text)
  "Replace the buffer text with TEXT, keeping the line of point."
  (let ((line (line-number-at-pos))
        (inhibit-read-only t)
        (neoment--bubble-edges (neoment-faces-bubble-edges)))
    (erase-buffer)
    (insert text)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun neoment-space-reload ()
  "Fetch the hierarchy of the current space again and render it."
  (interactive)
  (let ((buffer (current-buffer))
        (space-id neoment-space--id))
    (neoment-api-request
     'get (format "/_matrix/client/v1/rooms/%s/hierarchy" (neoment-api-encode space-id))
     :callback
     (lambda (result)
       (if (plist-get result :error)
           (neoment-notify--error
            (concat "Failed to fetch space hierarchy: "
                    (neoment-http-error-message (plist-get result :error))))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq neoment-space--hierarchy (alist-get 'rooms (plist-get result :ok)))
             (let ((neoment--bubble-edges (neoment-faces-bubble-edges)))
               (neoment-space--insert
                (neoment-space-render space-id neoment-space--hierarchy))))))))))

(defun neoment-space-buffer-name (space-id)
  "Return the buffer name of SPACE-ID."
  (format "*neoment-space: %s*" (neoment-room-display-name space-id)))

(defun neoment-space-open (space-id)
  "Show the hierarchy of SPACE-ID."
  (let ((buffer (seq-find (lambda (b)
                            (and (eq (buffer-local-value 'major-mode b) 'neoment-space-mode)
                                 (equal (buffer-local-value 'neoment-space--id b) space-id)))
                          (buffer-list))))
    (unless buffer
      (setq buffer (generate-new-buffer (neoment-space-buffer-name space-id)))
      (with-current-buffer buffer
        (neoment-space-mode)
        (setq neoment-space--id space-id)
        (let ((inhibit-read-only t)) (insert "Loading space..."))))
    (switch-to-buffer buffer)
    (neoment-space-reload)
    buffer))

(defun neoment-space-enter ()
  "Open, or offer to join, the room or space on the current line."
  (interactive)
  (let ((item (get-text-property (line-beginning-position) 'neoment-space-item)))
    (if (null item)
        (neoment-notify--error "No room or space under the cursor")
      (let ((id (plist-get item :room-id)))
        (cond
         ((not (neoment-room-is-member-p id))
          (when (eq (car (read-multiple-choice "Do you want to join this room?"
                                               '((?j "Join") (?c "Cancel"))))
                    ?j)
            (neoment-api-join
             id (plist-get item :via)
             (lambda (result)
               (if (plist-get result :error)
                   (neoment-notify--error
                    (concat "Error joining room: "
                            (neoment-http-error-message (plist-get result :error))))
                 (neoment-rooms-open-room (or (plist-get result :ok) id)))))))
         ((or (plist-get item :is-space) (neoment-room-is-space id))
          (neoment-space-open id))
         (t (neoment-rooms-open-room id)))))))

(defun neoment-space-quit ()
  "Kill the space buffer."
  (interactive)
  (kill-buffer (current-buffer)))

(provide 'neoment-space)
;;; neoment-space.el ends here
