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

(defmacro neoment-media-test-gui (&rest body)
  "Run BODY as in a GUI frame, with `create-image' returning a fake image."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
             ((symbol-function 'display-images-p) (lambda (&rest _) t))
             ((symbol-function 'create-image)
              (lambda (file _type _data &rest props) (append (list 'image :file file) props))))
     ,@body))

(defun neoment-media-test-image-message (id &rest props)
  "Return an image message ID (cat.png); PROPS override the defaults."
  (apply #'neoment-message--create
         (append props
                 (list :id id :sender "@a:s" :content "cat.png" :timestamp 1000
                       :attachment (list :type 'image :filename "cat.png"
                                         :mimetype "image/png"
                                         :mxc-url (concat "mxc://s/" (substring id 1)))))))

(defun neoment-media-test-height (key)
  "Return the max height of KEY's displayed inline image."
  (plist-get (cdr (get-text-property (neoment-room--image-position key) 'display))
             :max-height))

(defun neoment-media-test-expected-height (fraction)
  "Return the max height of an image without a known size at FRACTION."
  (cdr (neoment-media-image-size (get-buffer-window (current-buffer)) nil nil fraction)))

(defun neoment-media-test-on-image-p (key)
  "Return non-nil when point is on the image line of KEY."
  (equal (get-text-property (line-beginning-position) 'neoment-image) key))

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
              (should-not (text-property-not-all (point-min) (point-max) 'neoment-image nil))
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
        (should (equal (neoment-media-image-size w nil nil 0.2) '(650 . 200)))
        (should (equal (neoment-media-image-size w 300 100 0.2) '(300 . 100)))
        (should (equal (neoment-media-image-size w nil 5000 1.0) '(650 . 1000)))
        (should (equal (neoment-media-image-size w 300 700 1.0) '(300 . 700)))))))

(ert-deftest neoment-media-image-fraction ()
  (with-temp-buffer
    (should (= (neoment-media--image-fraction "$a") 0.2))
    (should (= (neoment-media--set-image-fraction "$a" 5) 1.0))
    (should (= (neoment-media--image-fraction "$a") 1.0))
    (should (= (neoment-media--set-image-fraction "$a" 0.01) 0.05))
    (should (= (neoment-media--image-fraction "$b") 0.2))
    ;; nil, or the default, removes the entry.
    (should (= (neoment-media--set-image-fraction "$a" nil) 0.2))
    (should-not neoment-room--image-heights)
    (neoment-media--set-image-fraction "$a" 0.5)
    (neoment-media--set-image-fraction "$a" (/ (* 0.2 1.25) 1.25))
    (should-not neoment-room--image-heights)))

;;;; Focusable image line

(ert-deftest neoment-media-image-window-prefers-graphic ()
  (cl-letf (((symbol-function 'get-buffer-window-list) (lambda (&rest _) '(tty-win gui-win)))
            ((symbol-function 'window-frame) (lambda (w) (if (eq w 'gui-win) 'gui 'tty)))
            ((symbol-function 'display-graphic-p) (lambda (frame) (eq frame 'gui)))
            ((symbol-function 'get-buffer-window) (lambda (&rest _) 'tty-win)))
    (should (eq (neoment-media--image-window (current-buffer)) 'gui-win))
    (cl-letf (((symbol-function 'display-graphic-p) #'ignore))
      (should (eq (neoment-media--image-window (current-buffer)) 'tty-win)))))

(ert-deftest neoment-media-image-line ()
  (neoment-media-test
    (save-window-excursion
      (neoment-media-test-gui
        (puthash "$t" (neoment-message--create :id "$t" :sender "@a:s" :content "hello"
                                               :timestamp 2000)
                 (neoment-room-messages (neoment-get-room "!r:s")))
        (let ((buffer (neoment-media-test-buffer (neoment-media-test-image-message "$i"))))
          (unwind-protect
              (progn
                ;; Point is on the header; the image line is right below it.
                (should (get-text-property (point) 'neoment-header))
                (forward-line 1)
                (should (neoment-media-test-on-image-p "$i"))
                (should (= (neoment-room--image-position "$i")
                           (+ (point) neoment-room-header-width)))
                (let ((img (neoment-room--image-position "$i")))
                  (should (equal (get-text-property img 'neoment-image-file)
                                 (plist-get (cdr (get-text-property img 'display)) :file))))
                (should (equal (neoment-message-id (neoment-room-message-at-point)) "$i"))
                (should (eq (key-binding "+") #'neoment-room-image-enlarge))
                (should (eq (key-binding "o") #'neoment-room-image-open))
                (should (eq (key-binding "r") #'neoment-room-reply))
                (end-of-line)
                (should (eq (key-binding "+") #'neoment-room-image-enlarge))
                ;; Copying leaves the image line out.
                (let ((copied (filter-buffer-substring (point-min) (point-max))))
                  (should (string-search "hello" copied))
                  (neoment-media--remove-images)
                  (should-not (neoment-room--image-position "$i"))
                  (should (equal copied (filter-buffer-substring (point-min) (point-max))))))
            (kill-buffer buffer)))))))

(ert-deftest neoment-media-image-async-order ()
  (neoment-media-test
    (save-window-excursion
      (neoment-media-test-gui
        (let ((requests nil)
              (room (neoment-get-room "!r:s")))
          (setq neoment-media-test--http
                (lambda (args)
                  (if (eq (plist-get args :as) 'file)
                      (progn (push args requests) 'pending)
                    '(:ok nil))))
          (puthash "$a" (neoment-media-test-image-message "$a") (neoment-room-messages room))
          (let ((buffer (neoment-media-test-buffer
                         (neoment-media-test-image-message "$b" :timestamp 2000))))
            (unwind-protect
                ;; Replies in reverse order, then in order after a fresh render.
                (dolist (reverse '(t nil))
                  (unless reverse
                    (setq requests nil)
                    (dolist (file (directory-files (neoment-storage-media-dir) t "\\`image-"))
                      (delete-file file))
                    (neoment-room-render-buffer))
                  (should (= (length requests) 2))
                  (should-not (neoment-room--image-position "$a"))
                  ;; `requests' is newest first: $b, then $a.
                  (dolist (req (if reverse requests (reverse requests)))
                    (with-temp-file (plist-get req :output-file) (insert "data"))
                    (funcall (plist-get req :callback) (list :ok (plist-get req :output-file))))
                  (dolist (key '("$a" "$b"))
                    (goto-char (neoment-room--image-position key))
                    (forward-line -1)
                    (should (get-text-property (point) 'neoment-header))
                    (should (equal (get-text-property (point) 'neoment-message) key))))
              (kill-buffer buffer))))))))

;;;; Stable point with images

(ert-deftest neoment-media-anchor-body-line ()
  (neoment-media-test
    (save-window-excursion
      (let ((buffer (neoment-media-test-gui
                      (neoment-media-test-buffer
                       (neoment-media-test-image-message
                        "$i" :content "look at this\nsecond line")))))
        (unwind-protect
            (progn
              (should (neoment-room--image-position "$i"))
              (search-forward "second l")
              ;; The image disappears (terminal frame).
              (neoment-room-render-buffer)
              (should-not (neoment-room--image-position "$i"))
              (should (looking-at "ine"))
              ;; The image comes back.
              (neoment-media-test-gui (neoment-room-render-buffer))
              (should (neoment-room--image-position "$i"))
              (should (looking-at "ine"))
              ;; Point at the end of the header stays on the header.
              (goto-char (point-min))
              (forward-line 1)
              (end-of-line)
              (should (get-text-property (point) 'neoment-image))
              (neoment-room-render-buffer)
              (should (eolp))
              (should (get-text-property (line-beginning-position) 'neoment-header)))
          (kill-buffer buffer))))))

(ert-deftest neoment-media-anchor-non-message-line ()
  (neoment-media-test
    (save-window-excursion
      (puthash "$t" (neoment-message--create :id "$t" :sender "@a:s" :content "hello"
                                             :timestamp (+ 1000 (* 2 86400000)))
               (neoment-room-messages (neoment-get-room "!r:s")))
      (let ((buffer (neoment-media-test-gui
                      (neoment-media-test-buffer (neoment-media-test-image-message "$i")))))
        (unwind-protect
            (progn
              (should (neoment-room--image-position "$i"))
              ;; Point on the date separator of the later message, below the image.
              (goto-char (neoment-room--image-position "$i"))
              (while (or (get-text-property (point) 'neoment-message)
                         (looking-at-p "^\\s-*$"))
                (forward-line 1))
              (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
                ;; The image disappears (terminal frame), then comes back.
                (neoment-room-render-buffer)
                (should-not (neoment-room--image-position "$i"))
                (should (equal line (buffer-substring (line-beginning-position)
                                                      (line-end-position))))
                (neoment-media-test-gui (neoment-room-render-buffer))
                (should (neoment-room--image-position "$i"))
                (should (equal line (buffer-substring (line-beginning-position)
                                                      (line-end-position))))))
          (kill-buffer buffer))))))

(ert-deftest neoment-media-anchor-image-line ()
  (neoment-media-test
    (save-window-excursion
      (neoment-media-test-gui
        (let ((buffer (neoment-media-test-buffer (neoment-media-test-image-message "$i"))))
          (unwind-protect
              (progn
                (forward-line 1)
                (should (neoment-media-test-on-image-p "$i"))
                (let ((anchor (neoment-room--position-anchor (point))))
                  (should (equal (car anchor) "$i"))
                  (should (nth 2 anchor)))
                ;; A new message arrives and the image is cached.
                (puthash "$n" (neoment-message--create :id "$n" :sender "@b:s"
                                                       :content "new" :timestamp 3000)
                         (neoment-room-messages (neoment-get-room "!r:s")))
                (neoment-room-render-buffer)
                (should (string-search "new" (buffer-string)))
                (should (= (point) (neoment-room--image-position "$i")))
                ;; A window start on the image line stays at the line start.
                (let ((w (get-buffer-window buffer)))
                  (set-window-start w (line-beginning-position))
                  (neoment-room-render-buffer)
                  (should (= (window-start w) (line-beginning-position)))))
            (kill-buffer buffer)))))))

;;;; Image keymap: zoom and resize

(ert-deftest neoment-media-image-resize-in-place ()
  (neoment-media-test
    (save-window-excursion
      (neoment-media-test-gui
        (let ((buffer (neoment-media-test-buffer (neoment-media-test-image-message "$i"))))
          (unwind-protect
              (progn
                (forward-line 1)
                (set-buffer-modified-p nil)
                (let ((pos (point))
                      (text (buffer-substring-no-properties (point-min) (point-max))))
                  (neoment-room-image-enlarge)
                  (should (= (point) pos))
                  (should-not (buffer-modified-p))
                  (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (= (neoment-media-test-height "$i")
                             (neoment-media-test-expected-height 0.25)))))
            (kill-buffer buffer)))))))

(ert-deftest neoment-media-image-zoom ()
  (neoment-media-test
    (save-window-excursion
      (neoment-media-test-gui
        (let ((buffer (neoment-media-test-buffer (neoment-media-test-image-message "$i"))))
          (unwind-protect
              (progn
                ;; Zoom in on the image.
                (forward-line 1)
                (let ((pos (point)))
                  (should (eq (key-binding "z") #'neoment-room-toggle-image-zoom))
                  (neoment-room-toggle-image-zoom)
                  (should (= (point) pos))
                  (should (= (neoment-media--image-fraction "$i") 1.0))
                  (should (= (neoment-media-test-height "$i")
                             (neoment-media-test-expected-height 1.0)))
                  (neoment-room-toggle-image-zoom)
                  (should (= (neoment-media--image-fraction "$i") 0.2))
                  (should (= (neoment-media-test-height "$i")
                             (neoment-media-test-expected-height 0.2))))
                ;; Zoom from the header line.
                (forward-line -1)
                (neoment-room-toggle-image-zoom)
                (should (= (neoment-media--image-fraction "$i") 1.0))
                (neoment-room-toggle-image-zoom)
                ;; Reset after `+'.
                (forward-line 1)
                (neoment-room-image-enlarge)
                (neoment-room-toggle-image-zoom)
                (should (= (neoment-media--image-fraction "$i") 0.2))
                (should-not neoment-room--image-heights)
                ;; No image elsewhere.
                (goto-char (point-min))
                (neoment-room-toggle-image-zoom)
                (should (neoment-test-message-p "No image on this line")))
            (kill-buffer buffer)))))))

(ert-deftest neoment-media-image-enlarge-shrink ()
  (neoment-media-test
    (save-window-excursion
      (neoment-media-test-gui
        (let ((buffer (neoment-media-test-buffer (neoment-media-test-image-message "$i"))))
          (unwind-protect
              (progn
                (forward-line 1)
                (neoment-room-image-enlarge)
                (should (< (abs (- (neoment-media--image-fraction "$i") 0.25)) 1e-9))
                ;; The size survives a render.
                (neoment-room-render-buffer)
                (should (neoment-media-test-on-image-p "$i"))
                (should (= (neoment-media-test-height "$i")
                           (neoment-media-test-expected-height 0.25)))
                (neoment-room-image-shrink)
                (should (= (neoment-media--image-fraction "$i") 0.2))
                ;; Limits.
                (neoment-media--set-image-fraction "$i" 0.05)
                (neoment-room-image-shrink)
                (should (= (neoment-media--image-fraction "$i") 0.05))
                (should (neoment-test-message-p "Image is at its minimum size"))
                (neoment-media--set-image-fraction "$i" 1.0)
                (neoment-room-image-enlarge)
                (should (= (neoment-media--image-fraction "$i") 1.0))
                (should (neoment-test-message-p "Image is at its maximum size")))
            (kill-buffer buffer)))))))

(ert-deftest neoment-media-image-keys-outside-image ()
  (neoment-media-test
    (save-window-excursion
      (neoment-media-test-gui
        (let ((buffer (neoment-media-test-buffer
                       (neoment-media-test-image-message "$i" :content "caption"))))
          (unwind-protect
              (progn
                ;; The header line, then the caption line right after the image.
                (should-not (eq (key-binding "+") #'neoment-room-image-enlarge))
                (forward-line 2)
                (should (looking-at-p " *│ caption"))
                (should-not (eq (key-binding "+") #'neoment-room-image-enlarge))
                (should (eq (key-binding "o") #'neoment-room-open-attachment))
                (neoment-room-image-enlarge)
                (should (neoment-test-message-p "No image on this line"))
                (should-not neoment-room--image-heights))
            (kill-buffer buffer)))))))

;;;; Open image in image-mode

(ert-deftest neoment-media-image-open ()
  (neoment-media-test
    (save-window-excursion
      (cl-letf (((symbol-function 'image-mode) (lambda () (setq major-mode 'image-mode))))
        (let ((buffer (neoment-media-test-gui
                        (neoment-media-test-buffer (neoment-media-test-image-message "$i")))))
          (unwind-protect
              (progn
                (forward-line 1)
                (neoment-room-image-open)
                (let ((image (get-buffer "*neoment-image: cat.png*")))
                  (should image)
                  (should (eq (buffer-local-value 'major-mode image) 'image-mode))
                  (should (equal (with-current-buffer image (buffer-string)) "data"))
                  (should (equal (buffer-local-value 'default-directory image)
                                 (file-name-as-directory (neoment-storage-media-dir))))
                  ;; The full attachment shares the cache name of `o'.
                  (should (file-exists-p (expand-file-name "$icat.png"
                                                           (neoment-storage-media-dir))))
                  (switch-to-buffer buffer)
                  (neoment-room-image-open)
                  (should (eq (get-buffer "*neoment-image: cat.png*") image))
                  (should (= 1 (seq-count (lambda (b) (equal (buffer-name b)
                                                             "*neoment-image: cat.png*"))
                                          (buffer-list))))))
            (when (get-buffer "*neoment-image: cat.png*")
              (kill-buffer "*neoment-image: cat.png*"))
            (kill-buffer buffer)))))))

(ert-deftest neoment-media-image-open-video-and-error ()
  (neoment-media-test
    (save-window-excursion
      (let* ((got nil)
             (neoment-on-open-attachment-function (lambda (path att) (push (list path att) got))))
        (let ((buffer (neoment-media-test-gui
                        (neoment-media-test-buffer
                         (neoment-message--create
                          :id "$v" :sender "@a:s" :content "clip.mp4" :timestamp 1000
                          :attachment '(:type video :filename "clip.mp4" :mxc-url "mxc://s/v"
                                              :thumbnail (:type image :mxc-url "mxc://s/vt")))))))
          (forward-line 1)
          (should (neoment-media-test-on-image-p "$v"))
          (neoment-room-image-open)
          (should (equal (file-name-nondirectory (car (car got))) "$vclip.mp4"))
          (should (eq (plist-get (cadr (car got)) :type) 'video))
          (kill-buffer buffer))
        (let ((buffer (neoment-media-test-gui
                        (neoment-media-test-buffer (neoment-media-test-image-message "$e")))))
          (forward-line 1)
          (setq neoment-media-test--http (lambda (_) '(:error (:error "boom"))))
          (neoment-room-image-open)
          (should (neoment-test-message-p "Error fetching attachment: boom"))
          (should-not (get-buffer "*neoment-image: cat.png*"))
          (kill-buffer buffer))))))

(ert-deftest neoment-media-image-open-same-filename ()
  (neoment-media-test
    (save-window-excursion
      (cl-letf (((symbol-function 'image-mode) (lambda () (setq major-mode 'image-mode))))
        (setq neoment-media-test--http
              (lambda (args)
                (if (eq (plist-get args :as) 'file)
                    (progn (with-temp-file (plist-get args :output-file)
                             (insert (plist-get args :url)))
                           (list :ok (plist-get args :output-file)))
                  '(:ok nil))))
        (puthash "$a" (neoment-media-test-image-message "$a")
                 (neoment-room-messages (neoment-get-room "!r:s")))
        (let ((buffer (neoment-media-test-gui
                        (neoment-media-test-buffer
                         (neoment-media-test-image-message "$b" :timestamp 2000))))
              (opened nil))
          (unwind-protect
              (cl-flet ((open (key)
                          (switch-to-buffer buffer)
                          (goto-char (neoment-room--image-position key))
                          (neoment-room-image-open)
                          (push (current-buffer) opened)
                          (current-buffer)))
                (let ((a (open "$a"))
                      (b (open "$b")))
                  (should-not (eq a b))
                  (should (string-match-p "/a\\'" (with-current-buffer a (buffer-string))))
                  (should (string-match-p "/b\\'" (with-current-buffer b (buffer-string))))
                  (should (string-prefix-p "*neoment-image: cat.png*" (buffer-name b)))
                  (should (eq (open "$a") a))))
            (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b))) opened)
            (kill-buffer buffer)))))))

(ert-deftest neoment-media-window-start-on-missing-image ()
  (neoment-media-test
    (save-window-excursion
      (let ((buffer (neoment-media-test-gui
                      (neoment-media-test-buffer (neoment-media-test-image-message "$i")))))
        (unwind-protect
            (progn
              (forward-line 1)
              (should (neoment-media-test-on-image-p "$i"))
              (set-window-start (selected-window) (point) t)
              ;; The image disappears (terminal frame).
              (neoment-room-render-buffer)
              (should-not (neoment-room--image-position "$i"))
              (let ((start (window-start)))
                (should (= start (save-excursion (goto-char start) (line-beginning-position))))
                (should (get-text-property start 'neoment-header))))
          (kill-buffer buffer))))))

(ert-deftest neoment-media-image-stale-callbacks ()
  (neoment-media-test
    (save-window-excursion
      (neoment-media-test-gui
        (let ((requests nil)
              (markers nil)
              (orig (symbol-function 'neoment-media--place-image)))
          (setq neoment-media-test--http
                (lambda (args)
                  (if (eq (plist-get args :as) 'file)
                      (progn (push args requests) 'pending)
                    '(:ok nil))))
          (cl-letf (((symbol-function 'neoment-media--place-image)
                     (lambda (buf tick marker file key)
                       (push marker markers)
                       (funcall orig buf tick marker file key))))
            (let ((buffer (neoment-media-test-buffer (neoment-media-test-image-message "$i")))
                  (deliver (lambda ()
                             (let ((req (car requests)))
                               (with-temp-file (plist-get req :output-file) (insert "data"))
                               (funcall (plist-get req :callback)
                                        (list :ok (plist-get req :output-file)))))))
              (unwind-protect
                  (progn
                    ;; A re-render while the download is in flight.
                    (should (= (length requests) 1))
                    (neoment-room-render-buffer)
                    (should (= (length requests) 1))
                    (funcall deliver)
                    (should (= (length markers) 2))
                    (should-not (seq-some #'marker-buffer markers))
                    ;; Only the current render placed an image, below its header.
                    (goto-char (point-min))
                    (let ((lines 0))
                      (while (not (eobp))
                        (when (get-text-property (line-beginning-position) 'neoment-image)
                          (cl-incf lines))
                        (forward-line 1))
                      (should (= lines 1)))
                    (goto-char (neoment-room--image-position "$i"))
                    (forward-line -1)
                    (should (get-text-property (point) 'neoment-header))
                    ;; The buffer is killed before the download ends.
                    (setq requests nil markers nil)
                    (dolist (file (directory-files (neoment-storage-media-dir) t "\\`image-"))
                      (delete-file file))
                    (neoment-room-render-buffer)
                    (should (= (length requests) 1))
                    (kill-buffer buffer)
                    (funcall deliver)
                    (should (= (length markers) 1))
                    (should-not (marker-buffer (car markers))))
                (when (buffer-live-p buffer) (kill-buffer buffer))))))))))

(ert-deftest neoment-media-image-error-keeps-view ()
  (neoment-media-test
    (save-window-excursion
      (let ((buffer (neoment-media-test-gui
                      (neoment-media-test-buffer
                       (neoment-media-test-image-message "$i" :content "look at this")))))
        (unwind-protect
            (progn
              (search-forward "look")
              (neoment-media-test-gui
                (cl-letf (((symbol-function 'neoment-media-image-file)
                           (lambda (&rest _) (error "Disk full"))))
                  (neoment-room-render-buffer)))
              (should (looking-at " at this"))
              (should-not (neoment-room--image-position "$i")))
          (kill-buffer buffer))))))

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

(ert-deftest neoment-media-open-links ()
  (neoment-media-test
    (save-window-excursion
      (let* ((got nil)
             (browsed nil)
             (neoment-on-open-attachment-function (lambda (path att) (push (list path att) got))))
        (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (push url browsed))))
          ;; Open a link
          (let ((buffer (neoment-media-test-buffer
                         (neoment-message--create :id "$k" :sender "@a:s"
                                                  :content "see [docs](https://example.org)"
                                                  :timestamp 1000
                                                  :attachment '(:type file :filename "f.pdf"
                                                                      :mxc-url "mxc://s/f")))))
            (search-forward "[do")
            (neoment-room-open-attachment)
            (should (equal browsed '("https://example.org")))
            (should-not got)
            (should-not (neoment-test-message-p "Fetching attachment f.pdf..."))
            ;; Elsewhere on the line, the attachment is opened as before.
            (beginning-of-line)
            (search-forward "see")
            (neoment-room-open-attachment)
            (should (neoment-test-message-p "Fetching attachment f.pdf..."))
            (kill-buffer buffer))
          ;; Reveal a spoiler
          (let ((buffer (neoment-media-test-buffer
                         (neoment-message--create :id "$s" :sender "@a:s"
                                                  :content "[Spoiler](<the end>)"
                                                  :timestamp 1000))))
            (search-forward "Spoi")
            (neoment-room-open-attachment)
            (should (neoment-test-message-p "the end"))
            (should (equal browsed '("https://example.org")))
            (kill-buffer buffer))
          ;; mouse-1 on the link text opens it at the click position.
          (let ((buffer (neoment-media-test-buffer
                         (neoment-message--create :id "$m" :sender "@a:s"
                                                  :content "[Alice](https://matrix.to/#/@alice:s)"
                                                  :timestamp 1000))))
            (let ((pos (save-excursion (search-forward "Ali"))))
              (should (eq (lookup-key (get-text-property pos 'keymap) [mouse-1])
                          #'neoment-room-open-link-at-mouse))
              (cl-letf (((symbol-function 'mouse-set-point)
                         (lambda (event &rest _) (goto-char (posn-point (event-start event))))))
                (neoment-room-open-link-at-mouse
                 `(mouse-1 (,(selected-window) ,pos (0 . 0) 0)))))
            (should (equal (car browsed) "https://matrix.to/#/@alice:s"))
            (kill-buffer buffer)))
        ;; An mxc emoticon still downloads as before.
        (let ((buffer (neoment-media-test-buffer
                       (neoment-message--create :id "$e2" :sender "@a:s"
                                                :content "[img: :ok:](mxc://s/ok)"
                                                :timestamp 1000))))
          (search-forward "img")
          (neoment-room-open-attachment)
          (should (equal (file-name-nondirectory (car (car got))) "_ok_.png"))
          (should (eq (plist-get (cadr (car got)) :origin) 'emoticon))
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
                         "*neoment-compose: Sending to dev with the attachment report.pdf*"))
          (should (equal (buffer-local-value 'neoment-compose--attachment compose)
                         (list :filename "report.pdf" :url "mxc://s/up"
                               :mimetype "application/pdf" :size 5)))
          (kill-buffer compose))
        (switch-to-buffer buffer)
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) "/nonexistent/x")))
          (neoment-room-upload))
        (should (neoment-test-message-p "File does not exist: /nonexistent/x")))
        (dolist (b (buffer-list))
          (when (string-prefix-p "*neoment-compose:" (buffer-name b)) (kill-buffer b)))
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
