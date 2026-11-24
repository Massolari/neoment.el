;;; neoment-media-test.el --- Tests for media  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 8 of the port: downloads, inline images, opening and saving
;; attachments, uploads, clipboard images and popups.

;;; Code:

(require 'test-helper)
(require 'neoment-media)
(require 'neoment-compose)
(require 'neoment-emoji)

(defvar neoment-media-test--http nil
  "HTTP handler of the media tests.")

(defmacro neoment-media-test (&rest body)
  "Run BODY with a client, room `room' (!r:s) and a fake HTTP layer.
Downloads write \"data\" to the requested output file."
  (declare (indent 0))
  `(neoment-test-with-temp-dir
     (neoment-test-with-messages
       (let ((neoment--client nil)
             (neoment-media--downloads (make-hash-table :test 'equal))
             (neoment--bubble-edges neoment-faces-bubble-edges-nerd)
             (neoment-icons neoment-default-icons)
             (neoment-media-test--http
              (lambda (args)
                (if (eq (plist-get args :as) 'file)
                    (progn (with-temp-file (plist-get args :output-file) (insert "data"))
                           (list :ok (plist-get args :output-file)))
                  '(:ok ((content_uri . "mxc://s/up")))))))
         (neoment-test-new-client)
         (let ((room (neoment-get-room "!r:s")))
           (setf (neoment-room-name room) "dev")
           (neoment-room-set-tracked room t)
           (neoment-test-with-http (lambda (args) (funcall neoment-media-test--http args))
             ,@body))))))

(defun neoment-media-test-buffer (message)
  "Return a rendered room buffer showing MESSAGE, with point on it."
  (puthash (neoment-message-id message) message
           (neoment-room-messages (neoment-get-room "!r:s")))
  (let ((buffer (generate-new-buffer "neoment-media-test")))
    (neoment-room--setup-buffer buffer "!r:s")
    (switch-to-buffer buffer)
    (cl-letf (((symbol-function 'neoment-room-mark-read) #'ignore))
      (neoment-room-render-buffer))
    (goto-char (point-min))
    (forward-line 1)
    buffer))

;;;; 8.1 Download

(ert-deftest neoment-media-download-cache-and-guard ()
  (neoment-media-test
    (let (a b)
      (neoment-media-image-file "mxc://s/img" (lambda (r) (setq a r)))
      (neoment-media-image-file "mxc://s/img" (lambda (r) (setq b r)))
      (should (= (length neoment-test--requests) 1))
      (let ((req (car neoment-test--requests)))
        (should (equal (plist-get req :url)
                       "https://hs.example/_matrix/client/v1/media/download/s/img"))
        (should (equal (cdr (assoc "Authorization" (plist-get req :headers))) "Bearer TOKEN")))
      (should (equal a b))
      (should (file-exists-p (plist-get a :ok)))
      (should (string-prefix-p (neoment-storage-media-dir) (plist-get a :ok))))
    (let (r)
      (neoment-media-download "https://evil.example/x.png" "x.png" (lambda (x) (setq r x)))
      (should (plist-get r :error))
      (should (= (length neoment-test--requests) 1)))))

;;;; 8.2 Inline images

(ert-deftest neoment-media-terminal-shows-bubble-only ()
  (neoment-media-test
    (save-window-excursion
      (let ((buffer (neoment-media-test-buffer
                     (neoment-message--create :id "$i" :sender "@a:s" :content "cat.png"
                                              :timestamp 1000
                                              :attachment '(:type image :mimetype "image/png"
                                                                  :mxc-url "mxc://s/cat")))))
        (unwind-protect
            (progn
              (should (string-search "Image: cat.png" (buffer-string)))
              (should-not (seq-find (lambda (ov) (overlay-get ov 'neoment-image))
                                    (overlays-in (point-min) (point-max))))
              (should-not (seq-find (lambda (u) (string-search "/media/" u))
                                    (neoment-test-request-urls)))
              (neoment-room-toggle-image-zoom)
              (should (neoment-test-message-p "No image on this line")))
          (kill-buffer buffer))))))

(ert-deftest neoment-media-image-size ()
  (save-window-excursion
    (let ((w (selected-window)))
      (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 100))
                ((symbol-function 'window-pixel-height) (lambda (&rest _) 1000))
                ((symbol-function 'frame-char-width) (lambda (&rest _) 10)))
        (should (equal (neoment-media-image-size w nil nil nil) '(650 . 200)))
        (should (equal (neoment-media-image-size w 300 100 nil) '(300 . 100)))
        (should (equal (neoment-media-image-size w nil 5000 t) '(650 . 1000)))))))

;;;; 8.3 Open

(ert-deftest neoment-media-open-attachment ()
  (neoment-media-test
    (save-window-excursion
      (let* ((got nil)
             (neoment-on-open-attachment-function (lambda (path att) (push (list path att) got)))
             (buffer (neoment-media-test-buffer
                      (neoment-message--create :id "$f" :sender "@a:s" :content "doc.pdf"
                                               :timestamp 1000
                                               :attachment '(:type file :filename "doc.pdf"
                                                                   :mxc-url "mxc://s/doc")))))
        (unwind-protect
            (progn
              (neoment-room-open-attachment)
              (should (equal (file-name-nondirectory (car (car got))) "$fdoc.pdf"))
              (should (eq (plist-get (cadr (car got)) :origin) 'message))
              (should (neoment-test-message-p "Fetching attachment doc.pdf..."))
              (should (neoment-test-message-p "Opening attachment doc.pdf...")))
          (kill-buffer buffer))))))

(ert-deftest neoment-media-open-special-cases ()
  (neoment-media-test
    (save-window-excursion
      (let* ((got nil)
             (neoment-on-open-attachment-function (lambda (path att) (push (list path att) got))))
        (let ((buffer (neoment-media-test-buffer
                       (neoment-message--create :id "$t" :sender "@a:s" :content "plain"
                                                :timestamp 1000))))
          (neoment-room-open-attachment)
          (should (neoment-test-message-p "No attachment on this message"))
          (kill-buffer buffer))
        (let ((buffer (neoment-media-test-buffer
                       (neoment-message--create :id "$l" :sender "@a:s" :content "here"
                                                :timestamp 1000 :attachment '(:type location)))))
          (neoment-room-open-attachment)
          (should (neoment-test-message-p "No URL for this location attachment"))
          (kill-buffer buffer))
        (let ((buffer (neoment-media-test-buffer
                       (neoment-message--create :id "$l2" :sender "@a:s" :content "here"
                                                :timestamp 1000
                                                :attachment '(:type location :url "https://maps.google.com/?q=1,2")))))
          (neoment-room-open-attachment)
          (should (equal (car (car got)) "https://maps.google.com/?q=1,2"))
          (kill-buffer buffer))
        (let ((buffer (neoment-media-test-buffer
                       (neoment-message--create :id "$e" :sender "@a:s"
                                                :content "x [img: :party:](mxc://s/party)"
                                                :timestamp 1000))))
          (search-forward "[img")
          (neoment-room-open-attachment)
          (should (equal (file-name-nondirectory (car (car got))) "_party_.png"))
          (should (eq (plist-get (cadr (car got)) :origin) 'emoticon))
          (should (equal (plist-get (cadr (car got)) :mimetype) "image/png"))
          (kill-buffer buffer))))))

(ert-deftest neoment-media-default-handler ()
  (let (opened played)
    (cl-letf (((symbol-function 'neoment-media--system-open) (lambda (p) (setq opened p)))
              ((symbol-function 'neoment-player-play) (lambda (p) (setq played p))))
      (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/mpv"))
                (system-type 'gnu/linux))
        (neoment-media-default-open-handler "/tmp/a.ogg" '(:type audio))
        (should (equal played "/tmp/a.ogg"))
        (should-not opened)
        (neoment-media-default-open-handler "/tmp/a.pdf" '(:type file))
        (should (equal opened "/tmp/a.pdf"))
        (should (equal played "/tmp/a.ogg")))
      (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
        (neoment-media-default-open-handler "/tmp/b.ogg" '(:type audio))
        (should (equal opened "/tmp/b.ogg"))
        (should (equal played "/tmp/a.ogg")))
      (setq opened nil)
      (cl-letf (((symbol-function 'executable-find) (lambda (_) "C:/mpv.exe"))
                (system-type 'windows-nt))
        (neoment-media-default-open-handler "/tmp/c.ogg" '(:type audio))
        (should (equal opened "/tmp/c.ogg"))))))

;;;; 8.4 Save

(ert-deftest neoment-media-save-names ()
  (neoment-test-with-temp-dir
    (let ((dir user-emacs-directory))
      (write-region "" nil (expand-file-name "a.png" dir))
      (write-region "" nil (expand-file-name "a(1).png" dir))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (should (equal q "File exists. Overwrite? ")) nil)))
        (should (equal (neoment-media-save-target (expand-file-name "a.png" dir) "x")
                       (expand-file-name "a(2).png" dir))))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (should (equal (neoment-media-save-target (expand-file-name "a.png" dir) "x")
                       (expand-file-name "a.png" dir))))
      (should (equal (neoment-media-save-target dir "new.png")
                     (expand-file-name "new.png" dir))))))

(ert-deftest neoment-media-save-attachment ()
  (neoment-media-test
    (save-window-excursion
      (let ((buffer (neoment-media-test-buffer
                     (neoment-message--create :id "$f" :sender "@a:s" :content "doc.pdf"
                                              :timestamp 1000
                                              :attachment '(:type file :filename "doc.pdf"
                                                                  :mxc-url "mxc://s/doc"))))
            (target (expand-file-name "out" user-emacs-directory)))
        (make-directory target)
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) target)))
          (neoment-room-save-attachment))
        (should (file-exists-p (expand-file-name "doc.pdf" target)))
        (should (neoment-test-message-p
                 (concat "Attachment saved to " (expand-file-name "doc.pdf" target))))
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) "")))
          (neoment-room-save-attachment))
        (should (neoment-test-message-p "Save location not provided"))
        (kill-buffer buffer)))))

;;;; 8.5 Upload

(ert-deftest neoment-media-upload ()
  (neoment-media-test
    (save-window-excursion
      (let ((file (expand-file-name "report.pdf" user-emacs-directory))
            (buffer (neoment-media-test-buffer
                     (neoment-message--create :id "$x" :sender "@a:s" :content "x" :timestamp 1))))
       (unwind-protect
        (progn
        (write-region "12345" nil file)
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) file)))
          (neoment-room-upload))
        (let ((req (seq-find (lambda (r) (string-search "/upload" (plist-get r :url)))
                             neoment-test--requests)))
          (should (eq (plist-get req :method) 'post))
          (should (equal (plist-get req :url) "https://hs.example/_matrix/media/v3/upload"))
          (should (equal (plist-get req :query) '((filename . "report.pdf"))))
          (should (equal (plist-get req :body-file) file))
          (should (equal (plist-get req :content-type) "application/pdf")))
        (let ((compose (current-buffer)))
          (should (equal (buffer-name compose)
                         "neoment://compose/Sending to dev with the attachment report.pdf"))
          (should (equal (buffer-local-value 'neoment-compose--attachment compose)
                         (list :filename "report.pdf" :url "mxc://s/up"
                               :mimetype "application/pdf" :size 5)))
          (kill-buffer compose))
        (switch-to-buffer buffer)
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) "/nonexistent/x")))
          (neoment-room-upload))
        (should (neoment-test-message-p "File does not exist: /nonexistent/x")))
        (dolist (b (buffer-list))
          (when (string-prefix-p "neoment://compose" (buffer-name b)) (kill-buffer b)))
        (kill-buffer buffer))))))

(ert-deftest neoment-media-clipboard-errors ()
  (let ((file (make-temp-file "neoment-clip" nil ".png")))
    (unwind-protect
        (progn
          (let ((system-type 'ms-dos))
            (should (equal (neoment-media-clipboard-png file)
                           "Clipboard image upload not supported on this platform")))
          (let ((system-type 'gnu/linux)
                (process-environment (cons "WAYLAND_DISPLAY" process-environment)))
            (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
              (should (equal (neoment-media-clipboard-png file)
                             "The 'xclip' command is not available. Install with your package manager.")))
            (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/xclip"))
                      ((symbol-function 'neoment-media--run) (lambda (&rest _) '(0 . "TARGETS\nUTF8_STRING"))))
              (should (equal (neoment-media-clipboard-png file) "No image found in clipboard")))
            (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/xclip"))
                      ((symbol-function 'neoment-media--run)
                       (lambda (&rest args)
                         (if (member "TARGETS" args) '(0 . "image/png") '(0 . "\211PNG")))))
              (should (null (neoment-media-clipboard-png file)))
              (should (= (file-attribute-size (file-attributes file)) 4)))))
      (delete-file file))))

;;;; 8.6 Popups

(ert-deftest neoment-media-popup-text ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (neoment-set-display-name "@a:s" "Alice" 1)
    (neoment-set-display-name "@b:s" "Bob" 1)
    (let ((text (neoment-media-popup-text
                 (list 'neoment-reaction '(:key "😄" :senders ("@a:s" "@b:s"))))))
      (should (equal (substring-no-properties text)
                     "😄 :smiling_face_with_open_mouth_and_smiling_eyes:\n\nAlice\nBob"))
      (should (eq (get-text-property 0 'face text) 'bold)))
    (should (equal (substring-no-properties
                    (neoment-media-popup-text (list 'neoment-reaction '(:key "custom" :senders ("@a:s")))))
                   "custom\n\nAlice"))
    (should (equal (substring-no-properties
                    (neoment-media-popup-text (list 'neoment-emoticon '(:title ":party:" :url "mxc://s/p"))))
                   ":party:"))
    (should-not (neoment-media-popup-text nil))
    ;; Without posframe or a GUI frame the text goes to the echo area.
    (with-temp-buffer
      (insert "x")
      (put-text-property 1 2 'neoment-reaction '(:key "custom" :senders ("@a:s")))
      (goto-char 1)
      (let ((shown nil))
        (cl-letf (((symbol-function 'message) (lambda (_fmt text) (setq shown text))))
          (neoment-media--show-popup (current-buffer) 1))
        (should (equal (substring-no-properties shown) "custom\n\nAlice"))))))

(provide 'neoment-media-test)
;;; neoment-media-test.el ends here
