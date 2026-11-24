;;; neoment-media.el --- Media download and upload  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Douglas M.

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Authenticated media download (only mxc:// URLs, the token only in a
;; header), inline images and zoom, opening and saving attachments,
;; uploads, clipboard images and hover popups.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mailcap)
(require 'neoment-config)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-events)
(require 'neoment-notify)
(require 'neoment-storage)
(require 'neoment-room)

(declare-function neoment-compose-open "neoment-compose")
(declare-function neoment-emoji-label "neoment-emoji")
(declare-function posframe-show "posframe")
(declare-function posframe-hide "posframe")

;;;; Download

(defvar neoment-media--downloads (make-hash-table :test 'equal)
  "Callbacks waiting for each file being downloaded.")

(defun neoment-media-sanitize (name)
  "Return NAME with characters unsafe in file names replaced."
  (replace-regexp-in-string "[^[:alnum:]._$-]" "_" name))

(defun neoment-media-download (mxc name callback)
  "Download the media MXC to NAME in the media directory.
CALLBACK receives (:ok PATH) or (:error ERR).  Only mxc:// URLs are
fetched, with the token in a header.  A file already present is
reused and concurrent downloads of the same file are merged."
  (let ((url (and (neoment-events-mxc-p mxc) (neoment-events-mxc-to-url mxc))))
    (if (not url)
        (funcall callback (list :error (list :error "Not homeserver media")))
      (let ((path (expand-file-name (neoment-media-sanitize name)
                                    (neoment-storage-media-dir))))
        (cond
         ((file-exists-p path) (funcall callback (list :ok path)))
         ((gethash path neoment-media--downloads)
          (push callback (gethash path neoment-media--downloads)))
         (t
          (puthash path (list callback) neoment-media--downloads)
          (let ((part (concat path ".part")))
            (when (file-exists-p part) (delete-file part))
            (neoment-api-request
             'get url :as 'file :output-file part
             :callback
             (lambda (result)
               (let ((callbacks (gethash path neoment-media--downloads))
                     (final nil))
                 (remhash path neoment-media--downloads)
                 (if (plist-get result :error)
                     (progn
                       (when (file-exists-p part) (delete-file part))
                       (setq final (list :error (plist-get result :error))))
                   (rename-file part path t)
                   (setq final (list :ok path)))
                 (dolist (cb (reverse callbacks))
                   (funcall cb final))))))))))))

(defun neoment-media-image-file (mxc callback)
  "Download the image MXC to a file named after it and call CALLBACK."
  (neoment-media-download
   mxc (concat "image-" (substring (secure-hash 'sha256 mxc) 0 32)) callback))

;;;; Inline images

(defvar-local neoment-media--render-tick 0
  "Counter bumped by each render, so late images are dropped.")

(defconst neoment-media-image-default-height 0.2
  "Default max height of an inline image, as a fraction of the window.")

(defconst neoment-media--min-height 0.05
  "Smallest max height of an inline image, as a fraction of the window.")

(defconst neoment-media--max-height 1.0
  "Largest max height of an inline image, as a fraction of the window.")

(defconst neoment-media--resize-step 1.25
  "Factor applied by each image resize.")

(defconst neoment-media--image-help "z: zoom, +/-: resize, o: open"
  "Help shown when hovering an inline image.")

(defvar-keymap neoment-media-image-map
  :doc "Keymap active with the cursor on an inline image.
Other keys fall through to `neoment-room-mode-map'."
  "z" #'neoment-room-toggle-image-zoom
  "+" #'neoment-room-image-enlarge
  "-" #'neoment-room-image-shrink
  "o" #'neoment-room-image-open)

(defun neoment-media--image-fraction (key)
  "Return the max height of KEY's inline image, as a fraction of the window."
  (or (alist-get key neoment-room--image-heights nil nil #'equal)
      neoment-media-image-default-height))

(defun neoment-media--set-image-fraction (key fraction)
  "Set the max height of KEY's inline image to FRACTION of the window.
FRACTION is clamped to the allowed range; nil (or the default) removes
the entry.  Return the fraction now in effect."
  (let ((value (and fraction
                    (min neoment-media--max-height
                         (max neoment-media--min-height fraction)))))
    (when (and value (< (abs (- value neoment-media-image-default-height)) 1e-9))
      (setq value nil))
    (setf (alist-get key neoment-room--image-heights nil t #'equal) value)
    (neoment-media--image-fraction key)))

(defun neoment-media--image-attachment (message)
  "Return the image (or video thumbnail) attachment of MESSAGE, or nil."
  (let ((attachment (neoment-message-attachment message)))
    (pcase (plist-get attachment :type)
      ('image attachment)
      ((or 'video 'location) (plist-get attachment :thumbnail)))))

(defun neoment-media-image-size (window image-width image-height fraction)
  "Return (MAX-WIDTH . MAX-HEIGHT) in pixels for an image in WINDOW.
IMAGE-WIDTH and IMAGE-HEIGHT are the real size, when known.  FRACTION
is the max height as a fraction of the window height."
  (let* ((char (frame-char-width (window-frame window)))
         (max-w (* char (max 1 (- (window-width window) neoment-room-header-width 4))))
         (max-h (* fraction (window-pixel-height window))))
    (cons (truncate (if image-width (min image-width max-w) max-w))
          (truncate (if image-height (min image-height max-h) max-h)))))

(defun neoment-media--image-window (buffer)
  "Return the window to size BUFFER's inline images for, or nil.
A window on a graphical frame is preferred, from any frame."
  (or (seq-find (lambda (w) (display-graphic-p (window-frame w)))
                (get-buffer-window-list buffer nil t))
      (get-buffer-window buffer t)))

(defun neoment-media--create-image (file key window)
  "Return the image of FILE for message KEY sized for WINDOW, or nil."
  (let* ((message (neoment-room-get-message (neoment-get-room neoment--room-id) key))
         (attachment (and message (neoment-media--image-attachment message)))
         (size (and window (neoment-media-image-size
                            window (plist-get attachment :width)
                            (plist-get attachment :height)
                            (neoment-media--image-fraction key)))))
    (and size (ignore-errors
                (create-image file nil nil :max-width (car size)
                              :max-height (cdr size))))))

(defun neoment-media--image-text (image file key)
  "Return the image line text showing IMAGE (from FILE) for message KEY."
  (let* ((line (concat (make-string neoment-room-header-width ?\s)
                       (propertize " " 'display image 'neoment-image-file file
                                   'help-echo neoment-media--image-help)))
         (text (progn
                 (add-text-properties 0 (length line)
                                      (list 'keymap neoment-media-image-map) line)
                 (concat "\n" line))))
    (add-text-properties 0 (length text)
                         (list 'neoment-message key 'neoment-decoration t
                               'neoment-image key)
                         text)
    text))

(defun neoment-media--place-image (buffer tick marker file key)
  "Show the image FILE on a line below the header at MARKER in BUFFER.
KEY is the message.  Nothing happens when BUFFER was re-rendered since
TICK.  MARKER is released."
  (unwind-protect
      (when (and (buffer-live-p buffer)
                 (= tick (buffer-local-value 'neoment-media--render-tick buffer)))
        (with-current-buffer buffer
          (let ((image (neoment-media--create-image file key (neoment-media--image-window buffer))))
            (when (and image (marker-position marker)
                       (not (neoment-room--image-position key)))
              (let ((inhibit-read-only t))
                (save-excursion
                  (goto-char marker)
                  (goto-char (line-end-position))
                  (insert (neoment-media--image-text image file key))))))))
    (set-marker marker nil)))

(defun neoment-media--remove-images ()
  "Delete the inline image lines of the current buffer."
  (let ((inhibit-read-only t)
        (pos (point-min)))
    (while (setq pos (text-property-not-all pos (point-max) 'neoment-image nil))
      (delete-region pos (or (next-single-property-change pos 'neoment-image)
                             (point-max))))))

(defun neoment-media-add-images ()
  "Add the inline images of the current room buffer (GUI frames only)."
  (cl-incf neoment-media--render-tick)
  (neoment-media--remove-images)
  (let ((window (neoment-media--image-window (current-buffer))))
    (when (and window (display-graphic-p (window-frame window)) (display-images-p))
      (let ((buffer (current-buffer))
            (tick neoment-media--render-tick)
            (room (neoment-get-room neoment--room-id))
            (pos (point-min))
            (pending nil))
        ;; Collect every header first: placing an image shifts the text.
        (while (setq pos (text-property-any pos (point-max) 'neoment-header t))
          (let* ((key (get-text-property pos 'neoment-message))
                 (message (and key (neoment-room-get-message room key)))
                 (mxc (and message (plist-get (neoment-media--image-attachment message)
                                              :mxc-url))))
            (when (neoment-events-mxc-p mxc)
              (push (list (copy-marker pos) key mxc) pending))
            ;; Adjacent header lines share one property run: go line by line.
            (setq pos (save-excursion (goto-char pos) (forward-line 1) (point)))))
        (pcase-dolist (`(,marker ,key ,mxc) (nreverse pending))
          (condition-case err
              (neoment-media-image-file
               mxc (lambda (result)
                     (if (plist-get result :ok)
                         (neoment-media--place-image buffer tick marker
                                                     (plist-get result :ok) key)
                       (set-marker marker nil))))
            (error
             (set-marker marker nil)
             (message "neoment: inline image failed: %s" (error-message-string err)))))))))

(setq neoment-room-image-function #'neoment-media-add-images)

(defun neoment-media--refresh-image (key)
  "Re-display KEY's inline image at its current size, without a render."
  (let ((pos (neoment-room--image-position key)))
    (when pos
      (let ((image (neoment-media--create-image
                    (get-text-property pos 'neoment-image-file) key
                    (or (neoment-media--image-window (current-buffer)) (selected-window)))))
        (when image
          (with-silent-modifications
            (put-text-property pos (1+ pos) 'display image)))))))

(defun neoment-media--image-key-at-point (&optional header)
  "Return the message key of the inline image on the current line, or nil.
With HEADER, a message header line also gives its image."
  (let ((bol (line-beginning-position)))
    (or (get-text-property bol 'neoment-image)
        (and header
             (get-text-property bol 'neoment-header)
             (let ((key (get-text-property bol 'neoment-message)))
               (and key (neoment-room--image-position key) key))))))

(defun neoment-room-toggle-image-zoom ()
  "Toggle the inline image of the current line between default and full height.
Works on the image line and on its message header line.  A resized
image returns to the default size."
  (interactive)
  (let ((key (neoment-media--image-key-at-point t)))
    (if (not key)
        (neoment-notify--message "No image on this line")
      (neoment-media--set-image-fraction
       key (and (= (neoment-media--image-fraction key) neoment-media-image-default-height)
                neoment-media--max-height))
      (neoment-media--refresh-image key))))

(defun neoment-media--resize (factor limit-message)
  "Multiply the max height of the image on this line by FACTOR.
Show LIMIT-MESSAGE when the size cannot change."
  (let ((key (neoment-media--image-key-at-point)))
    (if (not key)
        (neoment-notify--message "No image on this line")
      (let* ((old (neoment-media--image-fraction key))
             (new (neoment-media--set-image-fraction key (* old factor))))
        (if (= old new)
            (neoment-notify--message limit-message)
          (neoment-media--refresh-image key))))))

(defun neoment-room-image-enlarge ()
  "Enlarge the inline image under the cursor one step."
  (interactive)
  (neoment-media--resize neoment-media--resize-step "Image is at its maximum size"))

(defun neoment-room-image-shrink ()
  "Shrink the inline image under the cursor one step."
  (interactive)
  (neoment-media--resize (/ 1.0 neoment-media--resize-step) "Image is at its minimum size"))

;;;; Open and save

(defun neoment-media--system-open (target)
  "Open TARGET (a file or URL) with the system program."
  (cond
   ((string-match-p "\\`https?://" target) (browse-url target))
   ((eq system-type 'darwin) (call-process "open" nil 0 nil target))
   ((eq system-type 'windows-nt) (w32-shell-execute "open" target))
   (t (call-process "xdg-open" nil 0 nil target))))

(declare-function w32-shell-execute "w32fns.c")

(defun neoment-media-default-open-handler (path attachment)
  "Open PATH for ATTACHMENT: audio in the player, the rest in the system program.
Audio uses the `mpv' based player unless `mpv' is missing or the
platform cannot reach its control channel (Windows)."
  (if (and (eq (plist-get attachment :type) 'audio)
           (not (eq system-type 'windows-nt))
           (executable-find "mpv"))
      (progn (require 'neoment-player)
             (neoment-player-play path))
    (neoment-media--system-open path)))

(defun neoment-media--call-handler (path attachment)
  "Call `neoment-on-open-attachment-function' with PATH and ATTACHMENT."
  (funcall neoment-on-open-attachment-function path attachment))

(defun neoment-media--mxc-at-point ()
  "Return (MXC TITLE ORIGIN) for an mxc emoticon or reaction at point."
  (let ((emoticon (get-text-property (point) 'neoment-emoticon))
        (reaction (get-text-property (point) 'neoment-reaction)))
    (cond
     ((and emoticon (neoment-events-mxc-p (plist-get emoticon :url)))
      (list (plist-get emoticon :url) (plist-get emoticon :title) 'emoticon))
     ((and reaction (neoment-events-mxc-p (plist-get reaction :key)))
      (list (plist-get reaction :key) (plist-get reaction :key) 'reaction)))))

(defun neoment-media--attachment-file-name (message)
  "Return the media file name of MESSAGE's attachment."
  (concat (neoment-message-effective-id message)
          (or (plist-get (neoment-message-attachment message) :filename) "")))

(defun neoment-room-open-attachment ()
  "Open the attachment, emoticon or reaction under the cursor."
  (interactive)
  (let ((mxc (neoment-media--mxc-at-point)))
    (if mxc
        (pcase-let ((`(,url ,title ,origin) mxc))
          (let ((name (concat (neoment-media-sanitize title) ".png")))
            (neoment-media-download
             url name
             (lambda (result)
               (if (plist-get result :error)
                   (neoment-notify--error
                    (concat "Error fetching attachment: "
                            (neoment-http-error-message (plist-get result :error))))
                 (neoment-media--call-handler
                  (plist-get result :ok)
                  (list :type 'image :mimetype "image/png"
                        :url (neoment-events-mxc-to-url url) :mxc-url url
                        :filename name :origin origin)))))))
      (let* ((message (neoment-room-message-at-point))
             (attachment (and message (neoment-message-attachment message))))
        (cond
         ((null message))
         ((null attachment) (neoment-notify--message "No attachment on this message"))
         ((eq (plist-get attachment :type) 'location)
          (if (plist-get attachment :url)
              (neoment-media--call-handler (plist-get attachment :url)
                                           (append (list :origin 'message) attachment))
            (neoment-notify--message "No URL for this location attachment")))
         (t
          (let ((filename (or (plist-get attachment :filename) "attachment")))
            (neoment-notify--message (format "Fetching attachment %s..." filename))
            (neoment-media-download
             (plist-get attachment :mxc-url) (neoment-media--attachment-file-name message)
             (lambda (result)
               (if (plist-get result :error)
                   (neoment-notify--error
                    (concat "Error fetching attachment: "
                            (neoment-http-error-message (plist-get result :error))))
                 (neoment-notify--message (format "Opening attachment %s..." filename))
                 (neoment-media--call-handler
                  (plist-get result :ok)
                  (append (list :origin 'message) attachment))))))))))))

(defvar-local neoment-media--image-buffer-path nil
  "File shown by a `neoment-media--show-image-buffer' buffer.")

(defun neoment-media--show-image-buffer (path filename)
  "Show the image file PATH in an `image-mode' buffer named after FILENAME.
The buffer already showing PATH is reused; another image with the same
FILENAME gets a buffer of its own.  Return the buffer."
  (let ((buffer (seq-find (lambda (b)
                            (equal (buffer-local-value 'neoment-media--image-buffer-path b)
                                   path))
                          (buffer-list))))
    (unless buffer
      (setq buffer (generate-new-buffer (format "*neoment-image: %s*" filename)))
      (with-current-buffer buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path)
        (setq default-directory (file-name-as-directory (neoment-storage-media-dir)))
        (image-mode)
        (setq neoment-media--image-buffer-path path)))
    (pop-to-buffer buffer)
    buffer))

(defun neoment-room-image-open ()
  "Open the full image under the cursor in an `image-mode' buffer.
Video and location thumbnails are opened as attachments instead."
  (interactive)
  (let* ((message (neoment-room-message-at-point))
         (attachment (and message (neoment-message-attachment message))))
    (cond
     ((null message))
     ((not (eq (plist-get attachment :type) 'image))
      (neoment-room-open-attachment))
     (t
      (let ((filename (or (plist-get attachment :filename) "image")))
        (neoment-media-download
         (plist-get attachment :mxc-url) (neoment-media--attachment-file-name message)
         (lambda (result)
           (if (plist-get result :error)
               (neoment-notify--error
                (concat "Error fetching attachment: "
                        (neoment-http-error-message (plist-get result :error))))
             (neoment-media--show-image-buffer (plist-get result :ok) filename)))))))))

(defun neoment-media-free-name (path)
  "Return PATH, or the first free \"name(N).ext\" next to it."
  (if (not (file-exists-p path))
      path
    (let* ((dir (file-name-directory path))
           (base (file-name-sans-extension (file-name-nondirectory path)))
           (ext (file-name-extension path t))
           (n 1)
           candidate)
      (while (file-exists-p (setq candidate (expand-file-name (format "%s(%d)%s" base n ext) dir)))
        (cl-incf n))
      candidate)))

(defun neoment-media-save-target (input filename)
  "Return the path where to save FILENAME given the user INPUT, or nil.
A directory gets FILENAME appended.  An existing file is overwritten
only when the user agrees, otherwise a free name is picked."
  (let* ((path (expand-file-name input)))
    (when (or (file-directory-p path) (string-suffix-p "/" input))
      (setq path (expand-file-name filename path)))
    (if (and (file-exists-p path) (not (y-or-n-p (concat "File exists." " Overwrite? "))))
        (neoment-media-free-name path)
      path)))

(defun neoment-room-save-attachment ()
  "Save the attachment of the message under the cursor."
  (interactive)
  (let* ((message (neoment-room-message-at-point))
         (attachment (and message (neoment-message-attachment message))))
    (cond
     ((null message))
     ((or (null attachment) (null (plist-get attachment :mxc-url)))
      (neoment-notify--message "No attachment on this message"))
     (t
      (let* ((filename (or (plist-get attachment :filename) "attachment"))
             (input (read-file-name "Save attachment to: " nil "" nil filename)))
        (if (string-empty-p input)
            (neoment-notify--message "Save location not provided")
          (let ((target (neoment-media-save-target input filename)))
            (neoment-media-download
             (plist-get attachment :mxc-url) (neoment-media--attachment-file-name message)
             (lambda (result)
               (if (plist-get result :error)
                   (neoment-notify--error
                    (concat "Error fetching attachment: "
                            (neoment-http-error-message (plist-get result :error))))
                 (copy-file (plist-get result :ok) target t)
                 (neoment-notify--message (concat "Attachment saved to " target))))))))))))

;;;; Upload

(defun neoment-media-mimetype (file)
  "Return the mime type of FILE."
  (or (mailcap-file-name-to-mime-type file)
      (and (executable-find "file")
           (let ((out (string-trim (with-output-to-string
                                     (call-process "file" nil standard-output nil
                                                   "--mime-type" "-b" file)))))
             (and (string-match-p "/" out) out)))
      "application/octet-stream"))

(defun neoment-media-upload (file callback)
  "Upload FILE and call CALLBACK with (:ok ATTACHMENT) or (:error ERR)."
  (let ((mimetype (neoment-media-mimetype file))
        (filename (file-name-nondirectory file)))
    (neoment-api-request
     'post "/_matrix/media/v3/upload"
     :query `((filename . ,filename))
     :body-file file :content-type mimetype
     :callback
     (lambda (result)
       (funcall callback
                (if (plist-get result :error)
                    result
                  (list :ok (list :filename filename
                                  :url (alist-get 'content_uri (plist-get result :ok))
                                  :mimetype mimetype
                                  :size (file-attribute-size (file-attributes file))))))))))

(defun neoment-media--upload-and-compose (file room-id thread-root-id &optional window)
  "Upload FILE and open a compose buffer for ROOM-ID with it.
THREAD-ROOT-ID is the thread; WINDOW is the room window."
  (neoment-media-upload
   file
   (lambda (result)
     (if (plist-get result :error)
         (neoment-notify--error
          (concat "Error uploading file: "
                  (neoment-http-error-message (plist-get result :error))))
       (require 'neoment-compose)
       (when (window-live-p window) (select-window window))
       (neoment-compose-open room-id :thread-root-id thread-root-id
                             :attachment (plist-get result :ok))))))

(defun neoment-room-upload ()
  "Upload a file and compose a message with it."
  (interactive)
  (let ((file (expand-file-name (read-file-name "Enter file path: " nil nil t))))
    (if (not (file-regular-p file))
        (neoment-notify--error (concat "File does not exist: " file))
      (neoment-media--upload-and-compose file neoment--room-id neoment--thread-root-id
                                         (selected-window)))))

;;;; Clipboard

(defun neoment-media--run (program &rest args)
  "Run PROGRAM with ARGS.  Return (STATUS . OUTPUT)."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((status (apply #'call-process program nil (list t nil) nil args)))
      (cons status (buffer-string)))))

(defun neoment-media--write-bytes (bytes file)
  "Write the unibyte string BYTES to FILE.  Return non-nil on success."
  (condition-case nil
      (let ((coding-system-for-write 'binary))
        (with-temp-file file
          (set-buffer-multibyte nil)
          (insert bytes))
        (> (file-attribute-size (file-attributes file)) 0))
    (error nil)))

(defun neoment-media-clipboard-png (file)
  "Save the clipboard image as PNG to FILE.
Return nil on success, or the error message."
  (let ((gui (and (display-graphic-p)
                  (ignore-errors (gui-get-selection 'CLIPBOARD 'image/png)))))
    (cond
     ((and (stringp gui) (> (length gui) 0))
      (if (neoment-media--write-bytes (if (multibyte-string-p gui) (encode-coding-string gui (quote binary)) gui) file)
          nil
        "Failed to save clipboard image to temporary file"))
     ((eq system-type 'darwin)
      (if (executable-find "pngpaste")
          (if (zerop (car (neoment-media--run "pngpaste" file)))
              nil
            "No image found in clipboard")
        (let ((out (decode-coding-string
                    (cdr (neoment-media--run "osascript" "-e"
                                             "get the clipboard as «class PNGf»"))
                    'utf-8)))
          (if (string-match "«data PNGf\\([0-9A-Fa-f]+\\)»" out)
              (if (neoment-media--write-bytes
                   (let ((hex (match-string 1 out)))
                     (apply #'unibyte-string
                            (cl-loop for i from 0 below (length hex) by 2
                                     collect (string-to-number (substring hex i (+ i 2)) 16))))
                   file)
                  nil
                "Failed to save clipboard image to temporary file")
            "No image found in clipboard"))))
     ((memq system-type '(gnu/linux berkeley-unix gnu/kfreebsd))
      (cond
       ((and (getenv "WAYLAND_DISPLAY") (executable-find "wl-paste"))
        (if (not (string-search "image/png" (cdr (neoment-media--run "wl-paste" "--list-types"))))
            "No image found in clipboard"
          (if (neoment-media--write-bytes
               (cdr (neoment-media--run "wl-paste" "--type" "image/png")) file)
              nil
            "Failed to save clipboard image to temporary file")))
       ((not (executable-find "xclip"))
        "The 'xclip' command is not available. Install with your package manager.")
       ((not (string-search "image/png" (cdr (neoment-media--run "xclip" "-selection" "clipboard"
                                                                 "-t" "TARGETS" "-o"))))
        "No image found in clipboard")
       ((neoment-media--write-bytes
         (cdr (neoment-media--run "xclip" "-selection" "clipboard" "-t" "image/png" "-o")) file)
        nil)
       (t "Failed to save clipboard image to temporary file")))
     ((eq system-type 'windows-nt)
      (let ((script (format "Add-Type -AssemblyName System.Windows.Forms; $i = [System.Windows.Forms.Clipboard]::GetImage(); if ($i -eq $null) { exit 1 }; $i.Save('%s', [System.Drawing.Imaging.ImageFormat]::Png)" file)))
        (if (zerop (car (neoment-media--run "powershell" "-NoProfile" "-Command" script)))
            nil
          "No image found in clipboard")))
     (t "Clipboard image upload not supported on this platform"))))

(defun neoment-room-upload-clipboard-image ()
  "Upload the clipboard image and compose a message with it."
  (interactive)
  (let* ((file (make-temp-file "neoment-clipboard-" nil ".png"))
         (error-message (neoment-media-clipboard-png file)))
    (if error-message
        (progn (ignore-errors (delete-file file))
               (neoment-notify--error error-message))
      (neoment-media--upload-and-compose file neoment--room-id neoment--thread-root-id
                                         (selected-window)))))

;;;; Hover popups

(defvar neoment-media-popup-delay 0.5
  "Idle seconds before a popup is shown.")

(defvar neoment-media--popup-timer nil
  "Timer of the pending popup.")

(defvar-local neoment-media--popup-pos nil
  "Position the popup was shown for.")

(defconst neoment-media--posframe-buffer " *neoment-popup*"
  "Buffer of the posframe popup.")

(defun neoment-media-popup-text (props)
  "Return the popup text for the text PROPS at point, or nil."
  (let ((reaction (plist-get props 'neoment-reaction))
        (emoticon (plist-get props 'neoment-emoticon)))
    (cond
     (reaction
      (require 'neoment-emoji)
      (let ((key (plist-get reaction :key)))
        (concat (propertize (or (neoment-emoji-label key) key) 'face 'bold)
                "\n\n"
                (mapconcat #'neoment-display-name (plist-get reaction :senders) "\n"))))
     (emoticon
      (propertize (plist-get emoticon :title) 'face 'bold)))))

(defun neoment-media--hide-popup ()
  "Hide the popup."
  (when (and (featurep 'posframe) (get-buffer neoment-media--posframe-buffer))
    (posframe-hide neoment-media--posframe-buffer)))

(defun neoment-media--show-popup (buffer pos)
  "Show the popup for POS in BUFFER if point is still there."
  (setq neoment-media--popup-timer nil)
  (when (and (buffer-live-p buffer) (eq buffer (current-buffer)) (= (point) pos))
    (let* ((props (text-properties-at pos))
           (text (neoment-media-popup-text props)))
      (when text
        (setq neoment-media--popup-pos pos)
        (if (and (display-graphic-p) (require 'posframe nil t))
            (let ((mxc (or (plist-get (plist-get props 'neoment-emoticon) :url)
                           (let ((key (plist-get (plist-get props 'neoment-reaction) :key)))
                             (and (neoment-events-mxc-p key) key)))))
              (posframe-show neoment-media--posframe-buffer :string text :position pos
                             :border-width 1 :internal-border-width 1)
              (when (neoment-events-mxc-p mxc)
                (neoment-media-image-file
                 mxc (lambda (result)
                       (when (and (plist-get result :ok) (buffer-live-p buffer)
                                  (eq buffer (current-buffer)) (= (point) pos))
                         (let ((image (ignore-errors
                                        (create-image (plist-get result :ok) nil nil
                                                      :max-height (* 8 (frame-char-height))))))
                           (when image
                             (posframe-show neoment-media--posframe-buffer
                                            :string (concat text "\n"
                                                            (propertize " " 'display image))
                                            :position pos))))))))
          (message "%s" text))))))

(defun neoment-media--post-command ()
  "Hide the popup when point moved, and schedule a new one."
  (unless (equal neoment-media--popup-pos (point))
    (when neoment-media--popup-pos
      (setq neoment-media--popup-pos nil)
      (neoment-media--hide-popup))
    (when (timerp neoment-media--popup-timer)
      (cancel-timer neoment-media--popup-timer))
    (setq neoment-media--popup-timer
          (run-with-idle-timer neoment-media-popup-delay nil
                               #'neoment-media--show-popup (current-buffer) (point)))))

(defun neoment-media--setup-room-buffer ()
  "Enable hover popups in the current room buffer."
  (add-hook 'post-command-hook #'neoment-media--post-command nil t))

(add-hook 'neoment-room-mode-hook #'neoment-media--setup-room-buffer)

(provide 'neoment-media)
;;; neoment-media.el ends here
