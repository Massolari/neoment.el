;;; neoment-events.el --- Matrix event processing  -*- lexical-binding: t; -*-

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

;; Turns Matrix events into the room and message model: messages,
;; edits, replies, threads, redactions, reactions, receipts,
;; membership text and state.
;;
;; Nothing blocks: replied events and display names are fetched in the
;; background, and the room is marked changed when they arrive.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-notify)

(defconst neoment-events-attachment-types
  '(("m.image" . image) ("m.file" . file) ("m.audio" . audio)
    ("m.location" . location) ("m.video" . video))
  "Attachment type of each message msgtype.")

;;;; Helpers

(defun neoment-events--get (event &rest keys)
  "Follow KEYS into EVENT."
  (apply #'neoment-json-get event keys))

(defun neoment-events-mxc-p (url)
  "Return non-nil when URL is an mxc:// URL."
  (and (stringp url) (string-match-p "\\`mxc://[^/]+/." url) t))

(defun neoment-events-mxc-to-url (mxc &optional homeserver)
  "Return the authenticated download URL of MXC on HOMESERVER, or nil."
  (when (and (stringp mxc)
             (string-match "\\`mxc://\\([^/]+\\)/\\([^/?#]+\\)" mxc))
    (format "%s/_matrix/client/v1/media/download/%s/%s"
            (or homeserver (neoment-client-homeserver neoment--client))
            (match-string 1 mxc) (match-string 2 mxc))))

;;;; Display names

(defvar neoment-events--profile-requests (make-hash-table :test 'equal)
  "Users whose display name is being fetched.")

(defun neoment-events-fetch-display-name (user-id)
  "Fetch the display name of USER-ID in the background."
  (unless (gethash user-id neoment-events--profile-requests)
    (puthash user-id t neoment-events--profile-requests)
    (let ((client neoment--client))
      (neoment-api-request
       'get (format "/_matrix/client/v3/profile/%s/displayname"
                    (neoment-api-encode user-id))
       :callback
       (lambda (result)
         ;; After a reset the marker belongs to the new client.
         (when (eq client neoment--client)
           (remhash user-id neoment-events--profile-requests)
           (let ((name (neoment-json-get (plist-get result :ok) 'displayname)))
             ;; Remember failures too, so the name is not fetched again.
             (unless (neoment-has-display-name user-id)
               (puthash user-id (cons (and (stringp name) name) 0)
                        (neoment-client-display-names client)))
             (when (stringp name)
               (neoment-client-mark-room-changed nil)))))))))

(setq neoment-client-fetch-display-name-function
      #'neoment-events-fetch-display-name)

(add-hook 'neoment-client-reset-hook #'neoment-events-reset-caches)

(defun neoment-events--same-sender-p (a b)
  "Return non-nil when sender A is a string equal to sender B."
  (and (stringp a) (equal a b)))

;;;; Replies

(defvar neoment-events--reply-cache (make-hash-table :test 'equal)
  "Replied messages per \"ROOM EVENT\": plist (:message :waiting).")

(defun neoment-events--event-message-fields (event)
  "Return the message plist of the fields shown for EVENT."
  (let ((replacement (neoment-events--get event 'unsigned 'm.relations 'm.replace)))
    (neoment-events-event-to-message
     (if (and replacement
              (not (neoment-events--redacted-p event))
              (neoment-events--same-sender-p (alist-get 'sender replacement)
                                             (alist-get 'sender event)))
         replacement
       event))))

(defun neoment-events--fill-message (target source)
  "Copy the displayed fields of message SOURCE into TARGET."
  (setf (neoment-message-sender target) (neoment-message-sender source)
        (neoment-message-content target) (neoment-message-content source)
        (neoment-message-formatted-content target)
        (neoment-message-formatted-content source)
        (neoment-message-timestamp target) (neoment-message-timestamp source)
        (neoment-message-mentions target) (neoment-message-mentions source)
        (neoment-message-attachment target) (neoment-message-attachment source)
        (neoment-message-was-redacted target) (neoment-message-was-redacted source)
        (neoment-message-placeholder target) nil))

(defun neoment-events--reply-to (room event-id message)
  "Return the message EVENT-ID of ROOM that MESSAGE replies to.
When it is not known yet, return a placeholder and fetch the event."
  (let* ((room-id (neoment-room-id room))
         (key (concat room-id " " event-id))
         (entry (gethash key neoment-events--reply-cache)))
    (cond
     (entry
      (let ((replied (plist-get entry :message)))
        (when (neoment-message-placeholder replied)
          (plist-put entry :waiting (cons message (plist-get entry :waiting))))
        replied))
     (t
      (let ((placeholder (neoment-message--create :id event-id :placeholder t))
            (client neoment--client))
        (puthash key (list :message placeholder :waiting (list message))
                 neoment-events--reply-cache)
        (neoment-api-request
         'get (format "/_matrix/client/v3/rooms/%s/event/%s"
                      (neoment-api-encode room-id) (neoment-api-encode event-id))
         :callback
         (lambda (result)
           (when (eq client neoment--client)
             (let ((entry (gethash key neoment-events--reply-cache))
                   (data (plist-get result :ok))
                   (fetched nil))
               (when (and data (or (alist-get 'content data)
                                   (neoment-events--redacted-p data)))
                 (setq fetched (neoment-events--event-message-fields data)))
               (if fetched
                   (progn
                     (neoment-events--fill-message placeholder fetched)
                     (setf (neoment-message-id placeholder) event-id))
                 ;; The replied event is unavailable: show no reply.
                 (remhash key neoment-events--reply-cache)
                 (dolist (waiting (plist-get entry :waiting))
                   (when (eq (neoment-message-replying-to waiting) placeholder)
                     (setf (neoment-message-replying-to waiting) nil))))
               (when entry (plist-put entry :waiting nil))
               (neoment-client-mark-room-changed room-id))))))
      (plist-get (gethash key neoment-events--reply-cache) :message)))))

;;;; Messages

(defun neoment-events--thumbnail (content)
  "Return the thumbnail plist of CONTENT, or nil."
  (let ((info (alist-get 'info content)))
    (when (and (alist-get 'thumbnail_info info)
               (neoment-events-mxc-p (alist-get 'thumbnail_url info)))
      (let ((thumb (alist-get 'thumbnail_info info)))
        (list :type 'image :filename "thumbnail"
              :url (neoment-events-mxc-to-url (alist-get 'thumbnail_url info))
              :mxc-url (alist-get 'thumbnail_url info)
              :height (alist-get 'h thumb) :width (alist-get 'w thumb)
              :mimetype (alist-get 'mimetype thumb))))))

(defun neoment-events--geo-url (geo)
  "Return the map URL for the `geo:lat,lon' URI GEO, or nil.
Only the leading `geo:lat,lon' is read, so altitude and parameters are
ignored; anything else, including a non-string GEO, gives nil."
  (and (stringp geo)
       (string-match
        "\\`geo:\\(-?[0-9]+\\(?:\\.[0-9]+\\)?\\),\\(-?[0-9]+\\(?:\\.[0-9]+\\)?\\)\\(?:[,;]\\|\\'\\)"
        geo)
       (format "https://maps.google.com/?q=%s,%s"
               (match-string 1 geo) (match-string 2 geo))))

(defun neoment-events--attachment (content type)
  "Return the attachment plist of TYPE for the message CONTENT."
  (let ((info (alist-get 'info content)))
    (if (eq type 'location)
        (list :type 'location
              :url (neoment-events--geo-url (alist-get 'geo_uri content))
              :thumbnail (neoment-events--thumbnail content))
      (let* ((mxc (alist-get 'url content))
             (url (neoment-events-mxc-to-url mxc))
             (attachment (list :type type
                               :mimetype (alist-get 'mimetype info)
                               :mxc-url (and url mxc)
                               :url url
                               :filename (alist-get 'filename content))))
        (pcase type
          ('image (append attachment (list :height (alist-get 'h info)
                                           :width (alist-get 'w info))))
          ('file (append attachment (list :size (alist-get 'size info))))
          ('audio (append attachment (list :size (alist-get 'size info)
                                           :duration (alist-get 'duration info))))
          ('video (append attachment
                          (list :size (alist-get 'size info)
                                :duration (alist-get 'duration info)
                                :thumbnail (neoment-events--thumbnail content))))
          (_ attachment))))))

(defun neoment-events--content-attachment (content type)
  "Return the attachment of TYPE described by CONTENT, or nil.
A location needs a `geo_uri' of the form `geo:lat,lon'; every other TYPE
needs an mxc `url', so an edit cannot replace a working attachment with an
unusable one."
  (when (and type
             (if (eq type 'location)
                 (neoment-events--geo-url (alist-get 'geo_uri content))
               (neoment-events-mxc-p (alist-get 'url content))))
    (neoment-events--attachment content type)))

(defun neoment-events--redacted-p (event)
  "Return non-nil when EVENT arrived redacted (`unsigned.redacted_because')."
  (and (neoment-events--get event 'unsigned 'redacted_because) t))

(defun neoment-events-event-to-message (event)
  "Convert the message EVENT into a `neoment-message'.
Replies are not resolved here."
  (let* ((content (alist-get 'content event))
         (body (alist-get 'body content))
         (formatted (and (equal (alist-get 'format content) "org.matrix.custom.html")
                         (stringp (alist-get 'formatted_body content))
                         (not (equal (alist-get 'formatted_body content) "* "))
                         (alist-get 'formatted_body content)))
         (new-content (alist-get 'm.new_content content))
         (relates (alist-get 'm.relates_to content))
         (redacted (neoment-events--redacted-p event))
         (redacted-by (neoment-events--get event 'unsigned 'redacted_because 'sender))
         (type (or (cdr (assoc (alist-get 'msgtype content)
                               neoment-events-attachment-types))
                   (and (equal (alist-get 'type event) "m.sticker") 'image)))
         (thread-count (neoment-events--get event 'unsigned 'm.relations
                                            'm.thread 'count)))
    (when new-content
      (setq body (or (alist-get 'body new-content) body)
            formatted (or (alist-get 'formatted_body new-content) formatted)))
    (when redacted
      (setq body (if (or (null redacted-by)
                         (equal redacted-by (alist-get 'sender event)))
                     "[Redacted]"
                   (format "[Redacted by %s]" (neoment-display-name redacted-by)))
            formatted body))
    (neoment-message--create
     :id (alist-get 'event_id event)
     :sender (alist-get 'sender event)
     :content body
     :formatted-content formatted
     :timestamp (alist-get 'origin_server_ts event)
     :was-redacted redacted
     :age (neoment-events--get event 'unsigned 'age)
     :mentions (copy-sequence (neoment-events--get content 'm.mentions 'user_ids))
     :attachment (and (not redacted)
                      (neoment-events--content-attachment content type))
     :thread-root-id (and (equal (alist-get 'rel_type relates) "m.thread")
                          (alist-get 'event_id relates))
     :thread-replies-count (and (neoment-events--get event 'unsigned 'm.relations
                                                     'm.thread)
                                (or thread-count 0)))))

(defun neoment-events--state-message (event content)
  "Return a state message for EVENT with CONTENT."
  (neoment-message--create
   :id (alist-get 'event_id event)
   :sender (alist-get 'sender event)
   :content content
   :timestamp (alist-get 'origin_server_ts event)
   :age (neoment-events--get event 'unsigned 'age)
   :is-state t))

(defun neoment-events--history-may-set-name-p (user-id timestamp)
  "Return non-nil when a history name of USER-ID at TIMESTAMP may be stored.
History may fill in an unknown name, or replace one from an older
event.  A name stored with timestamp 0 came from `joined_members' or
the profile and is current, so history never replaces it."
  (let ((old (gethash user-id (neoment-client-display-names neoment--client))))
    (or (null (car old))
        (and (> (or (cdr old) 0) 0)
             (>= (or timestamp 0) (cdr old))))))

(defun neoment-events-member-message (event &optional is-history)
  "Return the membership state message of the `m.room.member' EVENT, or nil.
When IS-HISTORY is non-nil, EVENT comes from paginated history and its
display name never replaces a current one."
  (let* ((content (alist-get 'content event))
         (membership (alist-get 'membership content))
         (prev (neoment-events--get event 'unsigned 'prev_content))
         (prev-membership (alist-get 'membership prev))
         (sender (alist-get 'sender event))
         (target (alist-get 'state_key event))
         (by-other (not (equal sender target)))
         (s (neoment-display-name sender))
         (action
          (pcase membership
            ("join"
             (let ((name (alist-get 'displayname content))
                   (prev-name (alist-get 'displayname prev)))
               (cond
                ((not (equal prev-membership "join")) "joined the room")
                ((not (equal name prev-name))
                 (if name
                     (concat "changed display name"
                             (if prev-name (concat " from " prev-name) "")
                             " to " name)
                   "removed their display name"))
                ((not (equal (alist-get 'avatar_url content)
                             (alist-get 'avatar_url prev)))
                 "changed avatar picture")
                (t "joined the room"))))
            ("leave"
             (pcase prev-membership
               ("invite" (if by-other
                             (concat "had their invite to the room revoked by " s)
                           "rejected the invite to the room"))
               ((and "join" (guard by-other)) (concat "was removed from the room by " s))
               ("ban" (concat "was unbanned from the room by " s))
               ("knock" (if by-other
                            (concat "had their knock to the room denied by " s)
                          "retracted their knock to the room"))
               (_ "left the room")))
            ("invite"
             (pcase prev-membership
               ("leave" "was re-invited to the room")
               ("knock" (concat "had their knock to the room accepted by " s))
               (_ "was invited to the room")))
            ("ban"
             (if (equal prev-membership "join")
                 (concat "was kicked and banned from the room by " s)
               (concat "was banned from the room by " s)))
            ("knock"
             (if (equal prev-membership "invite")
                 "is re-knocking on the room"
               "is knocking on the room")))))
    (when action
      (when (and (stringp (alist-get 'displayname content))
                 (or (not is-history)
                     (neoment-events--history-may-set-name-p
                      target (alist-get 'origin_server_ts event))))
        (neoment-set-display-name target (alist-get 'displayname content)
                                  (or (alist-get 'origin_server_ts event) 0)))
      (neoment-events--state-message
       event (format "Membership: %s %s" (neoment-display-name target) action)))))

;;;; Pending events

(defun neoment-events--add-pending (room target-id event)
  "Keep EVENT of ROOM until the event TARGET-ID arrives.
An untracked room keeps no pending events: it does not keep the
target, and loading history when the room is opened delivers EVENT
again together with its target."
  (when (neoment-room-is-tracked room)
    (let ((id (alist-get 'event_id event))
          (pending (neoment-room-pending-events room)))
      (remhash id (neoment-room-events room))
      (puthash target-id
               (append (seq-remove (lambda (e) (equal (alist-get 'event_id e) id))
                                   (gethash target-id pending))
                       (list event))
               pending))))

;;;; Handlers

(defvar neoment-events--timeline-limited nil
  "Non-nil while applying a sync timeline that has a gap before it.
Other users' thread replies then count as unread activity.")

(defvar neoment-events--batch-ids nil
  "Hash set of ids of thread roots with a server count, or nil.
It holds the messages stored in the current batch that carry a positive
`unsigned.m.relations.m.thread.count'.  `neoment-events-handle-multiple'
binds it.  Such a count already includes the replies delivered in the
same batch.")

(defun neoment-events--handle-message (room event is-history)
  "Handle the message EVENT of ROOM.
IS-HISTORY is non-nil for paginated history.  Return non-nil when the
room changed.

A thread reply adds one to its loaded root's replies count unless the
root was stored in the same batch with a server count: that count
already includes the replies that existed when the server sent the
root.  A history reply's root is always in its own page or not loaded
yet, so history never increments a server count."
  (let* ((content (alist-get 'content event))
         (relates (alist-get 'm.relates_to content))
         (event-ts (or (alist-get 'origin_server_ts event) 0)))
    (cond
     ;; A server-redacted event has empty content but is still shown.
     ((not (or (neoment-events--redacted-p event)
               (stringp (alist-get 'body content))))
      nil)
     ;; Edit
     ((equal (alist-get 'rel_type relates) "m.replace")
      (let* ((target-id (alist-get 'event_id relates))
             (target (neoment-room-get-message room target-id))
             (new-content (alist-get 'm.new_content content)))
        (cond
         ((null target)
          (neoment-events--add-pending room target-id event)
          nil)
         ;; Only the original sender may edit, and state is never edited.
         ((or (neoment-message-is-state target)
              (not (neoment-events--same-sender-p
                    (alist-get 'sender event) (neoment-message-sender target))))
          nil)
         ;; A redacted message keeps its redaction text, whatever order
         ;; the edit and the redaction arrive in.
         ((neoment-message-was-redacted target) nil)
         ((and (neoment-message-edit-data target)
               (>= (plist-get (neoment-message-edit-data target) :timestamp)
                   event-ts))
          nil)
         (new-content
          (when-let* ((attachment (neoment-events--content-attachment
                                   new-content
                                   (cdr (assoc (alist-get 'msgtype new-content)
                                               neoment-events-attachment-types)))))
            (setf (neoment-message-attachment target) attachment))
          (setf (neoment-message-content target) (alist-get 'body new-content)
                (neoment-message-formatted-content target)
                (alist-get 'formatted_body new-content)
                (neoment-message-edit-data target)
                (list :id target-id :timestamp event-ts)
                (neoment-message-id target) (alist-get 'event_id event))
          t))))
     (t
      (let* ((message (neoment-events-event-to-message event))
             (in-reply-to (neoment-events--get relates 'm.in_reply_to 'event_id)))
        (when (and in-reply-to
                   (not (eq (alist-get 'is_falling_back relates) t)))
          (setf (neoment-message-replying-to message)
                (neoment-events--reply-to room in-reply-to message)))
        (neoment-room-add-message room message)
        (when-let* ((neoment-events--batch-ids)
                    (count (neoment-events--get event 'unsigned 'm.relations
                                                'm.thread 'count))
                    ((and (integerp count) (> count 0))))
          (puthash (alist-get 'event_id event) t neoment-events--batch-ids))
        (unless is-history
          (neoment-notify-add-candidate room message))
        (when-let* ((root-id (neoment-message-thread-root-id message))
                    ((not (and neoment-events--batch-ids
                               (gethash root-id neoment-events--batch-ids))))
                    (root (neoment-room-get-message room root-id)))
          (setf (neoment-message-thread-replies-count root)
                (1+ (or (neoment-message-thread-replies-count root) 0))))
        (when-let* ((replace (neoment-events--get event 'unsigned 'm.relations
                                                  'm.replace)))
          (neoment-events-handle room replace is-history))
        ;; A message redacted before it arrived is not new activity.
        (unless (neoment-message-was-redacted message)
          (let ((id (alist-get 'event_id event))
                (age (neoment-events--get event 'unsigned 'age)))
            (neoment-room-set-last-activity room event-ts id age)
            (unless (or (equal (neoment-message-sender message) (neoment-user-id))
                        ;; In a limited timeline, main-timeline messages
                        ;; before this reply may be missing, so count it.
                        (and (neoment-message-thread-root-id message)
                             (not neoment-events--timeline-limited)))
              (neoment-room-set-unread-activity room event-ts id age))))
        t)))))

(defun neoment-events--redact-message (room redacts event)
  "Replace the message REDACTS of ROOM by the text of redaction EVENT.
Return the message, or nil when ROOM does not store it."
  (let ((message (neoment-room-get-message room redacts))
        (reason (neoment-events--get event 'content 'reason)))
    (when message
      (let ((text (if (stringp reason)
                      (format "[Redacted: %s]" reason)
                    "[Redacted]")))
        (setf (neoment-message-content message) text
              (neoment-message-formatted-content message) text
              (neoment-message-was-redacted message) t
              (neoment-message-attachment message) nil
              ;; Drop any applied edit, so the message is not
              ;; shown as edited and keeps its original id.
              (neoment-message-edit-data message) nil
              (neoment-message-id message) redacts)))
    message))

(defun neoment-events--handle-redaction (room event)
  "Handle the redaction EVENT of ROOM.  Return non-nil when it changed."
  (let* ((redacts (or (alist-get 'redacts event)
                      (neoment-events--get event 'content 'redacts)))
         (target (gethash redacts (neoment-room-events room))))
    ;; Never notify with a redacted message, even in an untracked room
    ;; whose raw events are not kept.
    (neoment-notify-forget-candidate room redacts)
    (cond
     ((and (null target) (neoment-room-is-tracked room))
      (neoment-events--add-pending room redacts event)
      nil)
     ;; An untracked room keeps no raw events, only its last message:
     ;; redact that message when it is the target, or drop it when the
     ;; target is its applied edit, as a tracked room does.  The target
     ;; cannot arrive later, so nothing is kept pending.
     ((null target)
      (let ((message (neoment-room-find-message room redacts)))
        (cond
         ((or (null message) (neoment-message-was-redacted message)) nil)
         ((equal (neoment-message-effective-id message) redacts)
          (neoment-events--redact-message room redacts event)
          t)
         (t
          (remhash (neoment-message-effective-id message)
                   (neoment-room-messages room))
          t))))
     ((null (alist-get 'content target)) nil)
     ((member (alist-get 'type target) '("m.room.message" "m.sticker"))
      (let ((relates (neoment-events--get target 'content 'm.relates_to))
            (changed t))
        (if (and (equal (alist-get 'rel_type relates) "m.replace")
                 (alist-get 'event_id relates))
            (let* ((edited-id (alist-get 'event_id relates))
                   (edited (neoment-room-get-message room edited-id)))
              ;; Only an edit that was actually applied removes the
              ;; message: one from the message's own sender, never of a
              ;; state message, and never of a redacted message (whose
              ;; redaction placeholder must stay).
              (if (and edited
                       (not (neoment-message-is-state edited))
                       (not (neoment-message-was-redacted edited))
                       (neoment-events--same-sender-p
                        (alist-get 'sender target) (neoment-message-sender edited)))
                  (remhash edited-id (neoment-room-messages room))
                (setq changed nil)))
          (neoment-events--redact-message room redacts event))
        ;; The target event is now empty, so it is not redacted twice.
        (setf (alist-get 'content target) nil)
        changed))
     ((equal (alist-get 'type target) "m.reaction")
      (let* ((relates (neoment-events--get target 'content 'm.relates_to))
             (key (alist-get 'key relates))
             (message (neoment-room-get-message room (alist-get 'event_id relates))))
        (setf (alist-get 'content target) nil)
        (when (and message (assoc key (neoment-message-reactions message)))
          (let* ((reactions (neoment-message-reactions message))
                 (remaining (seq-remove (lambda (r) (equal (car r) redacts))
                                        (cdr (assoc key reactions)))))
            (setf (neoment-message-reactions message)
                  (if remaining
                      (mapcar (lambda (pair)
                                (if (equal (car pair) key) (cons key remaining) pair))
                              reactions)
                    (seq-remove (lambda (pair) (equal (car pair) key)) reactions))))
          t))))))

(defun neoment-events--receipt (room stored ts event-id)
  "Return the read receipt of ROOM on EVENT-ID sent at TS.
Record the event's own timestamp when it is loaded, or when STORED, the
current receipt, is on the same event and knows it.  It keeps a receipt
moved back to an older event from counting as read once that event is
no longer loaded."
  (let ((event-ts (or (neoment-room-event-timestamp room event-id)
                      (and (equal event-id (plist-get stored :event-id))
                           (plist-get stored :event-ts)))))
    (append (list :ts ts :event-id event-id)
            (and event-ts (list :event-ts event-ts)))))

(defun neoment-events--handle-receipt (room event)
  "Handle the `m.receipt' EVENT of ROOM."
  (let* ((user (neoment-user-id))
         (stored (neoment-room-read-receipt room))
         (last (or stored (list :ts 0 :event-id nil)))
         (newest (if (plist-get last :is-local) -1 (or (plist-get last :ts) 0)))
         (changed nil))
    (dolist (by-event (alist-get 'content event))
      (let ((event-id (symbol-name (car by-event))))
        (dolist (by-type (cdr by-event))
          (dolist (by-user (cdr by-type))
            (let* ((data (cdr by-user))
                   (thread (alist-get 'thread_id data))
                   (ts (alist-get 'ts data)))
              (when (and (equal (symbol-name (car by-user)) user)
                         (or (null thread) (equal thread "main")))
                (cond
                 ((and (numberp ts) (> ts newest))
                  (setq newest ts
                        last (neoment-events--receipt room stored ts event-id)
                        changed t))
                 ((and (not (numberp ts))
                       (not (equal event-id (plist-get last :event-id))))
                  (setq last (neoment-events--receipt
                              room stored (plist-get last :ts) event-id)
                        changed t)))))))))
    (when changed
      (neoment-room-set-read-receipt room last))
    changed))

(defun neoment-events--aliases (content)
  "Return the non-empty aliases of the `m.room.canonical_alias' CONTENT.
The canonical alias comes first, followed by the alternative aliases."
  (seq-filter (lambda (alias) (and (stringp alias) (not (string-empty-p alias))))
              (cons (alist-get 'alias content)
                    (append (alist-get 'alt_aliases content) nil))))

(defun neoment-events--handle-canonical-alias (room event &optional is-history)
  "Handle the `m.room.canonical_alias' EVENT of ROOM.
IS-HISTORY is non-nil for paginated history.  The state message is then
still added, but the aliases of ROOM are left unchanged.  The explicit
name of ROOM is never changed: the display name derives the alias."
  (let* ((content (alist-get 'content event))
         (aliases (neoment-events--aliases content))
         (sender (neoment-display-name (alist-get 'sender event))))
    (unless is-history
      (setf (neoment-room-aliases room) aliases))
    (neoment-room-add-message
     room (neoment-events--state-message
           event (if aliases
                     (format "%s set the room aliases to %s"
                             sender (string-join aliases ", "))
                   (format "%s removed the room aliases" sender))))
    t))

(defun neoment-events-handle (room event &optional is-history)
  "Apply EVENT to ROOM.
IS-HISTORY is non-nil for paginated history.  It turns off
notifications and keeps the current state of ROOM unchanged: state
events from history only add their timeline messages.  Return non-nil
when the room changed in a way that needs a re-render."
  (let ((id (alist-get 'event_id event))
        (type (alist-get 'type event))
        (content (alist-get 'content event)))
    (if (and id (gethash id (neoment-room-events room)))
        nil
      (when (and id (neoment-room-is-tracked room))
        (puthash id event (neoment-room-events room)))
      (pcase type
        ("m.fully_read"
         (setf (neoment-room-fully-read room) (alist-get 'event_id content))
         t)
        ("m.marked_unread"
         (setf (neoment-room-unread room) (eq (alist-get 'unread content) t))
         t)
        ("m.tag"
         (let ((tags (alist-get 'tags content)))
           (setf (neoment-room-is-favorite room) (and (assq 'm.favourite tags) t)
                 (neoment-room-is-lowpriority room)
                 (and (assq 'm.lowpriority tags) t)))
         t)
        ("m.receipt" (neoment-events--handle-receipt room event))
        ((or "m.room.message" "m.sticker")
         (neoment-events--handle-message room event is-history))
        ("m.room.name"
         (unless is-history
           (let ((name (alist-get 'name content)))
             (setf (neoment-room-name room)
                   (if (and (stringp name) (not (string-empty-p name)))
                       name
                     (neoment-room-id room)))))
         t)
        ("m.room.canonical_alias"
         (neoment-events--handle-canonical-alias room event is-history))
        ("m.room.topic"
         (unless is-history
           (setf (neoment-room-topic room) (or (alist-get 'topic content) "")))
         t)
        ("m.room.avatar"
         (unless is-history
           (setf (neoment-room-avatar-url room) (alist-get 'url content)))
         t)
        ("m.room.tombstone"
         (unless is-history
           (setf (neoment-room-tombstone room)
                 (list :body (or (alist-get 'body content)
                                 "This room has been upgraded")
                       :replacement-room (alist-get 'replacement_room content))))
         t)
        ("m.room.member"
         (let ((message (neoment-events-member-message event is-history))
               (membership (alist-get 'membership content))
               (target (alist-get 'state_key event)))
           (unless is-history
             (pcase membership
               ("join" (puthash target t (neoment-room-members room)))
               ((or "leave" "ban") (remhash target (neoment-room-members room)))))
           (when message
             (neoment-room-add-message room message)
             t)))
        ("m.room.redaction" (neoment-events--handle-redaction room event))
        ("m.space.child"
         (when (and content (not is-history))
           (neoment-room-add-space-child room (alist-get 'state_key event)))
         nil)
        ("m.reaction"
         (let ((relates (alist-get 'm.relates_to content)))
           (when (equal (alist-get 'rel_type relates) "m.annotation")
             (let* ((target-id (alist-get 'event_id relates))
                    (key (alist-get 'key relates))
                    (message (neoment-room-get-message room target-id)))
               (if (null message)
                   (progn (neoment-events--add-pending room target-id event) nil)
                 (let* ((reactions (neoment-message-reactions message))
                        (entry (cons id (alist-get 'sender event))))
                   (setf (neoment-message-reactions message)
                         (if (assoc key reactions)
                             (mapcar (lambda (pair)
                                       (if (equal (car pair) key)
                                           (cons key (append (cdr pair) (list entry)))
                                         pair))
                                     reactions)
                           (append reactions (list (list key entry))))))
                 t)))))
        ("m.typing"
         (setf (neoment-room-typing room) (alist-get 'user_ids content))
         t)
        (_ nil)))))

(defun neoment-events-handle-multiple (room events &optional is-history)
  "Apply EVENTS to ROOM in timestamp order, with their pending events.
IS-HISTORY is non-nil for paginated history.  Return non-nil when the
room changed.  Recursive calls for pending events share the outer
call's `neoment-events--batch-ids'."
  (let ((changed nil)
        (neoment-events--batch-ids (or neoment-events--batch-ids
                                       (make-hash-table :test 'equal))))
    (dolist (event (sort (copy-sequence events)
                         (lambda (a b)
                           (< (or (alist-get 'origin_server_ts a) 0)
                              (or (alist-get 'origin_server_ts b) 0)))))
      (when (neoment-events-handle room event is-history)
        (setq changed t))
      (let* ((id (alist-get 'event_id event))
             (pending (and id (gethash id (neoment-room-pending-events room)))))
        (when pending
          (remhash id (neoment-room-pending-events room))
          (when (neoment-events-handle-multiple room pending is-history)
            (setq changed t)))))
    changed))

(defun neoment-events-handle-invited (room event)
  "Apply the stripped state EVENT to the invited ROOM."
  (let ((content (alist-get 'content event)))
    (pcase (alist-get 'type event)
      ("m.room.name"
       (let ((name (alist-get 'name content)))
         (when (and (stringp name) (not (string-empty-p name)))
           (setf (neoment-invited-room-name room) name)))
       t)
      ("m.room.canonical_alias"
       (let ((alias (car (neoment-events--aliases content))))
         (setf (neoment-invited-room-alias room) alias))
       t)
      ("m.room.topic"
       (setf (neoment-invited-room-topic room) (or (alist-get 'topic content) ""))
       t)
      ("m.room.avatar"
       (setf (neoment-invited-room-avatar-url room) (alist-get 'url content))
       t)
      ("m.room.member"
       (when (equal (alist-get 'membership content) "join")
         (let ((id (alist-get 'state_key event)))
           (setf (neoment-invited-room-members room)
                 (append (assoc-delete-all id (neoment-invited-room-members room))
                         (list (cons id (or (alist-get 'displayname content) id))))))
         t))
      (_ nil))))

(defun neoment-events-reset-caches ()
  "Forget the cached replies and profile requests."
  (clrhash neoment-events--reply-cache)
  (clrhash neoment-events--profile-requests))

(provide 'neoment-events)
;;; neoment-events.el ends here
