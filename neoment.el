;;; neoment.el --- A Matrix client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Douglas M.

;; Author: Douglas M.
;; Maintainer: Douglas M.
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (plz "0.9"))
;; Keywords: comm
;; URL: https://github.com/Massolari/neoment.el

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

;; Neoment is a Matrix client.  Run `M-x neoment' to log in, or to
;; toggle the room list when already logged in.

;;; Code:

(require 'neoment-config)
(require 'neoment-faces)
(require 'neoment-notify)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-storage)
(require 'neoment-events)
(require 'neoment-sync)
(require 'neoment-auth)
(require 'neoment-rooms)
(require 'neoment-room)
(require 'neoment-compose)
(require 'neoment-emoji)
(require 'neoment-media)
(require 'neoment-space)
(require 'neoment-room-info)

;;;; Wiring

(defun neoment--after-sync (room-ids)
  "Re-render the room list and the open buffers of ROOM-IDS."
  (neoment-rooms-schedule-refresh)
  (dolist (room-id room-ids)
    (neoment-room-refresh room-id)))

(defun neoment--room-changed (room-id)
  "Re-render the buffers of ROOM-ID, or of every room when nil."
  (if room-id
      (progn (neoment-room-refresh room-id)
             (neoment-rooms-schedule-refresh))
    (neoment-room-refresh-all)))

(defun neoment--current-room ()
  "Return the room id shown in the selected window, or nil."
  (buffer-local-value 'neoment--room-id (window-buffer (selected-window))))

(add-hook 'neoment-sync-after-functions #'neoment--after-sync)
(add-hook 'neoment-client-room-changed-functions #'neoment--room-changed)
(setq neoment-notify--current-room-function #'neoment--current-room)
(setq neoment-http-unknown-token-function
      (or neoment-http-unknown-token-function
          (lambda (_client _err _token _retry give-up)
            (neoment-auth-session-expired)
            (funcall give-up))))

(defvar neoment--initialized nil
  "Non-nil once `neoment--init' ran.")

(defun neoment--init ()
  "Set up faces, validate options and track focus, once."
  (unless neoment--initialized
    (setq neoment--initialized t)
    (neoment-faces-setup)
    (neoment-config-validate)
    (neoment-notify-start-focus-tracking)))

;;;###autoload
(defun neoment ()
  "Log in to Matrix, or toggle the room list when logged in."
  (interactive)
  (neoment--init)
  (if (neoment-logged-in-p)
      (neoment-toggle-rooms-list)
    (neoment-login)))

(provide 'neoment)
;;; neoment.el ends here
