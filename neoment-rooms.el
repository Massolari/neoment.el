;;; neoment-rooms.el --- The room list  -*- lexical-binding: t; -*-

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

;; The room list: a side window that lists every room in sections, with
;; icons, relative times, unread badges and previews of the last
;; message, plus the actions on the room under point and the room
;; pickers.
;;
;; The buffer text is produced by `neoment-rooms-render', a pure
;; function of the model.  Every room line carries the `neoment-room'
;; property, section headers `neoment-section' and space lines
;; `neoment-space'.  Preview lines carry `neoment-preview' and no room.

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
(require 'neoment-storage)
(require 'neoment-sync)

(declare-function neoment-room-open "neoment-room")
(declare-function neoment-room-refresh "neoment-room")
(declare-function neoment-space-open "neoment-space")
(declare-function neoment-room-info-open "neoment-room-info")
(declare-function neoment-notification-settings "neoment-notification-settings")
(declare-function neoment-notification-settings-room "neoment-notification-settings")

(defconst neoment-rooms-buffer-name " *neoment-rooms*"
  "Name of the room list buffer.
The leading space hides it from `switch-to-buffer' and buffer lists.")

(defconst neoment-rooms-sections
  '((invited . "Invited") (buffers . "Buffers") (favorites . "Favorites")
    (people . "People") (spaces . "Spaces") (rooms . "Rooms")
    (low_priority . "Low priority"))
  "Room list sections, in display order.")

(defconst neoment-rooms-section-icons
  '((invited . invite) (buffers . buffer) (favorites . favorite)
    (people . people) (spaces . space) (rooms . room)
    (low_priority . low_priority))
  "Icon key of each section.")

;;;; Rendering helpers

(defun neoment-rooms--relative-time (timestamp now)
  "Return the time of TIMESTAMP relative to NOW (both in ms)."
  (let* ((minutes (/ (- now timestamp) 60000.0))
         (hours (/ minutes 60))
         (days (/ hours 24)))
    (cond
     ((>= days 7) (format-time-string "%d/%m" (/ timestamp 1000)))
     ((>= days 1) (format "%dd" (floor days)))
     ((>= hours 1) (format "%dh" (floor hours)))
     ((>= minutes 1) (format "%dm" (floor minutes)))
     (t "now"))))

(defun neoment-rooms--has-counts (room)
  "Return non-nil when ROOM has unread notifications or highlights."
  (or (> (or (neoment-room-unread-highlights room) 0) 0)
      (> (or (neoment-room-unread-notifications room) 0) 0)))

(defun neoment-rooms--badge (room)
  "Return (ICON . FACE) for the unread badge of ROOM, or nil."
  (when (plist-get (neoment-room-last-activity room) :timestamp)
    (cond
     ((> (or (neoment-room-unread-highlights room) 0) 0)
      (cons (neoment-icon 'bell) 'neoment-notification-bell))
     ((> (or (neoment-room-unread-notifications room) 0) 0)
      (cons (neoment-icon 'dot_circle) 'neoment-notification-circle))
     ((neoment-room-unread-p room)
      (cons (neoment-icon 'dot) 'neoment-notification-dot)))))

(defun neoment-rooms--room-icon (room)
  "Return the icon of ROOM."
  (cond
   ((neoment-invited-room-p room) (neoment-icon 'room))
   ((neoment-room-space-rooms room) (neoment-icon 'space))
   ((neoment-room-is-direct room) (neoment-icon 'people))
   (t (neoment-icon 'room))))

(defun neoment-rooms--id (room)
  "Return the id of the joined or invited ROOM."
  (if (neoment-invited-room-p room)
      (neoment-invited-room-id room)
    (neoment-room-id room)))

(defun neoment-rooms--attention-rank (room)
  "Return how much ROOM needs attention, lower first.
0 when ROOM has unread highlights or notifications, 1 when it is
otherwise unread, 2 when it is read."
  (cond
   ((neoment-rooms--has-counts room) 0)
   ((neoment-room-unread-p room) 1)
   (t 2)))

(defun neoment-rooms--activity< (a b)
  "Return non-nil when room A sorts before room B by activity.
Rooms with unread highlights or notifications come first, then
other unread rooms, then read rooms.  Within each group the most
recent activity comes first."
  (let ((ra (neoment-rooms--attention-rank a))
        (rb (neoment-rooms--attention-rank b)))
    (if (/= ra rb)
        (< ra rb)
      (> (or (plist-get (neoment-room-last-activity a) :timestamp) 0)
         (or (plist-get (neoment-room-last-activity b) :timestamp) 0)))))

(defun neoment-rooms--name< (a b)
  "Return non-nil when room A sorts before room B by name."
  (let ((na (downcase (neoment-room-display-name (neoment-room-id a))))
        (nb (downcase (neoment-room-display-name (neoment-room-id b)))))
    (if (string= na nb)
        (string< (neoment-room-id a) (neoment-room-id b))
      (string< na nb))))

(defun neoment-rooms--member-rooms ()
  "Return the joined rooms the user is a member of."
  (seq-filter (lambda (r) (neoment-room-is-member-p (neoment-room-id r)))
              (neoment-rooms)))

(defun neoment-rooms--classify (open-ids)
  "Return an alist SECTION -> rooms, with OPEN-IDS open in buffers."
  (let ((result (mapcar (lambda (s) (list (car s))) neoment-rooms-sections)))
    (cl-flet ((add (section room)
                (push room (cdr (assq section result)))))
      (dolist (room (neoment-invited-rooms))
        (add 'invited room))
      (dolist (room (neoment-rooms--member-rooms))
        (let ((id (neoment-room-id room)))
          (cond
           ((member id open-ids) (add 'buffers room))
           ((neoment-room-is-favorite room) (add 'favorites room))
           ((neoment-room-is-direct room) (add 'people room))
           ((neoment-room-is-lowpriority room) (add 'low_priority room))
           ((neoment-room-space-rooms room)
            (unless (neoment-room-space id) (add 'spaces room)))
           (t (add 'rooms room))))))
    (mapcar (lambda (pair)
              (cons (car pair)
                    (pcase (car pair)
                      ('invited (sort (cdr pair)
                                      (lambda (a b)
                                        (string< (neoment-invited-room-id a)
                                                 (neoment-invited-room-id b)))))
                      ('spaces (sort (cdr pair) #'neoment-rooms--name<))
                      (_ (sort (cdr pair) #'neoment-rooms--activity<)))))
            result)))

;;;; Fold state

(defvar neoment-rooms--fold-sections nil
  "Alist of section key (string) to non-nil when folded.")

(defvar neoment-rooms--fold-spaces nil
  "Alist of space id to non-nil when folded.")

(defvar neoment-rooms--fold-loaded nil
  "Non-nil once the fold state was read from disk.")

(defun neoment-rooms--load-fold-state ()
  "Read the fold state from disk once."
  (unless neoment-rooms--fold-loaded
    (let ((state (neoment-storage-load-ui-state)))
      (setq neoment-rooms--fold-sections (plist-get state :sections)
            neoment-rooms--fold-spaces (plist-get state :spaces)
            neoment-rooms--fold-loaded t))))

(defun neoment-rooms--section-folded-p (section)
  "Return non-nil when SECTION is folded."
  (neoment-rooms--load-fold-state)
  (cdr (assoc (symbol-name section) neoment-rooms--fold-sections)))

(defun neoment-rooms--space-folded-p (space-id)
  "Return non-nil when the space SPACE-ID is folded (the default)."
  (neoment-rooms--load-fold-state)
  (let ((entry (assoc space-id neoment-rooms--fold-spaces)))
    (if entry (cdr entry) t)))

(defun neoment-rooms--save-fold-state ()
  "Write the fold state to disk."
  (neoment-storage-save-ui-state neoment-rooms--fold-sections
                                 neoment-rooms--fold-spaces))

;;;; Rendering

(defun neoment-rooms--sync-status (now)
  "Return (ICON TEXT FACE) for the sync status at NOW (seconds)."
  (let* ((status (neoment-sync-status))
         (last (plist-get status :last-sync)))
    (cond
     ((null last)
      (list "◇" (if (eq (plist-get status :kind) 'syncing) "connecting" "offline")
            'neoment-comment))
     ((< (- now last) 60) (list "●" "synced" 'neoment-sync-ok))
     ((< (- now last) 3600)
      (list "●" (format "%dm ago" (floor (- now last) 60)) 'neoment-sync-ok))
     (t (list "○" (format-time-string "%H:%M" last) 'neoment-comment)))))

(defun neoment-rooms--title-line (width)
  "Return the title line for a window WIDTH columns wide."
  (let* ((n (max 0 (- width (string-width "Neoment") 2)))
         (deco 'neoment-header-decoration))
    (concat (propertize (make-string (floor n 2) ?─) 'face deco)
            (propertize " " 'face deco)
            (propertize "Neoment" 'face 'neoment-rooms-title)
            (propertize " " 'face deco)
            (propertize (make-string (- n (floor n 2)) ?─) 'face deco))))

(defun neoment-rooms--user-line (now)
  "Return the user and sync status line at NOW (seconds)."
  (let* ((user (neoment-user-id))
         (name (if user (neoment-display-name user) "Unknown"))
         (presence (or (plist-get (neoment-get-presence user) :presence) "offline"))
         (icon (pcase presence ("online" "●") ("unavailable" "◐") (_ "○")))
         (sync (neoment-rooms--sync-status now)))
    (concat (neoment-faces-bubble
             (format " %s %s %s %s " name (neoment-icon 'vertical_bar) icon presence))
            (propertize (format "  %s " (nth 0 sync)) 'face (nth 2 sync))
            (propertize (nth 1 sync) 'face 'neoment-comment))))

(defun neoment-rooms--truncate (text width)
  "Return TEXT cut to WIDTH columns, ending in an ellipsis when cut."
  (if (> (string-width text) width)
      (concat (truncate-string-to-width text (1- width)) "…")
    text))

(defun neoment-rooms--preview-lines (room level)
  "Return the preview lines of ROOM at indentation LEVEL, or nil."
  (let ((style neoment-rooms-display-last-message)
        (message (and (neoment-room-p room) (neoment-room-last-message room))))
    (when (and message (not (eq style 'no)))
      (let* ((text (or (neoment-message-content message) ""))
             (attachment (neoment-message-attachment message))
             (content
              (cond
               ((not (string-empty-p text)) text)
               ((plist-get attachment :filename)
                (concat (neoment-icon (or (plist-get attachment :type) 'file))
                        " " (plist-get attachment :filename))))))
        (when content
          (let* ((content (neoment-rooms--truncate
                           (replace-regexp-in-string "\n" " " content) 40))
                 (tree (propertize (concat (make-string (* 2 level) ?\s) "  "
                                           (neoment-icon 'vertical_bar) " ")
                                   'face 'neoment-last-message-tree))
                 (sender (neoment-rooms--truncate
                          (neoment-display-name (neoment-message-sender message)) 15))
                 (body (propertize content 'face 'neoment-last-message)))
            (pcase style
              ('message (list (concat tree body)))
              ('sender_message
               (list (concat tree (propertize sender 'face 'neoment-last-message-sender))
                     (concat tree body)))
              ('sender_message_inline
               (list (concat tree (propertize (concat sender ": ")
                                              'face 'neoment-last-message-sender)
                             body))))))))))

(defun neoment-rooms--line (text &rest properties)
  "Return TEXT plus a newline, with PROPERTIES on all of it."
  (let ((line (concat text "\n")))
    (add-text-properties 0 (length line) properties line)
    line))

(defun neoment-rooms--room-lines (room level section now)
  "Return the lines of ROOM at indentation LEVEL in SECTION at NOW (ms)."
  (let* ((invited (neoment-invited-room-p room))
         (id (neoment-rooms--id room))
         (in-spaces (eq section 'spaces))
         (buffer (eq section 'buffers))
         (name (if (and (not in-spaces) (not invited)
                        (eq neoment-rooms-room-title-format 'space_room))
                   (neoment-room-display-name-with-space id)
                 (neoment-room-display-name id)))
         (activity (and (not invited)
                        (plist-get (neoment-room-last-activity room) :timestamp)))
         (badge (and (not invited) (neoment-rooms--badge room)))
         (counts (and (not invited) (neoment-rooms--has-counts room)))
         (space-name (and (not invited) (not in-spaces)
                          (eq neoment-rooms-room-title-format 'room_space)
                          (neoment-room-space-name id)))
         (icon-face (cond (buffer 'neoment-room-icon-buffer)
                          (badge 'neoment-room-icon-unread)
                          (t 'neoment-room-icon)))
         (line-face (cond ((and buffer counts) 'neoment-buffer-room-unread)
                          (buffer 'neoment-buffer-room)
                          (counts 'neoment-room-unread)))
         (text (concat (make-string (* 2 level) ?\s)
                       (propertize (concat (neoment-rooms--room-icon room) "  ")
                                   'face icon-face)
                       name
                       (if activity
                           (propertize (concat " " (neoment-rooms--relative-time
                                                    activity now))
                                       'face 'neoment-room-time)
                         "")
                       (if badge (propertize (concat " " (car badge)) 'face (cdr badge)) "")
                       (if space-name
                           (propertize (concat " " space-name) 'face 'neoment-room-space)
                         ""))))
    (when line-face
      (add-face-text-property 0 (length text) line-face t text))
    (cons (neoment-rooms--line text 'neoment-room id 'neoment-invited invited)
          (mapcar (lambda (l) (neoment-rooms--line l 'neoment-preview t))
                  (neoment-rooms--preview-lines room level)))))

(defun neoment-rooms--space-lines (space level now)
  "Return the lines of SPACE and its open subtree at LEVEL at NOW (ms)."
  (let* ((id (neoment-room-id space))
         (folded (neoment-rooms--space-folded-p id))
         (arrow (neoment-icon (if folded 'right_arrow 'down_arrow)))
         (lines (list (neoment-rooms--line
                       (concat (make-string (* 2 level) ?\s) arrow " "
                               (neoment-room-display-name id))
                       'neoment-room id 'neoment-space id))))
    (unless folded
      (dolist (child-id (neoment-room-space-rooms space))
        (let ((child (neoment-has-room child-id)))
          (when (and child (neoment-room-is-member-p child-id))
            (setq lines
                  (append lines
                          (if (neoment-room-space-rooms child)
                              (neoment-rooms--space-lines child (1+ level) now)
                            (neoment-rooms--room-lines child (1+ level)
                                                       'spaces now))))))))
    lines))

(defun neoment-rooms--open-room-ids ()
  "Return the ids of the rooms open in room buffers."
  (let (ids)
    (dolist (buffer (buffer-list))
      (when (and (eq (buffer-local-value 'major-mode buffer) 'neoment-room-mode)
                 (not (buffer-local-value 'neoment--thread-root-id buffer)))
        (push (buffer-local-value 'neoment--room-id buffer) ids)))
    ids))

(cl-defun neoment-rooms-render (&key (width 30) open-ids now)
  "Return the room list text for a window WIDTH columns wide.
OPEN-IDS are the ids of rooms open in buffers.  NOW is the current
time in seconds (default: the current time)."
  (let* ((now (or now (float-time)))
         (now-ms (truncate (* now 1000)))
         (status (neoment-sync-status)))
    (cond
     ((and (null (plist-get status :last-sync))
           (eq (plist-get status :kind) 'syncing))
      "Syncing...")
     ((null (plist-get status :last-sync))
      "No sync yet")
     (t
      (let* ((sections (neoment-rooms--classify open-ids))
             (shown (seq-filter
                     (lambda (pair)
                       (or (memq (car pair) '(favorites people rooms low_priority))
                           (cdr pair)))
                     sections))
             ;; PARTS is built in reverse and flipped at the end.
             (parts (list "\n"
                          (concat (neoment-rooms--user-line now) "\n")
                          (concat (neoment-rooms--title-line width) "\n")))
             (first t))
        (dolist (pair shown)
          (let* ((section (car pair))
                 (rooms (cdr pair))
                 (folded (neoment-rooms--section-folded-p section))
                 (header (format "%s %s  %s (%d)"
                                 (neoment-icon (if folded 'right_arrow 'down_arrow))
                                 (neoment-icon (alist-get section neoment-rooms-section-icons))
                                 (alist-get section neoment-rooms-sections)
                                 (length rooms))))
            (add-face-text-property 1 (length header) 'neoment-section-title nil header)
            (unless first (push "\n" parts))
            (setq first nil)
            (push (neoment-rooms--line header 'neoment-section section) parts)
            (unless folded
              (dolist (room rooms)
                (dolist (line (if (and (neoment-room-p room) (neoment-room-space-rooms room))
                                  (neoment-rooms--space-lines room 1 now-ms)
                                (neoment-rooms--room-lines room 1 section now-ms)))
                  (push line parts))))))
        (string-trim-right (apply #'concat (nreverse parts)) "\n"))))))

;;;; Buffer and window

(defun neoment-rooms--buffer ()
  "Return the room list buffer, or nil."
  (get-buffer neoment-rooms-buffer-name))

(defun neoment-rooms--window ()
  "Return the window showing the room list, or nil."
  (let ((buffer (neoment-rooms--buffer)))
    (and buffer (get-buffer-window buffer))))

(defun neoment-rooms--default-width ()
  "Return the width of the room list window."
  (min 50 (floor (* 0.2 (frame-width)))))

(defun neoment-rooms--line-key ()
  "Return a key identifying the line at point, for re-renders."
  (let ((props (text-properties-at (line-beginning-position))))
    (cond
     ((plist-get props 'neoment-section) (list 'section (plist-get props 'neoment-section)))
     ((plist-get props 'neoment-room) (list 'room (plist-get props 'neoment-room))))))

(defun neoment-rooms--goto-key (key)
  "Move to the line identified by KEY.  Return non-nil when found."
  (when key
    (let ((prop (if (eq (car key) 'section) 'neoment-section 'neoment-room))
          (pos (point-min))
          found)
      (while (and (not found) pos (< pos (point-max)))
        (if (equal (get-text-property pos prop) (cadr key))
            (setq found pos)
          (setq pos (next-single-property-change pos prop))))
      (when found (goto-char found) t))))

(defun neoment-rooms-refresh ()
  "Re-render the room list buffer, keeping point on the same line."
  (let ((buffer (neoment-rooms--buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((window (get-buffer-window buffer))
               (key (neoment-rooms--line-key))
               (line (line-number-at-pos))
               (column (current-column))
               (start-line (and window (line-number-at-pos (window-start window))))
               (inhibit-read-only t)
               (neoment--bubble-edges (neoment-faces-bubble-edges
                                       (and window (window-frame window)))))
          (erase-buffer)
          (insert (neoment-rooms-render
                   :width (if window (window-width window) (neoment-rooms--default-width))
                   :open-ids (neoment-rooms--open-room-ids)))
          (goto-char (point-min))
          (unless (neoment-rooms--goto-key key)
            (forward-line (1- line)))
          (move-to-column column)
          (when window
            (set-window-point window (point))
            (when start-line
              (set-window-start window (save-excursion
                                         (goto-char (point-min))
                                         (forward-line (1- start-line))
                                         (point))
                                t))))))))

;;;###autoload
(defun neoment-rooms-quit ()
  "Ask for confirmation, then run `neoment-quit'."
  (interactive)
  (if (y-or-n-p "Quit Neoment? ")
      (neoment-quit)
    (message "Operation canceled")))

(declare-function neoment-quit "neoment")

(defvar-keymap neoment-rooms-mode-map
  :doc "Keymap of `neoment-rooms-mode'."
  :parent special-mode-map
  "RET" #'neoment-rooms-enter
  "TAB" #'neoment-rooms-toggle-fold
  "<tab>" #'neoment-rooms-toggle-fold
  "q" #'neoment-toggle-rooms-list
  "Q" #'neoment-rooms-quit
  "a" #'neoment-rooms-toggle-favorite
  "d" #'neoment-rooms-toggle-direct
  "f" #'neoment-pick-room
  "F" #'neoment-pick-open-room
  "g" #'revert-buffer
  "i" #'neoment-rooms-show-room-info
  "l" #'neoment-rooms-toggle-low-priority
  "n" #'neoment-rooms-next
  "p" #'neoment-rooms-previous
  "N" #'neoment-rooms-room-notification-settings
  "M-n" #'neoment-notification-settings
  "r" #'neoment-rooms-toggle-read
  "s" #'neoment-rooms-change-status
  "u" #'neoment-rooms-refresh-room-state
  "?" #'describe-mode)

(define-derived-mode neoment-rooms-mode special-mode "Neoment Rooms"
  "Major mode for the Neoment room list.

\\{neoment-rooms-mode-map}"
  (setq-local truncate-lines t
              buffer-undo-list t
              window-size-fixed 'width
              revert-buffer-function (lambda (&rest _) (neoment-rooms-refresh)))
  (when (fboundp 'display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (hl-line-mode 1)
  (add-hook 'window-size-change-functions
            (lambda (_) (neoment-rooms-refresh)) nil t))

(defun neoment-rooms--get-buffer ()
  "Return the room list buffer, creating it."
  (or (neoment-rooms--buffer)
      (with-current-buffer (get-buffer-create neoment-rooms-buffer-name)
        (neoment-rooms-mode)
        (current-buffer))))

(defun neoment-rooms--show ()
  "Show the room list in the left side window and select it."
  (let* ((buffer (neoment-rooms--get-buffer))
         (window (display-buffer-in-side-window
                  buffer `((side . left) (slot . 0)
                           (window-width . ,(neoment-rooms--default-width))
                           (dedicated . t)
                           (window-parameters . ((no-delete-other-windows . t)))))))
    (when window
      (set-window-dedicated-p window t)
      (select-window window))
    (neoment-rooms-refresh)
    window))

;;;###autoload
(defun neoment-toggle-rooms-list ()
  "Show the room list, or close it when it is visible."
  (interactive)
  (let ((window (neoment-rooms--window)))
    (if window
        (delete-window window)
      (neoment-rooms--show))))

(defun neoment-rooms-open ()
  "Show the room list unless it is already visible."
  (unless (neoment-rooms--window)
    (neoment-rooms--show)))

(defun neoment-rooms-target-window ()
  "Return the window where rooms open, next to the room list."
  (let ((list-window (neoment-rooms--window)))
    (if (and list-window (eq (selected-window) list-window))
        (or (window-in-direction 'right list-window)
            (let ((main (window-main-window)))
              (and (not (eq main list-window)) main))
            (split-window list-window nil 'right))
      (selected-window))))

(defun neoment-rooms-open-room (room-id)
  "Open ROOM-ID (a room or a space) next to the room list."
  (select-window (neoment-rooms-target-window))
  (if (neoment-room-is-space room-id)
      (neoment-space-open room-id)
    (neoment-room-open room-id)))

;;;; Actions

(defconst neoment-rooms--no-room
  "No room found on this line. Position the cursor directly over the room name."
  "Message shown when no room is on the current line.")

(defun neoment-rooms--room-at-point (&optional silent)
  "Return the room id on the current line.
Show a message and return nil when there is none, unless SILENT."
  (or (get-text-property (line-beginning-position) 'neoment-room)
      (progn (unless silent (neoment-notify--message neoment-rooms--no-room))
             nil)))

(defun neoment-rooms--invited-at-point-p ()
  "Return non-nil when the line at point is an invited room."
  (get-text-property (line-beginning-position) 'neoment-invited))

(defun neoment-rooms--handle-invite (room-id)
  "Ask whether to join or reject the invite to ROOM-ID."
  (let* ((name (neoment-room-display-name room-id))
         (answer (car (read-multiple-choice
                       (concat "You have been invited to join the room: " name)
                       '((?j "Join") (?r "Reject") (?c "Cancel"))))))
    (pcase answer
      (?j (neoment-api-join
           room-id nil
           (lambda (result)
             (if (plist-get result :error)
                 (neoment-notify--error
                  (concat "Error joining room: "
                          (neoment-http-error-message (plist-get result :error))))
               (neoment-rooms-open-room (or (plist-get result :ok) room-id))))))
      (?r (neoment-api-leave
           room-id
           (lambda (result)
             (if (plist-get result :error)
                 (neoment-notify--error
                  (concat "Error leaving room: "
                          (neoment-http-error-message (plist-get result :error))))
               (neoment-notify--message (concat "Left room: " name))
               (neoment-rooms-refresh))))))))

(defun neoment-rooms-enter ()
  "Open the room or space on the current line, or answer its invite."
  (interactive)
  (let ((room-id (neoment-rooms--room-at-point)))
    (when room-id
      (if (neoment-rooms--invited-at-point-p)
          (neoment-rooms--handle-invite room-id)
        (neoment-rooms-open-room room-id)))))

(defun neoment-rooms-toggle-fold ()
  "Fold or unfold the section or space on the current line."
  (interactive)
  (let ((section (get-text-property (line-beginning-position) 'neoment-section))
        (space (get-text-property (line-beginning-position) 'neoment-space)))
    (cond
     (section
      (let ((key (symbol-name section)))
        (setf (alist-get key neoment-rooms--fold-sections nil nil #'equal)
              (not (neoment-rooms--section-folded-p section)))))
     (space
      (setf (alist-get space neoment-rooms--fold-spaces nil nil #'equal)
            (not (neoment-rooms--space-folded-p space))))
     (t (neoment-notify--message
         "No section found on this line. Position the cursor over a section title.")))
    (when (or section space)
      (neoment-rooms--save-fold-state)
      (neoment-rooms-refresh))))

(defun neoment-rooms-toggle-tag (tag room-id &optional callback)
  "Add or remove TAG on ROOM-ID, then call CALLBACK."
  (let* ((room (neoment-get-room room-id))
         (label (if (equal tag "m.favourite") "favorites" "low priority"))
         (name (neoment-room-display-name room-id))
         (tagged (if (equal tag "m.favourite")
                     (neoment-room-is-favorite room)
                   (neoment-room-is-lowpriority room)))
         (add (not tagged)))
    (neoment-api-set-tag
     room-id tag add
     (lambda (result)
       (if (plist-get result :error)
           (neoment-notify--error
            (format "Error %s %s %s: %s"
                    (if add "adding" "removing") name
                    (if add (concat "to " label) (concat "from " label))
                    (neoment-http-error-message (plist-get result :error))))
         (if (equal tag "m.favourite")
             (setf (neoment-room-is-favorite room) add)
           (setf (neoment-room-is-lowpriority room) add))
         (neoment-rooms-refresh)
         (when callback (funcall callback))
         (neoment-notify--message
          (format "%s %s %s" name (if add "added to" "removed from") label)))))))

(defun neoment-rooms--toggle-tag-at-point (tag)
  "Toggle TAG on the room at point."
  (let ((room-id (neoment-rooms--room-at-point)))
    (when room-id
      (if (neoment-rooms--invited-at-point-p)
          (neoment-notify--message
           (format "You cannot add an invited room to %s."
                   (if (equal tag "m.favourite") "favorites" "low priority")))
        (neoment-rooms-toggle-tag tag room-id)))))

(defun neoment-rooms-toggle-favorite ()
  "Add or remove the room at point from the favorites."
  (interactive)
  (neoment-rooms--toggle-tag-at-point "m.favourite"))

(defun neoment-rooms-toggle-low-priority ()
  "Add or remove the room at point from low priority."
  (interactive)
  (neoment-rooms--toggle-tag-at-point "m.lowpriority"))

(defun neoment-rooms-toggle-direct-on (room-id)
  "Toggle, locally, whether ROOM-ID is a direct message."
  (let ((room (neoment-get-room room-id)))
    (setf (neoment-room-is-direct room) (not (neoment-room-is-direct room)))
    (neoment-rooms-refresh)
    (neoment-notify--message
     (format "%s %s" (neoment-room-display-name room-id)
             (if (neoment-room-is-direct room) "marked as direct" "unmarked as direct")))))

(defun neoment-rooms-toggle-direct ()
  "Toggle, locally, whether the room at point is a direct message."
  (interactive)
  (let ((room-id (neoment-rooms--room-at-point)))
    (when room-id
      (if (neoment-rooms--invited-at-point-p)
          (neoment-notify--message "You cannot mark an invited room as direct.")
        (neoment-rooms-toggle-direct-on room-id)))))

(defun neoment-rooms-toggle-read ()
  "Mark the room at point as read, or as unread when it is read."
  (interactive)
  (let ((room-id (neoment-rooms--room-at-point)))
    (when room-id
      (if (neoment-rooms--invited-at-point-p)
          (neoment-notify--message "You cannot mark an invited room as read.")
        (let* ((room (neoment-get-room room-id))
               (name (neoment-room-display-name room-id))
               (event-id (plist-get (neoment-room-last-activity room) :event-id)))
          (if (or (neoment-rooms--has-counts room) (neoment-room-unread-p room))
              (if (not event-id)
                  (neoment-notify--message
                   "No activity found in this room to mark as read.")
                (neoment-api-set-read-markers
                 room-id (list :read-private event-id)
                 (lambda (result)
                   (if (plist-get result :error)
                       (neoment-notify--error
                        (format "Failed to mark room '%s' as read: %s" name
                                (neoment-http-error-message (plist-get result :error))))
                     ;; Clear the counts now so the room leaves the top of
                     ;; its section without waiting for the next sync.
                     (setf (neoment-room-unread-highlights room) 0
                           (neoment-room-unread-notifications room) 0)
                     (neoment-rooms-refresh)
                     (neoment-notify--message
                      (format "Room '%s' marked as read" name))))))
            (neoment-api-send-event
             room-id "m.marked_unread" '((unread . t))
             (lambda (result)
               (if (plist-get result :error)
                   (neoment-notify--error
                    (format "Failed to mark room '%s' as unread: %s" name
                            (neoment-http-error-message (plist-get result :error))))
                 (setf (neoment-room-unread room) t)
                 (neoment-rooms-refresh)
                 (neoment-notify--message
                  (format "Room '%s' marked as unread" name)))))))))))

(defconst neoment-rooms--presence-labels
  '(("● online" . "online") ("◐ unavailable" . "unavailable") ("○ offline" . "offline"))
  "Presence choices.")

(defun neoment-rooms-change-status ()
  "Choose the presence to set on the next sync."
  (interactive)
  (let* ((current (or (plist-get (neoment-get-presence (neoment-user-id)) :presence)
                      "offline"))
         (choice (completing-read (format "Change status (current: %s): " current)
                                  neoment-rooms--presence-labels nil t))
         (presence (cdr (assoc choice neoment-rooms--presence-labels))))
    (when presence
      (setf (neoment-client-desired-presence neoment--client) presence)
      (neoment-rooms-refresh)
      (neoment-notify--message
       (format "Status will change to '%s' on next sync" presence)))))

(defconst neoment-rooms--refreshed-state-types
  '("m.room.tombstone" "m.room.name" "m.room.topic" "m.room.canonical_alias"
    "m.space.child")
  "State event types applied by `neoment-rooms-refresh-room-state'.")

(defun neoment-rooms--state-snapshot (room)
  "Return the parts of ROOM changed by a state refresh."
  (list (neoment-room-name room) (neoment-room-topic room)
        (neoment-room-aliases room) (neoment-room-tombstone room)
        (copy-sequence (neoment-room-space-rooms room))))

(defun neoment-rooms-refresh-room-state ()
  "Fetch the state of the room at point again."
  (interactive)
  (let ((room-id (neoment-rooms--room-at-point)))
    (when room-id
      (let* ((room (neoment-get-room room-id))
             (name (neoment-room-name room)))
        (neoment-notify--message (format "Refreshing state for %s..." name))
        (neoment-api-request
         'get (neoment-api-room-path room-id "state")
         :callback
         (lambda (result)
           (if (plist-get result :error)
               (neoment-notify--error
                (format "Failed to refresh state: %s"
                        (neoment-http-error-message (plist-get result :error))))
             (let ((before (neoment-rooms--state-snapshot room)))
               (neoment-events-handle-multiple
                room (seq-filter (lambda (e)
                                   (member (alist-get 'type e)
                                           neoment-rooms--refreshed-state-types))
                                 (plist-get result :ok)))
               (if (equal before (neoment-rooms--state-snapshot room))
                   (neoment-notify--message (format "No new state for %s" name))
                 (neoment-notify--message (format "State updated for %s" name))
                 (neoment-rooms-refresh)
                 (when (fboundp 'neoment-room-refresh)
                   (neoment-room-refresh room-id)))))))))))

(defun neoment-rooms-show-room-info ()
  "Show information about the room at point."
  (interactive)
  (let ((room-id (neoment-rooms--room-at-point)))
    (when room-id
      (select-window (neoment-rooms-target-window))
      (neoment-room-info-open room-id))))

(defun neoment-rooms-room-notification-settings ()
  "Open the notification settings of the room at point."
  (interactive)
  (let ((room-id (neoment-rooms--room-at-point)))
    (when room-id
      (if (neoment-has-invited-room room-id)
          (neoment-notify--message
           "Notification settings are available after joining the room.")
        (neoment-notification-settings-room room-id)))))

(defun neoment-rooms--move (direction)
  "Move to the next line with a room, space or section in DIRECTION (1 or -1)."
  (let ((target nil))
    (save-excursion
      (forward-line 0)
      (while (and (not target)
                  (let ((before (point)))
                    (and (zerop (forward-line direction)) (bolp)
                         (/= before (point)))))
        (let ((props (text-properties-at (point))))
          (when (or (plist-get props 'neoment-room)
                    (plist-get props 'neoment-section))
            (setq target (point))))))
    (if target
        (goto-char target)
      (neoment-notify--message "No more rooms in this direction"))))

(defun neoment-rooms-next ()
  "Move to the next room, space or section."
  (interactive)
  (neoment-rooms--move 1))

(defun neoment-rooms-previous ()
  "Move to the previous room, space or section."
  (interactive)
  (neoment-rooms--move -1))

;;;; Coalesced rendering

(defvar neoment-ui-render-delay 0.1
  "Idle seconds before dirty buffers are rendered.")

(defvar neoment-ui--dirty (make-hash-table :test 'eq)
  "Buffers waiting for a render, mapped to their render function.")

(defvar neoment-ui--timer nil
  "Idle timer that renders the dirty buffers.")

(defun neoment-ui-cancel-timer ()
  "Cancel the pending render and forget the buffers waiting for it."
  (when (timerp neoment-ui--timer)
    (cancel-timer neoment-ui--timer))
  (setq neoment-ui--timer nil)
  (clrhash neoment-ui--dirty))

(defun neoment-ui--visible-p (buffer)
  "Return non-nil when BUFFER is shown in a window."
  (and (get-buffer-window buffer t) t))

(defun neoment-ui-flush ()
  "Render the dirty buffers that are shown in a window."
  (setq neoment-ui--timer nil)
  (let (todo)
    (maphash (lambda (buffer function)
               (cond
                ((not (buffer-live-p buffer)) (push (cons buffer nil) todo))
                ((neoment-ui--visible-p buffer) (push (cons buffer function) todo))))
             neoment-ui--dirty)
    (pcase-dolist (`(,buffer . ,function) todo)
      (remhash buffer neoment-ui--dirty)
      (when function
        (with-current-buffer buffer
          (funcall function))))))

(defun neoment-ui-schedule (buffer function)
  "Render BUFFER with FUNCTION once Emacs is idle.
Several requests before the render cause a single render.  A buffer
that is not shown waits until it is displayed."
  (when (buffer-live-p buffer)
    (puthash buffer function neoment-ui--dirty)
    (unless neoment-ui--timer
      (setq neoment-ui--timer
            (run-with-idle-timer neoment-ui-render-delay nil #'neoment-ui-flush)))))

(defun neoment-ui--on-window-buffer-change (&optional _frame)
  "Render dirty buffers that just became visible."
  (when (> (hash-table-count neoment-ui--dirty) 0)
    (neoment-ui-flush)))

(add-hook 'window-buffer-change-functions #'neoment-ui--on-window-buffer-change)

(defun neoment-rooms-schedule-refresh ()
  "Re-render the room list soon."
  (let ((buffer (neoment-rooms--buffer)))
    (when buffer
      (neoment-ui-schedule buffer #'neoment-rooms-refresh))))

;;;; Pickers

(defun neoment-completing-read-picker (items callback prompt)
  "Pick one of ITEMS with `completing-read' and call CALLBACK with it.
ITEMS is a list of (LINE . ROOM-ID).  PROMPT is the prompt."
  (let* ((prompt (if (string-suffix-p " " prompt) prompt (concat prompt " ")))
         (choice (completing-read prompt items nil t))
         (room-id (cdr (assoc choice items))))
    (when room-id
      (funcall callback room-id))))

(defun neoment-rooms-picker-item (room-id &optional now)
  "Return the picker (LINE . ROOM-ID) item for ROOM-ID at NOW (ms)."
  (let ((room (neoment-get-room room-id)))
    (if (neoment-room-space-rooms room)
        (cons (concat (neoment-icon 'space) "  " (neoment-room-display-name room-id))
              room-id)
      (let* ((activity (plist-get (neoment-room-last-activity room) :timestamp))
             (badge (neoment-rooms--badge room)))
        (cons (concat (if (neoment-room-is-direct room)
                          (neoment-icon 'people)
                        (neoment-icon 'room))
                      "  " (neoment-room-display-name-with-space room-id)
                      (if activity
                          (concat " [" (neoment-rooms--relative-time
                                        activity (or now (neoment--now-ms)))
                                  "]"
                                  (if badge (concat " " (car badge)) ""))
                        ""))
              room-id)))))

(defun neoment-rooms-pick (room-ids prompt callback &optional function)
  "Let the user pick one of ROOM-IDS with PROMPT, then call CALLBACK.
FUNCTION is the picker (default `neoment-room-picker-function')."
  (neoment-faces-setup-icon-font)
  (funcall (or function neoment-room-picker-function)
           (mapcar #'neoment-rooms-picker-item room-ids)
           callback prompt))

;;;###autoload
(defun neoment-pick-room ()
  "Pick a room and open it."
  (interactive)
  (neoment-rooms-pick (mapcar #'neoment-room-id
                              (sort (neoment-rooms--member-rooms)
                                    #'neoment-rooms--activity<))
                      "Select a room:" #'neoment-rooms-open-room))

;;;###autoload
(defun neoment-pick-open-room ()
  "Pick one of the rooms open in buffers and show it."
  (interactive)
  (let ((ids (seq-filter #'neoment-has-room (neoment-rooms--open-room-ids))))
    (if (null ids)
        (neoment-notify--message "No open rooms")
      (neoment-rooms-pick ids "Select an open room:" #'neoment-rooms-open-room
                          neoment-open-room-picker-function))))

(provide 'neoment-rooms)
;;; neoment-rooms.el ends here
