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
    (setf (neoment-room-last-activity room) '(:timestamp 1 :event-id "$a" :age 0))
    (should (neoment-room-unread-p room))
    (setf (neoment-room-read-receipt room) '(:event-id "$a" :ts 1))
    (should-not (neoment-room-unread-p room))
    (setf (neoment-room-read-receipt room) nil
          (neoment-room-fully-read room) "$a")
    (should-not (neoment-room-unread-p room))
    (setf (neoment-room-unread room) t)
    (should (neoment-room-unread-p room))))

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

(provide 'neoment-events-test)
;;; neoment-events-test.el ends here
