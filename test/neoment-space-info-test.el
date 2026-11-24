;;; neoment-space-info-test.el --- Tests for spaces and room info  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 9 of the port: the space hierarchy buffer and the room
;; information buffer.

;;; Code:

(require 'test-helper)
(require 'neoment-space)
(require 'neoment-room-info)

(defmacro neoment-space-test (&rest body)
  "Run BODY with a client, the space !sp:s and no network."
  (declare (indent 0))
  `(neoment-test-with-temp-dir
     (neoment-test-with-messages
       (let ((neoment--client nil)
             (neoment--bubble-edges neoment-faces-bubble-edges-nerd)
             (neoment-icons neoment-default-icons))
         (neoment-test-new-client)
         (let ((space (neoment-get-room "!sp:s")))
           (setf (neoment-room-name space) "Neovim Brasil"
                 (neoment-room-topic space) "Line one\n\nLine two")
           (puthash "@me:s" t (neoment-room-members space))
           (neoment-test-with-http (lambda (_) 'pending)
             ,@body))))))

(defconst neoment-space-test-hierarchy
  (neoment-json-decode
   "{\"rooms\":[
     {\"room_id\":\"!sp:s\",\"name\":\"Neovim Brasil\",\"room_type\":\"m.space\",\"num_joined_members\":120,
      \"topic\":\"main\\nmore\",
      \"children_state\":[{\"state_key\":\"!geral:s\",\"content\":{\"via\":[\"s\"]}},
                          {\"state_key\":\"!off:s\",\"content\":{\"via\":[\"other\"]}},
                          {\"state_key\":\"!sub:s\",\"content\":{\"via\":[\"s\"]}}]},
     {\"room_id\":\"!geral:s\",\"name\":\"geral\",\"num_joined_members\":80,\"children_state\":[]},
     {\"room_id\":\"!off:s\",\"name\":\"\",\"num_joined_members\":40,\"children_state\":[]},
     {\"room_id\":\"!sub:s\",\"name\":\"Subespaco\",\"room_type\":\"m.space\",\"num_joined_members\":10,
      \"children_state\":[{\"state_key\":\"!x:s\",\"content\":{\"via\":[\"s\"]}},
                          {\"state_key\":\"!geral:s\",\"content\":{\"via\":[\"s\"]}}]},
     {\"room_id\":\"!x:s\",\"name\":\"sala-x\",\"num_joined_members\":5,\"children_state\":[]}]}")
  "A fixture /hierarchy response.")

;;;; 9.1 Space render

(ert-deftest neoment-space-render-layout ()
  (neoment-space-test
    (puthash "@me:s" t (neoment-room-members (neoment-get-room "!geral:s")))
    (let* ((rooms (alist-get 'rooms neoment-space-test-hierarchy))
           (text (neoment-space-render "!sp:s" rooms))
           (lines (split-string (substring-no-properties text) "\n"))
           (space (neoment-icon 'space))
           (room (neoment-icon 'room)))
      (should (equal lines
                     (list "Neovim Brasil" "" "Topic:" "Line one" "Line two" "" "Rooms:"
                           (concat space "  " "Joined Neovim Brasil (120 members) - main...")
                           (concat "  " room "  Joined geral (80 members)")
                           (concat "  " room "  (No Name) (40 members)")
                           (concat "  " space "  Subespaco (10 members)")
                           (concat "    " room "  sala-x (5 members)"))))
      (should (eq (get-text-property 0 'face text) 'neoment-rooms-title))
      (should (eq (get-text-property (string-search "Topic:" text) 'face text) 'bold))
      (should (eq (get-text-property (string-search " - main" text) 'face text) 'neoment-comment))
      (should (equal (get-text-property (string-search "geral" text) 'neoment-space-item text)
                     '(:room-id "!geral:s" :via ("s") :is-space nil))))))

(ert-deftest neoment-space-render-empty ()
  (neoment-space-test
    (setf (neoment-room-topic (neoment-get-room "!sp:s")) "")
    (let ((lines (split-string
                  (substring-no-properties
                   (neoment-space-render
                    "!sp:s" (list '((room_id . "!sp:s") (name . "S") (room_type . "m.space")
                                    (num_joined_members . 1) (children_state)))))
                  "\n")))
      (should (member "No topic" lines))
      (should (equal (car (last lines)) "  No rooms in this space")))))

;;;; 9.2 Space actions

(ert-deftest neoment-space-open-and-actions ()
  (neoment-space-test
    (save-window-excursion
      (let (opened)
        (neoment-test-with-http
            (lambda (args)
              (cond
               ((string-search "/hierarchy" (plist-get args :url))
                (list :ok neoment-space-test-hierarchy))
               ((string-search "/join/" (plist-get args :url)) '(:ok ((room_id . "!off:s"))))
               (t 'pending)))
          (let ((buffer (neoment-space-open "!sp:s")))
            (unwind-protect
                (cl-letf (((symbol-function 'neoment-rooms-open-room) (lambda (id) (push id opened))))
                  (should (equal (buffer-name buffer) "*neoment-space: Neovim Brasil*"))
                  (should (string-search "sala-x" (buffer-string)))
                  ;; Not an item.
                  (goto-char (point-min))
                  (neoment-space-enter)
                  (should (neoment-test-message-p "No room or space under the cursor"))
                  ;; Join with via.
                  (search-forward "(No Name)")
                  (cl-letf (((symbol-function 'read-multiple-choice)
                             (lambda (prompt &rest _)
                               (should (equal prompt "Do you want to join this room?"))
                               '(?j "Join"))))
                    (neoment-space-enter))
                  (let ((join (seq-find (lambda (r) (string-search "/join/" (plist-get r :url)))
                                        neoment-test--requests)))
                    (should (string-suffix-p "/join/%21off%3As" (plist-get join :url)))
                    (should (equal (plist-get join :query) '((via "s" "matrix.org" "other")))))
                  (should (equal (car opened) "!off:s"))
                  ;; Joined room opens.
                  (puthash "@me:s" t (neoment-room-members (neoment-get-room "!geral:s")))
                  (goto-char (point-min))
                  (search-forward "geral")
                  (neoment-space-enter)
                  (should (equal (car opened) "!geral:s"))
                  ;; Keys.
                  (should (eq (keymap-lookup neoment-space-mode-map "q") 'neoment-space-quit))
                  (should (eq (keymap-lookup neoment-space-mode-map "g") 'revert-buffer))
                  (should (eq (keymap-lookup neoment-space-mode-map "l") 'neoment-toggle-rooms-list)))
              (kill-buffer buffer))))))))

(ert-deftest neoment-space-hierarchy-error ()
  (neoment-space-test
    (save-window-excursion
      (neoment-test-with-http (lambda (_) '(:error (:status 403 :error "Forbidden")))
        (let ((buffer (neoment-space-open "!sp:s")))
          (should (equal (with-current-buffer buffer (buffer-string)) "Loading space..."))
          (kill-buffer buffer)))
      (should (neoment-test-message-p "Failed to fetch space hierarchy: Forbidden")))))

;;;; 9.3 Room info

(ert-deftest neoment-room-info-layout ()
  (neoment-space-test
    (let ((room (neoment-get-room "!r:s")))
      (setf (neoment-room-name room) "dev"
            (neoment-room-topic room) "Daily"
            (neoment-room-is-favorite room) t
            (neoment-room-aliases room) '("#dev:s"))
      (neoment-room-add-space-child (neoment-get-room "!sp:s") "!r:s")
      (dolist (m '(("@me:s" . "Me") ("@bob:s" . "bob") ("@alice:s" . "Alice")))
        (puthash (car m) t (neoment-room-members room))
        (neoment-set-display-name (car m) (cdr m) 1))
      (puthash "@noname:s" t (neoment-room-members room))
      (let* ((text (neoment-room-info-render "!r:s" :width 30))
             (lines (split-string (substring-no-properties text) "\n")))
        (should (equal lines
                       (list (concat (make-string 12 ?─) " dev " (make-string 13 ?─))
                             "No image"
                             "Room Type: Room" ""
                             "Topic:" "Daily" ""
                             "Space: Neovim Brasil" ""
                             "Status:"
                             (concat " " (neoment-icon 'favorite) " Favorite   [a] toggle")
                             (concat "  " (neoment-icon 'low_priority) " Low Priority   [l] toggle")
                             (concat "  " (neoment-icon 'people) " Direct Message   [d] toggle")
                             ""
                             "── Links ──"
                             "Room ID: !r:s"
                             "Aliases:"
                             "  - #dev:s"
                             ""
                             "── Members (4) ── [Tab to expand]")))
        (should (eq (get-text-property (string-search "Favorite" text) 'face text)
                    'neoment-bubble-active-content))
        (should (eq (get-text-property (string-search "Low Priority" text) 'face text)
                    'neoment-comment)))
      (let ((lines (last (split-string (substring-no-properties
                                        (neoment-room-info-render "!r:s" :expanded t))
                                       "\n")
                         5)))
        (should (equal lines '("── Members (4) ──"
                               "  - @noname:s"
                               "  - Alice (@alice:s)"
                               "  - bob (@bob:s)"
                               "  - Me (@me:s)"))))
      (setf (neoment-room-avatar-url room) "mxc://s/av")
      (should (string-search "Room avatar [o] open with attachment handler"
                             (neoment-room-info-render "!r:s")))
      (setf (neoment-room-avatar-url room) "https://evil/x.png")
      (should (string-search "No image" (neoment-room-info-render "!r:s"))))
    ;; Invited room: no direct status line.
    (setf (neoment-invited-room-name (neoment-get-invited-room "!i:s")) "inv")
    (should-not (string-search "Direct Message" (neoment-room-info-render "!i:s")))))

(ert-deftest neoment-room-info-actions ()
  (neoment-space-test
    (setf (neoment-room-name (neoment-get-room "!r:s")) "dev")
    (save-window-excursion
      (let ((buffer (neoment-room-info-open "!r:s")))
        (unwind-protect
            (with-current-buffer buffer
              (should (equal (buffer-name buffer) "*neoment-room-info: dev*"))
              (neoment-test-with-http (lambda (_) '(:ok nil))
                (neoment-room-info-toggle-low-priority)
                (should (string-suffix-p "/tags/m.lowpriority" (car (neoment-test-request-urls))))
                (should (neoment-test-message-p "dev added to low priority"))
                (should (string-search " " (buffer-string))))
              (neoment-test-with-http (lambda (_) '(:error (:status 500 :error "bad")))
                (neoment-room-info-toggle-favorite)
                (should (neoment-test-message-p "Error adding dev to favorites: bad")))
              (neoment-room-info-toggle-members)
              (should (string-search "── Members (0) ──\n" (concat (buffer-string) "\n")))
              (neoment-room-info-open-avatar)
              (should (neoment-test-message-p "No avatar image to open"))
              (neoment-room-info-toggle-avatar-zoom)
              (should (neoment-test-message-p "No avatar image to zoom")))
          (kill-buffer buffer))))
    (save-window-excursion
      (setf (neoment-invited-room-name (neoment-get-invited-room "!i:s")) "inv")
      (let ((buffer (neoment-room-info-open "!i:s")))
        (with-current-buffer buffer
          (neoment-room-info-toggle-favorite)
          (should (neoment-test-message-p "Cannot modify status for invited rooms")))
        (kill-buffer buffer)))))

(provide 'neoment-space-info-test)
;;; neoment-space-info-test.el ends here
