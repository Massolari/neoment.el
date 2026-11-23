;;; neoment-sync.el --- The sync loop  -*- lexical-binding: t; -*-

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

;; A continuous /sync long-poll loop.  Each request's callback
;; processes the response and schedules the next request, so there is
;; never more than one request in flight.  Processing errors are
;; reported as sync errors and never stop the loop.

;;; Code:

(require 'cl-lib)
(require 'neoment-config)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-events)
(require 'neoment-notify)
(require 'neoment-storage)

(defconst neoment-sync-filter
  "{\"room\":{\"state\":{\"lazy_load_members\":true},\"timeline\":{\"limit\":1,\"lazy_load_members\":true}}}"
  "Filter sent with every sync request.")

(defconst neoment-sync-client-timeout 45
  "Seconds after which a sync request is abandoned.")

(defconst neoment-sync-save-every 10
  "The session is saved after every this many successful syncs.")

(defvar neoment-sync-after-functions nil
  "Functions called with the list of changed room ids after each sync.")

(defvar neoment-sync-acknowledge-function #'neoment-sync--acknowledge
  "Function called with the text of a removal notice to acknowledge.")

(defvar neoment-sync--running nil
  "Non-nil while the sync loop should keep running.")

(defvar neoment-sync--in-flight nil
  "Non-nil while a sync request is in flight.")

(defvar neoment-sync--process nil
  "The process of the sync request in flight, if any.")

(defvar neoment-sync--generation 0
  "Counter bumped when the loop stops, to drop late responses.")

(defvar neoment-sync--status (list :kind 'stopped :last-sync nil :current-count 0)
  "Sync status: plist (:kind :last-sync :current-count).")

(defvar neoment-sync--error-count 0
  "Number of consecutive sync errors.")

(defvar neoment-sync--timer nil
  "Timer of the next scheduled sync.")

(defvar neoment-sync--status-client nil
  "The client `neoment-sync--status' belongs to.")

(defun neoment-sync-status ()
  "Return the sync status plist (:kind :last-sync :current-count).
The status starts over when the client changes."
  (unless (eq neoment-sync--status-client neoment--client)
    (setq neoment-sync--status-client neoment--client)
    (neoment-sync-reset))
  neoment-sync--status)

(defun neoment-sync--set-status (&rest props)
  "Update the sync status with PROPS."
  (setq neoment-sync--status (copy-sequence (neoment-sync-status)))
  (cl-loop for (k v) on props by #'cddr
           do (setq neoment-sync--status (plist-put neoment-sync--status k v))))

(defun neoment-sync--acknowledge (text)
  "Show TEXT in a dialog the user must acknowledge."
  (if (display-graphic-p)
      (message-box "%s" text)
    (read-char-choice (concat text " (press o) ") '(?o ?O ?\r ?\n ?\s))))

;;;; Processing

(defun neoment-sync--room-key (key)
  "Return KEY (a parsed JSON key) as a string."
  (if (symbolp key) (symbol-name key) key))

(defun neoment-sync--process-invited (invites)
  "Process the INVITES of a sync response.  Return changed room ids."
  (let (updated)
    (dolist (pair invites)
      (let* ((room-id (neoment-sync--room-key (car pair)))
             (room (neoment-get-invited-room room-id))
             (changed nil))
        (dolist (event (neoment-json-get (cdr pair) 'invite_state 'events))
          (when (neoment-events-handle-invited room event)
            (setq changed t)))
        (when changed (push room-id updated))))
    updated))

(defun neoment-sync--process-joined (joined)
  "Process the JOINED rooms of a sync response.  Return changed room ids."
  (let (updated)
    (dolist (pair joined)
      (let* ((room-id (neoment-sync--room-key (car pair)))
             (data (cdr pair))
             (room (neoment-get-room room-id))
             (changed nil)
             (summary (alist-get 'summary data))
             (counts (alist-get 'unread_notifications data)))
        (remhash room-id (neoment-client-invited-rooms neoment--client))
        (dolist (event (neoment-json-get data 'account_data 'events))
          (when (neoment-events-handle room event) (setq changed t)))
        (when (neoment-events-handle-multiple
               room (neoment-json-get data 'timeline 'events))
          (setq changed t))
        (when (neoment-events-handle-multiple
               room (neoment-json-get data 'state 'events))
          (setq changed t))
        (when (alist-get 'm.joined_member_count summary)
          (setf (neoment-room-joined-member-count room)
                (alist-get 'm.joined_member_count summary)))
        (when summary
          (let ((old (neoment-room-summary room)))
            (setf (neoment-room-summary room)
                  (list :heroes (if (assq 'm.heroes summary)
                                    (alist-get 'm.heroes summary)
                                  (plist-get old :heroes))
                        :joined (or (alist-get 'm.joined_member_count summary)
                                    (plist-get old :joined))
                        :invited (or (alist-get 'm.invited_member_count summary)
                                     (plist-get old :invited))))))
        (when (neoment-events-handle-multiple
               room (neoment-json-get data 'ephemeral 'events))
          (setq changed t))
        (when counts
          (let ((old-n (neoment-room-unread-notifications room))
                (old-h (neoment-room-unread-highlights room))
                (new-n (or (alist-get 'notification_count counts) 0))
                (new-h (or (alist-get 'highlight_count counts) 0)))
            (unless (and (eql old-n new-n) (eql old-h new-h))
              (setq changed t))
            (setf (neoment-room-unread-notifications room) new-n
                  (neoment-room-unread-highlights room) new-h)
            (neoment-notify-room-counts-changed room old-n old-h new-n new-h)))
        (when changed (push room-id updated))))
    updated))

(defun neoment-sync--removal-event (events user-id)
  "Return the last leave or ban of USER-ID in EVENTS, or nil."
  (seq-find (lambda (e)
              (and (equal (alist-get 'type e) "m.room.member")
                   (equal (alist-get 'state_key e) user-id)
                   (member (neoment-json-get e 'content 'membership)
                           '("leave" "ban"))))
            (reverse events)))

(defun neoment-sync--process-left (left initial)
  "Process the LEFT rooms of a sync response.
INITIAL is non-nil for the first sync.  Return the removed room ids."
  (let ((user (neoment-user-id))
        removed)
    (dolist (pair left)
      (let ((room-id (neoment-sync--room-key (car pair)))
            (data (cdr pair)))
        (when (or (neoment-has-room room-id) (neoment-has-invited-room room-id))
          (let ((event (or (neoment-sync--removal-event
                            (neoment-json-get data 'timeline 'events) user)
                           (neoment-sync--removal-event
                            (neoment-json-get data 'state 'events) user)))
                (name (neoment-room-display-name room-id)))
            (neoment-remove-room room-id)
            (push room-id removed)
            (when (and (not initial) event
                       (not (equal (alist-get 'sender event) user)))
              (let ((message (neoment-events-member-message event)))
                (when message
                  (neoment--defer
                   neoment-sync-acknowledge-function
                   (format "Room: %s\n\n%s\n\nPress OK to acknowledge."
                           name (neoment-message-content message))))))))))
    removed))

(defun neoment-sync--process-account-data (events)
  "Process the global account data EVENTS.  Return changed room ids."
  (let (updated)
    (dolist (event events)
      (pcase (alist-get 'type event)
        ("m.direct"
         (dolist (pair (alist-get 'content event))
           (dolist (room-id (cdr pair))
             (let ((room (neoment-has-room room-id)))
               (when room
                 (setf (neoment-room-is-direct room) t)
                 (push room-id updated))))))
        ("m.push_rules"
         (setf (neoment-client-push-rules neoment--client)
               (alist-get 'content event)))))
    updated))

(defun neoment-sync--process-presence (events)
  "Process the presence EVENTS."
  (dolist (event events)
    (when (equal (alist-get 'type event) "m.presence")
      (let ((content (alist-get 'content event)))
        (neoment-set-presence (alist-get 'sender event)
                              (list :presence (alist-get 'presence content)
                                    :last-active-ago (alist-get 'last_active_ago content)
                                    :status-msg (alist-get 'status_msg content)
                                    :currently-active
                                    (eq (alist-get 'currently_active content) t)))))))

(defun neoment-sync-process (data)
  "Apply the sync response DATA to the current client.
Return the ids of the rooms that changed."
  (let* ((gc-cons-threshold (max gc-cons-threshold (* 64 1024 1024)))
         (initial (null (neoment-client-sync-token neoment--client)))
         (neoment-notify--initial-sync-p initial)
         (rooms (alist-get 'rooms data))
         updated)
    (neoment-notify-clear-candidates)
    (setq updated (append (neoment-sync--process-invited (alist-get 'invite rooms))
                          (neoment-sync--process-joined (alist-get 'join rooms))
                          (neoment-sync--process-left (alist-get 'leave rooms) initial)
                          (neoment-sync--process-account-data
                           (neoment-json-get data 'account_data 'events))))
    (neoment-sync--process-presence (neoment-json-get data 'presence 'events))
    (neoment-notify-clear-candidates)
    (when (alist-get 'next_batch data)
      (setf (neoment-client-sync-token neoment--client) (alist-get 'next_batch data)))
    (delete-dups updated)))

;;;; The loop

(defun neoment-sync--schedule (delay)
  "Run the next sync after DELAY seconds."
  (when (timerp neoment-sync--timer)
    (cancel-timer neoment-sync--timer))
  (setq neoment-sync--timer (run-at-time delay nil #'neoment-sync--run)))

(defun neoment-sync--query ()
  "Return the query parameters of the next sync request."
  (let ((token (neoment-client-sync-token neoment--client)))
    `((filter . ,neoment-sync-filter)
      (full_state . ,(and (null token) "true"))
      (set_presence . ,(or (neoment-client-desired-presence neoment--client)
                           "online"))
      (since . ,token)
      (timeout . "30000"))))

(defun neoment-sync--run ()
  "Send the next sync request, unless one is in flight."
  (setq neoment-sync--timer nil)
  (when (and neoment-sync--running (not neoment-sync--in-flight)
             (neoment-logged-in-p))
    (let ((client neoment--client)
          (generation neoment-sync--generation))
      (setq neoment-sync--in-flight t)
      (neoment-sync--set-status :kind 'syncing)
      (setq neoment-sync--process
            (neoment-api-request
             'get "/_matrix/client/v3/sync"
             :query (neoment-sync--query)
             :timeout neoment-sync-client-timeout
             :callback (lambda (result)
                         (neoment-sync--handle client generation result)))))))

(defun neoment-sync--error (message)
  "Report the sync error MESSAGE and schedule a retry."
  (if (< neoment-sync--error-count 3)
      (progn
        (cl-incf neoment-sync--error-count)
        (neoment-notify--error (format "Error syncing: %s\nRetrying..." message)))
    (neoment-notify--error (format "Error syncing: %s" message)))
  (neoment-sync--schedule 1))

(defun neoment-sync--handle (client generation result)
  "Handle the sync RESULT of CLIENT for the loop GENERATION."
  (when (and (= generation neoment-sync--generation)
             (eq client neoment--client))
    (setq neoment-sync--in-flight nil
          neoment-sync--process nil)
    (neoment-sync--set-status :kind 'stopped)
    (if (plist-get result :error)
        (neoment-sync--error (neoment-http-error-message (plist-get result :error)))
      (let ((updated nil) (failure nil))
        (condition-case err
            (setq updated (neoment-sync-process (plist-get result :ok)))
          (error (setq failure (error-message-string err))))
        (if failure
            (neoment-sync--error failure)
          (setq neoment-sync--error-count 0)
          (let ((count (1+ (or (plist-get neoment-sync--status :current-count) 0))))
            (neoment-sync--set-status :last-sync (truncate (float-time))
                                      :current-count count)
            (when (zerop (% count neoment-sync-save-every))
              (neoment-storage-save-session)))
          (run-hook-with-args 'neoment-sync-after-functions updated)
          (neoment-sync--schedule 0))))))

;;;###autoload
(defun neoment-sync-start ()
  "Start the sync loop."
  (interactive)
  (setq neoment-sync--running t)
  (neoment-notify--message "Synchronization started")
  (neoment-sync--run))

;;;###autoload
(defun neoment-sync-stop (&optional silent)
  "Stop the sync loop.
With SILENT, do not show a message."
  (interactive)
  (setq neoment-sync--running nil)
  (cl-incf neoment-sync--generation)
  (when (timerp neoment-sync--timer)
    (cancel-timer neoment-sync--timer))
  (setq neoment-sync--timer nil)
  (when (processp neoment-sync--process)
    (delete-process neoment-sync--process))
  (setq neoment-sync--process nil
        neoment-sync--in-flight nil
        neoment-sync--error-count 0)
  (neoment-sync--set-status :kind 'stopped)
  (unless silent
    (neoment-notify--message "Synchronization stopped")))

(defun neoment-sync-reset ()
  "Forget the sync status of the previous session."
  (setq neoment-sync--status (list :kind 'stopped :last-sync nil :current-count 0)))

(provide 'neoment-sync)
;;; neoment-sync.el ends here
