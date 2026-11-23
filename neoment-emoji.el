;;; neoment-emoji.el --- Emoji table for reactions  -*- lexical-binding: t; -*-

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

;; The emoji offered as reactions, built lazily from `ucs-names' and
;; filtered to the emoji code blocks.  Labels look like
;; "😄 :grinning_face_with_smiling_eyes:".  Names follow Unicode, not
;; GitHub shortcodes.

;;; Code:

(require 'cl-lib)
(require 'mule-util)

(defconst neoment-emoji-ranges
  '((#x2600 . #x27BF) (#x1F300 . #x1F5FF) (#x1F600 . #x1F64F)
    (#x1F680 . #x1F6FF) (#x1F900 . #x1F9FF) (#x1FA70 . #x1FAFF))
  "Code point ranges considered emoji.")

(defvar neoment-emoji--table nil
  "Cached list of (LABEL . EMOJI).")

(defun neoment-emoji--in-ranges-p (char)
  "Return non-nil when CHAR is in `neoment-emoji-ranges'."
  (cl-some (lambda (range) (<= (car range) char (cdr range))) neoment-emoji-ranges))

(defun neoment-emoji-label-for (name char)
  "Return the label of the emoji CHAR named NAME."
  (format "%c :%s:" char (replace-regexp-in-string
                          "[^a-z0-9]+" "_" (downcase name))))

(defun neoment-emoji-list ()
  "Return the reaction emoji as a list of (LABEL . EMOJI), sorted by code point."
  (or neoment-emoji--table
      (let ((graphic (display-graphic-p))
            (entries nil))
        (maphash (lambda (name char)
                   (when (and (neoment-emoji--in-ranges-p char)
                              (or (not graphic) (char-displayable-p char)))
                     (push (cons char name) entries)))
                 (ucs-names))
        (setq entries (sort (delete-dups entries) (lambda (a b) (< (car a) (car b)))))
        (setq neoment-emoji--table
              (mapcar (lambda (e)
                        (cons (neoment-emoji-label-for (cdr e) (car e))
                              (char-to-string (car e))))
                      (cl-remove-duplicates entries :key #'car :from-end t))))))

(defun neoment-emoji-label (key)
  "Return the label of the reaction KEY, or nil when it is not in the table."
  (car (rassoc key (neoment-emoji-list))))

(provide 'neoment-emoji)
;;; neoment-emoji.el ends here
