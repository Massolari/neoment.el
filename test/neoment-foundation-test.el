;;; neoment-foundation-test.el --- Tests for config, faces, HTTP and storage  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 1 of the port: configuration, messages, faces, the HTTP layer
;; and storage.

;;; Code:

(require 'test-helper)
(require 'neoment-config)
(require 'neoment-notify)
(require 'neoment-faces)
(require 'neoment-http)
(require 'neoment-storage)

;;;; Config

(ert-deftest neoment-config-defaults ()
  (should (eq (default-value 'neoment-save-session) t))
  (should (eq (default-value 'neoment-desktop-notifications-enabled) t))
  (should (eq (default-value 'neoment-rooms-room-title-format) 'room_space))
  (should (eq (default-value 'neoment-rooms-display-last-message) 'message))
  (should (null (default-value 'neoment-login-method)))
  (should (equal (neoment-icon 'dot) "•"))
  (should-not (boundp 'neoment-desktop-notifications-source))
  (should-not (boundp 'neoment-desktop-notifications-rooms)))

(ert-deftest neoment-config-invalid-login-method-warns ()
  (let ((warnings nil)
        (neoment-login-method 'foo))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type msg &rest _) (push msg warnings))))
      (should-not (neoment-config-validate)))
    (should (= (length warnings) 1))
    (should (string-match-p "neoment-login-method" (car warnings)))))

(ert-deftest neoment-config-reload-message ()
  (neoment-test-with-messages
    (neoment-reload-config)
    (should (neoment-test-message-p "Configuration reloaded"))))

(ert-deftest neoment-config-icon-override ()
  (let ((neoment-icons '((room . "#"))))
    (should (equal (neoment-icon 'room) "#"))
    (should (equal (neoment-icon 'dot) "•"))))

;;;; Notifier

(ert-deftest neoment-notify-custom-notifier ()
  (let* ((got nil)
         (neoment-notifier (lambda (msg level) (push (list msg level) got))))
    (neoment-notify--message "hello" 'warn)
    (neoment-notify--message "plain")
    (should (equal (reverse got)
                   '(("[Neoment] hello" warn) ("[Neoment] plain" info))))))

;;;; Faces

(ert-deftest neoment-faces-border-matches-content ()
  (let ((old-content (face-attribute 'neoment-bubble-content :background))
        (old-default (face-attribute 'default :background)))
    (unwind-protect
        (progn
          (set-face-attribute 'neoment-bubble-content nil :background "#123456")
          (set-face-attribute 'default nil :background "#000000")
          (neoment-faces--update)
          (should (equal (face-attribute 'neoment-bubble-border :foreground)
                         "#123456"))
          (should (equal (face-attribute 'neoment-bubble-border :background)
                         "#000000")))
      (set-face-attribute 'neoment-bubble-content nil :background old-content)
      (set-face-attribute 'default nil :background old-default))))

(ert-deftest neoment-faces-twenty-user-faces ()
  (dotimes (i 20)
    (should (facep (intern (format "neoment-user-%d" (1+ i))))))
  (should (eq (neoment-faces-user-face 20) 'neoment-user-1)))

(ert-deftest neoment-faces-bubble-edge-fallback ()
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'char-displayable-p) (lambda (&rest _) nil)))
    (should (equal (neoment-faces-bubble-edges) '("▐" . "▌")))
    (let* ((neoment--bubble-edges (neoment-faces-bubble-edges))
           (bubble (neoment-faces-bubble "x")))
      (should (equal (substring-no-properties bubble) "▐x▌"))
      (should (eq (get-text-property 0 'face bubble) 'neoment-bubble-border))
      (should (eq (get-text-property 1 'face bubble) 'neoment-bubble-content))
      (should (eq (get-text-property 2 'face bubble) 'neoment-bubble-border))))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'char-displayable-p) (lambda (&rest _) t)))
    (should (equal (neoment-faces-bubble-edges) '("" . ""))))
  ;; Terminal frames keep the Nerd Font glyphs.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
            ((symbol-function 'char-displayable-p) (lambda (&rest _) nil)))
    (should (equal (neoment-faces-bubble-edges) '("" . "")))))

;;;; Icons

(defmacro neoment-test-with-icon-env (graphic displayable &rest body)
  "Run BODY with GRAPHIC frame and DISPLAYABLE glyph stubs, fresh cache."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) ,graphic))
             ((symbol-function 'char-displayable-p) (lambda (&rest _) ,displayable)))
     (neoment-icon--clear-cache)
     (unwind-protect (progn ,@body) (neoment-icon--clear-cache))))

(ert-deftest neoment-plain-icons-cover-defaults ()
  (should (equal (sort (mapcar #'car neoment-plain-icons) #'string<)
                 (sort (mapcar #'car neoment-default-icons) #'string<)))
  (dolist (cell neoment-plain-icons)
    (should (= (string-width (cdr cell)) 1))))

(ert-deftest neoment-icon-plain-fallback ()
  (neoment-test-with-icon-env t nil
    (should (equal (neoment-icon 'room) "#"))
    (let ((neoment-icons '((room . "\U000F9999"))))
      (should (equal (neoment-icon 'room) "\U000F9999")))
    (let ((neoment-icons neoment-plain-icons))
      (should (equal (neoment-icon 'room) "#"))))
  (neoment-test-with-icon-env t t
    (should (equal (neoment-icon 'room) "\U000F0BA7")))
  (neoment-test-with-icon-env nil nil
    (should (equal (neoment-icon 'room) "\U000F0BA7"))
    (let ((neoment-icons neoment-plain-icons))
      (should (equal (neoment-icon 'room) "#")))))

(ert-deftest neoment-faces-update-clears-icon-cache ()
  (puthash ?x t neoment-icon--displayable)
  (neoment-faces--update)
  (should (zerop (hash-table-count neoment-icon--displayable))))

(ert-deftest neoment-faces-setup-icon-font-routes-pua ()
  (let ((calls nil) (neoment-icon--font-applied nil)
        (neoment-icon-font-family "Test Font"))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'find-font) (lambda (&rest _) t))
              ((symbol-function 'set-fontset-font)
               (lambda (&rest args) (push args calls))))
      (neoment-faces-setup-icon-font)
      (should (cl-find-if (lambda (c) (and (eq (nth 1 c) #xF0BA7)
                                           (eq (nth 4 c) 'append)))
                          calls))
      (should (cl-find-if (lambda (c) (eq (nth 1 c) #xE0B6)) calls))
      (should-not (cl-find-if (lambda (c) (eq (nth 1 c) ?▶)) calls))
      (let ((n (length calls)))
        (neoment-faces-setup-icon-font)
        (should (= n (length calls)))))))

(ert-deftest neoment-faces-setup-icon-font-skips ()
  (dolist (case '((nil t t) ("Test Font" nil t) ("Test Font" t nil)))
    (let ((calls nil) (neoment-icon--font-applied nil)
          (neoment-icon-font-family (nth 0 case)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) (nth 1 case)))
                ((symbol-function 'find-font) (lambda (&rest _) (nth 2 case)))
                ((symbol-function 'set-fontset-font)
                 (lambda (&rest args) (push args calls))))
        (neoment-faces-setup-icon-font)
        (should-not calls)))))

(ert-deftest neoment-faces-bubble-edges-sets-up-font ()
  (let ((called nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'char-displayable-p) (lambda (&rest _) t))
              ((symbol-function 'neoment-faces-setup-icon-font)
               (lambda () (setq called t))))
      (neoment-faces-bubble-edges)
      (should called))))

;;;; JSON

(ert-deftest neoment-json-false-versus-empty-array ()
  (let ((json (neoment-json-encode '((a . :false) (b . []) ("c" . t)))))
    (should (equal json "{\"a\":false,\"b\":[],\"c\":true}"))
    (let ((back (neoment-json-decode json)))
      (should (eq (alist-get 'a back) :false))
      (should (null (alist-get 'b back)))
      (should (eq (alist-get 'c back) t)))))

;;;; HTTP

(defmacro neoment-test-with-plz (responder &rest body)
  "Run BODY with `plz' replaced by RESPONDER.
RESPONDER gets the plz keyword arguments and returns (then VALUE) or
\(else PLZ-ERROR)."
  (declare (indent 1))
  `(let ((plz-calls nil)
         (neoment-http-backend 'plz))
     (cl-letf (((symbol-function 'plz)
                (lambda (method url &rest args)
                  (push (append (list :method method :url url) args) plz-calls)
                  (pcase (funcall ,responder args)
                    (`(then ,v) (funcall (plist-get args :then) v))
                    (`(else ,e) (funcall (plist-get args :else) e)))
                  'proc)))
       ,@body)))

(ert-deftest neoment-http-success-json ()
  (let (result)
    (neoment-test-with-plz (lambda (_) '(then "{\"x\":1}"))
      (neoment-http-request :url "https://h/a" :query '((b . "c d"))
                            :json '((k . "v"))
                            :callback (lambda (r) (setq result r)))
      (should (equal result '(:ok ((x . 1)))))
      (let ((call (car plz-calls)))
        (should (equal (plist-get call :url) "https://h/a?b=c%20d"))
        (should (equal (plist-get call :body) "{\"k\":\"v\"}"))
        (should (plist-get call :noquery))
        (should (equal (cdr (assoc "Content-Type" (plist-get call :headers)))
                       "application/json"))))))

(ert-deftest neoment-http-form-body ()
  (neoment-test-with-plz (lambda (_) '(then "{}"))
    (neoment-http-request :method 'post :url "https://h/t"
                          :form '((grant_type . "device_code") (scope . "a b")))
    (should (equal (plist-get (car plz-calls) :body)
                   "grant_type=device_code&scope=a%20b"))))

(ert-deftest neoment-http-matrix-error ()
  (let (result)
    (neoment-test-with-plz
        (lambda (_)
          `(else ,(make-plz-error
                   :response (make-plz-response
                              :status 401
                              :body "{\"errcode\":\"M_UNKNOWN_TOKEN\",\"error\":\"Bad\",\"soft_logout\":true}"))))
      (neoment-http-request :url "https://h/a" :callback (lambda (r) (setq result r))))
    (let ((err (plist-get result :error)))
      (should (= (plist-get err :status) 401))
      (should (equal (plist-get err :errcode) "M_UNKNOWN_TOKEN"))
      (should (equal (plist-get err :error) "Bad"))
      (should (eq (plist-get err :soft-logout) t))
      (should-not (neoment-http-transient-p err)))))

(ert-deftest neoment-http-network-failure ()
  (let (result)
    (neoment-test-with-plz
        (lambda (_) `(else ,(make-plz-error :curl-error '(28 . "Timeout"))))
      (neoment-http-request :url "https://h/a" :callback (lambda (r) (setq result r))))
    (let ((err (plist-get result :error)))
      (should (null (plist-get err :status)))
      (should (equal (neoment-http-error-message err) "Timeout"))
      (should (neoment-http-transient-p err))))
  (should (neoment-http-transient-p '(:status 503)))
  (should (neoment-http-transient-p '(:status 429)))
  (should (neoment-http-transient-p '(:status 408)))
  (should-not (neoment-http-transient-p '(:status 400))))

;;;; Authenticated requests

(ert-deftest neoment-api-authorization-only-for-homeserver ()
  (neoment-test-new-client)
  (let ((neoment-http-ensure-token-function nil))
    (neoment-test-with-http (lambda (_) '(:ok nil))
      (neoment-api-request 'get "/_matrix/client/v3/sync")
      (neoment-api-request 'get "https://other.example/x")
      (neoment-api-request 'get "https://hs.example.evil/x")
      (let ((h1 (plist-get (nth 0 neoment-test--requests) :headers))
            (h2 (plist-get (nth 1 neoment-test--requests) :headers))
            (h3 (plist-get (nth 2 neoment-test--requests) :headers)))
        (should (equal (cdr (assoc "Authorization" h1)) "Bearer TOKEN"))
        (should-not (assoc "Authorization" h2))
        (should-not (assoc "Authorization" h3)))
      (dolist (url (neoment-test-request-urls))
        (should-not (string-search "TOKEN" url))))))

(ert-deftest neoment-api-stale-response-dropped ()
  (neoment-test-new-client)
  (let ((neoment-http-ensure-token-function nil)
        (pending nil)
        (called nil))
    (neoment-test-with-http (lambda (args) (setq pending args) 'pending)
      (neoment-api-request 'get "/_matrix/client/v3/sync"
                           :callback (lambda (_) (setq called t)))
      ;; The user logs out and in again.
      (neoment-test-new-client)
      (funcall (plist-get pending :callback) '(:ok ((next_batch . "x"))))
      (should-not called))))

;;;; Storage

(ert-deftest neoment-storage-data-file-mode ()
  (neoment-test-with-temp-dir
    (neoment-storage-write-json (neoment-storage-session-file)
                                '((access_token . "x")) t)
    (should (file-exists-p (neoment-storage-session-file)))
    (should (= (file-modes (neoment-storage-session-file)) #o600))
    (should (string-prefix-p user-emacs-directory (neoment-storage-session-file)))
    (should (equal (neoment-storage-read-json (neoment-storage-session-file))
                   '((access_token . "x"))))))

(ert-deftest neoment-storage-round-trip ()
  (neoment-test-with-temp-dir
    (neoment-storage-write-json (neoment-storage-cache-file)
                                '((a . :false) (b . [1 2]) (c . "ü")))
    (should (equal (neoment-storage-read-json (neoment-storage-cache-file))
                   '((a . :false) (b 1 2) (c . "ü"))))
    (should (file-directory-p (neoment-storage-media-dir)))
    (should (string-prefix-p (neoment-storage-cache-dir) (neoment-storage-media-dir)))))

(ert-deftest neoment-storage-ui-state-round-trip ()
  (neoment-test-with-temp-dir
    (neoment-storage-save-ui-state '(("People" . t) ("Rooms")) '(("!s:x" . t)))
    (should (equal (neoment-storage-load-ui-state)
                   '(:sections (("People" . t) ("Rooms")) :spaces (("!s:x" . t)))))))

(ert-deftest neoment-storage-oauth-clients ()
  (neoment-test-with-temp-dir
    (should-not (neoment-storage-oauth-client-id "https://auth/"))
    (neoment-storage-set-oauth-client-id "https://auth/" "abc")
    (neoment-storage-set-oauth-client-id "https://other/" "def")
    (should (equal (neoment-storage-oauth-client-id "https://auth/") "abc"))
    (neoment-storage-set-oauth-client-id "https://auth/" nil)
    (should-not (neoment-storage-oauth-client-id "https://auth/"))
    (should (equal (neoment-storage-oauth-client-id "https://other/") "def"))))

(provide 'neoment-foundation-test)
;;; neoment-foundation-test.el ends here
