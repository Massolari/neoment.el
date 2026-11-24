;;; neoment.el --- A Matrix client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Douglas M.

;; Author: Douglas M.
;; Maintainer: Douglas M.
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
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

(require 'transient)
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
(require 'neoment-player)
(require 'neoment-space)
(require 'neoment-room-info)
(require 'neoment-notification-settings)
(require 'neoment-token)
(require 'neoment-oauth)
(require 'neoment-sso)

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

(defvar neoment--initialized nil
  "Non-nil once `neoment--init' ran.")

(defun neoment--init ()
  "Set up faces, validate options and track focus, once."
  (unless neoment--initialized
    (setq neoment--initialized t)
    (neoment-faces-setup)
    (neoment-config-validate)
    (neoment-notify-start-focus-tracking)))

;;;; Dispatcher and menu

(defconst neoment-subcommands
  '(("join" . neoment-join)
    ("logout" . neoment-logout)
    ("rooms" . neoment-pick-room)
    ("open_rooms" . neoment-pick-open-room)
    ("sync_start" . neoment-sync-start)
    ("sync_stop" . neoment-sync-stop)
    ("reload_config" . neoment-reload-config)
    ("clear" . neoment-clear-cache)
    ("toggle_rooms_list" . neoment-toggle-rooms-list)
    ("notification_settings" . neoment-notification-settings))
  "Subcommands offered by `neoment-command'.")

;;;###autoload
(defun neoment-command (subcommand)
  "Run the Neoment SUBCOMMAND, chosen with completion."
  (interactive (list (completing-read "Neoment: " neoment-subcommands nil t)))
  (let ((command (cdr (assoc subcommand neoment-subcommands))))
    (when command
      (neoment--init)
      (call-interactively command))))

;;;###autoload (autoload 'neoment-menu "neoment" nil t)
(transient-define-prefix neoment-menu ()
  "Menu of the Neoment commands."
  [["Session"
    ("n" "Log in / toggle room list" neoment)
    ("L" "Log out" neoment-logout)
    ("s" "Start sync" neoment-sync-start)
    ("S" "Stop sync" neoment-sync-stop)]
   ["Rooms"
    ("j" "Join room, alias or user" neoment-join)
    ("f" "Pick a room" neoment-pick-room)
    ("F" "Pick an open room" neoment-pick-open-room)
    ("l" "Toggle room list" neoment-toggle-rooms-list)]
   ["Settings"
    ("N" "Notification settings" neoment-notification-settings)
    ("r" "Reload configuration" neoment-reload-config)
    ("c" "Clear cache" neoment-clear-cache)]])

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
