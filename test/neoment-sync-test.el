;;; neoment-sync-test.el --- Tests for the sync loop  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task 3.9 of the port: the sync request, the loop, retries, and the
;; processing of invited, joined and left rooms, account data and
;; presence.

;;; Code:

(require 'test-helper)
(require 'neoment-sync)

(defvar neoment-sync-test--scheduled nil
  "Delays of the syncs scheduled during a test.")

(defmacro neoment-sync-test (handler &rest body)
  "Run BODY with a fresh client and HANDLER answering HTTP requests.
Scheduled syncs are recorded in `neoment-sync-test--scheduled'
instead of running."
  (declare (indent 1))
  `(neoment-test-with-temp-dir
     (neoment-test-with-messages
       (let ((neoment--client nil)
             (neoment-sync--running nil)
             (neoment-sync--in-flight nil)
             (neoment-sync--process nil)
             (neoment-sync--error-count 0)
             (neoment-sync--status-client nil)
             (neoment-sync-after-functions nil)
             (neoment-sync-test--scheduled nil)
             (neoment-desktop-notifications-enabled nil))
         (neoment-test-new-client)
         (neoment-events-reset-caches)
         (cl-letf (((symbol-function 'neoment-sync--schedule)
                    (lambda (delay) (push delay neoment-sync-test--scheduled)))
                   ((symbol-function 'neoment--defer)
                    (lambda (fn &rest args) (apply fn args))))
           (neoment-test-with-http ,handler
             ,@body))))))

(defun neoment-sync-test-query (request)
  "Return the query alist of REQUEST."
  (plist-get request :query))

;;;; Request

(ert-deftest neoment-sync-first-request ()
  (neoment-sync-test (lambda (_) 'pending)
    (neoment-sync-start)
    (should (neoment-test-message-p "Synchronization started"))
    (let* ((req (car neoment-test--requests))
           (query (neoment-sync-test-query req)))
      (should (equal (plist-get req :url) "https://hs.example/_matrix/client/v3/sync"))
      (should (equal (alist-get 'filter query) neoment-sync-filter))
      (should (equal (alist-get 'full_state query) "true"))
      (should (null (alist-get 'since query)))
      (should (equal (alist-get 'set_presence query) "online"))
      (should (equal (alist-get 'timeout query) "30000"))
      (should (= (plist-get req :timeout) 45)))
    (should (equal (neoment-http-url "https://x/sync" '((filter . "{\"a\":1}")))
                   "https://x/sync?filter=%7B%22a%22%3A1%7D"))
    (should (eq (plist-get (neoment-sync-status) :kind) 'syncing))))

(ert-deftest neoment-sync-later-request-and-presence ()
  (neoment-sync-test (lambda (_) 'pending)
    (setf (neoment-client-sync-token neoment--client) "s1"
          (neoment-client-desired-presence neoment--client) "unavailable")
    (neoment-sync-start)
    (let ((query (neoment-sync-test-query (car neoment-test--requests))))
      (should (null (alist-get 'full_state query)))
      (should (equal (alist-get 'since query) "s1"))
      (should (equal (alist-get 'set_presence query) "unavailable")))))

(ert-deftest neoment-sync-single-request ()
  (neoment-sync-test (lambda (_) 'pending)
    (neoment-sync-start)
    (neoment-sync-start)
    (neoment-sync--run)
    (should (= (length neoment-test--requests) 1))))

(ert-deftest neoment-sync-success-updates-status ()
  (neoment-sync-test (lambda (_) '(:ok ((next_batch . "s2"))))
    (let ((after nil))
      (add-hook 'neoment-sync-after-functions (lambda (ids) (push ids after)))
      (neoment-sync-start)
      (should (equal (neoment-client-sync-token neoment--client) "s2"))
      (should (<= (abs (- (plist-get (neoment-sync-status) :last-sync) (float-time))) 2))
      (should (= (plist-get (neoment-sync-status) :current-count) 1))
      (should (eq (plist-get (neoment-sync-status) :kind) 'stopped))
      (should (equal after '(nil)))
      (should (equal neoment-sync-test--scheduled '(0))))))

(ert-deftest neoment-sync-retries ()
  (neoment-sync-test (lambda (_) '(:error (:status nil :error "Timeout")))
    (neoment-sync-start)
    (dotimes (_ 3) (neoment-sync--run))
    (should (= (length neoment-test--requests) 4))
    (should (equal (seq-filter (lambda (m) (string-prefix-p "[Neoment] Error" m))
                               neoment-test--messages)
                   '("[Neoment] Error syncing: Timeout\nRetrying..."
                     "[Neoment] Error syncing: Timeout\nRetrying..."
                     "[Neoment] Error syncing: Timeout\nRetrying..."
                     "[Neoment] Error syncing: Timeout")))
    (should (equal neoment-sync-test--scheduled '(1 1 1 1)))))

(ert-deftest neoment-sync-processing-error-continues ()
  (neoment-sync-test
      (lambda (_) (list :ok (neoment-json-decode
                             "{\"rooms\":{\"join\":{\"!r:s\":{\"timeline\":{\"events\":[42]}}}}}")))
    (neoment-sync-start)
    (should (seq-find (lambda (m) (string-prefix-p "[Neoment] Error syncing: " m))
                      neoment-test--messages))
    (should (equal neoment-sync-test--scheduled '(1)))
    (should-not neoment-sync--in-flight)))

(ert-deftest neoment-sync-stop-drops-response ()
  (let (pending)
    (neoment-sync-test (lambda (args) (setq pending args) 'pending)
      (neoment-sync-start)
      (neoment-sync-stop)
      (should (neoment-test-message-p "Synchronization stopped"))
      (funcall (plist-get pending :callback) '(:ok ((next_batch . "late"))))
      (should (null (neoment-client-sync-token neoment--client)))
      (should (null neoment-sync-test--scheduled)))))

(ert-deftest neoment-sync-stale-client-dropped ()
  (let (pending)
    (neoment-sync-test (lambda (args) (setq pending args) 'pending)
      (neoment-sync-start)
      (neoment-test-new-client)
      (funcall (plist-get pending :callback) '(:ok ((next_batch . "late"))))
      (should (null (neoment-client-sync-token neoment--client))))))

(ert-deftest neoment-sync-saves-every-tenth ()
  (neoment-sync-test (lambda (_) '(:ok ((next_batch . "s"))))
    (let ((saves 0))
      (cl-letf (((symbol-function 'neoment-storage-save-session)
                 (lambda (&rest _) (cl-incf saves))))
        (neoment-sync-start)
        (dotimes (_ 19) (neoment-sync--run))
        (should (= saves 2))))))

;;;; Processing

(ert-deftest neoment-sync-processing-order ()
  (neoment-sync-test (lambda (_) 'pending)
    (let ((calls nil))
      (cl-letf (((symbol-function 'neoment-notify-clear-candidates) (lambda () (push 'clear calls)))
                ((symbol-function 'neoment-sync--process-invited) (lambda (_) (push 'invite calls) nil))
                ((symbol-function 'neoment-sync--process-joined) (lambda (_) (push 'join calls) nil))
                ((symbol-function 'neoment-sync--process-left) (lambda (&rest _) (push 'leave calls) nil))
                ((symbol-function 'neoment-sync--process-account-data) (lambda (_) (push 'account calls) nil))
                ((symbol-function 'neoment-sync--process-presence) (lambda (_) (push 'presence calls) nil)))
        (neoment-sync-process '((next_batch . "x"))))
      (should (equal (nreverse calls) '(clear invite join leave account presence clear))))))

(ert-deftest neoment-sync-invited-room-by-alias ()
  (neoment-sync-test (lambda (_) 'pending)
    (neoment-sync-process
     (neoment-json-decode
      "{\"rooms\":{\"invite\":{\"!i:s\":{\"invite_state\":{\"events\":[
         {\"type\":\"m.room.canonical_alias\",\"content\":{\"alias\":\"#dev:example.org\"}},
         {\"type\":\"m.room.topic\",\"content\":{\"topic\":\"T\"}},
         {\"type\":\"m.room.member\",\"state_key\":\"@a:s\",
          \"content\":{\"membership\":\"join\",\"displayname\":\"A\"}}]}}}}}"))
    (let ((room (neoment-has-invited-room "!i:s")))
      (should (equal (neoment-invited-room-name room) "#dev:example.org"))
      (should (equal (neoment-invited-room-topic room) "T"))
      (should (equal (neoment-invited-room-members room) '(("@a:s" . "A")))))))

(ert-deftest neoment-sync-joined-counts-trigger ()
  (neoment-sync-test (lambda (_) 'pending)
    (let ((calls nil))
      (cl-letf (((symbol-function 'neoment-notify-room-counts-changed)
                 (lambda (_room &rest counts) (push counts calls))))
        (neoment-sync-process
         (neoment-json-decode
          "{\"rooms\":{\"join\":{\"!r:s\":{
             \"unread_notifications\":{\"notification_count\":2,\"highlight_count\":0},
             \"summary\":{\"m.joined_member_count\":3}}}}}"))
        (let ((room (neoment-has-room "!r:s")))
          (should (= (neoment-room-unread-notifications room) 2))
          (should (= (neoment-room-joined-member-count room) 3)))
        (should (equal calls '((0 0 2 0))))))))

(ert-deftest neoment-sync-heroes-name ()
  (neoment-sync-test (lambda (_) 'pending)
    (neoment-set-display-name "@alice:s" "Alice" 1)
    (neoment-set-display-name "@bob:s" "Bob" 1)
    (cl-flet ((name (summary)
                (neoment-sync-process
                 `((rooms (join (!h:s (summary . ,summary))))))
                (prog1 (neoment-room-display-name "!h:s")
                  (neoment-remove-room "!h:s"))))
      (should (equal (name '((m.heroes "@alice:s" "@bob:s") (m.joined_member_count . 5)
                             (m.invited_member_count . 0)))
                     "Alice, Bob and 3 others"))
      (should (equal (name '((m.heroes "@alice:s" "@bob:s") (m.joined_member_count . 3)))
                     "Alice, Bob"))
      (should (equal (name '((m.heroes) (m.joined_member_count . 1))) "Empty room"))
      (should (equal (name '((m.heroes "@alice:s") (m.joined_member_count . 1)))
                     "Empty room (was Alice)"))
      (should (equal (name '((m.heroes "@alice:s" "@bob:s" "@c:s") (m.joined_member_count . 1)))
                     "Empty room (was Alice and 2 others)")))))

(defun neoment-sync-test-leave (sender)
  "Return a rooms.leave entry for !r:s where SENDER removed @me:s."
  (neoment-json-decode
   (format "{\"rooms\":{\"leave\":{\"!r:s\":{\"timeline\":{\"events\":[
      {\"type\":\"m.room.member\",\"event_id\":\"$l\",\"sender\":%S,
       \"state_key\":\"@me:s\",\"origin_server_ts\":5,
       \"content\":{\"membership\":\"leave\"},
       \"unsigned\":{\"prev_content\":{\"membership\":\"join\"}}}]}}}}}"
           sender)))

(ert-deftest neoment-sync-left-rooms ()
  ;; Kicked by another user, not initial.
  (neoment-sync-test (lambda (_) 'pending)
    (let ((dialogs nil))
      (setf (neoment-client-sync-token neoment--client) "s1")
      (setf (neoment-room-name (neoment-get-room "!r:s")) "dev")
      (neoment-set-display-name "@mod:s" "@mod:s" 1)
      (let ((neoment-sync-acknowledge-function (lambda (text) (push text dialogs))))
        (neoment-sync-process (neoment-sync-test-leave "@mod:s")))
      (should-not (neoment-has-room "!r:s"))
      (should (equal dialogs
                     '("Room: dev\n\nMembership: @me:s was removed from the room by @mod:s\n\nPress OK to acknowledge.")))))
  ;; Self-leave: no dialog.
  (neoment-sync-test (lambda (_) 'pending)
    (let ((dialogs nil))
      (setf (neoment-client-sync-token neoment--client) "s1")
      (neoment-get-room "!r:s")
      (let ((neoment-sync-acknowledge-function (lambda (text) (push text dialogs))))
        (neoment-sync-process (neoment-sync-test-leave "@me:s")))
      (should-not (neoment-has-room "!r:s"))
      (should-not dialogs)))
  ;; Initial sync: no dialog.
  (neoment-sync-test (lambda (_) 'pending)
    (let ((dialogs nil))
      (neoment-get-room "!r:s")
      (let ((neoment-sync-acknowledge-function (lambda (text) (push text dialogs))))
        (neoment-sync-process (neoment-sync-test-leave "@mod:s")))
      (should-not dialogs)))
  ;; Unknown room: not created.
  (neoment-sync-test (lambda (_) 'pending)
    (neoment-sync-process (neoment-sync-test-leave "@mod:s"))
    (should-not (neoment-has-room "!r:s"))
    (should-not (neoment-has-invited-room "!r:s"))))

(ert-deftest neoment-sync-account-data-and-presence ()
  (neoment-sync-test (lambda (_) 'pending)
    (neoment-get-room "!a:s")
    (neoment-sync-process
     (neoment-json-decode
      "{\"account_data\":{\"events\":[
          {\"type\":\"m.direct\",\"content\":{\"@bob:s\":[\"!a:s\",\"!unknown:s\"]}},
          {\"type\":\"m.push_rules\",\"content\":{\"global\":{\"override\":[]}}}]},
        \"presence\":{\"events\":[
          {\"type\":\"m.presence\",\"sender\":\"@bob:s\",
           \"content\":{\"presence\":\"unavailable\",\"last_active_ago\":5}}]}}"))
    (should (neoment-room-is-direct (neoment-has-room "!a:s")))
    (should-not (neoment-has-room "!unknown:s"))
    (should (equal (neoment-client-push-rules neoment--client) '((global (override)))))
    (should (equal (plist-get (neoment-get-presence "@bob:s") :presence) "unavailable"))))

(provide 'neoment-sync-test)
;;; neoment-sync-test.el ends here
