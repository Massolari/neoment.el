;;; neoment-notify.el --- Messages and desktop notifications  -*- lexical-binding: t; -*-

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

;; User-facing messages (always prefixed with "[Neoment] ") and the
;; desktop notifications driven by the user's Matrix push rules.

;;; Code:

(require 'cl-lib)
(require 'neoment-config)
(require 'neoment-client)

;;;; Messages

(defun neoment-notify-default-notifier (msg _level)
  "Show MSG in the echo area."
  (message "%s" msg))

(defun neoment-notify--message (msg &optional level)
  "Show MSG to the user through `neoment-notifier' with LEVEL.
LEVEL is `info' (the default), `warn' or `error'."
  (funcall neoment-notifier (concat "[Neoment] " msg) (or level 'info)))

(defun neoment-notify--messagef (format-string &rest args)
  "Show a message built from FORMAT-STRING and ARGS at level `info'."
  (neoment-notify--message (apply #'format format-string args)))

(defun neoment-notify--error (msg)
  "Show MSG at level `error'."
  (neoment-notify--message msg 'error))

;;;; Focus tracking

(defvar neoment-notify--focused t
  "Non-nil when an Emacs frame has focus.")

(defun neoment-notify--update-focus ()
  "Update `neoment-notify--focused' from the frames' focus state."
  (setq neoment-notify--focused
        (and (seq-some (lambda (f) (eq (frame-focus-state f) t))
                       (frame-list))
             t)))

(defun neoment-notify-start-focus-tracking ()
  "Start tracking whether an Emacs frame has focus."
  (add-function :after after-focus-change-function
                #'neoment-notify--update-focus)
  (neoment-notify--update-focus))

;;;; Desktop notifications

(defvar neoment-notify--current-room-function nil
  "Function returning the room id shown in the selected window, or nil.")

(defvar neoment-notify--candidates (make-hash-table :test 'equal)
  "Newest incoming message of each room during the current sync.")

(defvar neoment-notify--last-notified (make-hash-table :test 'equal)
  "Timestamp (ms) of the last notification sent for each room.")

(defvar neoment-notify--client nil
  "The client the notification state belongs to.")

(defvar neoment-notify--initial-sync-p nil
  "Non-nil while the first sync of the client is processed.")

(defun neoment-notify--ensure-client ()
  "Reset the notification state when the client changed."
  (unless (eq neoment-notify--client neoment--client)
    (setq neoment-notify--client neoment--client)
    (clrhash neoment-notify--candidates)
    (clrhash neoment-notify--last-notified)))

(defun neoment-notify-clear-candidates ()
  "Forget the candidate messages of the current sync."
  (neoment-notify--ensure-client)
  (clrhash neoment-notify--candidates))

(defun neoment-notify--suppressed-p (room message)
  "Return non-nil when MESSAGE in ROOM must not be notified."
  (or (not neoment-desktop-notifications-enabled)
      neoment-notify--initial-sync-p
      (and message
           (or (neoment-message-is-state message)
               (equal (neoment-message-sender message)
                      (neoment-client-user-id neoment--client))))
      (and neoment-notify--focused
           neoment-notify--current-room-function
           (equal (funcall neoment-notify--current-room-function)
                  (neoment-room-id room)))))

(defun neoment-notify-add-candidate (room message)
  "Remember MESSAGE as the newest incoming message of ROOM."
  (neoment-notify--ensure-client)
  (unless (or (neoment-message-is-state message)
              (equal (neoment-message-sender message)
                     (neoment-client-user-id neoment--client)))
    (let ((old (gethash (neoment-room-id room) neoment-notify--candidates)))
      (when (or (null old)
                (>= (or (neoment-message-timestamp message) 0)
                    (or (neoment-message-timestamp old) 0)))
        (puthash (neoment-room-id room) message neoment-notify--candidates)))))

(defun neoment-notify--title (room-name sender-name)
  "Return the notification title for SENDER-NAME in ROOM-NAME."
  (if (equal room-name sender-name)
      sender-name
    (format "[%s] %s" room-name sender-name)))

(defun neoment-notify--fallback-message (room)
  "Return the newest stored message of ROOM worth notifying, or nil.
It must be newer than the read receipt and the last notification."
  (let* ((receipt-ts (or (plist-get (neoment-room-read-receipt room) :ts) 0))
         (last (gethash (neoment-room-id room) neoment-notify--last-notified 0))
         (limit (max receipt-ts last))
         (user (neoment-client-user-id neoment--client)))
    (seq-find (lambda (msg)
                (and (not (neoment-message-is-state msg))
                     (not (equal (neoment-message-sender msg) user))
                     (> (or (neoment-message-timestamp msg) 0) limit)))
              (reverse (neoment-room-sorted-messages room)))))

(defun neoment-notify--send (title content)
  "Send a desktop notification with TITLE and CONTENT."
  (funcall neoment-desktop-notifications-handler title content))

(defun neoment-notify-room-counts-changed (room old-notifications
                                                old-highlights new-notifications
                                                new-highlights)
  "Notify about ROOM when its unread counts increased.
OLD-NOTIFICATIONS and OLD-HIGHLIGHTS are the counts before the sync,
NEW-NOTIFICATIONS and NEW-HIGHLIGHTS the counts after it."
  (neoment-notify--ensure-client)
  (when (or (> (or new-notifications 0) (or old-notifications 0))
            (> (or new-highlights 0) (or old-highlights 0)))
    (let* ((room-id (neoment-room-id room))
           (candidate (gethash room-id neoment-notify--candidates))
           (msg (or candidate (neoment-notify--fallback-message room)))
           (room-name (neoment-room-display-name room-id)))
      (unless (neoment-notify--suppressed-p room msg)
        (puthash room-id
                 (if msg (neoment-message-timestamp msg) (neoment--now-ms))
                 neoment-notify--last-notified)
        (if msg
            (neoment-notify--send
             (neoment-notify--title
              room-name (neoment-display-name (neoment-message-sender msg)))
             (or (neoment-message-content msg) ""))
          (neoment-notify--send room-name "New notification"))))))

;;;; Default handlers

(declare-function notifications-notify "notifications")
(declare-function w32-notification-notify "w32fns.c")

(defvar neoment-notify--dbus-warned nil
  "Non-nil once the missing D-Bus warning was shown.")

(defun neoment-notify--osascript-args (title content)
  "Return the `osascript' arguments that show TITLE and CONTENT.
The texts are passed as arguments, never interpolated in the script."
  (list "osascript"
        "-e" "on run argv"
        "-e" (concat "display notification (item 1 of argv) "
                     "with title \"Neoment\" subtitle (item 2 of argv)")
        "-e" "end run"
        content title))

(defun neoment-notify-default-desktop-handler (title content)
  "Show a desktop notification with TITLE and CONTENT."
  (pcase system-type
    ('darwin
     (make-process :name "neoment-notify"
                   :command (neoment-notify--osascript-args title content)
                   :noquery t
                   :buffer nil
                   :connection-type 'pipe))
    ('windows-nt
     (when (fboundp 'w32-notification-notify)
       (w32-notification-notify :title title :body content)))
    (_
     (if (and (require 'notifications nil t)
              (featurep 'dbusbind))
         (condition-case err
             (notifications-notify :app-name "Neoment" :title title
                                   :body content :urgency 'normal)
           (error
            (unless neoment-notify--dbus-warned
              (setq neoment-notify--dbus-warned t)
              (neoment-notify--message
               (format "Desktop notifications are unavailable: %s"
                       (error-message-string err))
               'warn))))
       (unless neoment-notify--dbus-warned
         (setq neoment-notify--dbus-warned t)
         (neoment-notify--message
          "Desktop notifications need D-Bus, which is not available" 'warn))))))

(provide 'neoment-notify)
;;; neoment-notify.el ends here
