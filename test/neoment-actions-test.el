;;; neoment-actions-test.el --- Tests for message actions  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 7 of the port: navigation, compose entry points, threads,
;; reactions, redaction, read marker, forward, raw events, going to the
;; replied message, leaving and joining rooms, and the key bindings.

;;; Code:

(require 'test-helper)
(require 'neoment-room)
(require 'neoment-compose)
(require 'neoment-emoji)

(defvar neoment-actions-test--http nil
  "Current HTTP handler of the action tests.")

(defmacro neoment-actions-test (&rest body)
  "Run BODY in a rendered buffer for room `room' (!r:s, \"dev\").
HTTP requests are answered by `neoment-actions-test--http'."
  (declare (indent 0))
  `(neoment-test-with-temp-dir
     (neoment-test-with-messages
       (let ((neoment--client nil)
             (neoment-room-time-zone "UTC0")
             (neoment-icons neoment-default-icons)
             (neoment--bubble-edges neoment-faces-bubble-edges-nerd)
             (neoment-client-room-changed-functions nil)
             (neoment-actions-test--http (lambda (_) '(:ok ((event_id . "$new"))))))
         (neoment-test-new-client)
         (neoment-events-reset-caches)
         (let ((room (neoment-get-room "!r:s")))
           (setf (neoment-room-name room) "dev")
           (puthash "@me:s" t (neoment-room-members room))
           (neoment-room-set-tracked room t)
           (dolist (u '(("@alice:s" . "Alice") ("@bob:s" . "Bob") ("@me:s" . "Me")))
             (neoment-set-display-name (car u) (cdr u) 1))
           (neoment-test-with-http (lambda (args) (funcall neoment-actions-test--http args))
             (save-window-excursion
               (let ((buffer (generate-new-buffer "neoment-actions-test")))
                 (unwind-protect
                     (progn
                       (neoment-room--setup-buffer buffer "!r:s")
                       (switch-to-buffer buffer)
                       (cl-letf (((symbol-function 'neoment-room-mark-read) #'ignore))
                         ,@body))
                   (when (buffer-live-p buffer) (kill-buffer buffer)))))))))))

(defun neoment-actions-test-msg (id sender content minute &rest props)
  "Add message ID by SENDER with CONTENT at 09:MINUTE, with PROPS."
  (let ((m (apply #'neoment-message--create :id id :sender sender :content content
                  :timestamp (* 1000 (+ 1795424400 (* 60 minute))) props)))
    (puthash id m (neoment-room-messages (neoment-get-room "!r:s")))
    m))

(defun neoment-actions-test-render ()
  "Render the current room buffer."
  (cl-letf (((symbol-function 'neoment-room-mark-read) #'ignore))
    (neoment-room-render-buffer)))

(defun neoment-actions-test-goto (text)
  "Move to the line containing TEXT."
  (goto-char (point-min))
  (search-forward text)
  (forward-line 0))

(defun neoment-actions-test-standard ()
  "Add Alice's, a state and Bob's messages and render."
  (neoment-actions-test-msg "$a" "@alice:s" "hello" 0 :reactions '(("👍" ("$re" . "@me:s"))))
  (neoment-actions-test-msg "$j" "@carol:s" "Membership: Carol joined the room" 1 :is-state t)
  (neoment-actions-test-msg "$b" "@bob:s" "line1\nline2" 2
                            :replying-to (neoment-message--create :id "$a" :sender "@alice:s"
                                                                  :content "hello"))
  (neoment-actions-test-msg "$m" "@me:s" "mine" 3)
  (neoment-actions-test-render))

;;;; 7.1 Lookup and navigation

(ert-deftest neoment-actions-navigation ()
  (neoment-actions-test
    (neoment-actions-test-standard)
    (neoment-actions-test-goto "hello")
    (should (equal (neoment-message-id (neoment-room-message-at-point)) "$a"))
    (neoment-room-next-message)
    (should (bolp))
    (should (string-match-p " Bob ┃ Alice:\\'" (neoment-test-display-current-line)))
    (neoment-room-next-message)
    (should (bolp))
    (should (string-match-p " Me mine\\'" (neoment-test-display-current-line)))
    (neoment-room-next-message)
    (should (neoment-test-message-p "No more messages in this direction"))
    (neoment-room-previous-message)
    (should (bolp))
    (should (string-match-p " Bob ┃ Alice:\\'" (neoment-test-display-current-line)))
    (neoment-room-previous-message)
    (should (bolp))
    (should (string-match-p " Alice hello\\'" (neoment-test-display-current-line)))
    ;; Date separator line has no message.
    (goto-char (point-min))
    (should-not (neoment-room-message-at-point))
    (should (neoment-test-message-p "No message under the cursor"))))

;;;; 7.2 Entry points

(ert-deftest neoment-actions-compose-entry-points ()
  (neoment-actions-test
    (neoment-actions-test-standard)
    (let (opened)
      (cl-letf (((symbol-function 'neoment-compose-open)
                 (lambda (room-id &rest args) (push (cons room-id args) opened))))
        (neoment-actions-test-goto "hello")
        (neoment-room-edit)
        (should (neoment-test-message-p "You can only edit your own messages"))
        (neoment-room-reply)
        (should (eq (plist-get (plist-get (cdar opened) :relation) :type) 'reply))
        (neoment-actions-test-goto "mine")
        (neoment-room-edit)
        (should (eq (plist-get (plist-get (cdar opened) :relation) :type) 'replace))
        (neoment-room-compose)
        (should (equal (car opened) '("!r:s" :thread-root-id nil)))
        ;; t on a message outside a thread starts one.
        (neoment-room-open-thread)
        (should (equal (car opened) '("!r:s" :thread-root-id "$m")))))
    (should (equal (neoment-compose-buffer-name "!r:s" "$m")
                   "*neoment-compose: Sending to thread in dev*"))))

(ert-deftest neoment-actions-open-thread-buffer ()
  (neoment-actions-test
    (neoment-actions-test-msg "$root" "@alice:s" "root" 0 :thread-replies-count 1)
    (neoment-actions-test-msg "$t1" "@bob:s" "in thread" 1 :thread-root-id "$root")
    (neoment-actions-test-render)
    (neoment-actions-test-goto "root")
    (let ((thread (progn (neoment-room-open-thread) (current-buffer))))
      (unwind-protect
          (progn
            (should (equal (buffer-name thread) "*neoment-thread: Alice in dev*"))
            (should (equal neoment--thread-root-id "$root"))
            (should (equal (buffer-string) "Loading thread..."))
            (neoment-actions-test-render)
            (should (string-search "in thread" (buffer-string))))
        (kill-buffer thread)))))

;;;; 7.3 Reactions

(ert-deftest neoment-actions-reactions ()
  (neoment-actions-test
    (neoment-actions-test-standard)
    (neoment-actions-test-goto "hello")
    ;; Existing own reaction: redacted.
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (car (rassoc "👍" (neoment-emoji-list))))))
      (neoment-room-react-emoji))
    (let ((req (car neoment-test--requests)))
      (should (eq (plist-get req :method) 'put))
      (should (string-match-p "/redact/%24re/neoment-el-" (plist-get req :url))))
    ;; New reaction on the effective id.
    (neoment-actions-test-goto "hello")
    (setf (neoment-message-edit-data (neoment-room-get-message room "$a")) '(:id "$a" :timestamp 9))
    (setf (neoment-message-id (neoment-room-get-message room "$a")) "$edit")
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "lol")))
      (neoment-room-react-text))
    (let ((req (cadr neoment-test--requests)))
      (should (string-match-p "/send/m.reaction/" (plist-get req :url)))
      (should (equal (plist-get req :json)
                     '((m.relates_to . ((rel_type . "m.annotation") (event_id . "$a") (key . "lol")))))))))

(ert-deftest neoment-actions-emoji-table ()
  (let ((neoment-emoji--table nil))
    (let ((table (neoment-emoji-list)))
      (should (> (length table) 500))
      (should (equal (cdr (assoc "😄 :smiling_face_with_open_mouth_and_smiling_eyes:" table)) "😄"))
      (should (equal (neoment-emoji-label "😄") "😄 :smiling_face_with_open_mouth_and_smiling_eyes:"))
      (should-not (neoment-emoji-label "custom")))))

;;;; 7.4 Redact, read marker, forward, event

(ert-deftest neoment-actions-redact ()
  (neoment-actions-test
    (neoment-actions-test-standard)
    (neoment-actions-test-goto "mine")
    (cl-letf (((symbol-function 'read-string) (lambda (prompt &rest _)
                                                (should (equal prompt "Redact message reason: "))
                                                "")))
      (neoment-room-redact))
    (let ((req (car neoment-test--requests)))
      (should (string-match-p "/rooms/%21r%3As/redact/%24m/neoment-el-" (plist-get req :url)))
      (should (equal (plist-get req :json) '((reason . "")))))
    (setq neoment-actions-test--http (lambda (_) '(:error (:status 403 :error "Forbidden"))))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "spam")))
      (neoment-room-redact))
    (should (neoment-test-message-p "Error redacting message: Forbidden"))))

(ert-deftest neoment-actions-set-read-marker ()
  (neoment-actions-test
    (neoment-actions-test-standard)
    (setf (neoment-room-fully-read room) "$m")
    (neoment-actions-test-render)
    (should-not (string-search "New messages" (buffer-string)))
    (neoment-actions-test-goto "hello")
    (neoment-room-set-read-marker)
    (should (equal (plist-get (car neoment-test--requests) :json)
                   '((m.fully_read . "$a") (m.read . "$a"))))
    (should (equal (neoment-room-fully-read room) "$a"))
    (let ((marker (string-search "New messages" (buffer-string))))
      (should marker)
      (should (< (string-search "hello" (buffer-string)) marker (string-search "line1" (buffer-string)))))))

(ert-deftest neoment-actions-forward ()
  (neoment-actions-test
    (let ((target (neoment-get-room "!t:s")))
      (setf (neoment-room-name target) "target")
      (puthash "@me:s" t (neoment-room-members target)))
    (neoment-actions-test-msg "$i" "@alice:s" "pic.png" 0
                              :formatted-content "<strong>pic</strong>"
                              :attachment '(:type image :filename "pic.png" :mimetype "image/png"
                                                  :mxc-url "mxc://s/pic" :size 5))
    (neoment-actions-test-render)
    (neoment-actions-test-goto "Image")
    (let (opened prompt)
      (cl-letf (((symbol-function 'neoment-room-open) (lambda (id) (setq opened id)))
                (neoment-room-picker-function
                 (lambda (_items callback p) (setq prompt p) (funcall callback "!t:s"))))
        (neoment-room-forward))
      (should (equal prompt "Forward to room: "))
      (should (equal opened "!t:s"))
      (let ((json (plist-get (car neoment-test--requests) :json)))
        (should (string-search "/rooms/%21t%3As/send/m.room.message/"
                               (plist-get (car neoment-test--requests) :url)))
        (should (equal (alist-get 'body json) "**pic**"))
        (should (equal (alist-get 'url json) "mxc://s/pic"))
        (should (equal (alist-get 'msgtype json) "m.image")))
      (should (neoment-test-message-p "Message forwarded to target")))))

(ert-deftest neoment-actions-show-event ()
  (neoment-actions-test
    (neoment-actions-test-standard)
    (neoment-actions-test-goto "hello")
    (neoment-room-show-event)
    (should (neoment-test-message-p "Event not found for this message"))
    (puthash "$a" '((type . "m.room.message") (event_id . "$a") (content . ((body . "hello"))))
             (neoment-room-events room))
    (neoment-actions-test-goto "hello")
    (save-window-excursion
      (neoment-room-show-event)
      (should (equal header-line-format "Event: $a"))
      (should (string-search "\"body\": \"hello\"" (buffer-string)))
      (kill-buffer))))

;;;; 7.5 Go to replied

(ert-deftest neoment-actions-goto-replied ()
  ;; Found.
  (neoment-actions-test
    (neoment-actions-test-standard)
    (neoment-actions-test-goto "line1")
    (let ((from (point)))
      (neoment-room-goto-replied)
      (should (equal (get-text-property (point) 'neoment-message) "$a"))
      (should (neoment-test-message-p "Found replied message"))
      (should (= (mark t) from)))
    (neoment-actions-test-goto "hello")
    (neoment-room-goto-replied)
    (should (neoment-test-message-p "This message is not replying to another message")))
  ;; Found after one page.
  (neoment-actions-test
    (neoment-actions-test-msg "$b" "@bob:s" "reply" 5
                              :replying-to (neoment-message--create :id "$old" :sender "@alice:s"
                                                                    :content "old"))
    (neoment-actions-test-render)
    (setq neoment-actions-test--http
          (lambda (_) '(:ok ((end . "e2")
                             (chunk ((type . "m.room.message") (event_id . "$old")
                                     (sender . "@alice:s") (origin_server_ts . 1000)
                                     (content . ((body . "old")))))))))
    (let ((questions nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (push q questions) t)))
        (neoment-actions-test-goto "reply")
        (neoment-room-goto-replied))
      (should (equal questions
                     '("The replied message is older than the loaded messages. Load more messages? ")))
      (should (equal (get-text-property (point) 'neoment-message) "$old"))))
  ;; History exhausted.
  (neoment-actions-test
    (neoment-actions-test-msg "$b" "@bob:s" "reply" 5
                              :replying-to (neoment-message--create :id "$gone" :sender "@alice:s"))
    (neoment-actions-test-render)
    (setq neoment-actions-test--http (lambda (_) '(:ok ((chunk ((type . "m.room.message") (event_id . "$x") (sender . "@a:s") (origin_server_ts . 1) (content . ((body . "x")))))))))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (neoment-actions-test-goto "reply")
      (neoment-room-goto-replied))
    (should (neoment-test-message-p "The replied message was not found in the room history"))))

;;;; 7.6 Leave and join

(ert-deftest neoment-actions-leave ()
  (neoment-actions-test
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (q) (should (equal q "Are you sure you want to leave the room dev? ")) t)))
      (neoment-room-leave))
    (should (neoment-test-message-p "Left room dev"))
    (should-not (neoment-has-room "!r:s"))
    (should (string-suffix-p "/rooms/%21r%3As/leave" (car (neoment-test-request-urls)))))
  (neoment-actions-test
    (setq neoment-actions-test--http (lambda (_) '(:error (:status 404 :error "Not a known room"))))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (neoment-room-leave))
    (should (neoment-test-message-p "Removed room dev from list"))
    (should-not (neoment-has-room "!r:s")))
  (neoment-actions-test
    (setq neoment-actions-test--http (lambda (_) '(:error (:status 403 :errcode "M_FORBIDDEN" :error "No"))))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (neoment-room-leave))
    (should (neoment-test-message-p "Left room dev")))
  (neoment-actions-test
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (neoment-room-leave))
    (should (null neoment-test--requests))))

(ert-deftest neoment-actions-join ()
  (neoment-actions-test
    (let (opened)
      (cl-letf (((symbol-function 'neoment-rooms-open-room) (lambda (id) (push id opened))))
        ;; Existing DM.
        (let ((dm (neoment-get-room "!dm:s")))
          (puthash "@me:s" t (neoment-room-members dm))
          (puthash "@bob:s" t (neoment-room-members dm)))
        (neoment-join "@bob:s")
        (should (neoment-test-message-p "Opening existing DM with @bob:s"))
        (should (equal (car opened) "!dm:s"))
        (should (null neoment-test--requests))
        ;; New DM.
        (setq neoment-actions-test--http (lambda (_) '(:ok ((room_id . "!new:s")))))
        (neoment-join "@carol:s")
        (should (neoment-test-message-p "Creating DM with @carol:s..."))
        (should (neoment-test-message-p "Created DM with @carol:s"))
        (should (equal (plist-get (car neoment-test--requests) :json)
                       '((invite . ["@carol:s"]) (is_direct . t) (preset . "trusted_private_chat"))))
        (should (equal (car opened) "!new:s"))
        ;; Already joined id and alias.
        (neoment-join "!r:s")
        (should (neoment-test-message-p "Room !r:s already joined. Opening..."))
        (setf (neoment-room-aliases room) '("#dev:s"))
        (neoment-join "#dev:s")
        (should (neoment-test-message-p "Room #dev:s already joined. Opening..."))
        ;; Join new alias with via.
        (setq neoment-actions-test--http (lambda (_) '(:ok ((room_id . "!emacs:matrix.org")))))
        (neoment-join "#emacs:matrix.org")
        (let ((req (car (last neoment-test--requests))))
          (should (string-suffix-p "/join/%23emacs%3Amatrix.org" (plist-get req :url)))
          (should (equal (plist-get req :query) '((via "s" "matrix.org")))))
        (should (neoment-test-message-p "Successfully joined room #emacs:matrix.org"))
        (should (equal (car opened) "!emacs:matrix.org"))
        (setq neoment-actions-test--http (lambda (_) '(:error (:status 404 :error "No such room"))))
        (neoment-join "#nope:s")
        (should (neoment-test-message-p "Failed to join room #nope:s: No such room")))))
  (let ((neoment--client nil))
    (neoment-test-with-messages
      (neoment-join "#x:s")
      (should (neoment-test-message-p "Not logged in")))))

;;;; 7.7 Keys

(ert-deftest neoment-actions-key-bindings ()
  (pcase-dolist (`(,key . ,command)
                 '(("RET" . neoment-room-compose) ("r" . neoment-room-reply)
                   ("e" . neoment-room-edit) ("t" . neoment-room-open-thread)
                   ("n" . neoment-room-next-message) ("p" . neoment-room-previous-message)
                   ("a" . neoment-room-react-emoji) ("A" . neoment-room-react-text)
                   ("d" . neoment-room-redact) ("w" . neoment-room-forward)
                   ("R" . neoment-room-goto-replied) ("m" . neoment-room-set-read-marker)
                   ("V" . neoment-room-show-event) ("P" . neoment-room-load-previous)
                   ("L" . neoment-room-leave) ("o" . neoment-room-open-attachment)
                   ("s" . neoment-room-save-attachment) ("u" . neoment-room-upload)
                   ("U" . neoment-room-upload-clipboard-image) ("z" . neoment-room-toggle-image-zoom) ("O" . neoment-player-menu)
                   ("i" . neoment-room-show-info) ("N" . neoment-room-notification-settings)
                   ("f" . neoment-pick-room) ("F" . neoment-pick-open-room)
                   ("l" . neoment-toggle-rooms-list) ("q" . neoment-room-quit)
                   ("g" . revert-buffer) ("?" . describe-mode)))
    (should (eq (keymap-lookup neoment-room-mode-map key) command))))

(provide 'neoment-actions-test)
;;; neoment-actions-test.el ends here
