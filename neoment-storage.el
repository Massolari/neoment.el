;;; neoment-storage.el --- Files on disk for Neoment  -*- lexical-binding: t; -*-

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

;; Where Neoment keeps its files, and the JSON helpers to read and write
;; them:
;;
;; - neoment/data.json            session credentials (mode 0600)
;; - neoment/ui_state.json        fold state of the room list
;; - neoment/oauth_clients.json   OAuth client ids per issuer
;; - neoment/cache/cache.json     compact room cache
;; - neoment/cache/media/         downloaded media

;;; Code:

(require 'cl-lib)
(require 'neoment-config)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-notify)

(defun neoment-storage-dir ()
  "Return the directory holding Neoment's data files."
  (file-name-as-directory (locate-user-emacs-file "neoment/")))

(defun neoment-storage-cache-dir ()
  "Return the directory holding Neoment's cache."
  (file-name-as-directory (expand-file-name "cache" (neoment-storage-dir))))

(defun neoment-storage-media-dir ()
  "Return the directory holding downloaded media, creating it."
  (let ((dir (file-name-as-directory
              (expand-file-name "media" (neoment-storage-cache-dir)))))
    (make-directory dir t)
    dir))

(defun neoment-storage-file (name)
  "Return the path of the data file NAME."
  (expand-file-name name (neoment-storage-dir)))

(defun neoment-storage-session-file ()
  "Return the path of `data.json'."
  (neoment-storage-file "data.json"))

(defun neoment-storage-ui-state-file ()
  "Return the path of `ui_state.json'."
  (neoment-storage-file "ui_state.json"))

(defun neoment-storage-oauth-clients-file ()
  "Return the path of `oauth_clients.json'."
  (neoment-storage-file "oauth_clients.json"))

(defun neoment-storage-cache-file ()
  "Return the path of `cache.json'."
  (expand-file-name "cache.json" (neoment-storage-cache-dir)))

(defun neoment-storage-read-json (file)
  "Read and parse the JSON FILE, or return nil when missing or invalid."
  (when (file-readable-p file)
    (condition-case nil
        (with-temp-buffer
          (set-buffer-multibyte t)
          (let ((coding-system-for-read 'utf-8))
            (insert-file-contents file))
          (neoment-json-decode (buffer-string)))
      (error nil))))

(defun neoment-storage-write-json (file object &optional private)
  "Write OBJECT as JSON to FILE.
With PRIVATE, the file is only readable by the user (mode 0600)."
  (make-directory (file-name-directory file) t)
  (let ((json (neoment-json-encode object))
        (coding-system-for-write 'utf-8-unix))
    (if private
        (with-file-modes #o600
          (write-region json nil file nil 'silent)
          (set-file-modes file #o600))
      (write-region json nil file nil 'silent))))

(defun neoment-storage-delete (file)
  "Delete FILE when it exists."
  (when (file-exists-p file)
    (delete-file file)))

;;;; UI state

(defun neoment-storage-load-ui-state ()
  "Return the saved UI state as a plist (:sections ALIST :spaces ALIST).
Each alist maps a name (string) to non-nil when folded."
  (let ((data (neoment-storage-read-json (neoment-storage-ui-state-file))))
    (cl-flet ((conv (alist)
                (mapcar (lambda (pair)
                          (cons (symbol-name (car pair)) (eq (cdr pair) t)))
                        alist)))
      (list :sections (conv (alist-get 'sections data))
            :spaces (conv (alist-get 'spaces data))))))

(defun neoment-storage-save-ui-state (sections spaces)
  "Save the fold state SECTIONS and SPACES (alists of NAME . FOLDED)."
  (cl-flet ((conv (alist)
              (mapcar (lambda (pair)
                        (cons (car pair) (if (cdr pair) t :false)))
                      alist)))
    (neoment-storage-write-json (neoment-storage-ui-state-file)
                                `((sections . ,(conv sections))
                                  (spaces . ,(conv spaces))))))

;;;; OAuth clients

(defun neoment-storage-oauth-client-id (issuer)
  "Return the saved OAuth client id for ISSUER, or nil."
  (let ((data (neoment-storage-read-json (neoment-storage-oauth-clients-file))))
    (cdr (assoc issuer (mapcar (lambda (p) (cons (symbol-name (car p)) (cdr p)))
                               data)))))

(defun neoment-storage-set-oauth-client-id (issuer client-id)
  "Save CLIENT-ID for ISSUER, or forget it when CLIENT-ID is nil."
  (let* ((data (mapcar (lambda (p) (cons (symbol-name (car p)) (cdr p)))
                       (neoment-storage-read-json
                        (neoment-storage-oauth-clients-file))))
         (data (assoc-delete-all issuer data)))
    (when client-id
      (setq data (append data (list (cons issuer client-id)))))
    (neoment-storage-write-json (neoment-storage-oauth-clients-file)
                                data)))

;;;; JSON conversion of the model

(defun neoment-storage--bool (value)
  "Return VALUE as a JSON boolean."
  (if (and value (not (eq value :false))) t :false))

(defun neoment-storage--parse-bool (value)
  "Return non-nil when the parsed JSON VALUE is true."
  (eq value t))

(defun neoment-storage--key (key)
  "Return the JSON key (a symbol) for the plist KEY."
  (intern (string-replace "-" "_" (substring (symbol-name key) 1))))

(defun neoment-storage--plist-key (key)
  "Return the plist keyword for the parsed JSON KEY (a symbol)."
  (intern (concat ":" (string-replace "_" "-" (symbol-name key)))))

(defun neoment-storage--plist-to-alist (plist)
  "Convert PLIST (possibly nested) to an alist for JSON."
  (cl-loop for (k v) on plist by #'cddr
           when v
           collect (cons (neoment-storage--key k)
                         (cond
                          ((and (consp v) (keywordp (car v)))
                           (neoment-storage--plist-to-alist v))
                          ((and (symbolp v) (not (memq v '(t :false :null))))
                           (symbol-name v))
                          (t v)))))

(defun neoment-storage--alist-to-plist (alist)
  "Convert the parsed JSON ALIST (possibly nested) to a plist."
  (cl-loop for (k . v) in alist
           append (list (neoment-storage--plist-key k)
                        (if (and (consp v) (consp (car v)) (symbolp (caar v)))
                            (neoment-storage--alist-to-plist v)
                          v))))

(defun neoment-storage--message-to-json (message)
  "Return MESSAGE as a JSON alist."
  `((id . ,(neoment-message-id message))
    (sender . ,(or (neoment-message-sender message) :null))
    (content . ,(or (neoment-message-content message) :null))
    (formatted_content . ,(or (neoment-message-formatted-content message) :null))
    (timestamp . ,(or (neoment-message-timestamp message) 0))
    (age . ,(or (neoment-message-age message) 0))
    (edit_data . ,(if (neoment-message-edit-data message)
                      (neoment-storage--plist-to-alist
                       (neoment-message-edit-data message))
                    :null))
    (was_redacted . ,(neoment-storage--bool (neoment-message-was-redacted message)))
    (mentions . ,(vconcat (neoment-message-mentions message)))
    (reactions . ,(mapcar (lambda (pair)
                            (cons (car pair)
                                  (vconcat
                                   (mapcar (lambda (r)
                                             `((event_id . ,(car r))
                                               (sender . ,(cdr r))))
                                           (cdr pair)))))
                          (neoment-message-reactions message)))
    (attachment . ,(if (neoment-message-attachment message)
                       (neoment-storage--plist-to-alist
                        (neoment-message-attachment message))
                     :null))
    (is_state . ,(neoment-storage--bool (neoment-message-is-state message)))
    (thread_root_id . ,(or (neoment-message-thread-root-id message) :null))
    (thread_replies_count . ,(or (neoment-message-thread-replies-count message)
                                 :null))))

(defun neoment-storage--message-from-json (data)
  "Return the message described by the parsed JSON DATA."
  (let ((attachment (alist-get 'attachment data)))
    (when attachment
      (setq attachment (neoment-storage--alist-to-plist attachment))
      (plist-put attachment :type (intern (format "%s" (plist-get attachment :type)))))
    (neoment-message--create
     :id (alist-get 'id data)
     :sender (alist-get 'sender data)
     :content (alist-get 'content data)
     :formatted-content (alist-get 'formatted_content data)
     :timestamp (alist-get 'timestamp data)
     :age (alist-get 'age data)
     :edit-data (and (alist-get 'edit_data data)
                     (neoment-storage--alist-to-plist (alist-get 'edit_data data)))
     :was-redacted (neoment-storage--parse-bool (alist-get 'was_redacted data))
     :mentions (alist-get 'mentions data)
     :reactions (mapcar (lambda (pair)
                          (cons (symbol-name (car pair))
                                (mapcar (lambda (r)
                                          (cons (alist-get 'event_id r)
                                                (alist-get 'sender r)))
                                        (cdr pair))))
                        (alist-get 'reactions data))
     :attachment attachment
     :is-state (neoment-storage--parse-bool (alist-get 'is_state data))
     :thread-root-id (alist-get 'thread_root_id data)
     :thread-replies-count (alist-get 'thread_replies_count data))))

(defun neoment-storage--room-to-json (room)
  "Return the compact JSON form of ROOM (only its last message)."
  (let ((last (neoment-room-last-message room))
        (members nil))
    (maphash (lambda (k _) (push (cons k k) members)) (neoment-room-members room))
    `((id . ,(neoment-room-id room))
      (name . ,(neoment-room-name room))
      (aliases . ,(vconcat (neoment-room-aliases room)))
      (tombstone . ,(if (neoment-room-tombstone room)
                        (neoment-storage--plist-to-alist (neoment-room-tombstone room))
                      :null))
      (avatar_url . ,(or (neoment-room-avatar-url room) :null))
      (topic . ,(or (neoment-room-topic room) ""))
      (events)
      (pending_events)
      (messages . ,(and last (list (cons (neoment-message-id last)
                                         (neoment-storage--message-to-json last)))))
      (last_activity . ,(if (neoment-room-last-activity room)
                            (neoment-storage--plist-to-alist
                             (neoment-room-last-activity room))
                          :null))
      (unread_activity . ,(if (neoment-room-unread-activity room)
                              (neoment-storage--plist-to-alist
                               (neoment-room-unread-activity room))
                            :null))
      (is_direct . ,(neoment-storage--bool (neoment-room-is-direct room)))
      (is_favorite . ,(neoment-storage--bool (neoment-room-is-favorite room)))
      (is_lowpriority . ,(neoment-storage--bool (neoment-room-is-lowpriority room)))
      (space_rooms . ,(vconcat (neoment-room-space-rooms room)))
      (members . ,(nreverse members))
      (typing . [])
      (is_tracked . :false)
      (unread_notifications . ,(or (neoment-room-unread-notifications room) 0))
      (unread_highlights . ,(or (neoment-room-unread-highlights room) 0))
      (joined_member_count . ,(or (neoment-room-joined-member-count room) :null))
      (unread . ,(neoment-storage--bool (neoment-room-unread room)))
      (read_receipt . ,(if (neoment-room-read-receipt room)
                           (neoment-storage--plist-to-alist
                            (let ((r (copy-sequence (neoment-room-read-receipt room))))
                              (plist-put r :is-local
                                         (neoment-storage--bool
                                          (plist-get r :is-local)))))
                         :null))
      (fully_read . ,(or (neoment-room-fully-read room) :null))
      (summary . ,(let ((summary (neoment-room-summary room)))
                    (if summary
                        `((heroes . ,(vconcat (plist-get summary :heroes)))
                          (joined . ,(or (plist-get summary :joined) 0))
                          (invited . ,(or (plist-get summary :invited) 0)))
                      :null))))))

(defun neoment-storage--room-from-json (data)
  "Return the room described by the parsed JSON DATA."
  (let ((room (neoment-room--create
               :id (alist-get 'id data)
               :name (or (alist-get 'name data) (alist-get 'id data))
               :aliases (alist-get 'aliases data)
               :topic (or (alist-get 'topic data) "")
               :tombstone (and (alist-get 'tombstone data)
                               (neoment-storage--alist-to-plist
                                (alist-get 'tombstone data)))
               :avatar-url (alist-get 'avatar_url data)
               :last-activity (and (alist-get 'last_activity data)
                                   (neoment-storage--alist-to-plist
                                    (alist-get 'last_activity data)))
               ;; A cache from an older version has no unread_activity key.
               ;; A null value means the room has no unread activity.
               :unread-activity (let ((activity (if (assq 'unread_activity data)
                                                    (alist-get 'unread_activity data)
                                                  (alist-get 'last_activity data))))
                                  (and activity
                                       (neoment-storage--alist-to-plist activity)))
               :is-direct (neoment-storage--parse-bool (alist-get 'is_direct data))
               :is-favorite (neoment-storage--parse-bool (alist-get 'is_favorite data))
               :is-lowpriority (neoment-storage--parse-bool
                                (alist-get 'is_lowpriority data))
               :space-rooms (alist-get 'space_rooms data)
               :unread-notifications (or (alist-get 'unread_notifications data) 0)
               :unread-highlights (or (alist-get 'unread_highlights data) 0)
               :joined-member-count (alist-get 'joined_member_count data)
               :unread (neoment-storage--parse-bool (alist-get 'unread data))
               :fully-read (alist-get 'fully_read data)
               :summary (let ((summary (alist-get 'summary data)))
                          (and summary
                               (list :heroes (alist-get 'heroes summary)
                                     :joined (alist-get 'joined summary)
                                     :invited (alist-get 'invited summary))))
               :is-tracked nil)))
    (let ((receipt (alist-get 'read_receipt data)))
      (when receipt
        (setq receipt (neoment-storage--alist-to-plist receipt))
        (setf (neoment-room-read-receipt room)
              (plist-put receipt :is-local
                         (neoment-storage--parse-bool (plist-get receipt :is-local))))))
    (dolist (pair (alist-get 'members data))
      (puthash (symbol-name (car pair)) t (neoment-room-members room)))
    (dolist (pair (alist-get 'messages data))
      (let ((msg (neoment-storage--message-from-json (cdr pair))))
        (puthash (symbol-name (car pair)) msg (neoment-room-messages room))))
    room))

(defun neoment-storage--invited-room-to-json (room)
  "Return the JSON form of the invited ROOM."
  `((id . ,(neoment-invited-room-id room))
    (name . ,(neoment-invited-room-name room))
    (topic . ,(or (neoment-invited-room-topic room) ""))
    (members . ,(neoment-invited-room-members room))
    (avatar_url . ,(or (neoment-invited-room-avatar-url room) :null))))

(defun neoment-storage--invited-room-from-json (data)
  "Return the invited room described by the parsed JSON DATA."
  (neoment-invited-room--create
   :id (alist-get 'id data)
   :name (or (alist-get 'name data) (alist-get 'id data))
   :topic (or (alist-get 'topic data) "")
   :members (mapcar (lambda (p) (cons (symbol-name (car p)) (cdr p)))
                    (alist-get 'members data))
   :avatar-url (alist-get 'avatar_url data)))

(defun neoment-storage-cache-json (&optional client)
  "Return the JSON form of the room cache of CLIENT."
  (let ((client (or client neoment--client))
        rooms invited)
    (maphash (lambda (id room)
               (push (cons id (neoment-storage--room-to-json room)) rooms))
             (neoment-client-rooms client))
    (maphash (lambda (id room)
               (push (cons id (neoment-storage--invited-room-to-json room)) invited))
             (neoment-client-invited-rooms client))
    `((sync_token . ,(or (neoment-client-sync-token client) :null))
      (rooms . ,(nreverse rooms))
      (invited_rooms . ,(nreverse invited)))))

(defun neoment-storage-load-cache-json (data &optional client)
  "Load the parsed room cache DATA into CLIENT."
  (let ((client (or client neoment--client)))
    (setf (neoment-client-sync-token client) (alist-get 'sync_token data))
    (dolist (pair (alist-get 'rooms data))
      (puthash (symbol-name (car pair))
               (neoment-storage--room-from-json (cdr pair))
               (neoment-client-rooms client)))
    (dolist (pair (alist-get 'invited_rooms data))
      (puthash (symbol-name (car pair))
               (neoment-storage--invited-room-from-json (cdr pair))
               (neoment-client-invited-rooms client)))))

;;;; Session

(defconst neoment-storage-max-session-age (* 7 24 60 60)
  "Age in seconds after which a session without refresh token expires.")

(defun neoment-storage-session-json (&optional client)
  "Return the JSON form of the credentials of CLIENT."
  (let ((client (or client neoment--client)))
    `((user_id . ,(neoment-client-user-id client))
      (homeserver . ,(neoment-client-homeserver client))
      (device_id . ,(neoment-client-device-id client))
      (access_token . ,(neoment-client-access-token client))
      (refresh_token . ,(or (neoment-client-refresh-token client) :null))
      (expires_at . ,(or (neoment-client-expires-at client) :null))
      (refresh . ,(if (neoment-client-refresh client)
                      (neoment-storage--plist-to-alist (neoment-client-refresh client))
                    :null))
      (last_save . ,(truncate (float-time))))))

(defun neoment-storage-save-session (&optional client)
  "Save the session and the room cache of CLIENT.
Nothing is written when `neoment-save-session' is nil."
  (let ((client (or client neoment--client)))
    (when (and neoment-save-session client
               (neoment-client-access-token client))
      (neoment-storage-write-json (neoment-storage-cache-file)
                                  (neoment-storage-cache-json client))
      (neoment-storage-write-json (neoment-storage-session-file)
                                  (neoment-storage-session-json client)
                                  t)
      t)))

(defun neoment-storage-read-session ()
  "Return the saved session as a parsed alist, or nil."
  (neoment-storage-read-json (neoment-storage-session-file)))

(defun neoment-storage-restore-session ()
  "Restore the saved session into a new client.
Return non-nil on success."
  (let ((data (neoment-storage-read-session)))
    (cond
     ((not (alist-get 'access_token data)) nil)
     ((and (not (alist-get 'refresh_token data))
           (alist-get 'last_save data)
           (> (- (float-time) (alist-get 'last_save data))
              neoment-storage-max-session-age))
      (neoment-notify--message "Session data is expired, please log in again"
                               'warn)
      nil)
     (t
      (setq neoment--client nil)
      (neoment-client-reset (alist-get 'homeserver data))
      (let ((client neoment--client))
        (when (alist-get 'device_id data)
          (setf (neoment-client-device-id client) (alist-get 'device_id data)))
        (setf (neoment-client-access-token client) (alist-get 'access_token data)
              (neoment-client-refresh-token client) (alist-get 'refresh_token data)
              (neoment-client-expires-at client) (alist-get 'expires_at data)
              (neoment-client-refresh client)
              (and (alist-get 'refresh data)
                   (neoment-storage--alist-to-plist (alist-get 'refresh data)))
              (neoment-client-user-id client) (alist-get 'user_id data))
        (let ((cache (neoment-storage-read-json (neoment-storage-cache-file))))
          (when cache
            (neoment-storage-load-cache-json cache client))))
      (neoment-notify--message
       (format "Matrix session restored for %s" (neoment-user-id)))
      t))))

(defun neoment-storage-clear-session ()
  "Delete the saved session, the cache and the UI state.
The OAuth client ids are kept."
  (neoment-storage-delete (neoment-storage-session-file))
  (neoment-storage-delete (neoment-storage-cache-file))
  (neoment-storage-delete (neoment-storage-ui-state-file)))

;;;###autoload
(defun neoment-clear-cache ()
  "Delete the room cache file."
  (interactive)
  (let ((file (neoment-storage-cache-file)))
    (if (not (file-exists-p file))
        (neoment-notify--message "No cache file found to remove")
      (let ((size-kb (/ (file-attribute-size (file-attributes file)) 1024)))
        (delete-file file)
        (neoment-notify--message
         (format "Neoment cache removed (%dKB)" size-kb))))))

(provide 'neoment-storage)
;;; neoment-storage.el ends here
