;;; neoment-oauth.el --- OAuth 2.0 device code login  -*- lexical-binding: t; -*-

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

;; OAuth 2.0 device authorization grant (RFC 8628) against the
;; homeserver's authorization server: client registration, the device
;; code, token polling, completion and revocation (RFC 7009).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-notify)
(require 'neoment-storage)
(require 'neoment-auth)

(defconst neoment-oauth-client-name "Neoment for Emacs"
  "Client name sent when registering.")

(defconst neoment-oauth-client-uri "https://github.com/Massolari/neoment.el"
  "Client URI sent when registering.")

(defconst neoment-oauth-slow-down-step 5
  "Seconds added to the polling interval on `slow_down'.")

(defvar neoment-oauth-now-function #'float-time
  "Function returning the current time in seconds.")

(defvar neoment-oauth-defer-function
  (lambda (seconds function) (run-at-time seconds nil function))
  "Function that calls a function after a number of seconds.")

(defun neoment-oauth--error (err)
  "Return the OAuth error ERR with `:code' and a readable `:error'."
  (let* ((data (plist-get err :data))
         (code (and (plist-get err :status) (alist-get 'error data))))
    (append (list :code (and (stringp code) code)
                  :error (or (alist-get 'error_description data)
                             (plist-get err :error)
                             "unknown error"))
            err)))

;;;; Registration and device code

(defun neoment-oauth-register (metadata callback)
  "Return the client id for METADATA's issuer through CALLBACK.
A saved id is reused; otherwise a client is registered and saved."
  (let* ((issuer (plist-get metadata :issuer))
         (saved (neoment-storage-oauth-client-id issuer)))
    (if saved
        (funcall callback (list :ok saved))
      (neoment-http-request
       :method 'post :url (plist-get metadata :registration-endpoint)
       :json `((client_name . ,neoment-oauth-client-name)
               (client_uri . ,neoment-oauth-client-uri)
               (grant_types . [,neoment-auth-device-code-grant "refresh_token"])
               (token_endpoint_auth_method . "none")
               (application_type . "native"))
       :connect-timeout 5 :timeout 30
       :callback
       (lambda (result)
         (let ((client-id (alist-get 'client_id (plist-get result :ok))))
           (cond
            ((plist-get result :error)
             (let ((err (neoment-oauth--error (plist-get result :error))))
               (funcall callback
                        (list :error (plist-put err :error
                                                (concat "Could not register the client: "
                                                        (plist-get err :error)))))))
            ((not (and (stringp client-id) (not (string-empty-p client-id))))
             (funcall callback
                      (list :error (list :error (concat "Could not register the client: "
                                                        "the server returned no client ID")))))
            (t
             (neoment-storage-set-oauth-client-id issuer client-id)
             (funcall callback (list :ok client-id))))))))))

(defun neoment-oauth-request-device-code (metadata client-id device-id callback)
  "Ask for a device code for CLIENT-ID and DEVICE-ID, then call CALLBACK.
METADATA is the OAuth metadata plist.  CALLBACK receives (:ok DEVICE)
where DEVICE is a plist (:device-code :user-code :verification-url
:code-in-url :expires-in :interval), or (:error ERR)."
  (neoment-http-request
   :method 'post :url (plist-get metadata :device-authorization-endpoint)
   :form `((client_id . ,client-id)
           (scope . ,(concat "urn:matrix:client:api:* urn:matrix:client:device:" device-id)))
   :connect-timeout 5 :timeout 30
   :callback
   (lambda (result)
     (let ((data (plist-get result :ok)))
       (cond
        ((plist-get result :error)
         (let ((err (neoment-oauth--error (plist-get result :error))))
           (when (equal (plist-get err :code) "invalid_client")
             (neoment-storage-set-oauth-client-id (plist-get metadata :issuer) nil))
           (funcall callback (list :error err))))
        ((not (and (stringp (alist-get 'device_code data))
                   (stringp (alist-get 'user_code data))
                   (neoment-auth-http-url-p (alist-get 'verification_uri data))))
         (funcall callback
                  (list :error (list :error (concat "The server returned an incomplete "
                                                    "device authorization response")))))
        (t
         (let ((complete (and (neoment-auth-http-url-p (alist-get 'verification_uri_complete data))
                              (alist-get 'verification_uri_complete data))))
           (funcall callback
                    (list :ok (list :device-code (alist-get 'device_code data)
                                    :user-code (alist-get 'user_code data)
                                    :verification-url (or complete (alist-get 'verification_uri data))
                                    :code-in-url (and complete t)
                                    :expires-in (if (numberp (alist-get 'expires_in data))
                                                    (alist-get 'expires_in data)
                                                  600)
                                    :interval (if (numberp (alist-get 'interval data))
                                                  (alist-get 'interval data)
                                                5)))))))))))

;;;; Polling

(defun neoment-oauth-poll (metadata client-id device callback)
  "Poll the token endpoint of METADATA until DEVICE is approved.
CLIENT-ID is the registered client.  CALLBACK receives (:ok DATA) with
the token response, or (:error ERR).  Each request is sent only after
the previous one answered.  Return a function that cancels polling."
  (let* ((interval (plist-get device :interval))
         (deadline (+ (funcall neoment-oauth-now-function) (plist-get device :expires-in)))
         (active t)
         request)
    (cl-labels ((finish (result)
                  (when active
                    (setq active nil)
                    (funcall callback result)))
                (schedule ()
                  (funcall neoment-oauth-defer-function interval request)))
      (setq request
            (lambda ()
              (when active
                (if (>= (funcall neoment-oauth-now-function) deadline)
                    (finish (list :error (list :error "The login code expired" :code "expired_token")))
                  (neoment-http-request
                   :method 'post :url (plist-get metadata :token-endpoint)
                   :form `((grant_type . ,neoment-auth-device-code-grant)
                           (device_code . ,(plist-get device :device-code))
                           (client_id . ,client-id))
                   :connect-timeout 5 :timeout 30
                   :callback
                   (lambda (result)
                     (when active
                       (if (plist-get result :ok)
                           (finish result)
                         (let* ((err (neoment-oauth--error (plist-get result :error)))
                                (code (plist-get err :code)))
                           (pcase code
                             ("authorization_pending" (schedule))
                             ("slow_down"
                              (setq interval (+ interval neoment-oauth-slow-down-step))
                              (schedule))
                             ("expired_token"
                              (finish (list :error (list :error "The login code expired"
                                                         :code code))))
                             ("access_denied"
                              (finish (list :error (list :error "The login was denied"
                                                         :code code))))
                             (_ (if (neoment-http-transient-p err)
                                    (schedule)
                                  (finish (list :error err))))))))))))))
      (schedule))
    (lambda () (setq active nil))))

;;;; Completion and revocation

(defun neoment-oauth-revoke (endpoint client-id token callback)
  "Revoke the refresh TOKEN of CLIENT-ID at ENDPOINT, then call CALLBACK."
  (neoment-http-request
   :method 'post :url endpoint :as 'string
   :form `((token . ,token) (token_type_hint . "refresh_token") (client_id . ,client-id))
   :connect-timeout 5 :timeout 30
   :callback (lambda (result)
               (funcall callback (if (plist-get result :error)
                                     (list :error (neoment-oauth--error (plist-get result :error)))
                                   (list :ok nil))))))

(defun neoment-oauth-complete (tokens metadata client-id callback current-p)
  "Finish the login with the token response TOKENS.
METADATA and CLIENT-ID describe the OAuth client.  CALLBACK receives
the login result.  CURRENT-P returns nil when the attempt was
superseded."
  (let* ((client neoment--client)
         (refresh-token (and (stringp (alist-get 'refresh_token tokens))
                             (alist-get 'refresh_token tokens)))
         (refresh (list :kind "oauth"
                        :token-endpoint (plist-get metadata :token-endpoint)
                        :client-id client-id
                        :revocation-endpoint (plist-get metadata :revocation-endpoint)))
         (revoke (lambda ()
                   (when (and refresh-token (plist-get metadata :revocation-endpoint))
                     (neoment-oauth-revoke (plist-get metadata :revocation-endpoint)
                                           client-id refresh-token #'ignore)))))
    (if (not (stringp (alist-get 'access_token tokens)))
        (funcall callback (list :error (list :error "The server returned no access token")))
      (setf (neoment-client-access-token client) (alist-get 'access_token tokens)
            (neoment-client-refresh-token client) refresh-token
            (neoment-client-expires-at client)
            (and refresh-token (numberp (alist-get 'expires_in tokens))
                 (+ (truncate (float-time)) (floor (alist-get 'expires_in tokens))))
            (neoment-client-refresh client) refresh)
      (neoment-api-request
       'get "/_matrix/client/v3/account/whoami"
       :client client
       :callback
       (lambda (result)
         (let ((user-id (alist-get 'user_id (plist-get result :ok))))
           (cond
            ((or (not (eq client neoment--client)) (not (funcall current-p)))
             (funcall revoke)
             (funcall callback (list :error (list :error "The login was superseded by another login attempt"))))
            ((not (stringp user-id))
             (funcall revoke)
             (neoment-client-reset (neoment-client-homeserver client))
             (funcall callback
                      (if (plist-get result :error)
                          result
                        (list :error (list :error (concat "The server did not say which user "
                                                          "the token belongs to"))))))
            (t
             (setf (neoment-client-user-id client) user-id)
             (funcall callback (list :ok nil))))))))))

;;;; Login flow

(defun neoment-oauth--show-instructions (device ctx)
  "Show how to approve DEVICE and offer to open the page, for attempt CTX."
  (let ((url (plist-get device :verification-url))
        (code (plist-get device :user-code)))
    (neoment-notify--message
     (if (plist-get device :code-in-url)
         (format "Open this URL and approve the login (code %s):\n%s\nThe login completes on its own once you approve it."
                 code url)
       (format "Open %s and enter the code %s.\nThe login completes on its own once you approve it."
               url code)))
    (unless (neoment-auth-remote-session-p)
      (neoment--defer
       (lambda ()
         (when (funcall (neoment-auth-current-function ctx))
           (let ((choice (condition-case nil
                             (completing-read "Verification page: "
                                              '("Open in browser" "Not now") nil t)
                           (quit nil))))
             (when (equal choice "Open in browser")
               (condition-case err
                   (browse-url url)
                 (error
                  (neoment-notify--message
                   (format "Could not open the browser (%s). Use the URL above to log in."
                           (error-message-string err))
                   'warn)))))))))))

(defun neoment-oauth-device-login (ctx)
  "Run the OAuth device code login for the attempt CTX."
  (let* ((metadata (plist-get ctx :oauth-metadata))
         (current-p (neoment-auth-current-function ctx))
         (fail (lambda (result)
                 (when (funcall current-p)
                   (neoment-notify--error
                    (concat "Error logging in: "
                            (neoment-http-error-message (plist-get result :error))))))))
    (neoment-oauth-register
     metadata
     (lambda (registered)
       (if (plist-get registered :error)
           (funcall fail registered)
         (let ((client-id (plist-get registered :ok)))
           (neoment-oauth-request-device-code
            metadata client-id (neoment-client-device-id neoment--client)
            (lambda (requested)
              (cond
               ((not (funcall current-p)))
               ((plist-get requested :error) (funcall fail requested))
               (t
                (let* ((device (plist-get requested :ok))
                       (cancel (neoment-oauth-poll
                                metadata client-id device
                                (lambda (polled)
                                  (when (funcall current-p)
                                    (if (plist-get polled :error)
                                        (neoment-notify--error
                                         (neoment-http-error-message (plist-get polled :error)))
                                      (neoment-oauth-complete
                                       (plist-get polled :ok) metadata client-id
                                       (neoment-auth-result-handler ctx) current-p)))))))
                  (neoment-auth-add-cancel-function cancel)
                  (neoment-oauth--show-instructions device ctx))))))))))))

(provide 'neoment-oauth)
;;; neoment-oauth.el ends here
