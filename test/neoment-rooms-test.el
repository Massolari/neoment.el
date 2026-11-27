;;; neoment-rooms-test.el --- Tests for the room list  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 4 of the port: header lines, sections, room lines, previews,
;; the spaces tree, folding, the window, actions and pickers.

;;; Code:

(require 'test-helper)
(require 'neoment-rooms)

(defvar neoment-rooms-test-now 1800000000.0
  "Fixed current time (seconds) for the tests.")

(defmacro neoment-rooms-test (&rest body)
  "Run BODY with a fresh synced client and no network."
  (declare (indent 0))
  `(neoment-test-with-temp-dir
     (neoment-test-with-messages
       (let ((neoment-rooms-test-now (float-time))
             (neoment--client nil)
             (neoment-sync--status-client nil)
             (neoment-rooms--fold-sections nil)
             (neoment-rooms--fold-spaces nil)
             (neoment-rooms--fold-loaded nil)
             (neoment-rooms-display-last-message 'message)
             (neoment-rooms-room-title-format 'room_space)
             (neoment-icons neoment-default-icons)
             (neoment--bubble-edges neoment-faces-bubble-edges-nerd))
         (neoment-test-new-client)
         (neoment-sync-status)
         (neoment-sync--set-status :kind 'stopped
                                   :last-sync (- (truncate neoment-rooms-test-now) 10))
         (neoment-test-with-http (lambda (_) 'pending)
           ,@body)))))

(defun neoment-rooms-test-room (id name &rest props)
  "Create the joined room ID named NAME with the user as member.
PROPS: :ago (minutes since activity), :fav, :direct, :low, :unread,
:notifications, :highlights, :message."
  (let ((room (neoment-get-room id)))
    (setf (neoment-room-name room) name)
    (puthash "@me:s" t (neoment-room-members room))
    (when (plist-member props :ago)
      (let ((ts (truncate (* 1000 (- neoment-rooms-test-now
                                     (* 60 (plist-get props :ago)))))))
        (setf (neoment-room-last-activity room) (list :timestamp ts :event-id (concat "$" id) :age 0)
              (neoment-room-unread-activity room) (list :timestamp ts :event-id (concat "$" id) :age 0))
        (setf (neoment-room-fully-read room)
              (if (plist-get props :unread) "$other" (concat "$" id)))))
    (setf (neoment-room-is-favorite room) (plist-get props :fav)
          (neoment-room-is-direct room) (plist-get props :direct)
          (neoment-room-is-lowpriority room) (plist-get props :low)
          (neoment-room-unread-notifications room) (or (plist-get props :notifications) 0)
          (neoment-room-unread-highlights room) (or (plist-get props :highlights) 0))
    (when (plist-get props :message)
      (puthash "$m" (neoment-message--create :id "$m" :sender "@alice:s"
                                             :content (plist-get props :message)
                                             :timestamp 1)
               (neoment-room-messages room)))
    room))

(defun neoment-rooms-test-render (&optional open-ids width)
  "Render the room list with OPEN-IDS and WIDTH."
  (neoment-rooms-render :width (or width 30) :open-ids open-ids
                        :now neoment-rooms-test-now))

(defun neoment-rooms-test-lines (&optional open-ids)
  "Return the rendered room list lines without properties."
  (split-string (substring-no-properties (neoment-rooms-test-render open-ids)) "\n"))

;;;; 4.1 Header

(ert-deftest neoment-rooms-title-line ()
  (should (equal (substring-no-properties (neoment-rooms--title-line 30))
                 (concat (make-string 10 ?─) " Neoment " (make-string 11 ?─))))
  (let ((line (neoment-rooms--title-line 30)))
    (should (eq (get-text-property 0 'face line) 'neoment-header-decoration))
    (should (eq (get-text-property 11 'face line) 'neoment-rooms-title))))

(ert-deftest neoment-rooms-empty-states ()
  (neoment-rooms-test
    (neoment-sync-reset)
    (should (equal (neoment-rooms-test-render) "No sync yet"))
    (neoment-sync--set-status :kind 'syncing)
    (should (equal (neoment-rooms-test-render) "Syncing..."))))

(ert-deftest neoment-rooms-user-line-variants ()
  (neoment-rooms-test
    (neoment-set-display-name "@me:s" "Douglas" 1)
    (neoment-set-presence "@me:s" '(:presence "online"))
    (let ((line (neoment-rooms--user-line neoment-rooms-test-now)))
      (should (equal (substring-no-properties line)
                     " Douglas │ ● online   ● synced"))
      (should (eq (get-text-property (string-search "● synced" line) 'face line)
                  'neoment-sync-ok))
      (should (eq (get-text-property (string-search "synced" line) 'face line)
                  'neoment-comment)))
    (neoment-set-presence "@me:s" '(:presence "unavailable"))
    (should (string-search "◐ unavailable"
                           (neoment-rooms--user-line neoment-rooms-test-now)))
    (neoment-set-presence "@me:s" nil)
    (should (string-search "○ offline" (neoment-rooms--user-line neoment-rooms-test-now)))
    (cl-flet ((status (ago &optional kind)
                (neoment-sync--set-status :kind (or kind 'stopped)
                                          :last-sync (and ago (- (truncate neoment-rooms-test-now) ago)))
                (let ((s (neoment-rooms--sync-status neoment-rooms-test-now)))
                  (concat (nth 0 s) " " (nth 1 s)))))
      (should (equal (status nil) "◇ offline"))
      (should (equal (status nil 'syncing) "◇ connecting"))
      (should (equal (status 30) "● synced"))
      (should (equal (status 600) "● 10m ago"))
      (should (equal (status 7200)
                     (concat "○ " (format-time-string "%H:%M" (- (truncate neoment-rooms-test-now) 7200))))))))

;;;; 4.2 Sections

(ert-deftest neoment-rooms-sections-and-priority ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!fav:s" "favdm" :fav t :direct t :ago 1)
    (neoment-rooms-test-room "!dm:s" "dm" :direct t :low t :ago 1)
    (neoment-rooms-test-room "!low:s" "low" :low t :ago 1)
    (neoment-rooms-test-room "!plain:s" "plain" :ago 1)
    (let* ((sections (neoment-rooms--classify '("!fav:s")))
           (ids (lambda (s) (mapcar #'neoment-room-id (alist-get s sections)))))
      (should (equal (funcall ids 'buffers) '("!fav:s")))
      (should (equal (funcall ids 'favorites) nil))
      (should (equal (funcall ids 'people) '("!dm:s")))
      (should (equal (funcall ids 'low_priority) '("!low:s")))
      (should (equal (funcall ids 'rooms) '("!plain:s"))))
    (let ((headers (seq-filter (lambda (l) (string-match-p "([0-9]+)\\'" l))
                               (neoment-rooms-test-lines))))
      ;; No Invited, Buffers or Spaces section.
      (should (equal (mapcar (lambda (l) (car (last (split-string l "  ")))) headers)
                     '("Favorites (1)" "People (1)" "Rooms (1)" "Low priority (1)"))))
    (neoment-get-invited-room "!inv:s")
    (should (member (concat "▼ " (neoment-icon 'invite) "  Invited (1)")
                    (neoment-rooms-test-lines)))))

(ert-deftest neoment-rooms-unread-before-recent ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!a:s" "A" :ago 1)
    (neoment-rooms-test-room "!b:s" "B" :ago 60 :unread t)
    (should (equal (mapcar #'neoment-room-id (alist-get 'rooms (neoment-rooms--classify nil)))
                   '("!b:s" "!a:s")))))

(ert-deftest neoment-rooms-notifications-before-unread ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!a:s" "A" :ago 1 :unread t)
    (neoment-rooms-test-room "!b:s" "B" :ago 60 :unread t :notifications 1)
    (should (equal (mapcar #'neoment-room-id (alist-get 'rooms (neoment-rooms--classify nil)))
                   '("!b:s" "!a:s")))))

(ert-deftest neoment-rooms-highlights-before-unread ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!a:s" "A" :ago 1 :unread t)
    (neoment-rooms-test-room "!b:s" "B" :ago 60 :unread t :highlights 1)
    (should (equal (mapcar #'neoment-room-id (alist-get 'rooms (neoment-rooms--classify nil)))
                   '("!b:s" "!a:s")))))

(ert-deftest neoment-rooms-highlights-and-notifications-by-activity ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!a:s" "A" :ago 60 :unread t :highlights 1)
    (neoment-rooms-test-room "!b:s" "B" :ago 1 :unread t :notifications 1)
    (should (equal (mapcar #'neoment-room-id (alist-get 'rooms (neoment-rooms--classify nil)))
                   '("!b:s" "!a:s")))))

(ert-deftest neoment-rooms-full-attention-order ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!read:s" "Read" :ago 1)
    (neoment-rooms-test-room "!unread:s" "Unread" :ago 5 :unread t)
    (neoment-rooms-test-room "!notif:s" "Notif" :ago 60 :unread t :notifications 2)
    (should (equal (mapcar #'neoment-room-id (alist-get 'rooms (neoment-rooms--classify nil)))
                   '("!notif:s" "!unread:s" "!read:s")))))

(ert-deftest neoment-rooms-counts-rank-first-even-when-read ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!a:s" "A" :ago 1 :unread t)
    (neoment-rooms-test-room "!b:s" "B" :ago 60 :notifications 1)
    (should-not (neoment-room-unread-p (neoment-get-room "!b:s")))
    (should (equal (mapcar #'neoment-room-id (alist-get 'rooms (neoment-rooms--classify nil)))
                   '("!b:s" "!a:s")))))

(ert-deftest neoment-rooms-mark-read-clears-counts ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!r:s" "dev" :ago 60 :notifications 1 :highlights 1)
    (neoment-test-with-http (lambda (_) '(:ok nil))
      (neoment-rooms-test-at "dev 1h"
        (neoment-rooms-toggle-read)))
    (let ((room (neoment-get-room "!r:s")))
      (should (equal (neoment-room-unread-highlights room) 0))
      (should (equal (neoment-room-unread-notifications room) 0))
      (should-not (neoment-rooms--has-counts room)))))

(ert-deftest neoment-rooms-mark-read-failure-keeps-counts ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!r:s" "dev" :ago 60 :notifications 1)
    (neoment-test-with-http (lambda (_) '(:error (:status 500)))
      (neoment-rooms-test-at "dev 1h"
        (neoment-rooms-toggle-read)))
    (should (neoment-rooms--has-counts (neoment-get-room "!r:s")))))

(ert-deftest neoment-rooms-header-face-and-blank-lines ()
  (neoment-rooms-test
    (let* ((text (neoment-rooms-test-render))
           (lines (split-string (substring-no-properties text) "\n"))
           (pos (string-search "Favorites" text)))
      (should (equal (nth 2 lines) ""))
      (should (equal (nth 3 lines) (concat "▼ " (neoment-icon 'favorite) "  Favorites (0)")))
      (should (equal (nth 4 lines) ""))
      (should (eq (get-text-property pos 'neoment-section text) 'favorites))
      (should (memq 'neoment-section-title
                    (ensure-list (get-text-property pos 'face text))))
      (should-not (get-text-property 0 'face (substring text (string-search "▼" text)))))))

;;;; 4.3 Room lines and previews

(ert-deftest neoment-rooms-room-line-format ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!r:s" "dev" :ago 5 :highlights 1 :notifications 1)
    (let* ((text (neoment-rooms-test-render))
           (line (seq-find (lambda (l) (string-search "dev" l))
                           (split-string text "\n"))))
      (should (equal (substring-no-properties line)
                     (concat "  " (neoment-icon 'room) "  dev 5m " (neoment-icon 'bell))))
      (should (memq 'neoment-notification-bell (ensure-list (get-text-property (1- (length line)) 'face line))))
      (should (memq 'neoment-room-icon-unread (ensure-list (get-text-property 2 'face line))))
      (should (memq 'neoment-room-unread (ensure-list (get-text-property 6 'face line))))
      (should (equal (get-text-property 0 'neoment-room line) "!r:s")))))

(ert-deftest neoment-rooms-relative-times-and-badges ()
  (let ((now (* 1000 (truncate neoment-rooms-test-now))))
    (should (equal (neoment-rooms--relative-time (- now 1000) now) "now"))
    (should (equal (neoment-rooms--relative-time (- now (* 5 60000)) now) "5m"))
    (should (equal (neoment-rooms--relative-time (- now (* 3 3600000)) now) "3h"))
    (should (equal (neoment-rooms--relative-time (- now (* 2 86400000)) now) "2d"))
    (let ((old (- now (* 10 86400000))))
      (should (equal (neoment-rooms--relative-time old now)
                     (format-time-string "%d/%m" (/ old 1000)))))
    (should (equal (neoment-rooms--relative-time
                    (* 1000 (truncate (float-time (encode-time '(0 0 12 13 11 2026 nil nil nil)))))
                    (* 1000 (truncate (float-time (encode-time '(0 0 12 23 11 2026 nil nil nil))))))
                   "13/11")))
  (neoment-rooms-test
    (let ((r (neoment-rooms-test-room "!r:s" "dev" :ago 1 :notifications 2)))
      (should (equal (neoment-rooms--badge r)
                     (cons (neoment-icon 'dot_circle) 'neoment-notification-circle)))
      (setf (neoment-room-unread-notifications r) 0
            (neoment-room-fully-read r) "$x")
      (should (equal (neoment-rooms--badge r) (cons "•" 'neoment-notification-dot)))
      (setf (neoment-room-last-activity r) nil)
      (should-not (neoment-rooms--badge r)))))

;;;; Issue #7: plain unread false positives

(defun neoment-rooms-test-order ()
  "Return the ids of the rooms group in display order."
  (mapcar #'neoment-room-id (alist-get 'rooms (neoment-rooms--classify nil))))

(defun neoment-rooms-test-now-ms ()
  "Return the test's current time in milliseconds."
  (truncate (* 1000 neoment-rooms-test-now)))

(ert-deftest neoment-rooms-receipt-moved-to-later-event-is-read ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!old:s" "Old" :ago 60 :unread t)
    (neoment-rooms-test-room "!recent:s" "Recent" :ago 1)
    (let ((r (neoment-rooms-test-room "!a:s" "A" :ago 5 :unread t)))
      (should (equal (neoment-rooms--badge r) (cons "•" 'neoment-notification-dot)))
      (should (equal (neoment-rooms-test-order) '("!a:s" "!old:s" "!recent:s")))
      ;; Another client put the receipt on a later event this room never loaded.
      (setf (neoment-room-read-receipt r)
            (list :event-id "$later-state" :ts (neoment-rooms-test-now-ms)))
      (should-not (neoment-rooms--badge r))
      (should (equal (neoment-rooms-test-order) '("!old:s" "!recent:s" "!a:s"))))))

(ert-deftest neoment-rooms-own-message-is-read ()
  (neoment-rooms-test
    (let ((r (neoment-rooms-test-room "!a:s" "A" :ago 5)))
      (neoment-events-handle
       r (neoment-test-event "m.room.message" :id "$mine" :sender "@me:s"
                             :ts (neoment-rooms-test-now-ms)
                             :content '((msgtype . "m.text") (body . "hi"))))
      (should (equal (plist-get (neoment-room-last-activity r) :event-id) "$mine"))
      (should-not (neoment-room-unread-p r))
      (should-not (neoment-rooms--badge r)))))

(ert-deftest neoment-rooms-thread-reply-is-read-but-moves-up ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!b:s" "B" :ago 1)
    (let ((r (neoment-rooms-test-room "!a:s" "A" :ago 5)))
      (should (equal (neoment-rooms-test-order) '("!b:s" "!a:s")))
      (neoment-events-handle
       r (neoment-test-event "m.room.message" :id "$reply" :sender "@alice:s"
                             :ts (neoment-rooms-test-now-ms)
                             :content '((msgtype . "m.text") (body . "reply")
                                        (m.relates_to . ((rel_type . "m.thread")
                                                         (event_id . "$root"))))))
      (should-not (neoment-rooms--badge r))
      (should (equal (neoment-rooms-test-order) '("!a:s" "!b:s"))))))

(ert-deftest neoment-rooms-buffer-and-space-suffix ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!r:s" "geral" :ago 1)
    (let ((space (neoment-rooms-test-room "!sp:s" "Neovim")))
      (neoment-room-add-space-child space "!r:s"))
    (let* ((text (neoment-rooms-test-render '("!r:s")))
           (line (seq-find (lambda (l) (string-search "geral" l)) (split-string text "\n"))))
      (should (string-suffix-p " Neovim" (substring-no-properties line)))
      (should (memq 'neoment-room-space (ensure-list (get-text-property (1- (length line)) 'face line))))
      (should (memq 'neoment-buffer-room (ensure-list (get-text-property 6 'face line))))
      (should (memq 'neoment-room-icon-buffer (ensure-list (get-text-property 2 'face line)))))
    (let ((neoment-rooms-room-title-format 'space_room))
      (should (seq-find (lambda (l) (string-search "Neovim/geral" l))
                        (neoment-rooms-test-lines '("!r:s")))))))

(ert-deftest neoment-rooms-previews ()
  (neoment-rooms-test
    (neoment-set-display-name "@alice:s" "Alice Wonderland Long" 1)
    (neoment-rooms-test-room "!r:s" "dev" :ago 1 :message (make-string 60 ?x))
    (let ((preview (cl-flet ((line () (nth 1 (member (concat "  " (neoment-icon 'room) "  dev 1m")
                                                     (neoment-rooms-test-lines)))))
                     (list (line)
                           (let ((neoment-rooms-display-last-message 'sender_message_inline)) (line))
                           (let ((neoment-rooms-display-last-message 'no)) (line))))))
      (should (equal (nth 0 preview) (concat "    │ " (make-string 39 ?x) "…")))
      (should (equal (nth 1 preview) (concat "    │ Alice Wonderla…: " (make-string 39 ?x) "…")))
      (should (equal (nth 2 preview) "")))
    (let ((neoment-rooms-display-last-message 'sender_message))
      (should (member "    │ Alice Wonderla…" (neoment-rooms-test-lines))))
    ;; Attachment without text.
    (let ((m (neoment-room-last-message (neoment-get-room "!r:s"))))
      (setf (neoment-message-content m) ""
            (neoment-message-attachment m) '(:type image :filename "cat.png")))
    (should (member (concat "    │ " (neoment-icon 'image) " cat.png") (neoment-rooms-test-lines)))
    ;; Preview lines are not rooms.
    (let* ((text (neoment-rooms-test-render))
           (pos (string-search "    │ " text)))
      (should (get-text-property pos 'neoment-preview text))
      (should-not (get-text-property pos 'neoment-room text)))))

;;;; 4.4 Spaces and folding

(ert-deftest neoment-rooms-spaces-tree ()
  (neoment-rooms-test
    (let ((top (neoment-rooms-test-room "!top:s" "Top"))
          (sub (neoment-rooms-test-room "!sub:s" "Sub")))
      (neoment-rooms-test-room "!a:s" "a" :ago 1)
      (neoment-rooms-test-room "!b:s" "b" :ago 1)
      (neoment-get-room "!notmember:s")
      (neoment-room-add-space-child top "!a:s")
      (neoment-room-add-space-child top "!sub:s")
      (neoment-room-add-space-child top "!notmember:s")
      (neoment-room-add-space-child sub "!b:s")
      ;; Folded by default; Sub is not top level.
      (let ((lines (neoment-rooms-test-lines)))
        (should (member (concat "▼ " (neoment-icon 'space) "  Spaces (1)") lines))
        (should (member "  ▶ Top" lines))
        (should-not (member "  ▶ Sub" lines)))
      (setq neoment-rooms--fold-spaces '(("!top:s") ("!sub:s")))
      (let ((lines (neoment-rooms-test-lines)))
        (should (member "  ▼ Top" lines))
        (should (member (concat "    " (neoment-icon 'room) "  a 1m") lines))
        (should (member "    ▼ Sub" lines))
        (should (member (concat "      " (neoment-icon 'room) "  b 1m") lines))
        (should-not (seq-find (lambda (l) (string-search "notmember" l)) lines))))))

(defun neoment-rooms-test-buffer ()
  "Render the room list into its buffer and return it."
  (let ((buffer (neoment-rooms--get-buffer)))
    (neoment-rooms-refresh)
    buffer))

(defun neoment-rooms-test-goto (text)
  "Move point to the line containing TEXT."
  (goto-char (point-min))
  (search-forward text)
  (forward-line 0))

(ert-deftest neoment-rooms-fold-toggling ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!dm:s" "Alice" :direct t :ago 1)
    (let ((sp (neoment-rooms-test-room "!sp:s" "Space")))
      (neoment-room-add-space-child sp "!dm:s"))
    (with-current-buffer (neoment-rooms-test-buffer)
      (unwind-protect
          (progn
            (neoment-rooms-test-goto "People (1)")
            (neoment-rooms-toggle-fold)
            (should (search-forward "▶" (line-end-position) t))
            (should-not (string-search "Alice 1m" (buffer-string)))
            ;; Space.
            (neoment-rooms-test-goto "▶ Space")
            (neoment-rooms-toggle-fold)
            (should (string-search "▼ Space" (buffer-string)))
            ;; Elsewhere.
            (goto-char (point-min))
            (neoment-rooms-toggle-fold)
            (should (neoment-test-message-p
                     "No section found on this line. Position the cursor over a section title."))
            ;; Reloaded from disk.
            (setq neoment-rooms--fold-sections nil neoment-rooms--fold-spaces nil
                  neoment-rooms--fold-loaded nil)
            (should (neoment-rooms--section-folded-p 'people))
            (should-not (neoment-rooms--space-folded-p "!sp:s")))
        (kill-buffer)))))

;;;; 4.5 Window

(ert-deftest neoment-rooms-toggle-window ()
  (neoment-rooms-test
    (delete-other-windows)
    (neoment-toggle-rooms-list)
    (let ((window (neoment-rooms--window)))
      (should window)
      (should (window-parameter window 'window-side))
      (should (window-dedicated-p window))
      (should (eq (window-buffer (selected-window)) (neoment-rooms--buffer)))
      (with-current-buffer (neoment-rooms--buffer)
        (should (eq major-mode 'neoment-rooms-mode))
        (should (eq window-size-fixed 'width))
        (should hl-line-mode)))
    (neoment-toggle-rooms-list)
    (should-not (neoment-rooms--window))
    (kill-buffer (neoment-rooms--buffer))))

(ert-deftest neoment-rooms-width ()
  (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) 300)))
    (should (= (neoment-rooms--default-width) 50)))
  (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) 120)))
    (should (= (neoment-rooms--default-width) 24))))

;;;; 4.6 Actions

(defmacro neoment-rooms-test-at (text &rest body)
  "Run BODY in the rendered room list with point on the line with TEXT."
  (declare (indent 1))
  `(with-current-buffer (neoment-rooms-test-buffer)
     (unwind-protect
         (progn (neoment-rooms-test-goto ,text) ,@body)
       (kill-buffer))))

(ert-deftest neoment-rooms-tag-actions ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!r:s" "dev" :ago 1)
    (neoment-test-with-http (lambda (_) '(:ok nil))
      (neoment-rooms-test-at "dev 1m"
        (neoment-rooms-toggle-favorite)
        (let ((req (car neoment-test--requests)))
          (should (eq (plist-get req :method) 'put))
          (should (equal (plist-get req :url)
                         "https://hs.example/_matrix/client/v3/user/%40me%3As/rooms/%21r%3As/tags/m.favourite"))
          (should (equal (plist-get req :json) '((order . 0)))))
        (should (neoment-test-message-p "dev added to favorites"))
        (should (neoment-room-is-favorite (neoment-get-room "!r:s")))
        (neoment-rooms-test-goto "dev 1m")
        (neoment-rooms-toggle-favorite)
        (should (eq (plist-get (cadr neoment-test--requests) :method) 'delete))
        (should (neoment-test-message-p "dev removed from favorites"))))
    (neoment-test-with-http (lambda (_) '(:error (:status 500 :error "boom")))
      (neoment-rooms-test-at "dev 1m"
        (neoment-rooms-toggle-low-priority)
        (should (neoment-test-message-p "Error adding dev to low priority: boom"))))))

(ert-deftest neoment-rooms-invite-specific-messages ()
  (neoment-rooms-test
    (setf (neoment-invited-room-name (neoment-get-invited-room "!i:s")) "invroom")
    (neoment-rooms-test-at "invroom"
      (neoment-rooms-toggle-favorite)
      (should (neoment-test-message-p "You cannot add an invited room to favorites."))
      (neoment-rooms-room-notification-settings)
      (should (neoment-test-message-p
               "Notification settings are available after joining the room."))
      (neoment-rooms-toggle-direct)
      (should (neoment-test-message-p "You cannot mark an invited room as direct.")))))

(ert-deftest neoment-rooms-invite-reject ()
  (neoment-rooms-test
    (setf (neoment-invited-room-name (neoment-get-invited-room "!i:s")) "invroom")
    (neoment-test-with-http (lambda (_) '(:ok nil))
      (cl-letf (((symbol-function 'read-multiple-choice)
                 (lambda (prompt &rest _)
                   (should (equal prompt "You have been invited to join the room: invroom"))
                   '(?r "Reject"))))
        (neoment-rooms-test-at "invroom"
          (neoment-rooms-enter)))
      (should (equal (car (neoment-test-request-urls))
                     "https://hs.example/_matrix/client/v3/rooms/%21i%3As/leave"))
      (should (neoment-test-message-p "Left room: invroom"))
      (should-not (neoment-has-invited-room "!i:s")))))

(ert-deftest neoment-rooms-direct-read-status ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!r:s" "dev" :ago 1)
    (neoment-test-with-http (lambda (_) '(:ok ((event_id . "$e"))))
      (neoment-rooms-test-at "dev 1m"
        (neoment-rooms-toggle-direct)
        (should (neoment-test-message-p "dev marked as direct"))
        (should (null neoment-test--requests))
        ;; Read room -> marked unread.
        (neoment-rooms-test-goto "dev 1m")
        (neoment-rooms-toggle-read)
        (let ((req (car neoment-test--requests)))
          (should (string-match-p "/send/m.marked_unread/neoment-el-" (plist-get req :url)))
          (should (equal (plist-get req :json) '((unread . t)))))
        (should (neoment-test-message-p "Room 'dev' marked as unread"))
        ;; Unread room -> private receipt.
        (neoment-rooms-test-goto "dev 1m")
        (neoment-rooms-toggle-read)
        (let ((req (cadr neoment-test--requests)))
          (should (string-suffix-p "/read_markers" (plist-get req :url)))
          (should (equal (plist-get req :json) '((m.read.private . "$!r:s")))))
        (should (neoment-test-message-p "Room 'dev' marked as read"))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (should (equal prompt "Change status (current: offline): "))
                 "◐ unavailable")))
      (neoment-rooms-change-status))
    (should (equal (neoment-client-desired-presence neoment--client) "unavailable"))
    (should (neoment-test-message-p "Status will change to 'unavailable' on next sync"))))

(ert-deftest neoment-rooms-refresh-state ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!r:s" "dev" :ago 1)
    (neoment-test-with-http
        (lambda (_) '(:ok (((type . "m.room.name") (event_id . "$n") (content . ((name . "dev")))))))
      (neoment-rooms-test-at "dev 1m"
        (neoment-rooms-refresh-room-state)))
    (should (neoment-test-message-p "Refreshing state for dev..."))
    (should (neoment-test-message-p "No new state for dev"))
    (neoment-test-with-http
        (lambda (_) '(:ok (((type . "m.room.topic") (event_id . "$t") (content . ((topic . "new"))))
                           ((type . "m.room.message") (event_id . "$x") (content . ((body . "ignored")))))))
      (neoment-rooms-test-at "dev 1m"
        (neoment-rooms-refresh-room-state)))
    (should (neoment-test-message-p "State updated for dev"))
    (should (equal (neoment-room-topic (neoment-get-room "!r:s")) "new"))
    (should-not (neoment-room-last-message (neoment-get-room "!r:s")))))

(ert-deftest neoment-rooms-refresh-state-alias-name ()
  (neoment-rooms-test
    (let ((room (neoment-rooms-test-room "!r:s" "!r:s" :ago 1)))
      (setf (neoment-room-aliases room) '("#dev:s")))
    (neoment-test-with-http (lambda (_) '(:ok nil))
      (neoment-rooms-test-at "#dev:s 1m"
        (neoment-rooms-refresh-room-state)))
    (should (neoment-test-message-p "Refreshing state for #dev:s..."))
    (should (neoment-test-message-p "No new state for #dev:s"))))

(ert-deftest neoment-rooms-navigation ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!a:s" "aaa" :ago 1 :message "hello")
    (neoment-rooms-test-room "!b:s" "bbb" :ago 2 :message "world")
    (neoment-rooms-test-at "aaa 1m"
      (neoment-rooms-next)
      (should (looking-at (concat "  " (neoment-icon 'room) "  bbb")))
      (neoment-rooms-previous)
      (should (looking-at (concat "  " (neoment-icon 'room) "  aaa")))
      ;; RET on a preview line.
      (forward-line 1)
      (neoment-rooms-enter)
      (should (neoment-test-message-p
               "No room found on this line. Position the cursor directly over the room name."))
      ;; End of list.
      (goto-char (point-max))
      (forward-line 0)
      (neoment-rooms-next)
      (should (neoment-test-message-p "No more rooms in this direction")))))

;;;; 4.7 Pickers

(ert-deftest neoment-rooms-pickers ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!r:s" "dev" :ago 5 :notifications 1)
    (neoment-rooms-test-room "!q:s" "quiet")
    (let ((sp (neoment-rooms-test-room "!sp:s" "Space")))
      (neoment-room-add-space-child sp "!r:s"))
    (let (got opened)
      (let ((neoment-room-picker-function
             (lambda (items callback prompt)
               (setq got (list items prompt))
               (funcall callback "!r:s"))))
        (cl-letf (((symbol-function 'neoment-rooms-open-room) (lambda (id) (setq opened id))))
          (neoment-pick-room)))
      (should (equal (cadr got) "Select a room:"))
      (should (member (cons (concat (neoment-icon 'room) "  Space/dev [5m] " (neoment-icon 'dot_circle)) "!r:s")
                      (car got)))
      (should (member (cons (concat (neoment-icon 'room) "  quiet") "!q:s") (car got)))
      (should (member (cons (concat (neoment-icon 'space) "  Space") "!sp:s") (car got)))
      (should (equal opened "!r:s")))
    (neoment-pick-open-room)
    (should (neoment-test-message-p "No open rooms"))
    ;; Default picker.
    (let (picked)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt items &rest _)
                   (should (equal prompt "Select a room: "))
                   (caar items))))
        (neoment-completing-read-picker '(("x" . "!x:s")) (lambda (id) (setq picked id))
                                        "Select a room:"))
      (should (equal picked "!x:s")))))

(ert-deftest neoment-rooms-pick-room-notifications-first ()
  (neoment-rooms-test
    (neoment-rooms-test-room "!read:s" "Read" :ago 1)
    (neoment-rooms-test-room "!unread:s" "Unread" :ago 5 :unread t)
    (neoment-rooms-test-room "!notif:s" "Notif" :ago 60 :unread t :highlights 1)
    (let (ids)
      (cl-letf (((symbol-function 'neoment-rooms-pick)
                 (lambda (room-ids &rest _) (setq ids room-ids))))
        (neoment-pick-room))
      (should (equal ids '("!notif:s" "!unread:s" "!read:s"))))))

(provide 'neoment-rooms-test)
;;; neoment-rooms-test.el ends here
