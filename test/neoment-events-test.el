;;; neoment-events-test.el --- Tests for the model and events  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 3 of the port: derived rules, event dispatch, messages, edits,
;; redactions, reactions, membership text, receipts, async replies,
;; room tracking and the compact cache.

;;; Code:

(require 'test-helper)
(require 'neoment-events)
(require 'neoment-storage)

(defmacro neoment-events-test (&rest body)
  "Run BODY with a fresh client, a tracked room `room' and no network."
  (declare (indent 0))
  `(let ((neoment--client nil)
         (neoment-client-room-changed-functions nil))
     (neoment-test-new-client)
     (neoment-events-reset-caches)
     (let ((room (neoment-get-room "!r:s")))
       (neoment-room-set-tracked room t)
       (neoment-test-with-http (lambda (_) 'pending)
         ,@body))))

(defun neoment-events-test-text (body &rest props)
  "Return an m.room.message event with BODY and PROPS (see `neoment-test-event')."
  (apply #'neoment-test-event "m.room.message"
         :content (append `((msgtype . "m.text") (body . ,body))
                          (plist-get props :extra))
         props))

(defun neoment-events-test-member (membership target sender &optional prev content)
  "Return a member event for TARGET by SENDER with MEMBERSHIP and PREV content."
  (neoment-test-event "m.room.member" :sender sender :state-key target
                      :content (append `((membership . ,membership)) content)
                      :unsigned (and prev `((prev_content . ,prev)))))

;;;; 3.1 Derived rules

(ert-deftest neoment-client-display-name-rules ()
  (neoment-events-test
    (should (equal (neoment-room-display-name "!r:s") "Empty room"))
    (dolist (m '("@me:s" "@alice:s" "@bob:s" "@carol:s"))
      (puthash m t (neoment-room-members room)))
    (neoment-set-display-name "@alice:s" "Alice" 1)
    (neoment-set-display-name "@bob:s" "Bob" 1)
    (neoment-set-display-name "@carol:s" "Carol" 1)
    (should (equal (neoment-room-display-name "!r:s") "Alice, Bob and 1 others"))
    (remhash "@carol:s" (neoment-room-members room))
    (should (equal (neoment-room-display-name "!r:s") "Alice, Bob"))
    (setf (neoment-room-name room) "dev")
    (should (equal (neoment-room-display-name "!r:s") "dev"))))

(ert-deftest neoment-client-space-rules ()
  (neoment-events-test
    (let ((space (neoment-get-room "!space:s")))
      (setf (neoment-room-name space) "Neovim")
      (setf (neoment-room-name room) "geral")
      (should-not (neoment-room-is-space "!space:s"))
      (neoment-room-add-space-child space "!r:s")
      (should (neoment-room-is-space "!space:s"))
      (should (eq (neoment-room-space "!r:s") space))
      (should (equal (neoment-room-space-name "!r:s") "Neovim"))
      (should (equal (neoment-room-display-name-with-space "!r:s") "Neovim/geral"))
      (should (equal (neoment-room-display-name-with-space "!space:s") "Neovim")))))

(ert-deftest neoment-client-membership ()
  (neoment-events-test
    (should-not (neoment-room-is-member-p "!r:s"))
    (puthash "@me:s" t (neoment-room-members room))
    (should (neoment-room-is-member-p "!r:s"))
    (should (member "!r:s" (neoment-user-rooms)))))

(ert-deftest neoment-client-unread-rule ()
  (neoment-events-test
    (should-not (neoment-room-unread-p room))
    (setf (neoment-room-unread-activity room) '(:timestamp 1 :event-id "$a" :age 0))
    (should (neoment-room-unread-p room))
    (setf (neoment-room-read-receipt room) '(:event-id "$a" :ts 1))
    (should-not (neoment-room-unread-p room))
    (setf (neoment-room-read-receipt room) nil
          (neoment-room-fully-read room) "$a")
    (should-not (neoment-room-unread-p room))
    (setf (neoment-room-unread room) t)
    (should (neoment-room-unread-p room))))

(defmacro neoment-events-test-unread (&rest body)
  "Run BODY in `neoment-events-test' with unread activity $act at 100."
  (declare (indent 0))
  `(neoment-events-test
     (setf (neoment-room-unread-activity room)
           '(:timestamp 100 :event-id "$act" :age 0))
     ,@body))

(ert-deftest neoment-client-unread-zero-counts ()
  (neoment-events-test-unread
    (setf (neoment-room-unread-notifications room) 0
          (neoment-room-unread-highlights room) 0)
    (should (neoment-room-unread-p room))))

(ert-deftest neoment-client-unread-marker-same-event ()
  (neoment-events-test-unread
    (setf (neoment-room-read-receipt room) '(:event-id "$act" :ts 1))
    (should-not (neoment-room-unread-p room)))
  (neoment-events-test-unread
    (setf (neoment-room-fully-read room) "$act")
    (should-not (neoment-room-unread-p room))))

(ert-deftest neoment-client-unread-receipt-on-later-state-event ()
  (neoment-events-test-unread
    (neoment-events-handle
     room (neoment-events-test-member "join" "@bob:s" "@bob:s" nil nil))
    (let ((state (neoment-test-event "m.room.topic" :id "$state" :ts 200
                                     :state-key "" :content '((topic . "x")))))
      (puthash "$state" state (neoment-room-events room)))
    (setf (neoment-room-read-receipt room) '(:event-id "$state" :ts 50))
    (should-not (neoment-room-unread-p room))))

(ert-deftest neoment-client-unread-receipt-not-loaded ()
  (neoment-events-test-unread
    (setf (neoment-room-read-receipt room) '(:event-id "$unknown" :ts 150))
    (should-not (neoment-room-unread-p room))
    (setf (neoment-room-read-receipt room) '(:event-id "$unknown" :ts 50))
    (should (neoment-room-unread-p room))))

(ert-deftest neoment-client-unread-older-receipt ()
  (neoment-events-test-unread
    (neoment-room-add-message room (neoment-message--create :id "$old" :timestamp 40))
    ;; The receipt ts is ignored when its event is loaded.
    (setf (neoment-room-read-receipt room) '(:event-id "$old" :ts 500))
    (should (neoment-room-unread-p room))))

(ert-deftest neoment-client-unread-fully-read-not-loaded ()
  (neoment-events-test-unread
    (setf (neoment-room-fully-read room) "$unknown")
    (should (neoment-room-unread-p room))))

(ert-deftest neoment-client-unread-no-activity ()
  (neoment-events-test
    (setf (neoment-room-last-activity room) '(:timestamp 1 :event-id "$a" :age 0))
    (should-not (neoment-room-unread-p room))))

(ert-deftest neoment-client-unread-manually-marked ()
  (neoment-events-test-unread
    (setf (neoment-room-read-receipt room) '(:event-id "$act" :ts 100)
          (neoment-room-unread room) t)
    (should (neoment-room-unread-p room))))

(ert-deftest neoment-client-event-timestamp ()
  (neoment-events-test
    (neoment-room-add-message room (neoment-message--create :id "$m" :timestamp 7))
    (puthash "$s" (neoment-test-event "m.room.topic" :id "$s" :ts 9 :state-key "")
             (neoment-room-events room))
    (should (= (neoment-room-event-timestamp room "$m") 7))
    (should (= (neoment-room-event-timestamp room "$s") 9))
    (should-not (neoment-room-event-timestamp room "$unknown"))
    (should-not (neoment-room-event-timestamp room nil))))

;; A receipt on an edit event resolves to the edit's own timestamp,
;; not the edited message's.
(ert-deftest neoment-client-unread-receipt-on-edit-event ()
  (neoment-events-test
    (neoment-events-handle room (neoment-events-test-text "a" :id "$a" :ts 10))
    (neoment-events-handle room (neoment-events-test-text "b" :id "$b" :ts 20))
    (neoment-events-handle
     room (neoment-events-test-text
           "* a2" :id "$edit" :ts 30
           :extra '((m.new_content . ((msgtype . "m.text") (body . "a2")))
                    (m.relates_to . ((rel_type . "m.replace") (event_id . "$a"))))))
    (should (= (neoment-room-event-timestamp room "$edit") 30))
    (should (equal (plist-get (neoment-room-unread-activity room) :event-id) "$b"))
    (setf (neoment-room-fully-read room) "$edit")
    (should-not (neoment-room-unread-p room))
    (setf (neoment-room-fully-read room) nil
          (neoment-room-read-receipt room) '(:event-id "$edit" :ts 5))
    (should-not (neoment-room-unread-p room))))

;; Moving the marker back, then losing the loaded events, keeps the room
;; unread even though the server echoes the receipt with a later ts.
(ert-deftest neoment-client-unread-receipt-moved-back ()
  (neoment-events-test
    (neoment-events-handle room (neoment-events-test-text "old" :id "$old" :ts 40))
    (neoment-events-handle room (neoment-events-test-text "act" :id "$act" :ts 100))
    (neoment-api-set-read-markers "!r:s" '(:fully-read "$old" :read "$old"))
    (should (equal (plist-get (neoment-room-read-receipt room) :event-ts) 40))
    (should (neoment-room-unread-p room))
    (neoment-events-handle room (neoment-events-test-receipt "$old" "@me:s" 500))
    (should (equal (neoment-room-read-receipt room)
                   '(:ts 500 :event-id "$old" :event-ts 40)))
    (neoment-room-set-tracked room nil)
    (should-not (neoment-room-event-timestamp room "$old"))
    (should (neoment-room-unread-p room))
    ;; A later server receipt for the same event keeps the event ts.
    (neoment-events-handle room (neoment-events-test-receipt "$old" "@me:s" 600))
    (should (equal (plist-get (neoment-room-read-receipt room) :event-ts) 40))
    (should (neoment-room-unread-p room))))

(ert-deftest neoment-events-receipt-records-event-ts ()
  (neoment-events-test
    (neoment-events-handle room (neoment-events-test-text "a" :id "$a" :ts 40))
    (neoment-events-handle room (neoment-events-test-receipt "$a" "@me:s" 500))
    (should (equal (neoment-room-read-receipt room) '(:ts 500 :event-id "$a" :event-ts 40)))
    ;; A receipt on another unloaded event drops the old event ts.
    (neoment-events-handle room (neoment-events-test-receipt "$x" "@me:s" 600))
    (should (equal (neoment-room-read-receipt room) '(:ts 600 :event-id "$x")))))

(ert-deftest neoment-events-limited-thread-reply-is-unread-activity ()
  (neoment-events-test
    (let ((neoment-events--timeline-limited t))
      (neoment-events-handle
       room (neoment-events-test-text
             "reply" :id "$r" :ts 20
             :extra '((m.relates_to . ((rel_type . "m.thread") (event_id . "$root"))))))
      (neoment-events-handle room (neoment-events-test-text "mine" :id "$m" :ts 30
                                                            :sender "@me:s")))
    (should (equal (neoment-events-test-activity-ids room) '("$m" "$r")))))

(ert-deftest neoment-client-ordering-and-last-activity ()
  (let ((a (neoment-message--create :id "a" :timestamp 10 :age 500))
        (b (neoment-message--create :id "b" :timestamp 10 :age 100))
        (c (neoment-message--create :id "c" :timestamp 5)))
    (should (equal (mapcar #'neoment-message-id
                           (sort (list b c a) #'neoment-message<))
                   '("c" "a" "b"))))
  (neoment-events-test
    (neoment-room-set-last-activity room 10 "$a" 500)
    (neoment-room-set-last-activity room 9 "$old" 0)
    (should (equal (plist-get (neoment-room-last-activity room) :event-id) "$a"))
    (neoment-room-set-last-activity room 10 "$b" 100)
    (should (equal (plist-get (neoment-room-last-activity room) :event-id) "$b"))
    (neoment-room-set-last-activity room 10 "$c" 300)
    (should (equal (plist-get (neoment-room-last-activity room) :event-id) "$b"))))

(ert-deftest neoment-client-unread-activity-tie-rule ()
  (neoment-events-test
    (neoment-room-set-unread-activity room 10 "$a" 500)
    (neoment-room-set-unread-activity room 9 "$old" 0)
    (should (equal (plist-get (neoment-room-unread-activity room) :event-id) "$a"))
    (neoment-room-set-unread-activity room 10 "$b" 100)
    (should (equal (plist-get (neoment-room-unread-activity room) :event-id) "$b"))
    (neoment-room-set-unread-activity room 10 "$c" 300)
    (should (equal (plist-get (neoment-room-unread-activity room) :event-id) "$b"))
    (should-not (neoment-room-last-activity room))))

(defun neoment-events-test-activity-ids (room)
  "Return the last and unread activity event ids of ROOM."
  (list (plist-get (neoment-room-last-activity room) :event-id)
        (plist-get (neoment-room-unread-activity room) :event-id)))

(ert-deftest neoment-events-own-message-not-unread-activity ()
  (neoment-events-test
    (neoment-events-handle room (neoment-events-test-text "hi" :id "$1" :ts 10))
    (setf (neoment-room-read-receipt room) '(:event-id "$1" :ts 10))
    (neoment-events-handle room (neoment-events-test-text "mine" :id "$2" :ts 20
                                                          :sender "@me:s"))
    (should (equal (neoment-events-test-activity-ids room) '("$2" "$1")))
    (should-not (neoment-room-unread-p room))))

(ert-deftest neoment-events-thread-reply-not-unread-activity ()
  (neoment-events-test
    (neoment-events-handle room (neoment-events-test-text "hi" :id "$1" :ts 10))
    (setf (neoment-room-read-receipt room) '(:event-id "$1" :ts 10))
    (neoment-events-handle
     room (neoment-events-test-text
           "reply" :id "$2" :ts 20
           :extra '((m.relates_to . ((rel_type . "m.thread") (event_id . "$1"))))))
    (should (equal (neoment-events-test-activity-ids room) '("$2" "$1")))
    (should-not (neoment-room-unread-p room))))

(ert-deftest neoment-events-main-message-moves-unread-activity ()
  (neoment-events-test
    (neoment-events-handle room (neoment-events-test-text "hi" :id "$1" :ts 10))
    (setf (neoment-room-read-receipt room) '(:event-id "$1" :ts 10))
    (neoment-events-handle room (neoment-events-test-text "new" :id "$2" :ts 20))
    (should (equal (neoment-events-test-activity-ids room) '("$2" "$2")))
    (should (neoment-room-unread-p room))))

(ert-deftest neoment-client-effective-id ()
  (let ((m (neoment-message--create :id "$edit" :edit-data '(:id "$orig" :timestamp 2))))
    (should (equal (neoment-message-effective-id m) "$orig")))
  (should (equal (neoment-message-effective-id (neoment-message--create :id "$x")) "$x")))

;;;; 3.2 Dispatch

(ert-deftest neoment-events-duplicate-ignored ()
  (neoment-events-test
    (let ((e (neoment-events-test-text "hi" :id "$1" :ts 10)))
      (should (neoment-events-handle-multiple room (list e)))
      (should-not (neoment-events-handle-multiple room (list e)))
      (should (= (hash-table-count (neoment-room-messages room)) 1)))))

(ert-deftest neoment-events-reaction-before-target ()
  (neoment-events-test
    (let ((reaction (neoment-test-event
                     "m.reaction" :id "$react" :ts 20 :sender "@bob:s"
                     :content '((m.relates_to . ((rel_type . "m.annotation")
                                                 (event_id . "$msg")
                                                 (key . "👍")))))))
      (neoment-events-handle-multiple room (list reaction))
      (should (gethash "$msg" (neoment-room-pending-events room)))
      (neoment-events-handle-multiple room
                                      (list (neoment-events-test-text "hi" :id "$msg" :ts 10)))
      (should (equal (neoment-message-reactions (neoment-room-get-message room "$msg"))
                     '(("👍" ("$react" . "@bob:s")))))
      (should-not (gethash "$msg" (neoment-room-pending-events room))))))

(ert-deftest neoment-events-batch-sorted ()
  (neoment-events-test
    (neoment-events-handle-multiple
     room (list (neoment-events-test-text "late" :id "$2" :ts 20)
                (neoment-events-test-text "early" :id "$1" :ts 10)))
    (should (equal (plist-get (neoment-room-last-activity room) :event-id) "$2"))))

(ert-deftest neoment-events-invited-empty-name ()
  (neoment-events-test
    (let ((invited (neoment-get-invited-room "!i:s")))
      (neoment-events-handle-invited
       invited (neoment-test-event "m.room.name" :content '((name . ""))))
      (should (equal (neoment-invited-room-name invited) "!i:s"))
      (neoment-events-handle-invited
       invited (neoment-test-event "m.room.name" :content '((name . "inv"))))
      (should (equal (neoment-invited-room-name invited) "inv"))))
  (neoment-events-test
    (let ((invited (neoment-get-invited-room "!j:s")))
      (neoment-events-handle-invited
       invited (neoment-test-event "m.room.canonical_alias"
                                   :content '((alias . "") (alt_aliases . ["#alt:s"]))))
      (should (equal (neoment-invited-room-name invited) "#alt:s")))
    (neoment-events-handle
     room (neoment-test-event "m.room.canonical_alias" :content '((alias . ""))))
    (should-not (neoment-room-aliases room))
    (should (equal (neoment-room-name room) (neoment-room-id room)))))

(ert-deftest neoment-events-account-data-and-state ()
  (neoment-events-test
    (neoment-events-handle room (neoment-test-event "m.fully_read" :content '((event_id . "$f"))))
    (should (equal (neoment-room-fully-read room) "$f"))
    (neoment-events-handle room (neoment-test-event "m.marked_unread" :content '((unread . t))))
    (should (eq (neoment-room-unread room) t))
    (neoment-events-handle room (neoment-test-event "m.tag" :content '((tags . ((m.favourite . ((order . 0))))))))
    (should (neoment-room-is-favorite room))
    (should-not (neoment-room-is-lowpriority room))
    (neoment-events-handle room (neoment-test-event "m.room.name" :content '((name . "dev"))))
    (should (equal (neoment-room-name room) "dev"))
    (neoment-events-handle room (neoment-test-event "m.room.topic" :content '((topic . "Daily"))))
    (should (equal (neoment-room-topic room) "Daily"))
    (neoment-events-handle room (neoment-test-event "m.room.avatar" :content '((url . "mxc://s/av"))))
    (should (equal (neoment-room-avatar-url room) "mxc://s/av"))
    (neoment-events-handle room (neoment-test-event "m.room.tombstone"
                                                    :content '((replacement_room . "!new:s"))))
    (should (equal (neoment-room-tombstone room)
                   '(:body "This room has been upgraded" :replacement-room "!new:s")))
    (neoment-events-handle room (neoment-test-event "m.space.child" :state-key "!child:s"
                                                    :content '((via "s"))))
    (should (equal (neoment-room-space-rooms room) '("!child:s")))
    (neoment-events-handle room (neoment-test-event "m.typing" :content '((user_ids "@a:s" "@b:s"))))
    (should (equal (neoment-room-typing room) '("@a:s" "@b:s")))))

(ert-deftest neoment-events-canonical-alias ()
  (neoment-events-test
    (neoment-set-display-name "@alice:s" "Alice" 1)
    (neoment-events-handle room (neoment-test-event
                                 "m.room.canonical_alias" :id "$c1" :ts 1
                                 :content '((alias . "#a:s") (alt_aliases "#b:s"))))
    (should (equal (neoment-room-aliases room) '("#a:s" "#b:s")))
    (should (equal (neoment-room-name room) "#a:s"))
    (should (equal (neoment-message-content (neoment-room-get-message room "$c1"))
                   "Alice set the room aliases to #a:s, #b:s"))
    (neoment-events-handle room (neoment-test-event "m.room.canonical_alias" :id "$c2" :ts 2
                                                    :content nil))
    (let ((msg (neoment-room-get-message room "$c2")))
      (should (equal (neoment-message-content msg) "Alice removed the room aliases"))
      (should (neoment-message-is-state msg)))
    (should (null (neoment-room-aliases room)))))

;;;; 3.3 Message parsing

(ert-deftest neoment-events-message-content ()
  (neoment-events-test
    (should-not (neoment-events-handle room (neoment-test-event "m.room.message" :content '((msgtype . "m.text")))))
    (neoment-events-handle
     room (neoment-events-test-text
           "*hi*" :id "$1"
           :extra '((format . "org.matrix.custom.html") (formatted_body . "<em>hi</em>")
                    (m.mentions . ((user_ids "@me:s"))))))
    (let ((m (neoment-room-get-message room "$1")))
      (should (equal (neoment-message-content m) "*hi*"))
      (should (equal (neoment-message-formatted-content m) "<em>hi</em>"))
      (should (equal (neoment-message-mentions m) '("@me:s"))))
    (neoment-events-handle
     room (neoment-events-test-text "* x" :id "$2"
                                    :extra '((format . "org.matrix.custom.html")
                                             (formatted_body . "* "))))
    (should-not (neoment-message-formatted-content (neoment-room-get-message room "$2")))
    (neoment-set-display-name "@mod:s" "Mod" 1)
    (neoment-events-handle
     room (neoment-events-test-text "gone" :id "$3"
                                    :unsigned '((redacted_because . ((sender . "@mod:s"))))))
    (should (equal (neoment-message-content (neoment-room-get-message room "$3"))
                   "[Redacted by Mod]"))
    (neoment-events-handle
     room (neoment-events-test-text "gone" :id "$4" :sender "@x:s"
                                    :unsigned '((redacted_because . ((sender . "@x:s"))))))
    (should (equal (neoment-message-content (neoment-room-get-message room "$4"))
                   "[Redacted]"))))

(ert-deftest neoment-events-attachments ()
  (neoment-events-test
    (cl-flet ((att (msgtype content &optional type)
                (let ((id (format "$%s" (random 1000000))))
                  (neoment-events-handle
                   room (neoment-test-event (or type "m.room.message") :id id
                                            :content (append `((msgtype . ,msgtype) (body . "b"))
                                                             content)))
                  (neoment-message-attachment (neoment-room-get-message room id)))))
      (let ((img (att "m.image" '((url . "mxc://s/abc") (info . ((mimetype . "image/png") (w . 10) (h . 20)))))))
        (should (equal (plist-get img :url)
                       "https://hs.example/_matrix/client/v1/media/download/s/abc"))
        (should (equal (plist-get img :mxc-url) "mxc://s/abc"))
        (should (eq (plist-get img :type) 'image))
        (should (= (plist-get img :width) 10))
        (should (= (plist-get img :height) 20)))
      (let ((file (att "m.file" '((url . "mxc://s/f") (filename . "a.pdf") (info . ((size . 1536)))))))
        (should (eq (plist-get file :type) 'file))
        (should (equal (plist-get file :filename) "a.pdf"))
        (should (= (plist-get file :size) 1536)))
      (let ((audio (att "m.audio" '((url . "mxc://s/a") (info . ((size . 1) (duration . 61000)))))))
        (should (= (plist-get audio :duration) 61000)))
      (let ((video (att "m.video" '((url . "mxc://s/v")
                                    (info . ((thumbnail_url . "mxc://s/t")
                                             (thumbnail_info . ((w . 1) (h . 2) (mimetype . "image/jpeg")))))))))
        (should (equal (plist-get (plist-get video :thumbnail) :url)
                       "https://hs.example/_matrix/client/v1/media/download/s/t")))
      (let ((loc (att "m.location" '((url . "mxc://s/l") (geo_uri . "geo:-23.5,46.6")))))
        (should (eq (plist-get loc :type) 'location))
        (should (equal (plist-get loc :url) "https://maps.google.com/?q=-23.5,46.6")))
      (let ((sticker (att nil '((url . "mxc://s/st")) "m.sticker")))
        (should (eq (plist-get sticker :type) 'image)))
      (should-not (att "m.image" nil))
      ;; A sender-chosen https URL is not media.
      (let ((other (att "m.image" '((url . "https://evil.example/x.png")))))
        (should-not (plist-get other :url))
        (should-not (plist-get other :mxc-url))))))

(ert-deftest neoment-events-threads ()
  (neoment-events-test
    (neoment-events-handle
     room (neoment-events-test-text "root" :id "$r" :ts 1
                                    :unsigned '((m.relations . ((m.thread . ((count . 2))))))))
    (should (= (neoment-message-thread-replies-count (neoment-room-get-message room "$r")) 2))
    (neoment-events-handle
     room (neoment-events-test-text
           "reply" :id "$t1" :ts 2
           :extra '((m.relates_to . ((rel_type . "m.thread") (event_id . "$r")
                                     (is_falling_back . t)
                                     (m.in_reply_to . ((event_id . "$r"))))))))
    (let ((reply (neoment-room-get-message room "$t1")))
      (should (equal (neoment-message-thread-root-id reply) "$r"))
      (should-not (neoment-message-replying-to reply)))
    (should (= (neoment-message-thread-replies-count (neoment-room-get-message room "$r")) 3))
    ;; The thread fallback does not fetch the replied event.
    (should-not (seq-find (lambda (u) (string-search "/event/" u)) (neoment-test-request-urls)))))

;;;; 3.4 Edits, redactions and reactions

(defun neoment-events-test-edit (id target body ts)
  "Return an edit event ID of TARGET to BODY at TS."
  (neoment-events-test-text (concat "* " body) :id id :ts ts
                            :extra `((m.new_content . ((msgtype . "m.text") (body . ,body)))
                                     (m.relates_to . ((rel_type . "m.replace")
                                                      (event_id . ,target))))))

(ert-deftest neoment-events-edits ()
  (neoment-events-test
    (neoment-events-handle-multiple room (list (neoment-events-test-text "v1" :id "$m" :ts 1)))
    (neoment-events-handle-multiple room (list (neoment-events-test-edit "$e2" "$m" "v200" 200)))
    (let ((m (neoment-room-get-message room "$m")))
      (should (equal (neoment-message-content m) "v200"))
      (should (equal (neoment-message-id m) "$e2"))
      (should (equal (neoment-message-edit-data m) '(:id "$m" :timestamp 200)))
      (should (equal (neoment-message-effective-id m) "$m")))
    ;; The edited message stays stored under its original id.
    (should (equal (hash-table-keys (neoment-room-messages room)) '("$m")))
    (should-not (neoment-room-get-message room "$e2"))
    (neoment-events-handle-multiple room (list (neoment-events-test-edit "$e1" "$m" "v100" 100)))
    (should (equal (neoment-message-content (neoment-room-get-message room "$m")) "v200"))
    ;; Edit before target is pending.
    (neoment-events-handle-multiple room (list (neoment-events-test-edit "$e3" "$later" "new" 300)))
    (should (gethash "$later" (neoment-room-pending-events room)))
    (neoment-events-handle-multiple room (list (neoment-events-test-text "old" :id "$later" :ts 250)))
    (should (equal (neoment-message-content (neoment-room-get-message room "$later")) "new"))
    ;; Embedded edit.
    (neoment-events-handle-multiple
     room (list (neoment-events-test-text
                 "orig" :id "$emb" :ts 400
                 :unsigned `((m.relations . ((m.replace . ,(neoment-events-test-edit "$embe" "$emb" "fixed" 401))))))))
    (should (equal (neoment-message-content (neoment-room-get-message room "$emb")) "fixed"))))

(ert-deftest neoment-events-redactions ()
  (neoment-events-test
    (neoment-events-handle-multiple
     room (list (neoment-events-test-text "hi" :id "$m" :ts 1)
                (neoment-test-event "m.reaction" :id "$re" :ts 2 :sender "@bob:s"
                                    :content '((m.relates_to . ((rel_type . "m.annotation")
                                                                (event_id . "$m") (key . "👍")))))))
    (should (assoc "👍" (neoment-message-reactions (neoment-room-get-message room "$m"))))
    ;; Redact the only reaction.
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x1" :ts 3
                                                    :content '((redacts . "$re"))))
    (should-not (assoc "👍" (neoment-message-reactions (neoment-room-get-message room "$m"))))
    ;; Redact the message with a reason.
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x2" :ts 4
                                                    :content '((redacts . "$m") (reason . "spam"))))
    (let ((m (neoment-room-get-message room "$m")))
      (should (equal (neoment-message-content m) "[Redacted: spam]"))
      (should (neoment-message-was-redacted m)))
    ;; Already redacted: ignored.
    (should-not (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x3" :ts 5
                                                                :content '((redacts . "$m")))))
    (should (equal (neoment-message-content (neoment-room-get-message room "$m")) "[Redacted: spam]"))
    ;; Unknown target: pending.
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x4" :ts 6
                                                    :content '((redacts . "$unknown"))))
    (should (gethash "$unknown" (neoment-room-pending-events room)))
    ;; Redacting an edit removes the edited message.
    (neoment-events-handle-multiple
     room (list (neoment-events-test-text "v1" :id "$m2" :ts 10)
                (neoment-events-test-edit "$ed" "$m2" "v2" 11)))
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x5" :ts 12
                                                    :content '((redacts . "$ed"))))
    (should-not (neoment-room-get-message room "$m2"))))

(ert-deftest neoment-events-edit-after-redaction ()
  (neoment-events-test
    (neoment-events-handle-multiple room (list (neoment-events-test-text "secret" :id "$s" :ts 1)))
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x" :ts 2
                                                    :content '((redacts . "$s"))))
    ;; An edit handled after the redaction does not bring the text back.
    (should-not (neoment-events-handle room (neoment-events-test-edit "$e" "$s" "secret2" 3)))
    (let ((m (neoment-room-get-message room "$s")))
      (should (equal (neoment-message-content m) "[Redacted]"))
      (should (neoment-message-was-redacted m))
      (should (equal (neoment-message-id m) "$s"))
      (should-not (neoment-message-edit-data m)))))

(ert-deftest neoment-events-edit-of-event-redacted-on-arrival ()
  (neoment-events-test
    ;; The event arrives already redacted (`unsigned.redacted_because').
    (neoment-events-handle
     room (neoment-events-test-text "secret" :id "$s"
                                    :unsigned '((redacted_because . ((sender . "@alice:s"))))))
    (should (neoment-message-was-redacted (neoment-room-get-message room "$s")))
    (should-not (neoment-events-handle room (neoment-events-test-edit "$e" "$s" "secret2" 3)))
    (let ((m (neoment-room-get-message room "$s")))
      (should (equal (neoment-message-content m) "[Redacted]"))
      (should (equal (neoment-message-id m) "$s"))
      (should-not (neoment-message-edit-data m)))))

(ert-deftest neoment-events-redaction-after-edit ()
  (neoment-events-test
    (neoment-events-handle-multiple
     room (list (neoment-events-test-text "secret" :id "$s" :ts 1)
                (neoment-events-test-edit "$e" "$s" "secret2" 2)))
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x" :ts 3
                                                    :content '((redacts . "$s"))))
    ;; The redacted message is not shown as edited and keeps its id.
    (let ((m (neoment-room-get-message room "$s")))
      (should (equal (neoment-message-content m) "[Redacted]"))
      (should (equal (neoment-message-id m) "$s"))
      (should-not (neoment-message-edit-data m)))))

(ert-deftest neoment-events-redacting-ignored-edit-keeps-placeholder ()
  (neoment-events-test
    (neoment-events-handle-multiple room (list (neoment-events-test-text "secret" :id "$s" :ts 1)))
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x" :ts 2
                                                    :content '((redacts . "$s"))))
    (neoment-events-handle room (neoment-events-test-edit "$e" "$s" "secret2" 3))
    ;; Redacting the ignored edit leaves the placeholder in place.
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x2" :ts 4
                                                    :content '((redacts . "$e"))))
    (let ((m (neoment-room-get-message room "$s")))
      (should m)
      (should (equal (neoment-message-content m) "[Redacted]")))))

(ert-deftest neoment-events-pending-redaction-then-history-edit ()
  (neoment-events-test
    ;; The redaction arrives through sync before its target is known.
    (neoment-events-handle room (neoment-test-event "m.room.redaction" :id "$x" :ts 30
                                                    :content '((redacts . "$s"))))
    (should (gethash "$s" (neoment-room-pending-events room)))
    ;; A history page then delivers the original and its later edit.
    (neoment-events-handle-multiple
     room (list (neoment-events-test-text "secret" :id "$s" :ts 10)
                (neoment-events-test-edit "$e" "$s" "secret2" 20))
     t)
    (let ((m (neoment-room-get-message room "$s")))
      (should (equal (neoment-message-content m) "[Redacted]"))
      (should (neoment-message-was-redacted m)))))

(ert-deftest neoment-events-reactions-two-users ()
  (neoment-events-test
    (neoment-events-handle-multiple
     room (list (neoment-events-test-text "hi" :id "$m" :ts 1)
                (neoment-test-event "m.reaction" :id "$r1" :ts 2 :sender "@a:s"
                                    :content '((m.relates_to . ((rel_type . "m.annotation") (event_id . "$m") (key . "👍")))))
                (neoment-test-event "m.reaction" :id "$r2" :ts 3 :sender "@b:s"
                                    :content '((m.relates_to . ((rel_type . "m.annotation") (event_id . "$m") (key . "👍")))))))
    (should (= (length (cdr (assoc "👍" (neoment-message-reactions (neoment-room-get-message room "$m"))))) 2))))

;;;; 3.5 Membership text

(ert-deftest neoment-events-membership-table ()
  (neoment-events-test
    (neoment-set-display-name "@mod:s" "Mod" 1)
    (cl-flet ((text (membership sender &optional prev content)
                (neoment-message-content
                 (neoment-events-member-message
                  (neoment-events-test-member membership "@t:s" sender prev content)))))
      (should (equal (text "join" "@t:s") "Membership: @t:s joined the room"))
      (should (equal (text "join" "@t:s" '((membership . "leave"))) "Membership: @t:s joined the room"))
      (should (equal (text "join" "@t:s" '((membership . "join") (displayname . "A"))
                           '((displayname . "B")))
                     "Membership: B changed display name from A to B"))
      (should (equal (text "join" "@t:s" '((membership . "join"))
                           '((displayname . "C")))
                     "Membership: C changed display name to C"))
      (should (string-suffix-p "removed their display name"
                               (text "join" "@t:s" '((membership . "join") (displayname . "C")))))
      (should (string-suffix-p "changed avatar picture"
                               (text "join" "@t:s" '((membership . "join") (avatar_url . "mxc://a"))
                                     '((avatar_url . "mxc://b")))))
      (should (string-suffix-p " left the room" (text "leave" "@t:s")))
      (should (string-suffix-p "had their invite to the room revoked by Mod"
                               (text "leave" "@mod:s" '((membership . "invite")))))
      (should (string-suffix-p "rejected the invite to the room"
                               (text "leave" "@t:s" '((membership . "invite")))))
      (should (string-suffix-p "was removed from the room by Mod"
                               (text "leave" "@mod:s" '((membership . "join")))))
      (should (string-suffix-p " left the room" (text "leave" "@t:s" '((membership . "join")))))
      (should (string-suffix-p "was unbanned from the room by Mod"
                               (text "leave" "@mod:s" '((membership . "ban")))))
      (should (string-suffix-p "had their knock to the room denied by Mod"
                               (text "leave" "@mod:s" '((membership . "knock")))))
      (should (string-suffix-p "retracted their knock to the room"
                               (text "leave" "@t:s" '((membership . "knock")))))
      (should (string-suffix-p "was invited to the room" (text "invite" "@mod:s")))
      (should (string-suffix-p "was re-invited to the room"
                               (text "invite" "@mod:s" '((membership . "leave")))))
      (should (string-suffix-p "had their knock to the room accepted by Mod"
                               (text "invite" "@mod:s" '((membership . "knock")))))
      (should (string-suffix-p "was banned from the room by Mod" (text "ban" "@mod:s")))
      (should (string-suffix-p "was kicked and banned from the room by Mod"
                               (text "ban" "@mod:s" '((membership . "join")))))
      (should (string-suffix-p "is knocking on the room" (text "knock" "@t:s")))
      (should (string-suffix-p "is re-knocking on the room"
                               (text "knock" "@t:s" '((membership . "invite")))))
      (should-not (neoment-events-member-message
                   (neoment-events-test-member "weird" "@t:s" "@t:s"))))))

(ert-deftest neoment-events-member-add-remove ()
  (neoment-events-test
    (neoment-events-handle room (neoment-events-test-member "join" "@a:s" "@a:s" nil '((displayname . "A"))))
    (should (neoment-room-is-member-p "!r:s" "@a:s"))
    (should (equal (neoment-display-name "@a:s") "A"))
    (neoment-events-handle room (neoment-events-test-member "leave" "@a:s" "@a:s"))
    (should-not (neoment-room-is-member-p "!r:s" "@a:s"))))

;;;; 3.6 Receipts

(defun neoment-events-test-receipt (event-id user &optional ts thread)
  "Return an m.receipt event for USER on EVENT-ID."
  (neoment-test-event
   "m.receipt"
   :content `((,(intern event-id)
               . ((m.read . ((,(intern user)
                              . ,(append (and ts `((ts . ,ts)))
                                         (and thread `((thread_id . ,thread))))))))))))

(ert-deftest neoment-events-receipts ()
  (neoment-events-test
    ;; Other users are ignored.
    (neoment-events-handle room (neoment-events-test-receipt "$o" "@other:s" 5))
    (should-not (neoment-room-read-receipt room))
    ;; Own receipt; sets fully_read when unset.
    (neoment-events-handle room (neoment-events-test-receipt "$a" "@me:s" 100))
    (should (equal (neoment-room-read-receipt room) '(:ts 100 :event-id "$a")))
    (should (equal (neoment-room-fully-read room) "$a"))
    ;; Thread receipt ignored, main accepted.
    (neoment-events-handle room (neoment-events-test-receipt "$t" "@me:s" 200 "$root"))
    (should (equal (plist-get (neoment-room-read-receipt room) :event-id) "$a"))
    (neoment-events-handle room (neoment-events-test-receipt "$m" "@me:s" 150 "main"))
    (should (equal (plist-get (neoment-room-read-receipt room) :event-id) "$m"))
    ;; Older receipt ignored.
    (neoment-events-handle room (neoment-events-test-receipt "$old" "@me:s" 10))
    (should (equal (plist-get (neoment-room-read-receipt room) :event-id) "$m"))
    ;; Receipt without ts moves and keeps ts.
    (neoment-events-handle room (neoment-events-test-receipt "$nots" "@me:s"))
    (should (equal (neoment-room-read-receipt room) '(:ts 150 :event-id "$nots")))
    ;; A local receipt is replaced by the server's, even if older.
    (setf (neoment-room-read-receipt room) '(:event-id "$local" :ts 2000 :is-local t))
    (neoment-events-handle room (neoment-events-test-receipt "$srv" "@me:s" 1000))
    (should (equal (neoment-room-read-receipt room) '(:ts 1000 :event-id "$srv")))))

;;;; 3.7 Async replies and display names

(ert-deftest neoment-events-async-reply ()
  (let ((neoment--client nil) (changed nil) (pending nil))
    (neoment-test-new-client)
    (neoment-events-reset-caches)
    (let ((room (neoment-get-room "!r:s"))
          (neoment-client-room-changed-functions (list (lambda (id) (push id changed)))))
      (neoment-room-set-tracked room t)
      (neoment-test-with-http (lambda (args) (push args pending) 'pending)
        (neoment-events-handle
         room (neoment-events-test-text
               "answer" :id "$reply" :ts 10
               :extra '((m.relates_to . ((m.in_reply_to . ((event_id . "$orig"))))))))
        (let* ((msg (neoment-room-get-message room "$reply"))
               (replied (neoment-message-replying-to msg)))
          (should (neoment-message-placeholder replied))
          (should (equal (neoment-message-id replied) "$orig"))
          (let ((req (seq-find (lambda (r) (string-search "/event/" (plist-get r :url))) pending)))
            (should (equal (plist-get req :url)
                           "https://hs.example/_matrix/client/v3/rooms/%21r%3As/event/%24orig"))
            (funcall (plist-get req :callback)
                     `(:ok ((type . "m.room.message") (event_id . "$orig") (sender . "@bob:s")
                            (origin_server_ts . 5)
                            (content . ((body . "question") (m.mentions . ((user_ids "@me:s")))))
                            (unsigned . ((m.relations
                                          . ((m.replace
                                              . ((type . "m.room.message") (event_id . "$e")
                                                 (sender . "@bob:s") (origin_server_ts . 6)
                                                 (content . ((body . "* q2")
                                                             (m.new_content . ((body . "q2")))))))))))))))
          (should-not (neoment-message-placeholder replied))
          (should (equal (neoment-message-sender replied) "@bob:s"))
          (should (equal (neoment-message-content replied) "q2"))
          (should (equal (neoment-message-id replied) "$orig"))
          (should (member "!r:s" changed)))))))

(ert-deftest neoment-events-display-name-fetch ()
  (let ((neoment--client nil) (requests 0) (changed nil))
    (neoment-test-new-client)
    (neoment-events-reset-caches)
    (let ((neoment-client-room-changed-functions (list (lambda (id) (push id changed)))))
      (neoment-test-with-http (lambda (_) (cl-incf requests) '(:ok ((displayname . "Bob"))))
        (should (equal (neoment-display-name "@bob:s") "@bob:s"))
        (should (equal (neoment-display-name "@bob:s") "Bob"))
        (should (= requests 1))
        (should (member nil changed))))))

;;;; 3.8 Tracking

(ert-deftest neoment-events-room-tracking ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (neoment-test-with-http (lambda (_) 'pending)
      (let ((room (neoment-get-room "!r:s")))
        ;; Untracked: only the newest non-state message.
        (neoment-events-handle-multiple
         room (list (neoment-events-test-text "a" :id "$1" :ts 1)
                    (neoment-events-test-text "b" :id "$2" :ts 2)
                    (neoment-events-test-text "c" :id "$3" :ts 3)
                    (neoment-events-test-member "join" "@x:s" "@x:s")))
        (should (equal (hash-table-keys (neoment-room-messages room)) '("$3")))
        (should (zerop (hash-table-count (neoment-room-events room))))
        ;; Open: tracked and cleared.
        (neoment-room-set-tracked room t)
        (should (zerop (hash-table-count (neoment-room-messages room))))
        (neoment-events-handle-multiple
         room (list (neoment-events-test-text "d" :id "$4" :ts 4)
                    (neoment-events-test-text "e" :id "$5" :ts 5)))
        (setf (neoment-room-prev-batch room) "tok")
        (puthash "$x" '(1) (neoment-room-pending-events room))
        (should (= (hash-table-count (neoment-room-messages room)) 2))
        ;; Close: last message only, events cleared.
        (neoment-room-set-tracked room nil)
        (should (equal (hash-table-keys (neoment-room-messages room)) '("$5")))
        (should (zerop (hash-table-count (neoment-room-events room))))
        (should (zerop (hash-table-count (neoment-room-pending-events room))))
        (should-not (neoment-room-prev-batch room))))))

;; Issue #18: closing a buffer must keep an edited message under its original id.
(ert-deftest neoment-events-close-keeps-edited-message-key ()
  (neoment-events-test
    (neoment-events-handle-multiple room (list (neoment-events-test-text "v1" :id "$o" :ts 1)))
    (neoment-events-handle-multiple room (list (neoment-events-test-edit "$oe" "$o" "v2" 2)))
    (neoment-room-set-tracked room nil)
    (should (equal (hash-table-keys (neoment-room-messages room)) '("$o")))
    (neoment-events-handle
     room (neoment-test-event "m.reaction" :id "$r" :ts 3 :sender "@bob:s"
                              :content '((m.relates_to . ((rel_type . "m.annotation")
                                                          (event_id . "$o")
                                                          (key . "👍"))))))
    (should (equal (neoment-message-reactions (neoment-room-get-message room "$o"))
                   '(("👍" ("$r" . "@bob:s")))))
    (should (zerop (hash-table-count (neoment-room-pending-events room))))))

(ert-deftest neoment-client-add-message-keys-by-effective-id ()
  (neoment-events-test
    (neoment-room-set-tracked room nil)
    (neoment-room-add-message
     room (neoment-message--create :id "$oe" :timestamp 2 :content "v2"
                                   :edit-data '(:id "$o" :timestamp 2)))
    (should (equal (hash-table-keys (neoment-room-messages room)) '("$o")))
    (neoment-room-set-tracked room t)
    (neoment-room-add-message
     room (neoment-message--create :id "$pe" :timestamp 3 :content "v2"
                                   :edit-data '(:id "$p" :timestamp 3)))
    (should (equal (hash-table-keys (neoment-room-messages room)) '("$p")))))

;;;; 3.10 Cache

(ert-deftest neoment-storage-cache-compact-room ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (neoment-test-with-http (lambda (_) 'pending)
      (let ((room (neoment-get-room "!r:s")))
        (neoment-room-set-tracked room t)
        (setf (neoment-room-name room) "dev"
              (neoment-room-is-favorite room) t
              (neoment-room-read-receipt room) '(:event-id "$1" :ts 1 :is-local t))
        (puthash "@me:s" t (neoment-room-members room))
        (dotimes (i 50)
          (neoment-events-handle
           room (neoment-events-test-text (format "m%d" i) :id (format "$%d" i) :ts (+ 10 i))))
        (should (= (hash-table-count (neoment-room-messages room)) 50))
        (setf (neoment-client-sync-token neoment--client) "s123")
        (let* ((json (neoment-json-encode (neoment-storage-cache-json)))
               (data (neoment-json-decode json))
               (saved (cdr (assq '!r:s (alist-get 'rooms data)))))
          (should (= (length (alist-get 'messages saved)) 1))
          (should (eq (alist-get 'is_tracked saved) :false))
          (should (null (alist-get 'events saved)))
          (neoment-test-new-client)
          (neoment-storage-load-cache-json data)
          (let ((back (neoment-has-room "!r:s")))
            (should (equal (neoment-client-sync-token neoment--client) "s123"))
            (should (equal (neoment-room-name back) "dev"))
            (should (neoment-room-is-favorite back))
            (should-not (neoment-room-is-tracked back))
            (should (= (hash-table-count (neoment-room-messages back)) 1))
            (should (equal (neoment-message-content (neoment-room-last-message back)) "m49"))
            (should (equal (neoment-room-read-receipt back) '(:event-id "$1" :ts 1 :is-local t)))
            (should (neoment-room-is-member-p "!r:s"))))))))

(defun neoment-events-test-cache-round-trip ()
  "Save the cache to JSON and load it into a fresh client.  Return the data."
  (let ((data (neoment-json-decode (neoment-json-encode (neoment-storage-cache-json)))))
    (neoment-test-new-client)
    (neoment-storage-load-cache-json data)
    data))

(ert-deftest neoment-storage-cache-unread-activity-round-trip ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (neoment-test-with-http (lambda (_) 'pending)
      (let ((room (neoment-get-room "!r:s")))
        (puthash "@me:s" t (neoment-room-members room))
        (setf (neoment-room-last-activity room) '(:timestamp 20 :event-id "$mine" :age 0)
              (neoment-room-unread-activity room) '(:timestamp 10 :event-id "$a" :age 0)
              (neoment-room-read-receipt room) '(:event-id "$a" :ts 10 :is-local nil))
        (should-not (neoment-room-unread-p room))
        (neoment-events-test-cache-round-trip)
        (let ((back (neoment-has-room "!r:s")))
          (should (equal (neoment-room-unread-activity back)
                         '(:timestamp 10 :event-id "$a" :age 0)))
          (should (equal (neoment-room-last-activity back)
                         '(:timestamp 20 :event-id "$mine" :age 0)))
          (should-not (neoment-room-unread-p back)))))))

(ert-deftest neoment-storage-cache-null-unread-activity ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (neoment-test-with-http (lambda (_) 'pending)
      (let ((room (neoment-get-room "!r:s")))
        (puthash "@me:s" t (neoment-room-members room))
        (setf (neoment-room-last-activity room) '(:timestamp 20 :event-id "$reply" :age 0)
              (neoment-room-read-receipt room) '(:event-id "$a" :ts 10 :is-local nil))
        (should-not (neoment-room-unread-p room))
        (neoment-events-test-cache-round-trip)
        (let ((back (neoment-has-room "!r:s")))
          (should-not (neoment-room-unread-activity back))
          (should-not (neoment-room-unread-p back)))))))

(ert-deftest neoment-storage-cache-without-unread-activity ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (neoment-test-with-http (lambda (_) 'pending)
      (let ((room (neoment-get-room "!r:s")))
        (puthash "@me:s" t (neoment-room-members room))
        (setf (neoment-room-last-activity room) '(:timestamp 20 :event-id "$b" :age 0))
        (let* ((data (neoment-json-decode
                      (neoment-json-encode (neoment-storage-cache-json))))
               (saved (cdr (assq '!r:s (alist-get 'rooms data)))))
          ;; Drop the key, as in a cache written by an older version.
          (setcdr (assq '!r:s (alist-get 'rooms data))
                  (assq-delete-all 'unread_activity saved))
          (neoment-test-new-client)
          (neoment-storage-load-cache-json data)
          (let ((back (neoment-has-room "!r:s")))
            (should (equal (neoment-room-unread-activity back)
                           (neoment-room-last-activity back)))
            (should (equal (plist-get (neoment-room-unread-activity back) :event-id)
                           "$b"))))))))

;; Issue #18: an edited last message must survive a save/load cycle.
(ert-deftest neoment-storage-cache-edited-message-key ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (neoment-test-with-http (lambda (_) 'pending)
      (let ((room (neoment-get-room "!r:s")))
        (neoment-room-set-tracked room t)
        (neoment-events-handle room (neoment-events-test-text "v1" :id "$o" :ts 1))
        (neoment-events-handle room (neoment-events-test-edit "$oe" "$o" "v2" 2))
        (let* ((data (neoment-json-decode
                      (neoment-json-encode (neoment-storage-cache-json))))
               (saved (cdr (assq '!r:s (alist-get 'rooms data)))))
          (should (equal (mapcar #'car (alist-get 'messages saved)) '($o)))
          (neoment-test-new-client)
          (neoment-storage-load-cache-json data)
          (let ((m (neoment-room-get-message (neoment-has-room "!r:s") "$o")))
            (should m)
            (should (equal (neoment-message-content m) "v2"))
            (should (equal (neoment-message-id m) "$oe"))
            (should (equal (neoment-message-edit-data m) '(:id "$o" :timestamp 2)))))))))

(ert-deftest neoment-storage-load-heals-edit-id-key ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (let* ((msg (neoment-message--create :id "$oe" :timestamp 2 :content "v2"
                                         :sender "@a:s"
                                         :edit-data '(:id "$o" :timestamp 2)))
           (data (neoment-json-decode
                  (neoment-json-encode
                   `((id . "!r:s")
                     (messages . (($oe . ,(neoment-storage--message-to-json msg))))))))
           (room (neoment-storage--room-from-json data)))
      (should (equal (hash-table-keys (neoment-room-messages room)) '("$o")))
      (should (equal (neoment-message-content (neoment-room-get-message room "$o")) "v2")))))

(provide 'neoment-events-test)
;;; neoment-events-test.el ends here
