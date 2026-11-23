;;; neoment-faces.el --- Faces for Neoment  -*- lexical-binding: t; -*-

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

;; Faces used by Neoment.  They inherit from standard faces so they
;; follow the theme.  The bubble border faces are computed from the
;; bubble content and default backgrounds, and recomputed whenever a
;; theme is enabled.

;;; Code:

(require 'neoment-config)

(defgroup neoment-faces nil
  "Faces used by Neoment."
  :group 'neoment
  :group 'faces)

(defface neoment-rooms-title '((t :inherit (bold font-lock-function-name-face)))
  "Face for titles.")

(defface neoment-header-decoration '((t :inherit shadow))
  "Face for the lines around the room list title.")

(defface neoment-section-title '((t :inherit bold))
  "Face for section headers.")

(defface neoment-separator '((t :inherit font-lock-keyword-face))
  "Face for gutters and separators.")

(defface neoment-buffer-room '((t :inherit font-lock-keyword-face))
  "Face for rooms open in a buffer.")

(defface neoment-buffer-room-unread '((t :inherit (bold font-lock-keyword-face)))
  "Face for rooms open in a buffer with unread messages.")

(defface neoment-room-unread '((t :inherit bold))
  "Face for rooms with unread messages.")

(defface neoment-mention '((t :inherit highlight))
  "Face for mentions of other users.")

(defface neoment-mention-user '((t :inherit error))
  "Face for mentions of the current user.")

(defface neoment-emoticon '((t :inherit link))
  "Face for custom emoticons.")

(defface neoment-bubble-content
  '((((class color) (min-colors 88) (background dark))
     :background "gray25")
    (((class color) (min-colors 88) (background light))
     :background "gray85")
    (t :inherit highlight))
  "Face for the inside of bubbles.")

(defface neoment-bubble-border '((t))
  "Face for the edges of bubbles.
Its foreground is the background of `neoment-bubble-content'.")

(defface neoment-bubble-active-content '((t :inherit isearch))
  "Face for the inside of active bubbles.")

(defface neoment-bubble-active-border '((t))
  "Face for the edges of active bubbles.
Its foreground is the background of `neoment-bubble-active-content'.")

(defface neoment-room-icon '((t :inherit font-lock-comment-face))
  "Face for room icons.")

(defface neoment-room-icon-buffer '((t :inherit font-lock-keyword-face))
  "Face for icons of rooms open in a buffer.")

(defface neoment-room-icon-unread '((t :inherit font-lock-constant-face))
  "Face for icons of unread rooms.")

(defface neoment-room-time '((t :inherit font-lock-comment-face))
  "Face for relative times in the room list.")

(defface neoment-notification-dot '((t :inherit success))
  "Face for the unread dot.")

(defface neoment-notification-circle '((t :inherit warning))
  "Face for the notification badge.")

(defface neoment-notification-bell '((t :inherit error))
  "Face for the highlight badge.")

(defface neoment-room-space '((t :inherit font-lock-doc-face))
  "Face for space names in the room list.")

(defface neoment-last-message-tree '((t :inherit shadow))
  "Face for the tree line of last message previews.")

(defface neoment-last-message-sender '((t :inherit font-lock-variable-name-face))
  "Face for the sender of last message previews.")

(defface neoment-last-message '((t :inherit font-lock-comment-face))
  "Face for last message previews.")

(defface neoment-tombstone '((t :inherit warning))
  "Face for the notice of an upgraded room.")

(defface neoment-sync-ok '((t :inherit success))
  "Face for the synced indicator.")

(defface neoment-comment '((t :inherit font-lock-comment-face))
  "Face for secondary text such as state messages.")

(defmacro neoment-faces--define-user-faces (parents)
  "Define the faces `neoment-user-1' ... inheriting from PARENTS."
  (let ((i 0) forms)
    (dolist (parent parents)
      (setq i (1+ i))
      (push `(defface ,(intern (format "neoment-user-%d" i))
               '((t :inherit (bold ,parent)))
               ,(format "Face number %d for sender names." i))
            forms))
    `(progn ,@(nreverse forms))))

(neoment-faces--define-user-faces
 (font-lock-function-name-face font-lock-type-face font-lock-variable-name-face
  font-lock-keyword-face font-lock-string-face font-lock-number-face
  font-lock-constant-face font-lock-comment-face font-lock-property-name-face
  font-lock-builtin-face font-lock-preprocessor-face font-lock-operator-face
  font-lock-warning-face font-lock-property-use-face font-lock-doc-face
  font-lock-negation-char-face font-lock-variable-use-face
  font-lock-function-call-face italic font-lock-regexp-grouping-backslash))

(defconst neoment-faces-user-count 20
  "Number of sender name faces.")

(defun neoment-faces-user-face (index)
  "Return the sender name face for INDEX (0-based, cycled)."
  (intern (format "neoment-user-%d" (1+ (mod index neoment-faces-user-count)))))

;;;; Bubble borders

(defun neoment-faces--background (face)
  "Return the background color of FACE, or nil when unspecified."
  (let ((bg (face-background face nil t)))
    (and bg (not (string-prefix-p "unspecified" bg)) bg)))

(defun neoment-faces--update (&rest _)
  "Recompute the bubble border faces from the current theme."
  (let ((default-bg (neoment-faces--background 'default)))
    (pcase-dolist (`(,border . ,content)
                   '((neoment-bubble-border . neoment-bubble-content)
                     (neoment-bubble-active-border
                      . neoment-bubble-active-content)))
      (set-face-attribute border nil
                          :foreground (or (neoment-faces--background content)
                                          'unspecified)
                          :background (or default-bg 'unspecified)))))

(defun neoment-faces-setup ()
  "Compute the bubble faces and keep them in sync with the theme."
  (neoment-faces--update)
  (add-hook 'enable-theme-functions #'neoment-faces--update)
  (add-hook 'disable-theme-functions #'neoment-faces--update))

;;;; Bubble edges

(defconst neoment-faces-bubble-edges-nerd (cons "" "")
  "Rounded bubble edges (Nerd Font).")

(defconst neoment-faces-bubble-edges-fallback (cons "▐" "▌")
  "Bubble edges used when the Nerd Font glyphs cannot be displayed.")

(defvar neoment--bubble-edges neoment-faces-bubble-edges-nerd
  "The (LEFT . RIGHT) bubble edges used by the renderers.")

(defun neoment-faces-bubble-edges (&optional frame)
  "Return the (LEFT . RIGHT) bubble edges to use in FRAME."
  (let ((frame (or frame (selected-frame))))
    (if (and (display-graphic-p frame)
             (not (char-displayable-p #xE0B6)))
        neoment-faces-bubble-edges-fallback
      neoment-faces-bubble-edges-nerd)))

(defun neoment-faces-bubble (content &optional active)
  "Return CONTENT wrapped in bubble edges.
With ACTIVE, use the active bubble faces."
  (let ((border (if active 'neoment-bubble-active-border 'neoment-bubble-border))
        (inner (if active 'neoment-bubble-active-content 'neoment-bubble-content)))
    (concat (propertize (car neoment--bubble-edges) 'face border)
            (propertize content 'face inner)
            (propertize (cdr neoment--bubble-edges) 'face border))))

(provide 'neoment-faces)
;;; neoment-faces.el ends here
