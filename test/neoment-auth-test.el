;;; neoment-auth-test.el --- Tests for login and session  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 2 of the port: input parsing, discovery, login methods, the
;; generation counter, password login, session save/restore and logout.

;;; Code:

(require 'test-helper)
(require 'neoment-auth)
(require 'neoment-events)

(defmacro neoment-auth-test-env (&rest body)
  "Run BODY in a temp dir with messages captured and UI side effects stubbed.
`started' is set when sync starts and `opened' when the list opens."
  (declare (indent 0))
  `(neoment-test-with-temp-dir
     (neoment-test-with-messages
       (let ((started nil) (opened nil)
             (neoment--client nil)
             (neoment-login-method nil)
             (neoment-auth--cancel-functions nil))
         (ignore started opened)
         (cl-letf (((symbol-function 'neoment-sync-start) (lambda (&rest _) (setq started t)))
                   ((symbol-function 'neoment-sync-stop) (lambda (&rest _) nil))
                   ((symbol-function 'neoment-rooms-open) (lambda (&rest _) (setq opened t)))
                   ((symbol-function 'neoment--defer)
                    (lambda (fn &rest args) (apply fn args))))
           ,@body)))))

(defun neoment-auth-test-server (routes)
  "Return an HTTP handler answering from ROUTES, an alist (URL-REGEXP . RESULT)."
  (lambda (args)
    (let ((url (plist-get args :url)))
      (or (cdr (seq-find (lambda (r)
                           (let ((key (car r)))
                             (if (consp key)
                                 (and (eq (car key) (plist-get args :method))
                                      (string-match-p (cdr key) url))
                               (string-match-p key url))))
                         routes))
          '(:error (:status 404 :error "Not found"))))))

;;;; 2.1 Input parsing

(ert-deftest neoment-auth-parse-server-name ()
  (should (equal (neoment-auth-parse-server-name "@alice:example.org")
                 '("example.org" . "@alice:example.org")))
  (should (equal (neoment-auth-parse-server-name "example.org")
                 '("example.org")))
  (should (equal (neoment-auth-parse-server-name "https://matrix.example.org/")
                 '("https://matrix.example.org")))
  (should (null (neoment-auth-parse-server-name "")))
  (should (null (neoment-auth-parse-server-name "   ")))
  (should (null (neoment-auth-parse-server-name "@alice")))
  (should (null (neoment-auth-parse-server-name "not a server"))))

(ert-deftest neoment-auth-login-input-messages ()
  (neoment-auth-test-env
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (neoment-login))
    (should (neoment-test-message-p "Login cancelled"))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "@bad")))
      (neoment-login))
    (should (neoment-test-message-p "Invalid Matrix ID or server: @bad"))))

;;;; 2.2 Discovery

(ert-deftest neoment-auth-discover-cases ()
  (let (hs)
    (neoment-test-with-http
        (lambda (_) '(:ok ((m.homeserver . ((base_url . "https://matrix.example.org/"))))))
      (neoment-auth-discover "example.org:8448" (lambda (h) (setq hs h)))
      (should (equal hs "https://matrix.example.org"))
      (should (equal (car (neoment-test-request-urls))
                     "https://example.org/.well-known/matrix/client"))
      (should (= (plist-get (car neoment-test--requests) :connect-timeout) 5))
      (should (= (plist-get (car neoment-test--requests) :timeout) 10)))
    (neoment-test-with-http (lambda (_) '(:error (:status 404)))
      (neoment-auth-discover "example.org" (lambda (h) (setq hs h)))
      (should (equal hs "https://example.org")))
    (neoment-test-with-http
        (lambda (_) (quote (:ok ((m.homeserver . ((base_url . "ftp://x")))))))
      (neoment-auth-discover "example.org" (lambda (h) (setq hs h)))
      (should (equal hs "https://example.org")))
    (neoment-test-with-http (lambda (_) (error "Should not be called"))
      (neoment-auth-discover "https://hs.example" (lambda (h) (setq hs h)))
      (should (equal hs "https://hs.example"))
      (should (null neoment-test--requests)))))

(ert-deftest neoment-auth-client-reset-keeps-device-id ()
  (let ((neoment--client nil))
    (neoment-test-new-client)
    (setf (neoment-client-device-id neoment--client) "DEV")
    (neoment-get-room "!r:s")
    (neoment-client-reset "https://new.example")
    (should (equal (neoment-client-device-id neoment--client) "DEV"))
    (should (equal (neoment-client-homeserver neoment--client) "https://new.example"))
    (should (null (neoment-client-access-token neoment--client)))
    (should (null (neoment-rooms)))))

(ert-deftest neoment-auth-client-reset-runs-hook ()
  (let* ((neoment--client nil)
         (seen nil)
         (neoment-client-reset-hook
          (list (lambda () (push neoment--client seen)))))
    (neoment-test-new-client)
    (let ((new (neoment-client-reset "https://new.example")))
      (should (= (length seen) 1))
      (should (eq (car seen) new))
      (should (eq (car seen) neoment--client))
      (should (equal (neoment-client-homeserver (car seen)) "https://new.example")))))

(ert-deftest neoment-auth-session-expiry-clears-replies ()
  (neoment-auth-test-env
    (neoment-test-new-client)
    (neoment-storage-save-session)
    (neoment-events-reset-caches)
    (puthash "!r:s $orig" (list :message (neoment-message--create :id "$orig"))
             neoment-events--reply-cache)
    (neoment-auth-session-expired)
    (should-not (neoment-logged-in-p))
    (should (neoment-test-message-p "Session expired, please log in again"))
    (should (zerop (hash-table-count neoment-events--reply-cache)))))

;;;; 2.3 Login methods

(defconst neoment-auth-test-metadata
  '(:ok ((issuer . "https://auth.example/")
         (grant_types_supported "authorization_code"
                                "urn:ietf:params:oauth:grant-type:device_code")
         (device_authorization_endpoint . "https://auth.example/device")
         (token_endpoint . "https://auth.example/token")
         (registration_endpoint . "https://auth.example/register")
         (revocation_endpoint . "https://auth.example/revoke"))))

(defun neoment-auth-test-flows (&rest types)
  "Return a /login response offering TYPES."
  `(:ok ((flows . ,(mapcar (lambda (ty) `((type . ,ty))) types)))))

(ert-deftest neoment-auth-login-flows-detection ()
  (let (result metadata)
    ;; SSO without the token flow is not offered.
    (neoment-test-with-http
        (neoment-auth-test-server
         `(("/login\\'" . ,(neoment-auth-test-flows "m.login.password" "m.login.sso"))))
      (neoment-auth-get-login-flows "https://hs" (lambda (r m) (setq result r metadata m)))
      (should (equal result '(:ok (password))))
      (should (null metadata)))
    ;; All three, in order.
    (neoment-test-with-http
        (neoment-auth-test-server
         `(("/login\\'" . ,(neoment-auth-test-flows "m.login.sso" "m.login.token"
                                                    "m.login.password"))
           ("auth_metadata" . ,neoment-auth-test-metadata)))
      (neoment-auth-get-login-flows "https://hs" (lambda (r m) (setq result r metadata m)))
      (should (equal result '(:ok (oauth_device password sso))))
      (should (equal (plist-get metadata :revocation-endpoint) "https://auth.example/revoke")))
    ;; Nothing supported.
    (neoment-test-with-http
        (neoment-auth-test-server
         `(("/login\\'" . ,(neoment-auth-test-flows "m.login.dummy"))))
      (neoment-auth-get-login-flows "https://hs" (lambda (r _) (setq result r)))
      (should (equal result
                     '(:error "No supported login method. The server offers: m.login.dummy"))))
    ;; /login failed.
    (neoment-test-with-http
        (neoment-auth-test-server '(("/login\\'" . (:error (:status nil :error "boom")))))
      (neoment-auth-get-login-flows "https://hs" (lambda (r _) (setq result r)))
      (should (equal result
                     '(:error "Could not fetch login methods from https://hs: boom"))))))

(defun neoment-auth-test-run-login (routes &rest stubs)
  "Run `neoment-login' for @me:hs.example against ROUTES.
STUBS is a plist with :method-choice and :password."
  (cl-letf (((symbol-function 'read-string)
             (lambda (prompt &rest _)
               (if (string-prefix-p "Matrix ID" prompt) "@me:hs.example" "me")))
            ((symbol-function 'read-passwd)
             (lambda (&rest _) (or (plist-get stubs :password) "secret")))
            ((symbol-function 'completing-read)
             (lambda (prompt collection &rest _)
               (push (cons prompt (mapcar #'car collection)) neoment-auth-test--prompts)
               (let ((c (plist-get stubs :method-choice)))
                 (if (eq c 'quit) (signal 'quit nil) c))))
            ((symbol-function 'neoment-oauth-device-login)
             (lambda (_ctx) (push 'oauth neoment-auth-test--ran)))
            ((symbol-function 'neoment-sso-login)
             (lambda (_ctx) (push 'sso neoment-auth-test--ran))))
    (neoment-test-with-http (neoment-auth-test-server routes)
      (neoment-login)
      neoment-test--requests)))

(defvar neoment-auth-test--prompts nil)
(defvar neoment-auth-test--ran nil)

(defconst neoment-auth-test-login-ok
  '(:ok ((access_token . "AT") (refresh_token . "RT") (expires_in_ms . 300000)
         (user_id . "@me:hs.example"))))

(ert-deftest neoment-auth-method-selection ()
  ;; OAuth preferred silently.
  (neoment-auth-test-env
    (let ((neoment-auth-test--ran nil) (neoment-auth-test--prompts nil))
      (neoment-auth-test-run-login
       `(("well-known" . (:error (:status 404)))
         ("/login\\'" . ,(neoment-auth-test-flows "m.login.password"))
         ("auth_metadata" . ,neoment-auth-test-metadata)))
      (should (equal neoment-auth-test--ran '(oauth)))
      (should (null neoment-auth-test--prompts))
      (should (neoment-test-message-p "Looking up the homeserver for hs.example..."))))
  ;; Configured method not offered.
  (neoment-auth-test-env
    (let ((neoment-login-method 'sso))
      (neoment-auth-test-run-login
       `(("/login\\'" . ,(neoment-auth-test-flows "m.login.password"))))
      (should (neoment-test-message-p
               "Login method 'sso' is not offered by the server. It offers: password"))))
  ;; Configured method offered.
  (neoment-auth-test-env
    (let ((neoment-login-method 'sso) (neoment-auth-test--ran nil))
      (neoment-auth-test-run-login
       `(("/login\\'" . ,(neoment-auth-test-flows "m.login.password" "m.login.sso"
                                                  "m.login.token"))
         ("auth_metadata" . ,neoment-auth-test-metadata)))
      (should (equal neoment-auth-test--ran '(sso)))))
  ;; Several methods: prompt with labels, then cancel.
  (neoment-auth-test-env
    (let ((neoment-auth-test--prompts nil))
      (neoment-auth-test-run-login
       `(("/login\\'" . ,(neoment-auth-test-flows "m.login.password" "m.login.sso"
                                                  "m.login.token")))
       :method-choice 'quit)
      (should (equal (car neoment-auth-test--prompts)
                     '("Login method: " "Password" "Single Sign-On (browser)")))
      (should (neoment-test-message-p "Login cancelled"))))
  ;; Several methods: choose SSO.
  (neoment-auth-test-env
    (let ((neoment-auth-test--ran nil))
      (neoment-auth-test-run-login
       `(("/login\\'" . ,(neoment-auth-test-flows "m.login.password" "m.login.sso"
                                                  "m.login.token")))
       :method-choice "Single Sign-On (browser)")
      (should (equal neoment-auth-test--ran '(sso))))))

;;;; 2.4 Generation

(ert-deftest neoment-auth-stale-generation-ignored ()
  (neoment-auth-test-env
    (neoment-client-reset "https://hs")
    (let* ((pending nil)
           (cancelled nil)
           (ctx (list :generation neoment--login-generation)))
      (neoment-auth-add-cancel-function (lambda () (setq cancelled t)))
      (neoment-test-with-http (lambda (args) (setq pending args) 'pending)
        (neoment-auth-login-password "me" "pw" (neoment-auth-result-handler ctx)
                                     (neoment-auth-current-function ctx))
        ;; A second login starts.
        (neoment-auth-cancel-pending)
        (cl-incf neoment--login-generation)
        (should cancelled)
        (funcall (plist-get pending :callback) neoment-auth-test-login-ok)
        (should (null (neoment-client-access-token neoment--client)))
        (should-not started)
        (should-not (seq-find (lambda (m) (string-search "Login successful" m))
                              neoment-test--messages))))))

;;;; 2.5 Password login

(ert-deftest neoment-auth-password-login-flow ()
  (neoment-auth-test-env
    (let* ((now (truncate (float-time)))
           (requests
            (neoment-auth-test-run-login
             `(((post . "/v3/login\\'") . ,neoment-auth-test-login-ok)
               ("/login\\'" . ,(neoment-auth-test-flows "m.login.password"))))))
      ;; The POST went to /login with the right body.
      (let* ((post (seq-find (lambda (r) (eq (plist-get r :method) 'post))
                             requests))
             (json (plist-get post :json)))
        (should (equal (alist-get 'type json) "m.login.password"))
        (should (equal (alist-get 'identifier json)
                       '((type . "m.id.user") (user . "@me:hs.example"))))
        (should (equal (alist-get 'password json) "secret"))
        (should (eq (alist-get 'refresh_token json) t))
        (should (equal (alist-get 'device_id json) "emacs-matrix-client")))
      (should (equal (neoment-client-access-token neoment--client) "AT"))
      (should (equal (neoment-client-refresh-token neoment--client) "RT"))
      (should (<= (abs (- (neoment-client-expires-at neoment--client) (+ now 300))) 1))
      (should (neoment-test-message-p "Login successful as @me:hs.example"))
      (should started)
      (should opened)
      (should (file-exists-p (neoment-storage-session-file))))))

(ert-deftest neoment-auth-password-login-well-known-switch ()
  (neoment-auth-test-env
    (neoment-client-reset "https://hs")
    (let ((ctx (list :generation neoment--login-generation)))
      (neoment-test-with-http
          (lambda (_) '(:ok ((access_token . "AT") (user_id . "@me:s")
                             (well_known . ((m.homeserver . ((base_url . "https://new.hs/"))))))))
        (neoment-auth-login-password "me" "pw" #'ignore (neoment-auth-current-function ctx)))
      (should (equal (neoment-client-homeserver neoment--client) "https://new.hs")))))

(ert-deftest neoment-auth-password-login-error ()
  (neoment-auth-test-env
    (neoment-auth-test-run-login
     `(((post . "/v3/login\\'") . (:error (:status 403 :errcode "M_FORBIDDEN"
                                                   :error "Invalid password")))
       ("/login\\'" . ,(neoment-auth-test-flows "m.login.password"))))
    (should (neoment-test-message-p "Error logging in: Invalid password"))
    (should-not started)))

(ert-deftest neoment-auth-password-empty-cancels ()
  (neoment-auth-test-env
    (neoment-auth-test-run-login
     `(("/login\\'" . ,(neoment-auth-test-flows "m.login.password")))
     :password "")
    (should (neoment-test-message-p "Login cancelled"))))

;;;; 2.6 Session save and restore

(defun neoment-auth-test-write-session (age-days refresh-token)
  "Write a session saved AGE-DAYS ago, with REFRESH-TOKEN."
  (neoment-storage-write-json
   (neoment-storage-session-file)
   `((user_id . "@me:s") (homeserver . "https://hs") (device_id . "DEV")
     (access_token . "AT") (refresh_token . ,(or refresh-token :null))
     (last_save . ,(- (truncate (float-time)) (* age-days 86400))))
   t))

(ert-deftest neoment-auth-session-restore-rules ()
  (neoment-auth-test-env
    (neoment-auth-test-write-session 1 nil)
    (should (neoment-storage-restore-session))
    (should (neoment-test-message-p "Matrix session restored for @me:s"))
    (should (equal (neoment-client-device-id neoment--client) "DEV"))
    (should (neoment-logged-in-p)))
  (neoment-auth-test-env
    (neoment-auth-test-write-session 8 nil)
    (should-not (neoment-storage-restore-session))
    (should (neoment-test-message-p "Session data is expired, please log in again")))
  (neoment-auth-test-env
    (neoment-auth-test-write-session 30 "RT")
    (should (neoment-storage-restore-session))
    (should (equal (neoment-client-refresh-token neoment--client) "RT"))))

(ert-deftest neoment-auth-restore-starts-without-prompt ()
  (neoment-auth-test-env
    (neoment-auth-test-write-session 1 nil)
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (error "Prompted"))))
      (neoment-login))
    (should started)
    (should opened)))

(ert-deftest neoment-auth-save-session-respects-option ()
  (neoment-auth-test-env
    (neoment-test-new-client)
    (let ((neoment-save-session nil))
      (neoment-storage-save-session)
      (should-not (file-exists-p (neoment-storage-session-file)))
      (should-not (file-exists-p (neoment-storage-cache-file))))
    (neoment-storage-save-session)
    (should (= (file-modes (neoment-storage-session-file)) #o600))
    (should (file-exists-p (neoment-storage-cache-file)))))

;;;; 2.7 Logout and clear cache

(ert-deftest neoment-auth-logout-cases ()
  ;; Cancel.
  (neoment-auth-test-env
    (neoment-test-new-client)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (neoment-test-with-http (lambda (_) (error "No request expected"))
        (neoment-logout)))
    (should (neoment-test-message-p "Operation canceled"))
    (should (neoment-logged-in-p)))
  ;; Confirm.
  (neoment-auth-test-env
    (neoment-test-new-client)
    (neoment-storage-save-session)
    (neoment-storage-save-ui-state '(("People" . t)) nil)
    (neoment-storage-set-oauth-client-id "https://auth/" "cid")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (neoment-test-with-http (lambda (_) '(:ok nil))
        (neoment-logout)
        (should (equal (car (neoment-test-request-urls))
                       "https://hs.example/_matrix/client/v3/logout"))))
    (should (neoment-test-message-p "Logout successful"))
    (should-not (neoment-logged-in-p))
    (should-not (file-exists-p (neoment-storage-session-file)))
    (should-not (file-exists-p (neoment-storage-cache-file)))
    (should-not (file-exists-p (neoment-storage-ui-state-file)))
    (should (file-exists-p (neoment-storage-oauth-clients-file))))
  ;; Server error.
  (neoment-auth-test-env
    (neoment-test-new-client)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (neoment-test-with-http (lambda (_) '(:error (:status 500 :error "Oops")))
        (neoment-logout)))
    (should (neoment-test-message-p "Logout failed: Oops"))
    (should (neoment-logged-in-p))))

(ert-deftest neoment-auth-clear-cache-messages ()
  (neoment-auth-test-env
    (neoment-clear-cache)
    (should (neoment-test-message-p "No cache file found to remove"))
    (neoment-storage-write-json (neoment-storage-cache-file)
                                `((data . ,(make-string 3000 ?x))))
    (neoment-clear-cache)
    (should (neoment-test-message-p "Neoment cache removed (2KB)"))
    (should-not (file-exists-p (neoment-storage-cache-file)))))

(provide 'neoment-auth-test)
;;; neoment-auth-test.el ends here
