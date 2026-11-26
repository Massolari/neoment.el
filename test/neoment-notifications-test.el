;;; neoment-notifications-test.el --- Tests for push rules and notifications  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 10 of the port: push rule levels, their write sequences, the
;; settings window, desktop notification decisions and handlers.

;;; Code:

(require 'test-helper)
(require 'neoment-notification-settings)
(require 'neoment-notify)

(defun neoment-notif-test-rules (&rest specs)
  "Return a push ruleset built from SPECS.
Each spec is (KIND RULE-ID ENABLED ACTIONS [CONDITIONS])."
  (let ((global nil))
    (pcase-dolist (`(,kind ,id ,enabled ,actions ,conditions) specs)
      (let ((rule `((rule_id . ,id) (enabled . ,(if enabled t :false))
                    (actions . ,actions)
                    ,@(and conditions `((conditions . ,conditions))))))
        (setf (alist-get kind global) (append (alist-get kind global) (list rule)))))
    `((global . ,global))))

(defconst neoment-notif-test-defaults
  (neoment-notif-test-rules
   '(underride ".m.rule.room_one_to_one" t ("notify" ((set_tweak . "sound") (value . "default"))))
   '(underride ".m.rule.encrypted_room_one_to_one" t ("notify"))
   '(underride ".m.rule.message" t ("notify"))
   '(underride ".m.rule.encrypted" t ("notify")))
  "Server default rules.")

(defmacro neoment-notif-test (&rest body)
  "Run BODY with a client and the room `room' (!r:s)."
  (declare (indent 0))
  `(neoment-test-with-messages
     (let ((neoment--client nil))
       (neoment-test-new-client)
       (let ((room (neoment-get-room "!r:s")))
         (setf (neoment-room-name room) "dev")
         ,@body))))

;;;; 10.1 Reading levels

(ert-deftest neoment-notif-global-levels ()
  (should (equal (neoment-notification-settings-global-levels neoment-notif-test-defaults)
                 '((one_to_one . all) (group . all))))
  (should (equal (neoment-notification-settings-global-levels
                  (neoment-notif-test-rules '(underride ".m.rule.room_one_to_one" t ("notify"))
                                            '(underride ".m.rule.message" t ())))
                 '((one_to_one . all) (group . mentions))))
  (should (equal (neoment-notification-settings-global-levels
                  (neoment-notif-test-rules '(underride ".m.rule.room_one_to_one" nil ("notify"))
                                            '(underride ".m.rule.message" nil ("notify"))))
                 '((one_to_one . mentions) (group . mentions))))
  (should (equal (neoment-notification-settings-global-levels
                  (neoment-notif-test-rules '(underride ".m.rule.message" t ("dont_notify"))))
                 '((one_to_one . mentions) (group . mentions)))))

(ert-deftest neoment-notif-room-levels ()
  (let ((mute '(override "!r:s" t () (((kind . "event_match") (key . "room_id") (pattern . "!r:s"))))))
    (should (eq (neoment-notification-settings-room-level nil "!r:s") 'global))
    (should (eq (neoment-notification-settings-room-level
                 (neoment-notif-test-rules '(room "!r:s" t ("notify"))) "!r:s")
                'all))
    (should (eq (neoment-notification-settings-room-level
                 (neoment-notif-test-rules '(room "!r:s" t ("dont_notify"))) "!r:s")
                'mentions))
    (should (eq (neoment-notification-settings-room-level
                 (neoment-notif-test-rules mute '(room "!r:s" t ("notify"))) "!r:s")
                'none))
    (should (eq (neoment-notification-settings-room-level
                 (neoment-notif-test-rules '(room "!r:s" nil ("notify"))) "!r:s")
                'global))
    (should (eq (neoment-notification-settings-room-level
                 (neoment-notif-test-rules
                  '(override "!r:s" t () (((kind . "event_match") (key . "room_id") (pattern . "!r:s"))
                                          ((kind . "contains_display_name")))))
                 "!r:s")
                'global))))

(ert-deftest neoment-notif-applied-global-level ()
  (neoment-notif-test
    (let ((rules (neoment-notif-test-rules '(underride ".m.rule.room_one_to_one" t ("notify"))
                                           '(underride ".m.rule.message" t ()))))
      (setf (neoment-room-joined-member-count room) 2)
      (should (eq (neoment-notification-settings-applied-global-level rules room) 'all))
      (setf (neoment-room-joined-member-count room) 3 (neoment-room-is-direct room) t)
      (should (eq (neoment-notification-settings-applied-global-level rules room) 'mentions))
      (setf (neoment-room-joined-member-count room) nil)
      (should (eq (neoment-notification-settings-applied-global-level rules room) 'all))
      (setf (neoment-room-is-direct room) nil)
      (should (eq (neoment-notification-settings-applied-global-level rules room) 'mentions)))))

;;;; 10.2 Writing

(defun neoment-notif-test-requests ()
  "Return the captured requests as (METHOD PATH JSON)."
  (mapcar (lambda (r) (list (plist-get r :method)
                            (string-remove-prefix "https://hs.example" (plist-get r :url))
                            (plist-get r :json)))
          neoment-test--requests))

(ert-deftest neoment-notif-write-global ()
  (neoment-notif-test
    (setf (neoment-client-push-rules neoment--client) neoment-notif-test-defaults)
    (let (result)
      (neoment-test-with-http (lambda (_) '(:ok nil))
        (neoment-notification-settings-set-global 'group 'mentions (lambda (r) (setq result r)))
        (should (equal (neoment-notif-test-requests)
                       '((put "/_matrix/client/v3/pushrules/global/underride/.m.rule.message/actions"
                              ((actions . [])))
                         (put "/_matrix/client/v3/pushrules/global/underride/.m.rule.message/enabled"
                              ((enabled . t)))
                         (put "/_matrix/client/v3/pushrules/global/underride/.m.rule.encrypted/actions"
                              ((actions . [])))
                         (put "/_matrix/client/v3/pushrules/global/underride/.m.rule.encrypted/enabled"
                              ((enabled . t)))
                         (get "/_matrix/client/v3/pushrules/" nil))))
        (should (equal result '(:ok nil))))
      (neoment-test-with-http (lambda (_) '(:ok nil))
        (setf (neoment-client-push-rules neoment--client)
              (neoment-notif-test-rules '(underride ".m.rule.room_one_to_one" t ())))
        (neoment-notification-settings-set-global 'one_to_one 'all #'ignore)
        (should (equal (caddr (car (neoment-notif-test-requests)))
                       '((actions . ["notify" ((set_tweak . "sound") (value . "default"))]))))
        ;; The missing encrypted rule is skipped.
        (should (= (length neoment-test--requests) 3))))))

(ert-deftest neoment-notif-write-global-stops-on-error ()
  (neoment-notif-test
    (setf (neoment-client-push-rules neoment--client) neoment-notif-test-defaults)
    (let (result)
      (neoment-test-with-http
          (lambda (args) (if (eq (plist-get args :method) 'put)
                             '(:error (:status 500 :error "boom"))
                           '(:ok nil)))
        (neoment-notification-settings-set-global 'group 'all (lambda (r) (setq result r)))
        (should (equal (mapcar #'car (neoment-notif-test-requests)) '(put get)))
        (should (equal (plist-get (plist-get result :error) :error) "boom"))))))

(ert-deftest neoment-notif-write-room ()
  (neoment-notif-test
    (let ((mute '(override "!r:s" t () (((kind . "event_match") (key . "room_id") (pattern . "!r:s")))))
          (prefix "/_matrix/client/v3/pushrules/global/"))
      ;; From none to global: delete the override only.
      (setf (neoment-client-push-rules neoment--client) (neoment-notif-test-rules mute))
      (neoment-test-with-http (lambda (_) '(:ok nil))
        (neoment-notification-settings-set-room "!r:s" 'global #'ignore)
        (should (equal (neoment-notif-test-requests)
                       `((delete ,(concat prefix "override/%21r%3As") nil)
                         (get "/_matrix/client/v3/pushrules/" nil)))))
      ;; To none: create the override, then delete the room rule.
      (setf (neoment-client-push-rules neoment--client)
            (neoment-notif-test-rules '(room "!r:s" t ("notify"))))
      (neoment-test-with-http (lambda (_) '(:ok nil))
        (neoment-notification-settings-set-room "!r:s" 'none #'ignore)
        (should (equal (neoment-notif-test-requests)
                       `((put ,(concat prefix "override/%21r%3As")
                              ((conditions . [((kind . "event_match") (key . "room_id")
                                               (pattern . "!r:s"))])
                               (actions . [])))
                         (delete ,(concat prefix "room/%21r%3As") nil)
                         (get "/_matrix/client/v3/pushrules/" nil)))))
      ;; To all, enabling a disabled room rule.
      (setf (neoment-client-push-rules neoment--client)
            (neoment-notif-test-rules '(room "!r:s" nil ())))
      (neoment-test-with-http (lambda (_) '(:ok nil))
        (neoment-notification-settings-set-room "!r:s" 'all #'ignore)
        (should (equal (neoment-notif-test-requests)
                       `((put ,(concat prefix "room/%21r%3As")
                              ((actions . ["notify" ((set_tweak . "sound") (value . "default"))])))
                         (put ,(concat prefix "room/%21r%3As/enabled") ((enabled . t)))
                         (get "/_matrix/client/v3/pushrules/" nil)))))
      ;; Saved but reload failed.
      (let (result)
        (neoment-test-with-http
            (lambda (args) (if (eq (plist-get args :method) 'get)
                               '(:error (:status 500 :error "down"))
                             '(:ok nil)))
          (neoment-notification-settings-set-room "!r:s" 'mentions (lambda (r) (setq result r))))
        (should (plist-get (plist-get result :error) :saved))))))

;;;; 10.3 Window

(ert-deftest neoment-notif-window ()
  (neoment-notif-test
    (setf (neoment-client-push-rules neoment--client)
          (neoment-notif-test-rules '(underride ".m.rule.room_one_to_one" t ("notify"))
                                    '(underride ".m.rule.message" t ())))
    (save-window-excursion
      (neoment-test-with-http (lambda (_) 'pending)
        (neoment-notification-settings)
        (should (equal (buffer-string)
                       (string-join '("One-to-one rooms (2 members)"
                                      "  (•) All messages"
                                      "  ( ) Mentions and replies only"
                                      ""
                                      "Group rooms (3+ members)"
                                      "  ( ) All messages"
                                      "  (•) Mentions and replies only")
                                    "\n")))
        (should (= (line-number-at-pos) 2))
        (should (string-search "Notification settings" (neoment-notification-settings--header)))
        ;; RET on the current option does nothing.
        (neoment-notification-settings-apply)
        (should (null neoment-test--requests))
        ;; RET twice while saving: one change.
        (forward-line 4)
        (neoment-notification-settings-apply)
        (should (string-search "(Saving…)" (neoment-notification-settings--header)))
        (let ((n (length neoment-test--requests)))
          (neoment-notification-settings-apply)
          (should (= n (length neoment-test--requests))))
        (neoment-notification-settings-close)))
    ;; Room window.
    (setf (neoment-room-joined-member-count room) 2)
    (save-window-excursion
      (neoment-test-with-http (lambda (_) 'pending)
        (neoment-notification-settings-room "!r:s")
        (should (equal (buffer-string)
                       (string-join '("(•) Global settings (All messages)" "( ) All messages"
                                      "( ) Mentions and replies only" "( ) None")
                                    "\n")))
        (should (string-search "dev" (neoment-notification-settings--header)))
        (kill-buffer)))))

(ert-deftest neoment-notif-window-errors ()
  (neoment-notif-test
    (save-window-excursion
      (neoment-test-with-http (lambda (_) '(:error (:status 500 :error "down")))
        (neoment-notification-settings)
        (should (neoment-test-message-p "Could not load the notification settings: down"))))
    (setf (neoment-client-push-rules neoment--client) neoment-notif-test-defaults)
    (save-window-excursion
      (neoment-test-with-http
          (lambda (args) (if (eq (plist-get args :method) 'get)
                             (list :ok neoment-notif-test-defaults)
                           '(:error (:status 500 :error "nope"))))
        (neoment-notification-settings)
        (search-forward "( ) Mentions")
        (forward-line 0)
        (neoment-notification-settings-apply)
        (should (neoment-test-message-p "Could not change the notification settings: nope"))
        (should (looking-at "  (•) All"))
        (kill-buffer)))))

;;;; 10.4 Decisions

(defmacro neoment-notif-decision-test (&rest body)
  "Run BODY with notifications captured in `sent'."
  (declare (indent 0))
  `(neoment-notif-test
     (let ((sent nil)
           (neoment-desktop-notifications-enabled t)
           (neoment-notify--initial-sync-p nil)
           (neoment-notify--focused t)
           (neoment-notify--current-room-function (lambda () "!other:s"))
           (neoment-notify--client nil)
           (neoment-notify--candidates (make-hash-table :test 'equal))
           (neoment-notify--last-notified (make-hash-table :test 'equal)))
       (let ((neoment-desktop-notifications-handler (lambda (title body) (push (list title body) sent))))
         (neoment-set-display-name "@alice:s" "Alice" 1)
         ,@body))))

(defun neoment-notif-test-message (id sender content ts)
  "Return a message ID by SENDER with CONTENT at TS."
  (neoment-message--create :id id :sender sender :content content :timestamp ts))

(ert-deftest neoment-notif-decisions ()
  ;; Rising count with a candidate.
  (neoment-notif-decision-test
    (neoment-notify-clear-candidates)
    (neoment-notify-add-candidate room (neoment-notif-test-message "$1" "@alice:s" "old" 1))
    (neoment-notify-add-candidate room (neoment-notif-test-message "$2" "@alice:s" "hi" 2))
    (neoment-notify-add-candidate room (neoment-notif-test-message "$3" "@me:s" "mine" 3))
    (neoment-notify-room-counts-changed room 0 0 2 0)
    (should (equal sent '(("[dev] Alice" "hi")))))
  ;; A redacted message never replaces a real candidate or the fallback.
  (neoment-notif-decision-test
    (neoment-notify-clear-candidates)
    (neoment-notify-add-candidate room (neoment-notif-test-message "$1" "@alice:s" "hi" 1))
    (let ((r (neoment-notif-test-message "$r" "@alice:s" "[Redacted]" 2)))
      (setf (neoment-message-was-redacted r) t)
      (neoment-notify-add-candidate room r))
    (neoment-notify-room-counts-changed room 0 0 1 0)
    (should (equal sent '(("[dev] Alice" "hi")))))
  (neoment-notif-decision-test
    (puthash "$s" (neoment-notif-test-message "$s" "@alice:s" "stored" 50) (neoment-room-messages room))
    (let ((r (neoment-notif-test-message "$r" "@alice:s" "[Redacted]" 60)))
      (setf (neoment-message-was-redacted r) t)
      (puthash "$r" r (neoment-room-messages room)))
    (setf (neoment-room-read-receipt room) '(:event-id "$x" :ts 10))
    (neoment-notify-room-counts-changed room 0 0 1 0)
    (should (equal (car sent) '("[dev] Alice" "stored"))))
  ;; Unchanged or decreasing counts.
  (neoment-notif-decision-test
    (neoment-notify-add-candidate room (neoment-notif-test-message "$1" "@alice:s" "hi" 1))
    (neoment-notify-room-counts-changed room 2 0 2 0)
    (neoment-notify-room-counts-changed room 2 0 1 0)
    (should (null sent))
    (neoment-notify-room-counts-changed room 1 0 1 1)
    (should (= (length sent) 1)))
  ;; No message: generic text.
  (neoment-notif-decision-test
    (neoment-notify-room-counts-changed room 0 0 1 0)
    (should (equal sent '(("dev" "New notification")))))
  ;; Fallback to a stored message after the receipt; not again after notifying.
  (neoment-notif-decision-test
    (puthash "$s" (neoment-notif-test-message "$s" "@alice:s" "stored" 50) (neoment-room-messages room))
    (setf (neoment-room-read-receipt room) '(:event-id "$x" :ts 10))
    (neoment-notify-room-counts-changed room 0 0 1 0)
    (should (equal (car sent) '("[dev] Alice" "stored")))
    (neoment-notify-room-counts-changed room 1 0 2 0)
    (should (equal (car sent) '("dev" "New notification")))
    (setf (neoment-room-read-receipt room) '(:event-id "$x" :ts 100))
    (clrhash neoment-notify--last-notified))
  ;; DM title.
  (neoment-notif-decision-test
    (setf (neoment-room-name room) "Alice")
    (neoment-notify-add-candidate room (neoment-notif-test-message "$1" "@alice:s" "yo" 1))
    (neoment-notify-room-counts-changed room 0 0 1 0)
    (should (equal sent '(("Alice" "yo"))))))

(ert-deftest neoment-notif-suppression ()
  (neoment-notif-decision-test
    (let ((neoment-desktop-notifications-enabled nil))
      (neoment-notify-room-counts-changed room 0 0 1 0))
    (let ((neoment-notify--initial-sync-p t))
      (neoment-notify-room-counts-changed room 0 0 1 0))
    (let ((neoment-notify--current-room-function (lambda () "!r:s")))
      (neoment-notify-room-counts-changed room 0 0 1 0)
      (should (null sent))
      ;; Unfocused: notify even for the current room.
      (let ((neoment-notify--focused nil))
        (neoment-notify-room-counts-changed room 0 0 1 0)
        (should (= (length sent) 1)))))
  ;; Candidates are reset when the client changes.
  (neoment-notif-decision-test
    (neoment-notify-add-candidate room (neoment-notif-test-message "$1" "@alice:s" "hi" 1))
    (neoment-test-new-client)
    (let ((room (neoment-get-room "!r:s")))
      (setf (neoment-room-name room) "dev")
      (neoment-notify-room-counts-changed room 0 0 1 0))
    (should (equal sent '(("dev" "New notification"))))))

(ert-deftest neoment-notif-initial-sync-no-notification ()
  (require 'neoment-sync)
  (neoment-notif-decision-test
    (neoment-events-reset-caches)
    (neoment-test-with-http (lambda (_) 'pending)
      (setf (neoment-client-sync-token neoment--client) nil)
      (neoment-sync-process
       (neoment-json-decode
        "{\"next_batch\":\"s1\",\"rooms\":{\"join\":{\"!r:s\":{
           \"timeline\":{\"events\":[{\"type\":\"m.room.message\",\"event_id\":\"$a\",
              \"sender\":\"@alice:s\",\"origin_server_ts\":5,\"content\":{\"body\":\"hey\"}}]},
           \"unread_notifications\":{\"notification_count\":100}}}}}"))
      (should (null sent))
      ;; The next sync notifies.
      (neoment-sync-process
       (neoment-json-decode
        "{\"next_batch\":\"s2\",\"rooms\":{\"join\":{\"!r:s\":{
           \"timeline\":{\"events\":[{\"type\":\"m.room.message\",\"event_id\":\"$b\",
              \"sender\":\"@alice:s\",\"origin_server_ts\":6,\"content\":{\"body\":\"again\"}}]},
           \"unread_notifications\":{\"notification_count\":101}}}}}"))
      (should (equal sent '(("[dev] Alice" "again")))))))

;;;; 10.5 Handlers

(ert-deftest neoment-notif-osascript-args ()
  (let ((args (neoment-notify--osascript-args "[dev] Alice" "\"; do shell script \"x")))
    (should (equal (car args) "osascript"))
    (should (equal (last args 2) '("\"; do shell script \"x" "[dev] Alice")))
    (dolist (arg (butlast args 2))
      (should-not (string-search "Alice" arg))
      (should-not (string-search "shell script" arg)))))

(ert-deftest neoment-notif-default-handler-darwin ()
  (let (command)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq command (plist-get args :command)) nil)))
      (let ((system-type 'darwin))
        (neoment-notify-default-desktop-handler "T" "B")))
    (should (equal (last command 2) '("B" "T")))))

(provide 'neoment-notifications-test)
;;; neoment-notifications-test.el ends here
