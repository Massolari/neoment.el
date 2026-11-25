;;; neoment-client.el --- Client state for Neoment  -*- lexical-binding: t; -*-

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

;; The in-memory model: the client, its rooms, invited rooms, messages,
;; display names and presence, plus the rules derived from them.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst neoment-default-device-id "emacs-matrix-client"
  "Device id used when the server does not assign one.")

;;;; Structures

(cl-defstruct (neoment-client (:constructor neoment-client--create)
                              (:copier nil))
  "A Matrix client session."
  homeserver
  (device-id neoment-default-device-id)
  user-id access-token refresh-token expires-at
  refresh                               ; plist or nil
  sync-token
  (rooms (make-hash-table :test 'equal))
  (invited-rooms (make-hash-table :test 'equal))
  (display-names (make-hash-table :test 'equal)) ; user -> (NAME . TS)
  (presence (make-hash-table :test 'equal))      ; user -> plist
  desired-presence
  push-rules
  (space-cache (make-hash-table :test 'equal)))

(cl-defstruct (neoment-room (:constructor neoment-room--create)
                            (:copier nil))
  "A joined room."
  id name aliases (topic "") tombstone
  (members (make-hash-table :test 'equal))
  (events (make-hash-table :test 'equal))
  (pending-events (make-hash-table :test 'equal))
  (messages (make-hash-table :test 'equal))
  prev-batch                            ; nil, a token string, or `end'
  last-activity                         ; plist (:timestamp :event-id :age)
  is-direct is-favorite is-lowpriority
  space-rooms typing fully-read
  (unread-notifications 0) (unread-highlights 0)
  joined-member-count unread
  read-receipt                          ; plist (:event-id :ts :is-local)
  avatar-url is-tracked
  summary                               ; plist (:heroes :joined :invited)
  (sender-faces (make-hash-table :test 'equal)))

(cl-defstruct (neoment-invited-room (:constructor neoment-invited-room--create)
                                    (:copier nil))
  "A room the user was invited to."
  id name (topic "") members avatar-url)

(cl-defstruct (neoment-message (:constructor neoment-message--create)
                               (:copier copy-neoment-message))
  "A message shown in a room timeline."
  id sender content formatted-content timestamp age
  edit-data                             ; plist (:id :timestamp)
  was-redacted mentions
  replying-to                           ; `neoment-message' or nil
  reactions                             ; alist KEY -> list of (EVENT-ID . SENDER)
  attachment                            ; plist
  is-state thread-root-id thread-replies-count
  placeholder)

;;;; The current client

(defvar neoment--client nil
  "The current `neoment-client', or nil.")

(defvar-local neoment--room-id nil
  "Id of the room shown in the current buffer.")

(defvar-local neoment--thread-root-id nil
  "Id of the thread root shown in the current thread buffer.")

(defvar neoment-client-room-changed-functions nil
  "Functions called with a room id when that room changed.")

(defvar neoment-client-fetch-display-name-function nil
  "Function called with a user id to fetch its display name.")

(defun neoment--defer (function &rest args)
  "Call FUNCTION with ARGS from the command loop, outside process callbacks."
  (apply #'run-at-time 0 nil function args))

(defun neoment--now-ms ()
  "Return the current time in milliseconds."
  (truncate (* 1000 (float-time))))

(defun neoment-client-reset (homeserver)
  "Start a new client for HOMESERVER, keeping only the device id."
  (let ((device-id (and neoment--client
                        (neoment-client-device-id neoment--client))))
    (setq neoment--client (neoment-client--create
                           :homeserver homeserver
                           :device-id (or device-id
                                          neoment-default-device-id)))))

(defun neoment-logged-in-p ()
  "Return non-nil when there is an active session."
  (and neoment--client
       (neoment-client-access-token neoment--client)
       (neoment-client-user-id neoment--client)
       t))

(defun neoment-user-id ()
  "Return the current user id, or nil."
  (and neoment--client (neoment-client-user-id neoment--client)))

(defun neoment-client-mark-room-changed (room-id)
  "Signal that the room ROOM-ID changed."
  (run-hook-with-args 'neoment-client-room-changed-functions room-id))

;;;; Rooms

(defun neoment-get-room (room-id)
  "Return the room ROOM-ID, creating it when missing."
  (let ((rooms (neoment-client-rooms neoment--client)))
    (or (gethash room-id rooms)
        (puthash room-id (neoment-room--create :id room-id :name room-id)
                 rooms))))

(defun neoment-has-room (room-id)
  "Return the room ROOM-ID when it is a joined room."
  (and neoment--client
       (gethash room-id (neoment-client-rooms neoment--client))))

(defun neoment-get-invited-room (room-id)
  "Return the invited room ROOM-ID, creating it when missing."
  (let ((rooms (neoment-client-invited-rooms neoment--client)))
    (or (gethash room-id rooms)
        (puthash room-id (neoment-invited-room--create :id room-id
                                                       :name room-id)
                 rooms))))

(defun neoment-has-invited-room (room-id)
  "Return the invited room ROOM-ID, or nil."
  (and neoment--client
       (gethash room-id (neoment-client-invited-rooms neoment--client))))

(defun neoment-remove-room (room-id)
  "Forget the joined or invited room ROOM-ID."
  (remhash room-id (neoment-client-rooms neoment--client))
  (remhash room-id (neoment-client-invited-rooms neoment--client))
  (clrhash (neoment-client-space-cache neoment--client)))

(defun neoment-rooms ()
  "Return the list of joined rooms."
  (and neoment--client
       (hash-table-values (neoment-client-rooms neoment--client))))

(defun neoment-invited-rooms ()
  "Return the list of invited rooms."
  (and neoment--client
       (hash-table-values (neoment-client-invited-rooms neoment--client))))

;;;; Messages

(defun neoment-message< (a b)
  "Return non-nil when message A sorts before message B.
Messages sort by timestamp, then by larger age first."
  (let ((ta (or (neoment-message-timestamp a) 0))
        (tb (or (neoment-message-timestamp b) 0)))
    (if (= ta tb)
        (> (or (neoment-message-age a) 0) (or (neoment-message-age b) 0))
      (< ta tb))))

(defun neoment-room-sorted-messages (room)
  "Return the messages of ROOM in timeline order."
  (sort (hash-table-values (neoment-room-messages room)) #'neoment-message<))

(defun neoment-room-last-message (room)
  "Return the newest non-state message of ROOM, or nil."
  (let (best)
    (maphash (lambda (_ m)
               (when (and (not (neoment-message-is-state m))
                          (or (null best) (neoment-message< best m)))
                 (setq best m)))
             (neoment-room-messages room))
    best))

(defun neoment-room-get-message (room id)
  "Return the message of ROOM stored under ID, or nil."
  (gethash id (neoment-room-messages room)))

(defun neoment-room-find-message (room id)
  "Return the message of ROOM whose id or original id is ID."
  (or (gethash id (neoment-room-messages room))
      (seq-find (lambda (m) (equal (neoment-message-id m) id))
                (hash-table-values (neoment-room-messages room)))))

(defun neoment-room-add-message (room message)
  "Add MESSAGE to ROOM.
An untracked room only keeps its newest non-state message."
  (let ((messages (neoment-room-messages room)))
    (cond
     ((neoment-room-is-tracked room)
      (puthash (neoment-message-effective-id message) message messages))
     ((neoment-message-is-state message))
     (t
      (let ((last (neoment-room-last-message room)))
        (when (or (null last) (neoment-message< last message))
          (clrhash messages)
          (puthash (neoment-message-effective-id message) message messages)))))
    message))

(defun neoment-room-set-tracked (room tracked)
  "Set whether ROOM is TRACKED (open in a buffer)."
  (if tracked
      (clrhash (neoment-room-messages room))
    (let ((last (neoment-room-last-message room)))
      (clrhash (neoment-room-messages room))
      (when last
        (puthash (neoment-message-effective-id last) last
                 (neoment-room-messages room))))
    (clrhash (neoment-room-events room))
    (clrhash (neoment-room-pending-events room))
    (setf (neoment-room-prev-batch room) nil))
  (setf (neoment-room-is-tracked room) tracked)
  room)

(defun neoment-message-effective-id (message)
  "Return the id used to reply to or react to MESSAGE."
  (or (plist-get (neoment-message-edit-data message) :id)
      (neoment-message-id message)))

(defun neoment-room-set-last-activity (room timestamp event-id age)
  "Update the last activity of ROOM with TIMESTAMP, EVENT-ID and AGE."
  (let* ((last (neoment-room-last-activity room))
         (last-ts (or (plist-get last :timestamp) 0))
         (last-age (or (plist-get last :age) 0))
         (age (or age 0)))
    (when (or (< last-ts timestamp)
              (and last (= last-ts timestamp) (> last-age age)))
      (setf (neoment-room-last-activity room)
            (list :timestamp timestamp :event-id event-id :age age)))))

;;;; Display names and presence

(defun neoment-set-display-name (user-id name timestamp)
  "Record NAME as the display name of USER-ID at TIMESTAMP.
Older names never replace newer ones."
  (let* ((table (neoment-client-display-names neoment--client))
         (old (gethash user-id table)))
    (when (or (null old) (>= (or timestamp 0) (or (cdr old) 0)))
      (puthash user-id (cons name (or timestamp 0)) table))))

(defun neoment-has-display-name (user-id)
  "Return non-nil when the display name of USER-ID is known."
  (and neoment--client
       (car (gethash user-id (neoment-client-display-names neoment--client)))
       t))

(defun neoment-display-name (user-id)
  "Return the display name of USER-ID, or USER-ID itself.
An unknown name is fetched in the background."
  (let ((entry (and neoment--client user-id
                    (gethash user-id
                             (neoment-client-display-names neoment--client)))))
    (cond
     ((car entry))
     (t
      (when (and user-id neoment-client-fetch-display-name-function
                 (not entry))
        (funcall neoment-client-fetch-display-name-function user-id))
      user-id))))

(defun neoment-set-presence (user-id presence)
  "Record PRESENCE (a plist) for USER-ID."
  (puthash user-id presence (neoment-client-presence neoment--client)))

(defun neoment-get-presence (user-id)
  "Return the presence plist of USER-ID, or nil."
  (and neoment--client
       (gethash user-id (neoment-client-presence neoment--client))))

;;;; Derived room rules

(defun neoment--any-room (room-id)
  "Return the joined or invited room ROOM-ID, or nil."
  (or (neoment-has-room room-id) (neoment-has-invited-room room-id)))

(defun neoment-room-members-list (room)
  "Return the member ids of ROOM, in insertion order."
  (let (ids)
    (maphash (lambda (k _) (push k ids)) (neoment-room-members room))
    (nreverse ids)))

(defun neoment--display-name-from-members (member-names)
  "Return a room name made of MEMBER-NAMES (other members only)."
  (let* ((n (length member-names))
         (shown (seq-take member-names 2))
         (name (string-join shown ", ")))
    (when (> n 2)
      (setq name (format "%s and %d others" name (- n 2))))
    name))

(defun neoment--name-from-heroes (summary)
  "Return a room name built from the heroes SUMMARY, or nil."
  (let* ((heroes (plist-get summary :heroes))
         (joined (or (plist-get summary :joined) 0))
         (invited (or (plist-get summary :invited) 0))
         (total (+ joined invited))
         (names (mapcar #'neoment-display-name heroes)))
    ;; The empty room case is checked first: with one member or less,
    ;; any number of heroes would otherwise satisfy the first rule.
    (cond
     ((<= total 1)
      (pcase (length names)
        (0 "Empty room")
        (1 (format "Empty room (was %s)" (car names)))
        (n (format "Empty room (was %s and %d others)" (car names) (1- n)))))
     ((and names (>= (length names) (1- total)))
      (string-join names ", "))
     (names
      (format "%s and %d others"
              (string-join (seq-take names 2) ", ")
              (- total (length (seq-take names 2))))))))

(defun neoment-room-display-name (room-id)
  "Return the display name of the joined or invited room ROOM-ID."
  (let ((room (neoment--any-room room-id))
        (user (neoment-user-id)))
    (cond
     ((null room) room-id)
     ((neoment-invited-room-p room)
      (if (equal (neoment-invited-room-name room) room-id)
          (let ((names (delq nil
                             (mapcar (lambda (pair)
                                       (unless (equal (car pair) user)
                                         (cdr pair)))
                                     (neoment-invited-room-members room)))))
            (if names (neoment--display-name-from-members names) "Empty room"))
        (neoment-invited-room-name room)))
     ((not (equal (neoment-room-name room) room-id))
      (neoment-room-name room))
     ((and (neoment-room-summary room)
           (neoment--name-from-heroes (neoment-room-summary room))))
     (t
      (let ((names (mapcar #'neoment-display-name
                           (seq-remove (lambda (id) (equal id user))
                                       (neoment-room-members-list room)))))
        (if names (neoment--display-name-from-members names) "Empty room"))))))

(defun neoment-room-is-space (room-id)
  "Return non-nil when ROOM-ID is a space."
  (let ((room (neoment-has-room room-id)))
    (and room (neoment-room-space-rooms room) t)))

(defun neoment-room-space (room-id)
  "Return the first space room that lists ROOM-ID as a child, or nil."
  (let* ((cache (neoment-client-space-cache neoment--client))
         (cached (gethash room-id cache 'none)))
    (if (not (eq cached 'none))
        (and cached (neoment-has-room cached))
      (let ((space (seq-find (lambda (r)
                               (member room-id (neoment-room-space-rooms r)))
                             (neoment-rooms))))
        (puthash room-id (and space (neoment-room-id space)) cache)
        space))))

(defun neoment-room-space-name (room-id)
  "Return the display name of the space of ROOM-ID, or nil."
  (let ((space (neoment-room-space room-id)))
    (and space (neoment-room-display-name (neoment-room-id space)))))

(defun neoment-room-display-name-with-space (room-id)
  "Return \"<Space>/<Room>\" for ROOM-ID, or just the room name."
  (let ((name (neoment-room-display-name room-id))
        (space (neoment-room-space-name room-id)))
    (if (and space (not (string-empty-p space)))
        (format "%s/%s" space name)
      name)))

(defun neoment-room-add-space-child (room child-id)
  "Add CHILD-ID to the children of the space ROOM."
  (unless (member child-id (neoment-room-space-rooms room))
    (setf (neoment-room-space-rooms room)
          (append (neoment-room-space-rooms room) (list child-id))))
  (clrhash (neoment-client-space-cache neoment--client)))

(defun neoment-room-is-member-p (room-id &optional user-id)
  "Return non-nil when USER-ID (default: the user) is a member of ROOM-ID."
  (let ((room (neoment-has-room room-id)))
    (and room
         (gethash (or user-id (neoment-user-id)) (neoment-room-members room))
         t)))

(defun neoment-user-rooms ()
  "Return the ids of the rooms the user belongs to or is invited to."
  (append (mapcar #'neoment-room-id
                  (seq-filter (lambda (r)
                                (neoment-room-is-member-p (neoment-room-id r)))
                              (neoment-rooms)))
          (mapcar #'neoment-invited-room-id (neoment-invited-rooms))))

(defun neoment-room-unread-p (room)
  "Return non-nil when ROOM is unread."
  (or (eq (neoment-room-unread room) t)
      (let ((last-id (plist-get (neoment-room-last-activity room) :event-id)))
        (and last-id
             (not (equal last-id
                         (plist-get (neoment-room-read-receipt room) :event-id)))
             (not (equal last-id (neoment-room-fully-read room)))))))

(defun neoment-room-set-read-receipt (room receipt)
  "Set the read RECEIPT of ROOM.
When ROOM has no fully read marker, use the receipt's event."
  (setf (neoment-room-read-receipt room) receipt)
  (unless (neoment-room-fully-read room)
    (setf (neoment-room-fully-read room) (plist-get receipt :event-id))))

(defun neoment-room-other-members (room)
  "Return an alist (ID . NAME) of the members of ROOM except the user."
  (let ((user (neoment-user-id)))
    (mapcar (lambda (id) (cons id (neoment-display-name id)))
            (seq-remove (lambda (id) (equal id user))
                        (neoment-room-members-list room)))))

(provide 'neoment-client)
;;; neoment-client.el ends here
