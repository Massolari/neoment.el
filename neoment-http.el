;;; neoment-http.el --- HTTP layer for Neoment  -*- lexical-binding: t; -*-

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

;; `neoment-http-request' is the only function that touches the
;; network.  It calls back with (:ok DATA) or (:error ERR), where ERR is
;; a plist (:status :errcode :error :soft-logout).
;;
;; `neoment-api-request' sends authenticated requests to the
;; homeserver: it refreshes the token first when needed, adds the
;; `Authorization' header only for homeserver URLs, handles
;; M_UNKNOWN_TOKEN and drops responses that belong to a replaced client.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url-util)
(require 'plz)
(require 'neoment-client)

;;;; JSON

(defun neoment-json-decode (string)
  "Parse the JSON STRING.
Objects become alists with symbol keys, arrays become lists, null
becomes nil and false becomes `:false'.  An empty STRING gives nil."
  (if (or (null string) (string-empty-p (string-trim string)))
      nil
    (json-parse-string string :object-type 'alist :array-type 'list
                       :null-object nil :false-object :false)))

(defun neoment-json--normalize (object)
  "Return OBJECT with string alist keys turned into symbols."
  (cond
   ((vectorp object) (vconcat (mapcar #'neoment-json--normalize object)))
   ((and (consp object) (consp (car object)))
    (mapcar (lambda (pair)
              (cons (if (stringp (car pair)) (intern (car pair)) (car pair))
                    (neoment-json--normalize (cdr pair))))
            object))
   (t object)))

(defun neoment-json-encode (object)
  "Serialize OBJECT to a JSON string.
Objects are alists (symbol or string keys; nil is the empty object),
arrays are vectors, `:false' is false, `:null' is null and t is true."
  (json-serialize (neoment-json--normalize object)
                  :null-object :null :false-object :false))

(defun neoment-json-get (object &rest keys)
  "Follow KEYS (symbols) into the parsed JSON OBJECT."
  (let ((value object))
    (while (and keys value)
      (setq value (and (listp value) (alist-get (pop keys) value))))
    (if keys nil value)))

(defun neoment-json-true-p (value)
  "Return non-nil when VALUE is a parsed JSON true."
  (eq value t))

;;;; Errors

(defun neoment-http-transient-p (err)
  "Return non-nil when ERR is a transient failure.
That is a failure without status (network), or a 408, 429 or 5xx."
  (let ((status (plist-get err :status)))
    (or (null status) (memq status '(408 429)) (>= status 500))))

(defun neoment-http-error-message (err)
  "Return a readable message for ERR."
  (cond
   ((stringp err) err)
   ((plist-get err :error))
   ((plist-get err :errcode))
   ((plist-get err :status) (format "HTTP %d" (plist-get err :status)))
   (t "Unknown error")))

(defun neoment-http--parse-error (plz-err)
  "Convert the `plz-error' PLZ-ERR into an error plist."
  (let ((response (plz-error-response plz-err))
        (curl (plz-error-curl-error plz-err)))
    (cond
     (response
      (let* ((body (plz-response-body response))
             (data (and (stringp body)
                        (ignore-errors (neoment-json-decode body))))
             (data (and (consp data) (consp (car data)) data)))
        (list :status (plz-response-status response)
              :errcode (alist-get 'errcode data)
              :error (or (alist-get 'error data)
                         (alist-get 'error_description data))
              :soft-logout (eq (alist-get 'soft_logout data) t)
              :data data)))
     (curl
      (list :status nil :curl-code (car curl)
            :error (or (cdr curl) "Network error")))
     (t (list :status nil :error (or (plz-error-message plz-err)
                                     "Network error"))))))

;;;; Requests

(defun neoment-http-query-string (query)
  "Build a query string from the alist QUERY.
A value that is a list adds the key once per element."
  (mapconcat
   (lambda (pair)
     (let ((key (url-hexify-string (format "%s" (car pair))))
           (value (cdr pair)))
       (mapconcat (lambda (v)
                    (concat key "=" (url-hexify-string (format "%s" v))))
                  (if (listp value) value (list value))
                  "&")))
   (seq-filter #'cdr query)
   "&"))

(defun neoment-http-url (url query)
  "Return URL with the alist QUERY appended."
  (let ((qs (and query (neoment-http-query-string query))))
    (if (and qs (not (string-empty-p qs)))
        (concat url (if (string-search "?" url) "&" "?") qs)
      url)))

(defun neoment-http--safe-call (callback result)
  "Call CALLBACK with RESULT, reporting errors instead of signalling."
  (when callback
    (condition-case err
        (funcall callback result)
      (error
       (message "[Neoment] Error in request callback: %s"
                (error-message-string err))))))

(cl-defun neoment-http-request (&key (method 'get) url query headers json form
                                     body-file content-type (as 'json)
                                     output-file connect-timeout timeout
                                     callback)
  "Send an HTTP request and call CALLBACK with the result.
METHOD is a symbol (`get', `post', `put', `delete').  URL is the
full URL and QUERY an alist of query parameters.  HEADERS is an alist
of extra headers.  The body is JSON (an object for
`neoment-json-encode'), FORM (an alist sent form-encoded) or
BODY-FILE (a file sent as binary with CONTENT-TYPE).  AS is `json'
\(parse the response), `string' or `file' (save it in OUTPUT-FILE).
CONNECT-TIMEOUT and TIMEOUT are in seconds.

CALLBACK receives (:ok DATA) or (:error ERR).  Return the process."
  (let* ((full-url (neoment-http-url url query))
         (headers (copy-sequence headers))
         body body-type)
    (cond
     (json
      (setq body (encode-coding-string (neoment-json-encode json) 'utf-8))
      (push '("Content-Type" . "application/json") headers))
     (form
      (setq body (neoment-http-query-string form))
      (push '("Content-Type" . "application/x-www-form-urlencoded") headers))
     (body-file
      (setq body `(file ,body-file) body-type 'binary)
      (push (cons "Content-Type" (or content-type "application/octet-stream"))
            headers)))
    (when (and (memq method '(post put)) (null body))
      (setq body "{}")
      (push '("Content-Type" . "application/json") headers))
    (apply #'plz method full-url
           :headers headers
           :as (pcase as
                 ('file `(file ,output-file))
                 (_ 'string))
           :then (lambda (data)
                   (neoment-http--safe-call
                    callback
                    (if (eq as 'json)
                        (condition-case err
                            (list :ok (neoment-json-decode data))
                          (error (list :error
                                       (list :status nil
                                             :error (format "Invalid JSON: %s"
                                                            (error-message-string err))))))
                      (list :ok data))))
           :else (lambda (plz-err)
                   (neoment-http--safe-call
                    callback (list :error (neoment-http--parse-error plz-err))))
           :noquery t
           (append (and body (list :body body))
                   (and body-type (list :body-type body-type))
                   (and connect-timeout (list :connect-timeout connect-timeout))
                   (and timeout (list :timeout timeout))))))

;;;; Authenticated requests

(defvar neoment-http-ensure-token-function nil
  "Function called before an authenticated request.
It is called with the client and a continuation; the continuation
must be called with no argument once the token is fresh.")

(defvar neoment-http-unknown-token-function nil
  "Function called when a request fails with M_UNKNOWN_TOKEN.
It is called with the client, the error, the access token the
request used, a function that resends the request and a function
that gives up with the error.")

(defun neoment-http-homeserver-url-p (url &optional client)
  "Return non-nil when URL belongs to the homeserver of CLIENT."
  (let ((hs (neoment-client-homeserver (or client neoment--client))))
    (and hs (string-prefix-p (concat hs "/") url))))

(defun neoment-api-url (path &optional client)
  "Return the URL of PATH on the homeserver of CLIENT.
PATH may already be a full URL."
  (if (string-match-p "\\`https?://" path)
      path
    (concat (neoment-client-homeserver (or client neoment--client)) path)))

(defun neoment-api-encode (string)
  "Percent-encode STRING for use as a single path segment."
  (url-hexify-string string))

(cl-defun neoment-api-request (method path &rest args
                                      &key callback (client neoment--client)
                                      retried &allow-other-keys)
  "Send an authenticated METHOD request to PATH on the homeserver.
ARGS are passed to `neoment-http-request' (except CLIENT and RETRIED).
CALLBACK is called with the result, unless CLIENT stopped being the
current client in the meantime.  RETRIED is non-nil for a resend."
  (if (null client)
      (neoment-http--safe-call callback
                               (list :error (list :error "Not logged in")))
    (let ((http-args (cl-loop for (k v) on args by #'cddr
                              unless (memq k '(:callback :client :retried))
                              append (list k v)))
          (send nil))
      (setq
       send
       (lambda ()
         (when (eq client neoment--client)
           (let* ((url (neoment-api-url path client))
                  (token (neoment-client-access-token client))
                  (headers (append
                            (and token (neoment-http-homeserver-url-p url client)
                                 (list (cons "Authorization"
                                             (concat "Bearer " token))))
                            (plist-get http-args :headers))))
             (apply
              #'neoment-http-request
              :method method :url url :headers headers
              :callback
              (lambda (result)
                (when (eq client neoment--client)
                  (let ((err (plist-get result :error)))
                    (if (and err (not retried)
                             (equal (plist-get err :errcode) "M_UNKNOWN_TOKEN")
                             neoment-http-unknown-token-function)
                        (funcall neoment-http-unknown-token-function
                                 client err token
                                 (lambda ()
                                   (apply #'neoment-api-request method path
                                          :retried t args))
                                 (lambda ()
                                   (neoment-http--safe-call callback result)))
                      (neoment-http--safe-call callback result)))))
              (cl-loop for (k v) on http-args by #'cddr
                       unless (eq k :headers) append (list k v)))))))
      (if neoment-http-ensure-token-function
          (funcall neoment-http-ensure-token-function client send)
        (funcall send)))))

(provide 'neoment-http)
;;; neoment-http.el ends here
