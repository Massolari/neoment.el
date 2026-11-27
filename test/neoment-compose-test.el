;;; neoment-compose-test.el --- Tests for compose and send  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tasks 6.3 to 6.5 of the port: the compose buffer, mention completion
;; and the outgoing message payloads.

;;; Code:

(require 'test-helper)
(require 'neoment-compose)

(defmacro neoment-compose-test (&rest body)
  "Run BODY with a fresh client, room `room' (!r:s, \"dev\") and no network."
  (declare (indent 0))
  `(neoment-test-with-messages
     (let ((neoment--client nil))
       (neoment-test-new-client)
       (let ((room (neoment-get-room "!r:s")))
         (setf (neoment-room-name room) "dev")
         (dolist (u '(("@me:s" . "Me") ("@alice:s" . "Alice") ("@bob:s" . "Bob")))
           (puthash (car u) t (neoment-room-members room))
           (neoment-set-display-name (car u) (cdr u) 1))
         (neoment-test-with-http (lambda (_) '(:ok ((event_id . "$sent"))))
           ,@body)))))

;;;; 6.3 Buffer

(ert-deftest neoment-compose-buffer-names ()
  (neoment-compose-test
    (let ((msg (neoment-message--create :id "$m" :sender "@alice:s" :content "x")))
      (should (equal (neoment-compose-buffer-name "!r:s")
                     "*neoment-compose: Sending to dev*"))
      (should (equal (neoment-compose-buffer-name "!r:s" "$root")
                     "*neoment-compose: Sending to thread in dev*"))
      (should (equal (neoment-compose-buffer-name "!r:s" nil (list :type 'reply :message msg))
                     "*neoment-compose: Replying to Alice*"))
      (should (equal (neoment-compose-buffer-name "!r:s" nil (list :type 'replace :message msg))
                     "*neoment-compose: Editing message on dev*"))
      (should (equal (neoment-compose-buffer-name "!r:s" nil (list :type 'reply :message msg)
                                                  '(:filename "a.png"))
                     "*neoment-compose: Replying to Alice with the attachment a.png*")))))

(ert-deftest neoment-compose-edit-prefill-and-cancel ()
  (neoment-compose-test
    (save-window-excursion
      (delete-other-windows)
      (let* ((room-window (selected-window))
             (msg (neoment-message--create :id "$m" :sender "@me:s" :content "hello\n\nworld"))
             (buffer (neoment-compose-open "!r:s" :relation (list :type 'replace :message msg))))
        (with-current-buffer buffer
          (should (eq major-mode 'neoment-compose-mode))
          (should (equal (buffer-string) "hello\nworld"))
          (should (= (point) (point-max)))
          (should (eq window-size-fixed 'height)))
        (should (eq (window-buffer (selected-window)) buffer))
        (should (= (window-height (selected-window)) 10))
        (neoment-compose-cancel)
        (should-not (buffer-live-p buffer))
        (should (eq (selected-window) room-window))
        (should (one-window-p))))))

(ert-deftest neoment-compose-empty-send-does-nothing ()
  (neoment-compose-test
    (save-window-excursion
      (let ((buffer (neoment-compose-open "!r:s")))
        (with-current-buffer buffer
          (insert "  \n ")
          (neoment-compose-send-and-close)
          (should (buffer-live-p buffer))
          (should (null neoment-test--requests)))
        (kill-buffer buffer)))))

(ert-deftest neoment-compose-send-closes-and-marks-read ()
  (neoment-compose-test
    (save-window-excursion
      (let ((buffer (neoment-compose-open "!r:s")))
        (with-current-buffer buffer
          (insert "line 1\nline 2")
          (neoment-compose-send-and-close))
        (should-not (buffer-live-p buffer))
        (let ((req (car neoment-test--requests)))
          (should (string-match-p "/rooms/%21r%3As/send/m.room.message/neoment-el-[0-9a-f-]+\\'"
                                  (plist-get req :url)))
          (should (equal (alist-get 'body (plist-get req :json)) "line 1\nline 2")))
        (should (equal (neoment-room-fully-read room) "$sent"))))
    (neoment-test-with-http (lambda (_) '(:error (:status 500 :error "nope")))
      (neoment-compose-send "!r:s" "x"))
    (should (neoment-test-message-p "Error sending message: nope"))))

;;;; 6.4 Mentions

(ert-deftest neoment-compose-mention-completion ()
  (neoment-compose-test
    (with-temp-buffer
      (neoment-compose-mode)
      (setq neoment--room-id "!r:s")
      (insert "hi @ali")
      (let* ((capf (neoment-compose-mention-capf))
             (table (nth 2 capf))
             (annotate (plist-get (nthcdr 3 capf) :annotation-function)))
        (should (= (nth 0 capf) 4))
        (should (equal (all-completions "" table) '("@alice:s")))
        (should (equal (funcall annotate "@alice:s") " Alice")))
      (insert "\n@B")
      (should (equal (all-completions "" (nth 2 (neoment-compose-mention-capf))) '("@bob:s")))
      (insert " @")
      ;; Every member except the user.
      (should (equal (sort (all-completions "" (nth 2 (neoment-compose-mention-capf))) #'string<)
                     '("@alice:s" "@bob:s"))))))

;;;; 6.5 Payloads

(ert-deftest neoment-compose-payloads ()
  (neoment-compose-test
    ;; Known mention.
    (let ((c (neoment-compose-message-content "hi @alice:s")))
      (should (equal (alist-get 'msgtype c) "m.text"))
      (should (equal (alist-get 'body c) "hi @alice:s"))
      (should (equal (alist-get 'format c) "org.matrix.custom.html"))
      (should (equal (alist-get 'formatted_body c)
                     "hi <a href=\"https://matrix.to/#/@alice:s\">Alice</a>"))
      (should (equal (alist-get 'm.mentions c) '((user_ids . ["@alice:s"])))))
    ;; Unknown mention.
    (let ((c (neoment-compose-message-content "hi @stranger:s")))
      (should (equal (alist-get 'formatted_body c) "hi @stranger:s"))
      (should-not (alist-get 'm.mentions c)))
    ;; Reply.
    (should (equal (alist-get 'm.relates_to (neoment-compose-message-content "x" :reply-to "$orig"))
                   '((m.in_reply_to . ((event_id . "$orig"))))))
    ;; Thread with reply.
    (should (equal (alist-get 'm.relates_to
                              (neoment-compose-message-content "x" :thread-root-id "$root"
                                                               :reply-to "$r"))
                   '((rel_type . "m.thread") (event_id . "$root")
                     (m.in_reply_to . ((event_id . "$r"))))))
    ;; Edit.
    (let ((c (neoment-compose-message-content "fixed" :replace "$m")))
      (should (equal (alist-get 'body c) "* fixed"))
      (should (equal (alist-get 'body (alist-get 'm.new_content c)) "fixed"))
      (should (equal (alist-get 'm.relates_to c) '((rel_type . "m.replace") (event_id . "$m")))))
    ;; Attachments.
    (let ((c (neoment-compose-message-content
              "caption" :attachment '(:filename "r.pdf" :url "mxc://s/f"
                                                :mimetype "application/pdf" :size 10))))
      (should (equal (alist-get 'msgtype c) "m.file"))
      (should (equal (alist-get 'filename c) "r.pdf"))
      (should (equal (alist-get 'url c) "mxc://s/f"))
      (should (equal (alist-get 'info c) '((mimetype . "application/pdf") (size . 10))))
      (should (equal (alist-get 'body c) "caption")))
    (should (equal (neoment-compose-msgtype "image/png") "m.image"))
    (should (equal (neoment-compose-msgtype "video/mp4") "m.video"))
    (should (equal (neoment-compose-msgtype "audio/ogg") "m.audio"))
    ;; Every payload serialises.
    (should (stringp (neoment-json-encode
                      (neoment-compose-message-content
                       "hi @alice:s" :reply-to "$r" :thread-root-id "$t" :replace "$m"
                       :attachment '(:filename "a" :url "mxc://s/a" :mimetype "image/png")))))))

(ert-deftest neoment-compose-reply-uses-effective-id ()
  (neoment-compose-test
    (save-window-excursion
      (let* ((msg (neoment-message--create :id "$edit" :sender "@alice:s" :content "x"
                                           :edit-data '(:id "$orig" :timestamp 2)))
             (buffer (neoment-compose-open "!r:s" :relation (list :type 'reply :message msg))))
        (with-current-buffer buffer
          (insert "answer")
          (neoment-compose-send-and-close))
        (should (equal (neoment-json-get (plist-get (car neoment-test--requests) :json)
                                         'm.relates_to 'm.in_reply_to 'event_id)
                       "$orig"))))))

;;;; Reply mentions

(defun neoment-compose-test-send (text &rest open-args)
  "Send TEXT from a compose buffer opened with OPEN-ARGS; return the content."
  (save-window-excursion
    (with-current-buffer (apply #'neoment-compose-open "!r:s" open-args)
      (insert text)
      (neoment-compose-send-and-close)))
  (plist-get (car neoment-test--requests) :json))

(defun neoment-compose-test-reply (text sender)
  "Reply TEXT to a message from SENDER; return the sent content."
  (neoment-compose-test-send
   text :relation (list :type 'reply
                        :message (neoment-message--create :id "$orig" :sender sender
                                                          :content "x"))))

(ert-deftest neoment-compose-reply-mentions-sender ()
  (neoment-compose-test
    (should (equal (alist-get 'm.mentions (neoment-compose-test-reply "ok" "@bob:s"))
                   '((user_ids . ["@bob:s"]))))))

(ert-deftest neoment-compose-reply-sender-merged-with-body-mentions ()
  (neoment-compose-test
    (should (equal (alist-get 'm.mentions (neoment-compose-test-reply "hi @alice:s" "@bob:s"))
                   '((user_ids . ["@alice:s" "@bob:s"]))))))

(ert-deftest neoment-compose-reply-sender-already-mentioned ()
  (neoment-compose-test
    (should (equal (alist-get 'm.mentions (neoment-compose-test-reply "hi @bob:s" "@bob:s"))
                   '((user_ids . ["@bob:s"]))))))

(ert-deftest neoment-compose-reply-to-own-message-no-mentions ()
  (neoment-compose-test
    (let ((content (neoment-compose-test-reply "ok" "@me:s")))
      (should (alist-get 'm.relates_to content))
      (should-not (alist-get 'm.mentions content)))))

(ert-deftest neoment-compose-thread-without-reply-no-mentions ()
  (neoment-compose-test
    (let ((content (neoment-compose-test-send "ok" :thread-root-id "$root")))
      (should (equal (alist-get 'm.relates_to content)
                     '((rel_type . "m.thread") (event_id . "$root") (is_falling_back . t))))
      (should-not (alist-get 'm.mentions content)))))

;; A real reply inside a thread is not a fallback, so clients show it as a reply.
(ert-deftest neoment-compose-thread-reply-mentions-sender ()
  (neoment-compose-test
    (let ((content (neoment-compose-test-send
                    "ok" :thread-root-id "$root"
                    :relation (list :type 'reply
                                    :message (neoment-message--create
                                              :id "$r" :sender "@bob:s" :content "x")))))
      (should (equal (alist-get 'm.mentions content) '((user_ids . ["@bob:s"]))))
      (should (equal (alist-get 'm.relates_to content)
                     '((rel_type . "m.thread") (event_id . "$root")
                       (m.in_reply_to . ((event_id . "$r")))))))))

(defun neoment-compose-test-edit (replied)
  "Edit the user's own reply to REPLIED; return the sent content."
  (neoment-compose-test-send
   "fixed" :relation
   (list :type 'replace
         :message (neoment-message--create :id "$m" :sender "@me:s" :content "x"
                                           :replying-to replied))))

;; Editing a reply keeps the replied-to sender in `m.new_content' only.
(ert-deftest neoment-compose-edit-reply-keeps-sender-mention ()
  (neoment-compose-test
    (let ((content (neoment-compose-test-edit
                    (neoment-message--create :id "$orig" :sender "@bob:s" :content "q"))))
      (should-not (alist-get 'm.mentions content))
      (should (equal (alist-get 'm.mentions (alist-get 'm.new_content content))
                     '((user_ids . ["@bob:s"])))))))

(ert-deftest neoment-compose-edit-no-reply-no-mentions ()
  (neoment-compose-test
    (dolist (replied (list nil (neoment-message--create :id "$orig" :placeholder t)))
      (let ((content (neoment-compose-test-edit replied)))
        (should-not (alist-get 'm.mentions content))
        (should-not (alist-get 'm.mentions (alist-get 'm.new_content content)))))))

(provide 'neoment-compose-test)
;;; neoment-compose-test.el ends here
