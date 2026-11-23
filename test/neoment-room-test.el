;;; neoment-room-test.el --- Tests for the room buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 5 of the port: the timeline renderer, the room mode, stable
;; re-rendering, history, read marking and coalesced rendering.

;;; Code:

(require 'test-helper)
(require 'neoment-room)

(defmacro neoment-room-test (&rest body)
  "Run BODY with a fresh client, tracked room `room' (!r:s) and no network."
  (declare (indent 0))
  `(neoment-test-with-temp-dir
     (neoment-test-with-messages
       (let ((neoment--client nil)
             (neoment-room-time-zone "UTC0")
             (neoment-icons neoment-default-icons)
             (neoment--bubble-edges neoment-faces-bubble-edges-nerd)
             (neoment-client-room-changed-functions nil))
         (neoment-test-new-client)
         (neoment-events-reset-caches)
         (let ((room (neoment-get-room "!r:s")))
           (setf (neoment-room-name room) "dev")
           (neoment-room-set-tracked room t)
           (dolist (u '(("@alice:s" . "Alice") ("@bob:s" . "Bob") ("@carol:s" . "Carol")
                        ("@dave:s" . "Dave") ("@me:s" . "Me")))
             (neoment-set-display-name (car u) (cdr u) 1))
           (neoment-test-with-http (lambda (_) 'pending)
             ,@body))))))

(defun neoment-room-test-ts (h m s &optional day)
  "Return the ms timestamp of 2026-11-DAY (default 23) H:M:S UTC."
  (* 1000 (truncate (float-time (encode-time (list s m h (or day 23) 11 2026 nil nil 0))))))

(defun neoment-room-test-msg (room id sender content ts &rest props)
  "Add a message ID from SENDER with CONTENT at TS to ROOM, with PROPS."
  (let ((m (apply #'neoment-message--create :id id :sender sender :content content
                  :timestamp ts props)))
    (puthash id m (neoment-room-messages room))
    m))

(defun neoment-room-test-gutter (&optional rest)
  "Return a continuation line with REST."
  (concat (make-string 28 ?\s) " │ " rest))

(defun neoment-room-test-bubble (text)
  "Return TEXT between the Nerd Font bubble edges."
  (concat "" text ""))

(defun neoment-room-test-plain (room-id &optional thread)
  "Return the rendered text of ROOM-ID (THREAD) without properties."
  (substring-no-properties (neoment-room-render room-id thread)))

;;;; 5.1 Renderer

(ert-deftest neoment-room-render-example ()
  (neoment-room-test
    (let ((alice (neoment-room-test-msg room "$a" "@alice:s"
                                        "Bom dia! Alguém viu o **release**?\nsegunda linha da mesma mensagem"
                                        (neoment-room-test-ts 9 12 44)
                                        :thread-replies-count 3
                                        :reactions '(("👍" ("$r1" . "@bob:s") ("$r2" . "@me:s"))
                                                     ("❤️" ("$r3" . "@bob:s"))))))
      (neoment-room-test-msg room "$b" "@bob:s" "Vi sim, saiu ontem" (neoment-room-test-ts 9 13 2)
                             :replying-to (copy-neoment-message alice)
                             :edit-data '(:id "$b" :timestamp 2))
      (neoment-room-test-msg room "$j" "@carol:s" "Membership: Carol joined the room"
                             (neoment-room-test-ts 9 13 3) :is-state t)
      (neoment-room-test-msg room "$c" "@carol:s" "legenda da imagem" (neoment-room-test-ts 9 20 11)
                             :attachment '(:type image :filename "print.png" :mimetype "image/png"))
      (neoment-room-test-msg room "$d" "@bob:s" "[Redacted]" (neoment-room-test-ts 9 31 0)
                             :was-redacted t)
      (neoment-room-test-msg room "$e" "@dave:s" "ok" (neoment-room-test-ts 9 32 0))
      (neoment-room-test-msg room "$t" "@bob:s" "thread reply" (neoment-room-test-ts 9 15 0)
                             :thread-root-id "$a")
      (setf (neoment-room-fully-read room) "$c"
            (neoment-room-typing room) '("@alice:s" "@dave:s"))
      (should
       (equal (neoment-room-test-plain "!r:s")
              (string-join
               (list (concat (make-string 28 ?\s) " ├" (make-string 16 ?─)
                             " Monday November 23, 2026 " (make-string 16 ?─))
                     "09:12:44               Alice │ Bom dia! Alguém viu o **release**?"
                     (neoment-room-test-gutter "segunda linha da mesma mensagem")
                     (neoment-room-test-gutter (concat (neoment-room-test-bubble "👍 2")
                                                       (neoment-room-test-bubble "❤️")))
                     (neoment-room-test-gutter (neoment-room-test-bubble "↳ 3 replies"))
                     "09:13:02                 Bob │ ┃ Alice:"
                     (neoment-room-test-gutter "┃ Bom dia! Alguém viu o **release**?")
                     (neoment-room-test-gutter "┃ segunda linha da mesma mensagem")
                     (neoment-room-test-gutter "Vi sim, saiu ontem (edited)")
                     (neoment-room-test-gutter "Membership: Carol joined the room")
                     (concat "09:20:11               Carol │ "
                             (neoment-room-test-bubble (concat (neoment-icon 'image) "  Image: print.png")))
                     (neoment-room-test-gutter "legenda da imagem")
                     (substring-no-properties (neoment-room--unread-marker))
                     "09:31:00                 Bob │ [Redacted]"
                     "09:32:00                Dave │ ok"
                     (neoment-room-test-gutter "Typing: Alice, Dave"))
               "\n")))
      ;; The thread buffer shows the root and its reply only.
      (let ((thread (neoment-room-test-plain "!r:s" "$a")))
        (should (string-search "thread reply" thread))
        (should-not (string-search "replies" thread))
        (should-not (string-search "Vi sim" thread))))))

(ert-deftest neoment-room-render-properties ()
  (neoment-room-test
    (neoment-room-test-msg room "$a" "@alice:s" "hi [Me](https://matrix.to/#/@me:s) [Bob](https://matrix.to/#/@bob:s) [img: :party:](mxc://s/p) [img: x](https://evil/x)"
                           (neoment-room-test-ts 9 0 0)
                           :reactions '(("👍" ("$r" . "@me:s")) ("🎉" ("$r2" . "@bob:s"))))
    (neoment-room-test-msg room "$s" "@carol:s" "Membership: Carol joined the room"
                           (neoment-room-test-ts 9 1 0) :is-state t)
    (let ((text (neoment-room-render "!r:s")))
      (cl-flet ((face-at (s) (ensure-list (get-text-property (string-search s text) 'face text))))
        (should (memq 'neoment-mention-user (face-at "[Me]")))
        (should (memq 'neoment-mention (face-at "[Bob]")))
        (should (memq 'neoment-emoticon (face-at "[img: :party:]")))
        (should-not (memq 'neoment-emoticon (face-at "[img: x]")))
        (should (memq 'neoment-user-1 (face-at "Alice")))
        (should (memq 'neoment-separator (face-at " │ hi")))
        (should (memq 'neoment-comment (face-at "Membership")))
        (should (memq 'neoment-bubble-active-content (face-at "👍")))
        (should (memq 'neoment-bubble-content (face-at "🎉"))))
      (should (get-text-property (string-search "09:00:00" text) 'neoment-decoration text))
      (should-not (get-text-property (string-search "hi" text) 'neoment-decoration text))
      (should (equal (get-text-property (string-search "hi" text) 'neoment-message text) "$a"))
      (should (equal (get-text-property (string-search "👍" text) 'neoment-reaction text)
                     '(:key "👍" :senders ("@me:s"))))
      (should (equal (get-text-property 0 'wrap-prefix text) (neoment-room--wrap-prefix))))))

(ert-deftest neoment-room-render-name-rules ()
  (neoment-room-test
    (neoment-set-display-name "@long:s" "ABCDEFGHIJKLMNOPQRSTUVWXY" 1)
    (neoment-room-test-msg room "$1" "@long:s" "x" (neoment-room-test-ts 9 0 0))
    (neoment-room-test-msg room "$2" "@alice:s" "hi" (neoment-room-test-ts 9 12 44))
    (let ((lines (split-string (neoment-room-test-plain "!r:s") "\n")))
      (should (equal (nth 1 lines) "09:00:00 ABCDEFGHIJKLMNOPQRS │ x"))
      (should (equal (nth 2 lines) "09:12:44               Alice │ hi")))
    ;; Colours are assigned in order of first appearance and stay stable.
    (should (eq (neoment-room--sender-face room "@long:s") 'neoment-user-1))
    (should (eq (neoment-room--sender-face room "@alice:s") 'neoment-user-2))))

(ert-deftest neoment-room-render-date-change-and-blank-lines ()
  (neoment-room-test
    (neoment-room-test-msg room "$1" "@alice:s" "a\n   \nb" (neoment-room-test-ts 23 0 0 22))
    (neoment-room-test-msg room "$2" "@alice:s" "c" (neoment-room-test-ts 1 0 0 23))
    (let ((lines (split-string (neoment-room-test-plain "!r:s") "\n")))
      (should (string-search " Sunday November 22, 2026 " (nth 0 lines)))
      (should (equal (nth 2 lines) (neoment-room-test-gutter "")))
      (should (string-search " Monday November 23, 2026 " (nth 4 lines)))
      (should (string-prefix-p "01:00:00" (nth 5 lines))))))

(ert-deftest neoment-room-render-attachments ()
  (should (equal (neoment-room-format-bytes 1536) "1.50 KB"))
  (should (equal (neoment-room-format-bytes nil) "?.? B"))
  (should (equal (neoment-room-format-bytes 10) "10.00 B"))
  (should (equal (neoment-room-format-duration 61000) "01:01"))
  (should (equal (neoment-room-format-duration 3723000) "01:02:03"))
  (should (equal (neoment-room-format-duration nil) "--:--"))
  (neoment-room-test
    (cl-flet ((bubble (att body)
                (let* ((b (neoment-room--attachment-bubble att body)))
                  (cons (substring-no-properties (car b)) (cdr b)))))
      (should (equal (bubble '(:type file :filename "a.pdf" :size 1536) "a.pdf")
                     (cons (neoment-room-test-bubble (concat (neoment-icon 'file) "  File: a.pdf │ 1.50 KB"))
                           nil)))
      (should (equal (bubble '(:type audio :filename "s.ogg") "s.ogg")
                     (cons (neoment-room-test-bubble (concat (neoment-icon 'audio)
                                                             "  Audio: s.ogg │ --:-- │ ?.? B"))
                           nil)))
      (should (equal (bubble '(:type image :mimetype "image/png") "cat.png")
                     (cons (neoment-room-test-bubble (concat (neoment-icon 'image) "  Image: cat.png")) nil)))
      (should (equal (bubble '(:type image :mimetype "image/png") "look at this")
                     (cons (neoment-room-test-bubble (concat (neoment-icon 'image) "  Image"))
                           "look at this")))
      (should (equal (bubble '(:type video :filename "v.mp4" :duration 5000 :size 2048) "v.mp4")
                     (cons (neoment-room-test-bubble (concat (neoment-icon 'video)
                                                             "  Video: v.mp4 │ 00:05 │ 2.00 KB"))
                           nil)))
      (should (equal (bubble '(:type location :url "https://maps") "Here")
                     (cons (neoment-room-test-bubble (concat (neoment-icon 'location) "  Location"))
                           nil))))))

(ert-deftest neoment-room-render-marker-rules ()
  (neoment-room-test
    (neoment-room-test-msg room "$1" "@alice:s" "a" (neoment-room-test-ts 9 0 0))
    (neoment-room-test-msg room "$2" "@carol:s" "Membership: Carol joined the room"
                           (neoment-room-test-ts 9 1 0) :is-state t)
    (setf (neoment-room-fully-read room) "$1")
    (should-not (string-search "New messages" (neoment-room-test-plain "!r:s")))
    (neoment-room-test-msg room "$3" "@bob:s" "b" (neoment-room-test-ts 9 2 0))
    (should (string-search "New messages" (neoment-room-test-plain "!r:s")))))

(ert-deftest neoment-room-render-tombstone-and-reply-placeholder ()
  (neoment-room-test
    (neoment-room-test-msg room "$1" "@alice:s" "a" (neoment-room-test-ts 9 0 0)
                           :replying-to (neoment-message--create :id "$x" :placeholder t))
    (setf (neoment-room-tombstone room) '(:body "This room has been upgraded"
                                                :replacement-room "!new:s"))
    (let* ((text (neoment-room-render "!r:s"))
           (lines (split-string (substring-no-properties text) "\n")))
      (should (equal (nth 1 lines) "09:00:00               Alice │ ┃ …"))
      (should (equal (last lines 4)
                     (list (neoment-room-test-gutter)
                           (neoment-room-test-gutter "This room has been upgraded")
                           (neoment-room-test-gutter "New room: !new:s")
                           (neoment-room-test-gutter
                            "Use M-x neoment-join !new:s to join the new room."))))
      (should (eq (get-text-property (string-search "New room" text) 'face text)
                  'neoment-tombstone)))))

;;;; 5.2 Mode

(defun neoment-room-test-buffer ()
  "Return a rendered buffer for !r:s."
  (let ((buffer (generate-new-buffer "neoment-room-test")))
    (neoment-room--setup-buffer buffer "!r:s")
    (with-current-buffer buffer (neoment-room-render-buffer))
    buffer))

(ert-deftest neoment-room-mode-basics ()
  (neoment-room-test
    (setf (neoment-room-topic room) "Daily chat")
    (neoment-room-test-msg room "$a" "@alice:s" "hi" (neoment-room-test-ts 9 12 44))
    (should (equal (neoment-room-buffer-name "!r:s") "neoment://room/!r:s/dev"))
    (should (equal (neoment-room-thread-buffer-name "$a" "Alice")
                   "neoment://thread/$a/sender/Alice"))
    (let ((buffer (generate-new-buffer "x")))
      (neoment-room--setup-buffer buffer "!r:s")
      (with-current-buffer buffer
        (should (equal (buffer-string) (neoment-room-test-gutter "Loading...")))
        (should visual-line-mode)
        (should hl-line-mode)
        (should (equal (neoment-room--header-line) "dev - Daily chat"))
        (setq neoment--thread-root-id "$a")
        (should (equal (neoment-room--header-line) "🧵 Thread in dev")))
      (kill-buffer buffer))
    (let ((buffer (neoment-room-test-buffer)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "09:12:44")
        (should (equal (filter-buffer-substring (line-beginning-position)
                                                (line-end-position))
                       "hi"))
        (should (equal (filter-buffer-substring (point-min) (point-max)) "hi")))
      (kill-buffer buffer))))

;;;; 5.3 Stable re-render

(ert-deftest neoment-room-stable-rerender ()
  (neoment-room-test
    (neoment-room-test-msg room "$1" "@alice:s" "first" (neoment-room-test-ts 9 0 0))
    (neoment-room-test-msg room "$2" "@bob:s" "second message" (neoment-room-test-ts 9 5 0))
    (let ((buffer (neoment-room-test-buffer)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "second m")
        (let ((col (current-column)))
          ;; New message below.
          (neoment-room-test-msg room "$3" "@carol:s" "third" (neoment-room-test-ts 9 10 0))
          (neoment-room-render-buffer)
          (should (looking-at "essage"))
          (should (= (current-column) col))
          ;; New message above.
          (neoment-room-test-msg room "$0" "@carol:s" "zero\nmore" (neoment-room-test-ts 8 0 0))
          (neoment-room-render-buffer)
          (should (looking-at "essage"))
          (should (equal (get-text-property (point) 'neoment-message) "$2"))))
      (kill-buffer buffer))))

;;;; 5.4 History and opening

(ert-deftest neoment-room-history-pagination ()
  (neoment-room-test
    (setf (neoment-client-sync-token neoment--client) "s1")
    (let ((calls 0))
      (neoment-test-with-http
          (lambda (args)
            (cl-incf calls)
            (if (= calls 1)
                '(:ok ((chunk) (end . "e1")))
              `(:ok ((chunk ((type . "m.room.message") (event_id . "$h") (sender . "@alice:s")
                             (origin_server_ts . 5) (content . ((body . "old")))))
                     (state ((type . "m.room.member") (event_id . "$m") (sender . "@me:s")
                             (state_key . "@me:s") (origin_server_ts . 4)
                             (content . ((membership . "leave")))))))))
        (neoment-room-load-more "!r:s")
        (let ((first (car neoment-test--requests))
              (second (cadr neoment-test--requests)))
          (should (equal (plist-get first :query)
                         '((limit . "20") (dir . "b") (from . "s1"))))
          (should (equal (alist-get 'from (plist-get second :query)) "e1")))
        (should (= calls 2))
        (should (eq (neoment-room-prev-batch room) 'end))
        (should (equal (neoment-message-content (neoment-room-get-message room "$h")) "old"))
        ;; History never removes the room.
        (should (neoment-has-room "!r:s"))
        (should (neoment-test-message-p "Loading more messages..."))
        (should (neoment-test-message-p "Messages loaded"))
        (setq neoment-test--messages nil)
        (neoment-room-load-more "!r:s")
        (should (= calls 2))
        (should (equal neoment-test--messages '("[Neoment] No more messages to load"))))
      (neoment-test-with-http (lambda (_) '(:error (:status 500 :error "boom")))
        (setf (neoment-room-prev-batch room) "e2")
        (neoment-room-load-more "!r:s")
        (should (neoment-test-message-p "Error loading more messages: boom"))))))

(ert-deftest neoment-room-open-and-kill ()
  (neoment-room-test
    (neoment-room-test-msg room "$1" "@alice:s" "old" 1)
    (neoment-room-set-tracked room nil)
    (let (buffer)
      (neoment-test-with-http
          (lambda (args)
            (if (string-suffix-p "/joined_members" (plist-get args :url))
                '(:ok ((joined (@new:s (display_name . "Newbie")))))
              'pending))
        (save-window-excursion
          (setq buffer (neoment-room-open "!r:s"))
          (should (equal (buffer-name buffer) "neoment://room/!r:s/dev"))
          (should (neoment-room-is-tracked room))
          (should (zerop (hash-table-count (neoment-room-messages room))))
          (should (seq-find (lambda (u) (string-suffix-p "/messages" u)) (neoment-test-request-urls)))
          (should (neoment-room-is-member-p "!r:s" "@new:s"))
          (should (equal (neoment-display-name "@new:s") "Newbie"))
          (should (eq (neoment-room-open "!r:s") buffer))))
      (neoment-room-test-msg room "$2" "@alice:s" "a" 2)
      (neoment-room-test-msg room "$3" "@alice:s" "b" 3)
      (kill-buffer buffer)
      (should-not (neoment-room-is-tracked room))
      (should (equal (hash-table-keys (neoment-room-messages room)) '("$3"))))))

;;;; 5.5 Read marking

(ert-deftest neoment-room-mark-read ()
  (neoment-room-test
    (neoment-room-test-msg room "$1" "@alice:s" "a" 1000)
    (setf (neoment-room-last-activity room) '(:timestamp 1000 :event-id "$1" :age 0)
          (neoment-room-unread room) t)
    (should (neoment-room-unread-p room))
    (neoment-room-mark-read "!r:s")
    (should-not (neoment-room-unread-p room))
    (should (equal (neoment-room-read-receipt room) '(:event-id "$1" :ts 1000 :is-local t)))
    (should (equal (neoment-room-fully-read room) "$1"))
    (let ((urls (neoment-test-request-urls)))
      (should (seq-find (lambda (u) (string-match-p "/send/m.marked_unread/" u)) urls))
      (should (seq-find (lambda (u) (string-suffix-p "/read_markers" u)) urls)))
    (should (equal (plist-get (seq-find (lambda (r) (string-suffix-p "/read_markers" (plist-get r :url)))
                                        neoment-test--requests)
                              :json)
                   '((m.fully_read . "$1") (m.read . "$1"))))
    ;; Nothing to do the second time.
    (let ((n (length neoment-test--requests)))
      (neoment-room-mark-read "!r:s")
      (should (= n (length neoment-test--requests))))))

;;;; 5.6 Coalesced rendering

(ert-deftest neoment-room-coalesced-rendering ()
  (neoment-room-test
    (neoment-room-test-msg room "$1" "@alice:s" "a" 1000)
    (let ((other (neoment-get-room "!o:s"))
          (renders 0)
          (neoment-ui--dirty (make-hash-table :test 'eq))
          (neoment-ui--timer nil)
          buffer other-buffer)
      (setf (neoment-room-name other) "other")
      (neoment-room-set-tracked other t)
      (setq buffer (neoment-room-test-buffer)
            other-buffer (generate-new-buffer "other"))
      (neoment-room--setup-buffer other-buffer "!o:s")
      (with-current-buffer other-buffer (neoment-room-render-buffer))
      (cl-letf (((symbol-function 'run-with-idle-timer) (lambda (&rest _) 'timer))
                ((symbol-function 'neoment-room-mark-read) #'ignore))
        (save-window-excursion
          (switch-to-buffer buffer)
          (let ((other-tick (buffer-modified-tick other-buffer)))
            (add-function :before (symbol-function 'neoment-room-render-buffer)
                          (lambda () (cl-incf renders)) '((name . count)))
            (unwind-protect
                (progn
                  ;; Two syncs change !r:s; one render.
                  (neoment-room-refresh "!r:s")
                  (neoment-room-refresh "!r:s")
                  (neoment-ui-flush)
                  (should (= renders 1))
                  ;; The unchanged room was not touched.
                  (should (= other-tick (buffer-modified-tick other-buffer)))
                  ;; A hidden buffer waits until it is shown.
                  (neoment-room-refresh "!o:s")
                  (neoment-ui-flush)
                  (should (= renders 1))
                  (should (gethash other-buffer neoment-ui--dirty))
                  (switch-to-buffer other-buffer)
                  (neoment-ui--on-window-buffer-change)
                  (should (= renders 2))
                  (should-not (gethash other-buffer neoment-ui--dirty)))
              (remove-function (symbol-function 'neoment-room-render-buffer) 'count)))))
      (kill-buffer buffer)
      (kill-buffer other-buffer))))

(provide 'neoment-room-test)
;;; neoment-room-test.el ends here
