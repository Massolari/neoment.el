;;; neoment-sso.el --- Single Sign-On login  -*- lexical-binding: t; -*-

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

;; SSO login.  A local listener on 127.0.0.1, with a random port and a
;; random secret path, receives the login token from the browser.
;; Without a browser (SSH sessions, or after a timeout) the user pastes
;; the redirected URL instead.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-notify)
(require 'neoment-auth)

(defconst neoment-sso-manual-redirect-url "http://127.0.0.1/"
  "Redirect URL of the manual mode.")

(defconst neoment-sso-header-limit 8192
  "Maximum size in bytes of a request received by the listener.")

(defvar neoment-sso-timeout 120
  "Seconds the listener waits for the browser.")

(defconst neoment-sso--success-html
  "<!DOCTYPE html><html><body><p>Login complete. You can close this tab and return to Emacs.</p></body></html>"
  "Page shown when the login token arrived.")

(defconst neoment-sso--no-token-html
  "<!DOCTYPE html><html><body><p>This request did not contain a login token.</p></body></html>"
  "Page shown for a request without a login token.")

;;;; Helpers

(defun neoment-sso-redirect-url (homeserver redirect)
  "Return the SSO URL of HOMESERVER that redirects to REDIRECT."
  (concat homeserver "/_matrix/client/v3/login/sso/redirect?redirectUrl="
          (url-hexify-string redirect)))

(defun neoment-sso-parse-login-token (input)
  "Parse the pasted INPUT: a redirected URL or a raw token.
Return (TOKEN . nil), (nil . ERROR-MESSAGE), or nil when INPUT is empty."
  (let ((trimmed (string-trim (or input ""))))
    (cond
     ((string-empty-p trimmed) nil)
     ((string-match "[?&]loginToken=\\([^&#]+\\)" trimmed)
      (cons (url-unhex-string (match-string 1 trimmed)) nil))
     ((string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" trimmed)
      (cons nil "The URL does not contain a login token"))
     (t (cons trimmed nil)))))

(defun neoment-sso--random-secret ()
  "Return a random hexadecimal secret."
  (substring (secure-hash 'sha256 (format "%s%s%s" (random) (float-time) (emacs-pid))) 0 32))

;;;; Listener

(defun neoment-sso--respond (process status html)
  "Send STATUS and HTML to PROCESS and close it."
  (when (process-live-p process)
    (let ((body (encode-coding-string html 'utf-8)))
      (process-send-string
       process
       (concat "HTTP/1.1 " status "\r\n"
               "Content-Type: text/html; charset=utf-8\r\n"
               (format "Content-Length: %d\r\n" (length body))
               "Connection: close\r\n\r\n"
               body)))
    (delete-process process)))

(defun neoment-sso-listen (on-token on-timeout)
  "Start the SSO listener.
ON-TOKEN is called with the login token, ON-TIMEOUT when nothing
arrived in time.  Return a plist (:redirect-url :close :process)."
  (let* ((secret (neoment-sso--random-secret))
         (closed nil)
         server timer close)
    (setq close (lambda ()
                  (unless closed
                    (setq closed t)
                    (when (timerp timer) (cancel-timer timer))
                    (when (process-live-p server) (delete-process server)))))
    (setq server
          (make-network-process
           :name "neoment-sso" :server t :host "127.0.0.1" :service t :family 'ipv4
           :noquery t :coding 'binary
           :filter
           (lambda (process chunk)
             (let ((data (concat (or (process-get process 'neoment-data) "") chunk)))
               (process-put process 'neoment-data data)
               (cond
                ((> (length data) neoment-sso-header-limit)
                 (neoment-sso--respond process "431 Request Header Fields Too Large" ""))
                ((string-match "\r?\n\r?\n" data)
                 (if (not (string-match "\\`GET /\\([^ ?]*\\)\\(?:\\?\\([^ ]*\\)\\)? HTTP" data))
                     (neoment-sso--respond process "400 Bad Request" "")
                   (let ((path (match-string 1 data))
                         (query (match-string 2 data)))
                     (if (not (equal path secret))
                         (neoment-sso--respond process "404 Not Found" "")
                       (let ((token (and query
                                         (string-match "\\(?:\\`\\|&\\)loginToken=\\([^&]+\\)" query)
                                         (url-unhex-string (match-string 1 query)))))
                         (if (not token)
                             (neoment-sso--respond process "200 OK" neoment-sso--no-token-html)
                           (neoment-sso--respond process "200 OK" neoment-sso--success-html)
                           (unless closed
                             (funcall close)
                             (funcall on-token token)))))))))))))
    (setq timer (run-at-time neoment-sso-timeout nil
                             (lambda ()
                               (unless closed
                                 (funcall close)
                                 (funcall on-timeout)))))
    (list :redirect-url (format "http://127.0.0.1:%d/%s"
                                (process-contact server :service) secret)
          :close close
          :process server)))

;;;; Login

(defun neoment-sso--manual (ctx)
  "Run the manual SSO login for the attempt CTX."
  (let ((url (neoment-sso-redirect-url (plist-get ctx :homeserver)
                                       neoment-sso-manual-redirect-url)))
    (neoment-notify--message
     (concat "Open this URL in your browser and log in. The page you are sent to will fail to load; copy its URL from the address bar:\n"
             url))
    (neoment--defer
     (lambda ()
       (when (funcall (neoment-auth-current-function ctx))
         (let ((parsed (neoment-sso-parse-login-token
                        (read-string "Paste the redirected URL or login token: "))))
           (cond
            ((null parsed) (neoment-notify--message "Login cancelled"))
            ((cdr parsed) (neoment-notify--error (cdr parsed)))
            (t (neoment-auth-login-token (car parsed)
                                         (neoment-auth-result-handler ctx)
                                         (neoment-auth-current-function ctx))))))))))

(defun neoment-sso-login (ctx)
  "Run the SSO login for the attempt CTX."
  (if (neoment-auth-remote-session-p)
      (neoment-sso--manual ctx)
    (let* ((listener
            (condition-case err
                (neoment-sso-listen
                 (lambda (token)
                   (neoment-auth-login-token token (neoment-auth-result-handler ctx)
                                             (neoment-auth-current-function ctx)))
                 (lambda ()
                   (when (funcall (neoment-auth-current-function ctx))
                     (neoment-notify--message "Did not receive the login from the browser" 'warn)
                     (neoment-sso--manual ctx))))
              (error (neoment-notify--message (error-message-string err) 'warn)
                     nil))))
      (if (null listener)
          (neoment-sso--manual ctx)
        (neoment-auth-add-cancel-function (plist-get listener :close))
        (let ((url (neoment-sso-redirect-url (plist-get ctx :homeserver)
                                             (plist-get listener :redirect-url))))
          (condition-case err
              (progn (browse-url url)
                     (neoment-notify--message "Waiting for the login in the browser..."))
            (error
             (neoment-notify--message
              (format "Could not open the browser (%s). Open this URL to log in:\n%s"
                      (error-message-string err) url)
              'warn))))))))

(provide 'neoment-sso)
;;; neoment-sso.el ends here
