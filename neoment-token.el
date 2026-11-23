;;; neoment-token.el --- Access token refresh  -*- lexical-binding: t; -*-

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

;; Refreshes the access token before it expires and when the server
;; reports a soft logout.  Only one refresh runs at a time: requests
;; issued meanwhile wait for it and get its result.

;;; Code:

(require 'cl-lib)
(require 'neoment-config)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-storage)
(require 'neoment-auth)

(defconst neoment-token-expiry-skew 60
  "Seconds before expiry when the token is refreshed.")

(defconst neoment-token-refresh-timeout 30
  "Seconds after which a refresh request is abandoned.")

(defvar neoment-token--waiters nil
  "Callbacks waiting for the refresh in flight, or nil when none runs.")

(defun neoment-token-stale-p (&optional client)
  "Return non-nil when the token of CLIENT must be refreshed now."
  (let ((client (or client neoment--client)))
    (and client
         (neoment-client-refresh-token client)
         (neoment-client-expires-at client)
         (< (- (neoment-client-expires-at client) (float-time))
            neoment-token-expiry-skew))))

(defun neoment-token--permanent-p (err)
  "Return non-nil when ERR is a permanent refresh failure (4xx)."
  (let ((status (plist-get err :status)))
    (and status (>= status 400) (< status 500) (not (memq status '(408 429))))))

(defun neoment-token--request (client callback)
  "Ask the server for new tokens for CLIENT and call CALLBACK.
CALLBACK receives (:ok (ACCESS REFRESH EXPIRES-IN-SECONDS)) or
\(:error ERR)."
  (let* ((refresh (neoment-client-refresh client))
         (handle (lambda (result expires-key divisor)
                   (let ((data (plist-get result :ok)))
                     (funcall
                      callback
                      (cond
                       ((plist-get result :error) result)
                       ((not (stringp (alist-get 'access_token data)))
                        (list :error (list :error "The refresh response has no access token")))
                       (t (let ((expires (alist-get expires-key data)))
                            (list :ok (list (alist-get 'access_token data)
                                            (and (stringp (alist-get 'refresh_token data))
                                                 (alist-get 'refresh_token data))
                                            (and (numberp expires) (/ expires divisor))))))))))))
    (if (equal (plist-get refresh :kind) "oauth")
        (neoment-http-request
         :method 'post :url (plist-get refresh :token-endpoint)
         :form `((grant_type . "refresh_token")
                 (refresh_token . ,(neoment-client-refresh-token client))
                 (client_id . ,(plist-get refresh :client-id)))
         :timeout neoment-token-refresh-timeout
         :callback (lambda (result) (funcall handle result 'expires_in 1)))
      (neoment-http-request
       :method 'post
       :url (concat (neoment-client-homeserver client) "/_matrix/client/v3/refresh")
       :json `((refresh_token . ,(neoment-client-refresh-token client)))
       :timeout neoment-token-refresh-timeout
       :callback (lambda (result) (funcall handle result 'expires_in_ms 1000))))))

(defun neoment-token--adopt-saved (client)
  "Adopt the tokens saved by another instance for CLIENT, if any.
Return non-nil when a different refresh token of the same user and
homeserver was adopted."
  (let ((saved (neoment-storage-read-session)))
    (when (and saved
               (stringp (alist-get 'access_token saved))
               (stringp (alist-get 'refresh_token saved))
               (not (equal (alist-get 'refresh_token saved)
                           (neoment-client-refresh-token client)))
               (equal (alist-get 'homeserver saved) (neoment-client-homeserver client))
               (equal (alist-get 'user_id saved) (neoment-client-user-id client)))
      (setf (neoment-client-access-token client) (alist-get 'access_token saved)
            (neoment-client-refresh-token client) (alist-get 'refresh_token saved)
            (neoment-client-expires-at client) (alist-get 'expires_at saved))
      t)))

(defun neoment-token--expire ()
  "End the session after a permanent failure."
  (neoment-auth-session-expired))

(defun neoment-token-refresh (callback &optional client)
  "Refresh the token of CLIENT (default: the current one), then CALLBACK.
CALLBACK receives (:ok nil) or (:error ERR).  Concurrent calls share
one refresh."
  (let ((client (or client neoment--client)))
    (cond
     (neoment-token--waiters
      (setq neoment-token--waiters (append neoment-token--waiters (list callback))))
     ((not (and client (neoment-client-refresh-token client)))
      (funcall callback (list :error (list :error "Session expired, please log in again"
                                           :session-expired t))))
     (t
      (setq neoment-token--waiters (list callback))
      (cl-labels
          ((finish (result)
             (let ((callbacks neoment-token--waiters))
               (setq neoment-token--waiters nil)
               (dolist (cb callbacks) (funcall cb result))))
           (run (may-reread)
             (neoment-token--request
              client
              (lambda (result)
                (cond
                 ((not (eq client neoment--client))
                  (finish (list :error (list :error "The session changed during the token refresh"))))
                 ((plist-get result :ok)
                  (pcase-let ((`(,access ,refresh ,expires-in) (plist-get result :ok)))
                    (setf (neoment-client-access-token client) access
                          (neoment-client-refresh-token client)
                          (or refresh (neoment-client-refresh-token client))
                          (neoment-client-expires-at client)
                          (and expires-in (+ (truncate (float-time)) (floor expires-in)))))
                  (neoment-storage-save-session client)
                  (finish (list :ok nil)))
                 ((not (neoment-token--permanent-p (plist-get result :error)))
                  (finish result))
                 ((and may-reread neoment-save-session (neoment-token--adopt-saved client))
                  (if (neoment-token-stale-p client)
                      (run nil)
                    (finish (list :ok nil))))
                 (t
                  (let ((err (append (list :session-expired t) (plist-get result :error))))
                    (finish (list :error err))
                    (neoment-token--expire))))))))
        (run t))))))

(defun neoment-token-ensure-fresh (client send fail)
  "Refresh the token of CLIENT when needed, then call SEND.
FAIL is called with the error when the refresh fails."
  (if (not (neoment-token-stale-p client))
      (funcall send)
    (neoment-token-refresh (lambda (result)
                             (if (plist-get result :error)
                                 (funcall fail (plist-get result :error))
                               (funcall send)))
                           client)))

(defun neoment-token-handle-unknown-token (client err token retry give-up)
  "Handle an M_UNKNOWN_TOKEN error ERR for a request of CLIENT.
TOKEN is the access token the request used.  RETRY resends it once
and GIVE-UP reports the error."
  (cond
   ((not (eq client neoment--client)) (funcall give-up))
   ((not (equal token (neoment-client-access-token client)))
    (funcall retry))
   ((and (plist-get err :soft-logout) (neoment-client-refresh-token client))
    (neoment-token-refresh (lambda (result)
                             (if (plist-get result :error)
                                 (funcall give-up)
                               (funcall retry)))
                           client))
   (t
    (neoment-token--expire)
    (funcall give-up))))

(setq neoment-http-ensure-token-function #'neoment-token-ensure-fresh
      neoment-http-unknown-token-function #'neoment-token-handle-unknown-token)

(provide 'neoment-token)
;;; neoment-token.el ends here
