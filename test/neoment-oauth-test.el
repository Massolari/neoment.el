;;; neoment-oauth-test.el --- Tests for OAuth, SSO and tokens  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 11 of the port: OAuth client registration, device code,
;; polling and completion; the SSO listener and manual mode; token
;; refresh, M_UNKNOWN_TOKEN handling and OAuth logout.

;;; Code:

(require 'test-helper)
(require 'neoment-oauth)
(require 'neoment-sso)
(require 'neoment-token)

(defconst neoment-oauth-test-metadata
  '(:issuer "https://auth.example/" :device-authorization-endpoint "https://auth.example/device"
            :token-endpoint "https://auth.example/token"
            :registration-endpoint "https://auth.example/register"
            :revocation-endpoint "https://auth.example/revoke")
  "OAuth metadata used by the tests.")

(defmacro neoment-oauth-test (&rest body)
  "Run BODY in a temp dir with captured messages, a fresh client and stubs."
  (declare (indent 0))
  `(neoment-test-with-temp-dir
     (neoment-test-with-messages
       (let ((neoment--client nil)
             (neoment-token--waiters nil)
             (neoment-auth--cancel-functions nil)
             (neoment-http-ensure-token-function #'neoment-token-ensure-fresh)
             (neoment-http-unknown-token-function #'neoment-token-handle-unknown-token))
         (neoment-test-new-client)
         (cl-letf (((symbol-function 'neoment-sync-start) #'ignore)
                   ((symbol-function 'neoment-sync-stop) #'ignore)
                   ((symbol-function 'neoment-rooms-open) #'ignore)
                   ((symbol-function 'neoment--defer) (lambda (fn &rest args) (apply fn args))))
           ,@body)))))

(defun neoment-oauth-test-oauth-error (code &optional status)
  "Return an HTTP error result for the OAuth error CODE with STATUS."
  `(:error (:status ,(or status 400) :error ,code :data ((error . ,code)))))

;;;; 11.1 Registration

(ert-deftest neoment-oauth-register ()
  (neoment-oauth-test
    (let (result)
      (neoment-test-with-http (lambda (_) '(:ok ((client_id . "cid"))))
        (neoment-oauth-register neoment-oauth-test-metadata (lambda (r) (setq result r)))
        (should (equal result '(:ok "cid")))
        (let ((json (plist-get (car neoment-test--requests) :json)))
          (should (equal (plist-get (car neoment-test--requests) :url) "https://auth.example/register"))
          (should (equal (alist-get 'grant_types json)
                         ["urn:ietf:params:oauth:grant-type:device_code" "refresh_token"]))
          (should (equal (alist-get 'token_endpoint_auth_method json) "none"))
          (should (equal (alist-get 'application_type json) "native")))
        ;; Reused from oauth_clients.json, even with session saving off.
        (let ((neoment-save-session nil))
          (neoment-oauth-register neoment-oauth-test-metadata (lambda (r) (setq result r))))
        (should (= (length neoment-test--requests) 1))
        (should (equal (neoment-storage-oauth-client-id "https://auth.example/") "cid"))))))

(ert-deftest neoment-oauth-invalid-client-evicted ()
  (neoment-oauth-test
    (neoment-storage-set-oauth-client-id "https://auth.example/" "stale")
    (let (result)
      (neoment-test-with-http (lambda (_) (neoment-oauth-test-oauth-error "invalid_client"))
        (neoment-oauth-request-device-code neoment-oauth-test-metadata "stale" "DEV"
                                           (lambda (r) (setq result r))))
      (should (plist-get result :error))
      (should-not (neoment-storage-oauth-client-id "https://auth.example/")))))

;;;; 11.2 Device code and instructions

(ert-deftest neoment-oauth-device-code-request ()
  (neoment-oauth-test
    (let (result)
      (neoment-test-with-http
          (lambda (_) '(:ok ((device_code . "dc") (user_code . "ABCD")
                             (verification_uri . "https://auth.example/link")
                             (verification_uri_complete . "javascript:alert(1)"))))
        (neoment-oauth-request-device-code neoment-oauth-test-metadata "cid" "DEV"
                                           (lambda (r) (setq result r)))
        (should (equal (plist-get (car neoment-test--requests) :form)
                       '((client_id . "cid")
                         (scope . "urn:matrix:client:api:* urn:matrix:client:device:DEV")))))
      (should (equal (plist-get result :ok)
                     '(:device-code "dc" :user-code "ABCD" :verification-url "https://auth.example/link"
                                    :code-in-url nil :expires-in 600 :interval 5)))
      (neoment-test-with-http (lambda (_) '(:ok ((device_code . "dc") (user_code . "A")
                                                 (verification_uri . "ftp://x"))))
        (neoment-oauth-request-device-code neoment-oauth-test-metadata "cid" "DEV"
                                           (lambda (r) (setq result r))))
      (should (plist-get result :error)))))

(ert-deftest neoment-oauth-instructions ()
  (neoment-oauth-test
    (let ((process-environment (seq-remove (lambda (e) (string-match-p "\\`SSH_" e))
                                           process-environment))
          (prompts nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt &rest _) (push prompt prompts) "Not now")))
        (neoment-oauth--show-instructions
         '(:verification-url "https://a/c?x" :user-code "CODE" :code-in-url t)
         (list :generation neoment--login-generation))
        (should (neoment-test-message-p
                 "Open this URL and approve the login (code CODE):\nhttps://a/c?x\nThe login completes on its own once you approve it."))
        (should (equal prompts '("Verification page: ")))
        (neoment-oauth--show-instructions
         '(:verification-url "https://a/l" :user-code "CODE")
         (list :generation neoment--login-generation))
        (should (neoment-test-message-p
                 "Open https://a/l and enter the code CODE.\nThe login completes on its own once you approve it."))))
    ;; Remote session: no prompt.
    (let ((process-environment (cons "SSH_CONNECTION=1 2 3 4" process-environment)))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "Prompted"))))
        (neoment-oauth--show-instructions
         '(:verification-url "https://a/l" :user-code "C")
         (list :generation neoment--login-generation))))))

(ert-deftest neoment-oauth-polling-starts-before-prompt ()
  (neoment-oauth-test
    (let* ((order nil)
          (process-environment (seq-remove (lambda (e) (string-match-p "\\`SSH_" e))
                                           process-environment))
          (neoment-oauth-defer-function (lambda (_s fn) (push 'poll order) (ignore fn))))
      (neoment-storage-set-oauth-client-id "https://auth.example/" "cid")
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (push 'prompt order) "Not now")))
        (neoment-test-with-http
            (lambda (_) '(:ok ((device_code . "dc") (user_code . "U")
                               (verification_uri . "https://auth.example/link"))))
          (neoment-oauth-device-login (list :oauth-metadata neoment-oauth-test-metadata
                                            :generation neoment--login-generation))))
      (should (equal (nreverse order) '(poll prompt)))
      (should neoment-auth--cancel-functions))))

;;;; 11.3 Polling and completion

(defmacro neoment-oauth-test-poll (responses &rest body)
  "Poll with fake time and timers, answering with RESPONSES in order.
In BODY, `delays' holds the scheduled delays and `result' the outcome."
  (declare (indent 1))
  `(let* ((now 0)
          (delays nil)
          (result nil)
          (queue ,responses)
          (neoment-oauth-now-function (lambda () now))
          (neoment-oauth-defer-function
           (lambda (seconds fn) (push seconds delays) (setq now (+ now seconds)) (funcall fn))))
     (neoment-test-with-http (lambda (_) (pop queue))
       (neoment-oauth-poll neoment-oauth-test-metadata "cid"
                           '(:device-code "dc" :interval 5 :expires-in 600)
                           (lambda (r) (setq result r)))
       ,@body)))

(ert-deftest neoment-oauth-polling ()
  (neoment-oauth-test
    (neoment-oauth-test-poll (list (neoment-oauth-test-oauth-error "authorization_pending")
                                   (neoment-oauth-test-oauth-error "slow_down")
                                   '(:error (:status 503 :error "unavailable"))
                                   '(:error (:status nil :error "network"))
                                   '(:ok ((access_token . "AT"))))
      (should (equal (nreverse delays) '(5 5 10 10 10)))
      (should (equal result '(:ok ((access_token . "AT")))))
      (should (equal (plist-get (car neoment-test--requests) :form)
                     '((grant_type . "urn:ietf:params:oauth:grant-type:device_code")
                       (device_code . "dc") (client_id . "cid")))))
    (neoment-oauth-test-poll (list (neoment-oauth-test-oauth-error "expired_token"))
      (should (equal (plist-get (plist-get result :error) :error) "The login code expired")))
    (neoment-oauth-test-poll (list (neoment-oauth-test-oauth-error "access_denied"))
      (should (equal (plist-get (plist-get result :error) :error) "The login was denied")))
    ;; Deadline.
    (let ((queue nil) (now 0) (result nil))
      (let ((neoment-oauth-now-function (lambda () now))
            (neoment-oauth-defer-function (lambda (s fn) (setq now (+ now s)) (funcall fn))))
        (neoment-test-with-http (lambda (_) (or (pop queue) (neoment-oauth-test-oauth-error "authorization_pending")))
          (neoment-oauth-poll neoment-oauth-test-metadata "cid"
                              '(:device-code "dc" :interval 5 :expires-in 12)
                              (lambda (r) (setq result r)))))
      (should (equal (plist-get (plist-get result :error) :error) "The login code expired")))
    ;; Cancelled: a late response changes nothing.
    (let ((pending nil) (result 'untouched) cancel)
      (let ((neoment-oauth-defer-function (lambda (_s fn) (funcall fn))))
        (neoment-test-with-http (lambda (args) (setq pending args) 'pending)
          (setq cancel (neoment-oauth-poll neoment-oauth-test-metadata "cid"
                                           '(:device-code "dc" :interval 5 :expires-in 600)
                                           (lambda (r) (setq result r))))
          (funcall cancel)
          (funcall (plist-get pending :callback) '(:ok ((access_token . "late"))))))
      (should (eq result 'untouched)))))

(ert-deftest neoment-oauth-completion ()
  (neoment-oauth-test
    (setf (neoment-client-access-token neoment--client) nil
          (neoment-client-user-id neoment--client) nil)
    (let (result)
      (neoment-test-with-http (lambda (_) '(:ok ((user_id . "@me:hs"))))
        (neoment-oauth-complete '((access_token . "AT") (refresh_token . "RT") (expires_in . 300))
                                neoment-oauth-test-metadata "cid" (lambda (r) (setq result r))
                                (lambda () t))
        (should (string-suffix-p "/account/whoami" (car (neoment-test-request-urls)))))
      (should (equal result '(:ok nil)))
      (should (equal (neoment-client-user-id neoment--client) "@me:hs"))
      (should (equal (neoment-client-refresh neoment--client)
                     '(:kind "oauth" :token-endpoint "https://auth.example/token" :client-id "cid"
                             :revocation-endpoint "https://auth.example/revoke")))
      (should (equal (neoment-client-refresh-token neoment--client) "RT")))
    ;; whoami fails: revoke, reset and report.
    (neoment-test-new-client)
    (let (result)
      (neoment-test-with-http
          (lambda (args) (if (string-search "whoami" (plist-get args :url))
                             '(:error (:status 500 :error "broken"))
                           '(:ok nil)))
        (neoment-oauth-complete '((access_token . "AT") (refresh_token . "RT"))
                                neoment-oauth-test-metadata "cid" (lambda (r) (setq result r))
                                (lambda () t))
        (should (equal (plist-get (cadr neoment-test--requests) :url) "https://auth.example/revoke")))
      (should (equal (plist-get (plist-get result :error) :error) "broken"))
      (should-not (neoment-client-access-token neoment--client)))))

;;;; 11.4 SSO

(ert-deftest neoment-sso-parse-token ()
  (should (equal (neoment-sso-parse-login-token "http://127.0.0.1/?loginToken=abc%2Bd&x=1")
                 '("abc+d")))
  (should (equal (neoment-sso-parse-login-token "  rawtoken ") '("rawtoken")))
  (should (equal (neoment-sso-parse-login-token "http://127.0.0.1/?foo=1")
                 '(nil . "The URL does not contain a login token")))
  (should (null (neoment-sso-parse-login-token "")))
  (should (equal (neoment-sso-redirect-url "https://hs" "http://127.0.0.1:1234/s")
                 "https://hs/_matrix/client/v3/login/sso/redirect?redirectUrl=http%3A%2F%2F127.0.0.1%3A1234%2Fs")))

(defun neoment-sso-test-request (port text)
  "Send TEXT to the loopback PORT and return the response."
  (let* ((response "")
         (proc (make-network-process :name "neoment-sso-test" :host "127.0.0.1" :service port
                                     :family 'ipv4 :coding 'binary :noquery t
                                     :filter (lambda (_p s) (setq response (concat response s))))))
    (process-send-string proc text)
    (let ((deadline (+ (float-time) 3)))
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (when (process-live-p proc) (delete-process proc))
    response))

(ert-deftest neoment-sso-listener ()
  (let* ((tokens nil)
         (timeouts 0)
         (listener (neoment-sso-listen (lambda (tok) (push tok tokens))
                                       (lambda () (cl-incf timeouts))))
         (url (plist-get listener :redirect-url)))
    (unwind-protect
        (progn
          (should (string-match "\\`http://127\\.0\\.0\\.1:\\([0-9]+\\)/\\([0-9a-f]+\\)\\'" url))
          (let ((port (string-to-number (match-string 1 url)))
                (secret (match-string 2 url)))
            (should (string-search "404"
                                   (neoment-sso-test-request port "GET /wrong?loginToken=x HTTP/1.1\r\n\r\n")))
            (should (string-search "This request did not contain a login token."
                                   (neoment-sso-test-request
                                    port (format "GET /%s HTTP/1.1\r\nHost: x\r\n\r\n" secret))))
            (should (string-search "431"
                                   (neoment-sso-test-request
                                    port (concat "GET /" secret " HTTP/1.1\r\nX: "
                                                 (make-string 9000 ?a)))))
            (should (null tokens))
            (let ((response (neoment-sso-test-request
                             port (format "GET /%s?loginToken=tok%%2B1 HTTP/1.1\r\n\r\n" secret))))
              (should (string-search "return to Emacs" response)))
            (should (equal tokens '("tok+1")))
            (should-not (process-live-p (plist-get listener :process)))
            (should (= timeouts 0))))
      (funcall (plist-get listener :close)))))

(ert-deftest neoment-sso-listener-timeout ()
  (let* ((neoment-sso-timeout 0.1)
         (timeouts 0)
         (listener (neoment-sso-listen #'ignore (lambda () (cl-incf timeouts)))))
    (let ((deadline (+ (float-time) 2)))
      (while (and (= timeouts 0) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (should (= timeouts 1))
    (should-not (process-live-p (plist-get listener :process)))))

(ert-deftest neoment-sso-manual-mode ()
  (neoment-oauth-test
    (let ((process-environment (cons "SSH_TTY=/dev/pts/1" process-environment)))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "http://127.0.0.1/?x=1")))
        (neoment-sso-login (list :homeserver "https://hs" :generation neoment--login-generation)))
      (should (neoment-test-message-p
               (concat "Open this URL in your browser and log in. The page you are sent to will fail to load; copy its URL from the address bar:\n"
                       "https://hs/_matrix/client/v3/login/sso/redirect?redirectUrl=http%3A%2F%2F127.0.0.1%2F")))
      (should (neoment-test-message-p "The URL does not contain a login token"))
      (neoment-test-with-http (lambda (_) '(:ok ((access_token . "AT") (user_id . "@me:hs"))))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "TOKEN")))
          (neoment-sso-login (list :homeserver "https://hs" :generation neoment--login-generation)))
        (should (equal (alist-get 'type (plist-get (car neoment-test--requests) :json)) "m.login.token"))
        (should (equal (alist-get 'token (plist-get (car neoment-test--requests) :json)) "TOKEN")))
      (should (neoment-test-message-p "Login successful as @me:hs")))))

;;;; 11.5 Token refresh

(ert-deftest neoment-token-single-flight ()
  (neoment-oauth-test
    (setf (neoment-client-refresh-token neoment--client) "RT"
          (neoment-client-expires-at neoment--client) (+ (truncate (float-time)) 30))
    (let ((pending nil) (results nil))
      (neoment-test-with-http
          (lambda (args)
            (if (string-suffix-p "/refresh" (plist-get args :url))
                (progn (setq pending args) 'pending)
              '(:ok nil)))
        (dotimes (_ 3)
          (neoment-api-request 'get "/_matrix/client/v3/x" :callback (lambda (r) (push r results))))
        (should (= (length neoment-test--requests) 1))
        (should (equal (plist-get pending :json) '((refresh_token . "RT"))))
        (funcall (plist-get pending :callback)
                 '(:ok ((access_token . "NEW") (expires_in_ms . 300000))))
        (should (= (length neoment-test--requests) 4))
        (should (= (length results) 3))
        (dolist (r (cdr neoment-test--requests))
          (should (equal (cdr (assoc "Authorization" (plist-get r :headers))) "Bearer NEW")))
        ;; The old refresh token is kept, and the session saved.
        (should (equal (neoment-client-refresh-token neoment--client) "RT"))
        (should (file-exists-p (neoment-storage-session-file)))))))

(ert-deftest neoment-token-oauth-refresh ()
  (neoment-oauth-test
    (setf (neoment-client-refresh-token neoment--client) "RT"
          (neoment-client-refresh neoment--client)
          '(:kind "oauth" :token-endpoint "https://auth.example/token" :client-id "cid"))
    (let (result)
      (neoment-test-with-http (lambda (_) '(:ok ((access_token . "A2") (refresh_token . "R2")
                                                 (expires_in . 300))))
        (neoment-token-refresh (lambda (r) (setq result r)))
        (should (equal (plist-get (car neoment-test--requests) :form)
                       '((grant_type . "refresh_token") (refresh_token . "RT") (client_id . "cid"))))
        (should (= (plist-get (car neoment-test--requests) :timeout) 30)))
      (should (equal result '(:ok nil)))
      (should (equal (neoment-client-refresh-token neoment--client) "R2"))
      (should (<= (abs (- (neoment-client-expires-at neoment--client) (+ (float-time) 300))) 2)))))

;;;; 11.6 M_UNKNOWN_TOKEN and failures

(defconst neoment-token-test-unknown
  '(:error (:status 401 :errcode "M_UNKNOWN_TOKEN" :error "Unknown token"))
  "A hard M_UNKNOWN_TOKEN error.")

(ert-deftest neoment-token-soft-logout-retries-once ()
  (neoment-oauth-test
    (setf (neoment-client-refresh-token neoment--client) "RT")
    (let ((calls 0) result)
      (neoment-test-with-http
          (lambda (args)
            (cond
             ((string-suffix-p "/refresh" (plist-get args :url))
              '(:ok ((access_token . "NEW"))))
             (t (cl-incf calls)
                '(:error (:status 401 :errcode "M_UNKNOWN_TOKEN" :error "x" :soft-logout t)))))
        (neoment-api-request 'get "/_matrix/client/v3/x" :callback (lambda (r) (setq result r))))
      (should (= calls 2))
      (should (plist-get result :error))
      (should (neoment-logged-in-p)))))

(ert-deftest neoment-token-changed-retries ()
  (neoment-oauth-test
    (let ((pending nil) result)
      (neoment-test-with-http
          (lambda (args)
            (if (equal (cdr (assoc "Authorization" (plist-get args :headers))) "Bearer TOKEN")
                (progn (setq pending args) 'pending)
              '(:ok ((done . t)))))
        (neoment-api-request 'get "/_matrix/client/v3/x" :callback (lambda (r) (setq result r)))
        ;; Another request refreshed the token meanwhile.
        (setf (neoment-client-access-token neoment--client) "OTHER")
        (funcall (plist-get pending :callback) neoment-token-test-unknown))
      (should (equal result '(:ok ((done . t))))))))

(ert-deftest neoment-token-expiry-once ()
  (neoment-oauth-test
    (neoment-storage-save-session)
    (let ((pending nil))
      (neoment-test-with-http (lambda (args) (push args pending) 'pending)
        (dotimes (_ 5) (neoment-api-request 'get "/_matrix/client/v3/x"))
        (dolist (req pending)
          (funcall (plist-get req :callback) neoment-token-test-unknown))))
    (should (= (seq-count (lambda (m) (equal m "[Neoment] Session expired, please log in again"))
                          neoment-test--messages)
               1))
    (should-not (neoment-logged-in-p))
    (should-not (file-exists-p (neoment-storage-session-file)))))

(ert-deftest neoment-token-adopts-rotated-token ()
  (neoment-oauth-test
    (setf (neoment-client-refresh-token neoment--client) "OLD"
          (neoment-client-user-id neoment--client) "@me:s")
    (neoment-storage-write-json
     (neoment-storage-session-file)
     '((user_id . "@me:s") (homeserver . "https://hs.example") (access_token . "AT2")
       (refresh_token . "ROTATED") (expires_at . 9999999999))
     t)
    (let (result)
      (neoment-test-with-http (lambda (_) '(:error (:status 400 :errcode "M_UNKNOWN_TOKEN" :error "used")))
        (neoment-token-refresh (lambda (r) (setq result r))))
      (should (equal result '(:ok nil)))
      (should (equal (neoment-client-refresh-token neoment--client) "ROTATED"))
      (should (equal (neoment-client-access-token neoment--client) "AT2"))
      (should (neoment-logged-in-p)))))

(ert-deftest neoment-token-transient-failure-keeps-session ()
  (neoment-oauth-test
    (setf (neoment-client-refresh-token neoment--client) "RT"
          (neoment-client-expires-at neoment--client) (+ (truncate (float-time)) 10))
    (let (result)
      (neoment-test-with-http (lambda (_) '(:error (:status 503 :error "busy")))
        (neoment-api-request 'get "/_matrix/client/v3/x" :callback (lambda (r) (setq result r)))
        (should (= (length neoment-test--requests) 1))
        (should (equal (plist-get (plist-get result :error) :error) "busy"))
        (should (neoment-logged-in-p))
        ;; The next request tries to refresh again.
        (neoment-api-request 'get "/_matrix/client/v3/x")
        (should (= (length neoment-test--requests) 2))
        (should (string-suffix-p "/refresh" (plist-get (cadr neoment-test--requests) :url)))))))

(ert-deftest neoment-token-permanent-failure-expires ()
  (neoment-oauth-test
    (setf (neoment-client-refresh-token neoment--client) "RT")
    (let (result)
      (neoment-test-with-http (lambda (_) '(:error (:status 401 :errcode "M_UNKNOWN_TOKEN" :error "gone")))
        (neoment-token-refresh (lambda (r) (setq result r))))
      (should (plist-get (plist-get result :error) :session-expired))
      (should-not (neoment-logged-in-p))
      (should (neoment-test-message-p "Session expired, please log in again")))))

;;;; 11.7 OAuth logout

(ert-deftest neoment-oauth-logout-revokes ()
  (neoment-oauth-test
    (setf (neoment-client-refresh-token neoment--client) "RT"
          (neoment-client-refresh neoment--client)
          '(:kind "oauth" :token-endpoint "https://auth.example/token" :client-id "cid"
                  :revocation-endpoint "https://auth.example/revoke"))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (neoment-test-with-http (lambda (_) '(:ok ""))
        (neoment-logout)
        (let ((req (car neoment-test--requests)))
          (should (equal (plist-get req :url) "https://auth.example/revoke"))
          (should (equal (plist-get req :form)
                         '((token . "RT") (token_type_hint . "refresh_token") (client_id . "cid"))))
          (should (= (length neoment-test--requests) 1)))))
    (should (neoment-test-message-p "Logout successful"))))

(provide 'neoment-oauth-test)
;;; neoment-oauth-test.el ends here
