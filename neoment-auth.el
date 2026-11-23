;;; neoment-auth.el --- Login flows for Neoment  -*- lexical-binding: t; -*-

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

;; Homeserver discovery, login method detection and selection, the
;; password login, the login result, session expiry and logout.  The
;; OAuth device code and SSO flows live in `neoment-oauth' and
;; `neoment-sso'.
;;
;; Every login attempt bumps `neoment--login-generation'.  Callbacks of
;; older attempts check the generation and do nothing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'neoment-config)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-notify)
(require 'neoment-storage)

(declare-function neoment-sync-start "neoment-sync")
(declare-function neoment-sync-stop "neoment-sync")
(declare-function neoment-rooms-open "neoment-rooms")
(declare-function neoment-oauth-device-login "neoment-oauth")
(declare-function neoment-oauth-revoke "neoment-oauth")
(declare-function neoment-sso-login "neoment-sso")

(defconst neoment-auth-device-code-grant
  "urn:ietf:params:oauth:grant-type:device_code"
  "The OAuth 2.0 device code grant type.")

(defconst neoment-auth-method-order '(oauth_device password sso)
  "Login methods, in order of preference.")

(defconst neoment-auth-method-labels
  '((password . "Password")
    (sso . "Single Sign-On (browser)")
    (oauth_device . "OAuth (device code)"))
  "Labels of the login methods.")

(defvar neoment--login-generation 0
  "Counter bumped by each login attempt.")

(defvar neoment-auth--cancel-functions nil
  "Functions that cancel the pending SSO listener or OAuth polling.")

;;;; Helpers

(defun neoment-auth-http-url-p (value)
  "Return non-nil when VALUE is an http(s) URL."
  (and (stringp value) (string-match-p "\\`https?://[^/]" value) t))

(defun neoment-auth-remote-session-p ()
  "Return non-nil when Emacs runs in an SSH session."
  (and (or (getenv "SSH_CONNECTION") (getenv "SSH_TTY")) t))

(defun neoment-auth-parse-server-name (input)
  "Parse the Matrix ID or server INPUT.
Return (SERVER . USER-ID), where USER-ID is nil unless INPUT is a full
Matrix ID, or nil when INPUT is empty or invalid."
  (let ((trimmed (string-trim (or input ""))))
    (cond
     ((string-empty-p trimmed) nil)
     ((string-prefix-p "@" trimmed)
      (when (string-match "\\`@[^:]+:\\(.+\\)\\'" trimmed)
        (cons (match-string 1 trimmed) trimmed)))
     ((string-match-p "[[:space:]]" trimmed) nil)
     (t (cons (replace-regexp-in-string "/+\\'" "" trimmed) nil)))))

(defun neoment-auth--homeserver-from-well-known (well-known)
  "Return the homeserver URL of WELL-KNOWN, or nil."
  (let ((base-url (neoment-json-get well-known 'm.homeserver 'base_url)))
    (when (neoment-auth-http-url-p base-url)
      (replace-regexp-in-string "/+\\'" "" base-url))))

(defun neoment-auth--current-p (generation)
  "Return non-nil when GENERATION is the current login attempt."
  (= generation neoment--login-generation))

(defun neoment-auth-cancel-pending ()
  "Cancel the pending SSO listener and OAuth polling."
  (let ((functions neoment-auth--cancel-functions))
    (setq neoment-auth--cancel-functions nil)
    (mapc #'funcall functions)))

(defun neoment-auth-add-cancel-function (function)
  "Call FUNCTION when the current login attempt is superseded."
  (push function neoment-auth--cancel-functions))

;;;; Discovery

(defun neoment-auth-discover (server-name callback)
  "Find the homeserver of SERVER-NAME and call CALLBACK with its URL.
Discovery never fails: it falls back to https://SERVER-NAME."
  (if (neoment-auth-http-url-p server-name)
      (funcall callback server-name)
    (let ((fallback (concat "https://" server-name))
          (hostname (replace-regexp-in-string ":[0-9]+\\'" "" server-name)))
      (neoment-http-request
       :url (concat "https://" hostname "/.well-known/matrix/client")
       :connect-timeout 5 :timeout 10
       :callback
       (lambda (result)
         (funcall callback
                  (or (and (plist-member result :ok)
                           (neoment-auth--homeserver-from-well-known
                            (plist-get result :ok)))
                      fallback)))))))

(defun neoment-auth-get-oauth-metadata (homeserver callback)
  "Fetch the OAuth metadata of HOMESERVER and call CALLBACK with it.
CALLBACK receives a plist, or nil when device code login is not
available."
  (neoment-http-request
   :url (concat homeserver "/_matrix/client/v1/auth_metadata")
   :connect-timeout 5 :timeout 10
   :callback
   (lambda (result)
     (let ((data (plist-get result :ok)))
       (funcall
        callback
        (when (and data
                   (member neoment-auth-device-code-grant
                           (alist-get 'grant_types_supported data))
                   (cl-every (lambda (field)
                               (neoment-auth-http-url-p (alist-get field data)))
                             '(issuer device_authorization_endpoint
                                      token_endpoint registration_endpoint)))
          (let ((revocation (alist-get 'revocation_endpoint data)))
            (list :issuer (alist-get 'issuer data)
                  :device-authorization-endpoint
                  (alist-get 'device_authorization_endpoint data)
                  :token-endpoint (alist-get 'token_endpoint data)
                  :registration-endpoint (alist-get 'registration_endpoint data)
                  :revocation-endpoint
                  (and (neoment-auth-http-url-p revocation) revocation)))))))))

(defun neoment-auth-get-login-flows (homeserver callback)
  "Find the login methods HOMESERVER offers.
CALLBACK is called with (:ok METHODS) or (:error MESSAGE) and the OAuth
metadata.  Both requests run in parallel."
  (let (flows-result metadata metadata-done)
    (cl-labels
        ((finish ()
           (when (and flows-result metadata-done)
             (let ((available nil) (advertised nil) (token nil))
               (dolist (flow (neoment-json-get (plist-get flows-result :ok) 'flows))
                 (let ((type (alist-get 'type flow)))
                   (when (stringp type)
                     (push type advertised)
                     (pcase type
                       ("m.login.token" (setq token t))
                       ("m.login.password" (push 'password available))
                       ("m.login.sso" (push 'sso available))))))
               (unless token (setq available (delq 'sso available)))
               (when metadata (push 'oauth_device available))
               (let ((methods (seq-filter (lambda (m) (memq m available))
                                          neoment-auth-method-order)))
                 (funcall
                  callback
                  (cond
                   (methods (list :ok methods))
                   ((plist-get flows-result :error)
                    (list :error
                          (format "Could not fetch login methods from %s: %s"
                                  homeserver
                                  (neoment-http-error-message
                                   (plist-get flows-result :error)))))
                   (t (list :error
                            (concat "No supported login method. The server offers: "
                                    (string-join (nreverse advertised) ", ")))))
                  metadata))))))
      (neoment-http-request
       :url (concat homeserver "/_matrix/client/v3/login")
       :connect-timeout 5 :timeout 10
       :callback (lambda (result) (setq flows-result result) (finish)))
      (neoment-auth-get-oauth-metadata
       homeserver
       (lambda (result) (setq metadata result metadata-done t) (finish))))))

;;;; Login requests

(defun neoment-auth-set-tokens (client access-token refresh-token expires-in-ms)
  "Store ACCESS-TOKEN, REFRESH-TOKEN and the expiry in CLIENT.
EXPIRES-IN-MS is the token lifetime in milliseconds, or nil."
  (setf (neoment-client-access-token client) access-token
        (neoment-client-refresh-token client)
        (and (stringp refresh-token) refresh-token)
        (neoment-client-expires-at client)
        (and (numberp expires-in-ms)
             (+ (truncate (float-time)) (floor expires-in-ms 1000)))))

(defun neoment-auth--login-request (body callback current-p)
  "POST BODY to the login endpoint and call CALLBACK with the result.
CURRENT-P returns nil when the login attempt was superseded."
  (let ((client neoment--client))
    (neoment-http-request
     :method 'post
     :url (concat (neoment-client-homeserver client) "/_matrix/client/v3/login")
     :json (append body `((device_id . ,(neoment-client-device-id client))))
     :callback
     (lambda (result)
       (if (or (not (eq client neoment--client)) (not (funcall current-p)))
           (funcall callback
                    (list :error
                          (list :error "The login was superseded by another login attempt")))
         (let ((data (plist-get result :ok)))
           (when (plist-member result :ok)
             (neoment-auth-set-tokens client (alist-get 'access_token data)
                                      (alist-get 'refresh_token data)
                                      (alist-get 'expires_in_ms data))
             (setf (neoment-client-user-id client) (alist-get 'user_id data))
             (let ((hs (neoment-auth--homeserver-from-well-known
                        (alist-get 'well_known data))))
               (when hs (setf (neoment-client-homeserver client) hs))))
           (funcall callback result)))))))

(defun neoment-auth-login-password (user password callback current-p)
  "Log in as USER with PASSWORD and call CALLBACK with the result.
CURRENT-P returns nil when the login attempt was superseded."
  (neoment-auth--login-request
   `((type . "m.login.password")
     (identifier . ((type . "m.id.user") (user . ,user)))
     (password . ,password)
     (refresh_token . t))
   callback current-p))

(defun neoment-auth-login-token (token callback current-p)
  "Log in with the SSO login TOKEN and call CALLBACK with the result.
CURRENT-P returns nil when the login attempt was superseded."
  (neoment-auth--login-request
   `((type . "m.login.token") (token . ,token))
   callback current-p))

;;;; Login result

(defun neoment-auth-handle-login-result (result)
  "Finish a login with RESULT, (:ok ...) or (:error ERR)."
  (if (plist-get result :error)
      (neoment-notify--error
       (concat "Error logging in: "
               (neoment-http-error-message (plist-get result :error))))
    (neoment-notify--message
     (format "Login successful as %s" (neoment-user-id)))
    (neoment-storage-save-session)
    (neoment-sync-start)
    (neoment-rooms-open)))

(defun neoment-auth-result-handler (ctx)
  "Return a login result handler for the attempt CTX."
  (let ((generation (plist-get ctx :generation)))
    (lambda (result)
      (when (neoment-auth--current-p generation)
        (neoment-auth-handle-login-result result)))))

(defun neoment-auth-current-function (ctx)
  "Return a function telling whether the attempt CTX is still current."
  (let ((generation (plist-get ctx :generation)))
    (lambda () (neoment-auth--current-p generation))))

;;;; Password login

(defun neoment-auth--password-login (ctx)
  "Run the password login for the attempt CTX."
  (let ((user (or (plist-get ctx :user-id)
                  (string-trim (read-string "Username: ")))))
    (if (string-empty-p user)
        (neoment-notify--message "Login cancelled")
      (let ((password (read-passwd "Password: ")))
        (if (string-empty-p password)
            (neoment-notify--message "Login cancelled")
          (neoment-auth-login-password user password
                                       (neoment-auth-result-handler ctx)
                                       (neoment-auth-current-function ctx)))))))

(defun neoment-auth--run-method (method ctx)
  "Run the login METHOD for the attempt CTX."
  (pcase method
    ('password (neoment-auth--password-login ctx))
    ('sso (neoment-sso-login ctx))
    ('oauth_device (neoment-oauth-device-login ctx))))

(defun neoment-auth--choose-method (methods ctx)
  "Pick one of METHODS and run it for the attempt CTX."
  (let ((forced neoment-login-method))
    (cond
     (forced
      (if (memq forced methods)
          (neoment-auth--run-method forced ctx)
        (neoment-notify--error
         (format "Login method '%s' is not offered by the server. It offers: %s"
                 forced (mapconcat #'symbol-name methods ", ")))))
     ((memq 'oauth_device methods)
      (neoment-auth--run-method 'oauth_device ctx))
     ((= (length methods) 1)
      (neoment-auth--run-method (car methods) ctx))
     (t
      (let* ((labels (mapcar (lambda (m)
                               (cons (alist-get m neoment-auth-method-labels) m))
                             methods))
             (choice (condition-case nil
                         (completing-read "Login method: " labels nil t)
                       (quit nil)))
             (method (cdr (assoc choice labels))))
        (when (neoment-auth--current-p (plist-get ctx :generation))
          (if method
              (neoment-auth--run-method method ctx)
            (neoment-notify--message "Login cancelled"))))))))

;;;; Entry point

(defun neoment-login ()
  "Log in to a Matrix homeserver.
A saved session is restored when possible."
  (neoment-auth-cancel-pending)
  (cl-incf neoment--login-generation)
  (let ((generation neoment--login-generation))
    (if (neoment-storage-restore-session)
        (progn (neoment-sync-start)
               (neoment-rooms-open))
      (let* ((input (read-string "Matrix ID or server: "))
             (parsed (neoment-auth-parse-server-name input)))
        (cond
         ((and (null parsed) (string-empty-p (string-trim input)))
          (neoment-notify--message "Login cancelled"))
         ((null parsed)
          (neoment-notify--error (concat "Invalid Matrix ID or server: " input)))
         (t
          (let ((server (car parsed)))
            (neoment-notify--message
             (format "Looking up the homeserver for %s..." server))
            (neoment-auth-discover
             server
             (lambda (homeserver)
               (when (neoment-auth--current-p generation)
                 (neoment-client-reset homeserver)
                 (neoment-auth-get-login-flows
                  homeserver
                  (lambda (result metadata)
                    (when (neoment-auth--current-p generation)
                      (if (plist-get result :error)
                          (neoment-notify--error (plist-get result :error))
                        (neoment--defer
                         (lambda ()
                           (when (neoment-auth--current-p generation)
                             (neoment-auth--choose-method
                              (plist-get result :ok)
                              (list :homeserver homeserver
                                    :user-id (cdr parsed)
                                    :generation generation
                                    :oauth-metadata metadata)))))))))))))))))))

;;;; Session expiry and logout

(defun neoment-auth-session-expired ()
  "End the session after the server rejected it, once."
  (when (neoment-logged-in-p)
    (neoment-sync-stop t)
    (neoment-storage-clear-session)
    (neoment-client-reset (neoment-client-homeserver neoment--client))
    (neoment-notify--error "Session expired, please log in again")))

(defun neoment-auth--logout-request (callback)
  "Invalidate the session on the server and call CALLBACK with the result."
  (let* ((client neoment--client)
         (refresh (neoment-client-refresh client)))
    (if (and (equal (plist-get refresh :kind) "oauth")
             (plist-get refresh :revocation-endpoint)
             (neoment-client-refresh-token client))
        (neoment-oauth-revoke (plist-get refresh :revocation-endpoint)
                              (plist-get refresh :client-id)
                              (neoment-client-refresh-token client)
                              callback)
      (neoment-api-request 'post "/_matrix/client/v3/logout"
                           :json nil :callback callback))))

(defconst neoment-auth--logout-prompt
  (concat "Are you sure you want to log out?\n"
          "All saved data will be lost. ")
  "Prompt of `neoment-logout'.")

;;;###autoload
(defun neoment-logout ()
  "Log out and delete the saved session data."
  (interactive)
  (cond
   ((not (neoment-logged-in-p))
    (neoment-notify--error "Not logged in"))
   ((not (y-or-n-p neoment-auth--logout-prompt))
    (neoment-notify--message "Operation canceled"))
   (t
    (let ((client neoment--client))
      (neoment-auth--logout-request
       (lambda (result)
         (when (eq client neoment--client)
           (if (plist-get result :error)
               (neoment-notify--error
                (concat "Logout failed: "
                        (neoment-http-error-message (plist-get result :error))))
             (neoment-sync-stop t)
             (neoment-storage-clear-session)
             (neoment-client-reset (neoment-client-homeserver client))
             (neoment-notify--message "Logout successful")))))))))

(provide 'neoment-auth)
;;; neoment-auth.el ends here
