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
(require 'url-parse)
(require 'url)
(require 'url-http)
(require 'plz nil t)
(require 'neoment-config)
(require 'neoment-client)

(declare-function plz "plz")
(declare-function plz-error-response "plz")
(declare-function plz-error-curl-error "plz")
(declare-function plz-error-message "plz")
(declare-function plz-response-status "plz")
(declare-function plz-response-body "plz")

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

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

(defun neoment-http--response-error (status body)
  "Return the error plist of an HTTP STATUS response with BODY."
  (let* ((data (and (stringp body)
                    (ignore-errors (neoment-json-decode body))))
         (data (and (consp data) (consp (car data)) data)))
    (list :status status
          :errcode (alist-get 'errcode data)
          :error (or (alist-get 'error data)
                     (alist-get 'error_description data))
          :soft-logout (eq (alist-get 'soft_logout data) t)
          :data data)))

(defun neoment-http--parse-error (plz-err)
  "Convert the `plz-error' PLZ-ERR into an error plist."
  (let ((response (plz-error-response plz-err))
        (curl (plz-error-curl-error plz-err)))
    (cond
     (response
      (neoment-http--response-error (plz-response-status response)
                                    (plz-response-body response)))
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

CALLBACK receives (:ok DATA) or (:error ERR).  The request is sent
with the backend chosen by `neoment-http-backend'.  Return the
process, when there is one."
  (let* ((full-url (neoment-http-url url query))
         (headers (copy-sequence headers))
         body)
    (cond
     (json
      (setq body (encode-coding-string (neoment-json-encode json) 'utf-8))
      (push '("Content-Type" . "application/json") headers))
     (form
      (setq body (neoment-http-query-string form))
      (push '("Content-Type" . "application/x-www-form-urlencoded") headers))
     (body-file
      (push (cons "Content-Type" (or content-type "application/octet-stream"))
            headers)))
    (when (and (memq method '(post put)) (null body) (null body-file))
      (setq body "{}")
      (push '("Content-Type" . "application/json") headers))
    (if (eq (neoment-http-backend) 'plz)
        (if (fboundp 'plz)
            (neoment-http--plz method full-url headers body body-file as output-file
                               connect-timeout timeout callback)
          (neoment-http--safe-call
           callback (list :error (list :status nil
                                       :error "The plz package is not installed"))))
      (neoment-http--url method full-url headers body body-file as output-file
                         (and (or connect-timeout timeout)
                              (max (or connect-timeout 0) (or timeout 0)))
                         callback))))

(defun neoment-http-backend ()
  "Return the backend to use for requests: `plz' or `url'."
  (pcase neoment-http-backend
    ('plz 'plz)
    ('url 'url)
    (_ (if (or (featurep 'plz) (require 'plz nil t)) 'plz 'url))))

(defun neoment-http--success (as data)
  "Return the result of a successful response DATA read AS."
  (if (eq as 'json)
      (condition-case err
          (list :ok (neoment-json-decode data))
        (error (list :error
                     (list :status nil
                           :error (format "Invalid JSON: %s"
                                          (error-message-string err))))))
    (list :ok data)))

;;;;; plz backend

(defun neoment-http--plz (method url headers body body-file as output-file
                                 connect-timeout timeout callback)
  "Send the request with `plz'.
METHOD, URL, HEADERS, BODY, BODY-FILE, AS, OUTPUT-FILE,
CONNECT-TIMEOUT, TIMEOUT and CALLBACK are as in `neoment-http-request'."
  (apply #'plz method url
         :headers headers
         :as (pcase as
               ('file `(file ,output-file))
               (_ 'string))
         :then (lambda (data)
                 (neoment-http--safe-call callback (neoment-http--success as data)))
         :else (lambda (plz-err)
                 (neoment-http--safe-call
                  callback (list :error (neoment-http--parse-error plz-err))))
         :noquery t
         (append (cond (body-file (list :body `(file ,body-file) :body-type 'binary))
                       (body (list :body body)))
                 (and connect-timeout (list :connect-timeout connect-timeout))
                 (and timeout (list :timeout timeout)))))

;;;;; url.el backend

(defun neoment-http--file-bytes (file)
  "Return the contents of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun neoment-http--unibyte (string)
  "Return STRING encoded as UTF-8 bytes in a unibyte string."
  (if (multibyte-string-p string)
      (encode-coding-string string 'utf-8)
    string))

(defun neoment-http--url-error-text (error-info)
  "Return a readable text for the `url.el' ERROR-INFO."
  (cond
   ((null error-info) "Network error")
   ((consp error-info)
    (mapconcat (lambda (x) (format "%s" x)) (cdr error-info) " "))
   (t (format "%s" error-info))))

(defun neoment-http--url-result (status as output-file)
  "Return the result of the `url.el' response in the current buffer.
STATUS is the status plist `url-retrieve' passed to its callback.  AS
and OUTPUT-FILE are as in `neoment-http-request'."
  (let* ((code (and (boundp 'url-http-response-status) url-http-response-status))
         (start (if (and (boundp 'url-http-end-of-headers)
                         (markerp url-http-end-of-headers))
                    (min (point-max) (1+ url-http-end-of-headers))
                  (point-min)))
         (raw (buffer-substring-no-properties start (point-max))))
    (cond
     ((and (numberp code) (>= code 200) (< code 300))
      (if (eq as 'file)
          (let ((coding-system-for-write 'binary))
            (write-region raw nil output-file nil 'silent)
            (list :ok output-file))
        (neoment-http--success as (decode-coding-string raw 'utf-8))))
     ((numberp code)
      (list :error (neoment-http--response-error code (decode-coding-string raw 'utf-8))))
     (t
      (list :error (list :status nil
                         :error (neoment-http--url-error-text
                                 (plist-get status :error))))))))

(defun neoment-http--kill-buffer (buffer)
  "Kill BUFFER and its process without asking."
  (when (buffer-live-p buffer)
    (let ((process (get-buffer-process buffer)))
      (when process (delete-process process)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(defun neoment-http--url (method url headers body body-file as output-file timeout callback)
  "Send the request with the built-in `url.el'.
METHOD, URL, HEADERS, BODY, BODY-FILE, AS, OUTPUT-FILE and CALLBACK are
as in `neoment-http-request'.  TIMEOUT is the total timeout in seconds:
when it passes, the request fails without a status."
  ;; `url-http' refuses a request whose text is multibyte, which happens
  ;; as soon as one header is multibyte and the body has non-ASCII
  ;; bytes, so every part is made unibyte.
  (let* ((url (neoment-http--unibyte url))
         (url-request-method (neoment-http--unibyte (upcase (symbol-name method))))
         (url-request-extra-headers
          (mapcar (lambda (h) (cons (neoment-http--unibyte (car h))
                                    (neoment-http--unibyte (cdr h))))
                  headers))
         (url-request-data (cond (body-file (neoment-http--file-bytes body-file))
                                 ((and body (multibyte-string-p body))
                                  (encode-coding-string body 'utf-8))
                                 (t body)))
         (done nil)
         (timer nil)
         (buffer nil))
    (cl-flet ((finish (result)
                (unless done
                  (setq done t)
                  (when (timerp timer) (cancel-timer timer))
                  (neoment-http--safe-call callback result))))
      (condition-case err
          (setq buffer
                (url-retrieve
                 url
                 (lambda (status)
                   (let ((response (current-buffer)))
                     (unwind-protect
                         (finish (neoment-http--url-result status as output-file))
                       (neoment-http--kill-buffer response))))
                 nil t t))
        (error (finish (list :error (list :status nil
                                          :error (error-message-string err))))))
      (let ((process (and (buffer-live-p buffer) (get-buffer-process buffer))))
        (when process
          (set-process-query-on-exit-flag process nil))
        (when (and timeout (not done))
          (setq timer (run-at-time timeout nil
                                   (lambda ()
                                     ;; Report first: killing the connection
                                     ;; makes `url.el' call back too.
                                     (unless done
                                       (finish (list :error
                                                     (list :status nil
                                                           :error "Operation timed out")))
                                       (neoment-http--kill-buffer buffer))))))
        process))))

;;;; Authenticated requests

(defvar neoment-http-ensure-token-function nil
  "Function called before an authenticated request.
It is called with the client, a function to call with no argument
once the token is fresh, and a function to call with an error plist
when the request must fail instead.")

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
          (funcall neoment-http-ensure-token-function client send
                   (lambda (err)
                     (when (eq client neoment--client)
                       (neoment-http--safe-call callback (list :error err)))))
        (funcall send)))))

;;;; Matrix endpoints

(defun neoment-api-uuid ()
  "Return a random version 4 UUID string."
  (format "%04x%04x-%04x-4%03x-%x%03x-%04x%04x%04x"
          (random #x10000) (random #x10000) (random #x10000) (random #x1000)
          (+ 8 (random 4)) (random #x1000)
          (random #x10000) (random #x10000) (random #x10000)))

(defun neoment-api-txn-id ()
  "Return a new transaction id."
  (concat "neoment-el-" (neoment-api-uuid)))

(defun neoment-api-room-path (room-id &rest segments)
  "Return the client API path of ROOM-ID followed by SEGMENTS."
  (concat "/_matrix/client/v3/rooms/" (neoment-api-encode room-id)
          (mapconcat (lambda (s) (concat "/" (neoment-api-encode s))) segments "")))

(defun neoment-api-send-event (room-id type content callback)
  "Send an event of TYPE with CONTENT to ROOM-ID.
CALLBACK receives (:ok EVENT-ID) or (:error ERR)."
  (neoment-api-request
   'put (neoment-api-room-path room-id "send" type (neoment-api-txn-id))
   :json content
   :callback (lambda (result)
               (funcall callback
                        (if (plist-get result :error)
                            result
                          (list :ok (alist-get 'event_id (plist-get result :ok))))))))

(defun neoment-api-redact (room-id event-id reason callback)
  "Redact EVENT-ID in ROOM-ID with REASON and call CALLBACK."
  (neoment-api-request
   'put (neoment-api-room-path room-id "redact" event-id (neoment-api-txn-id))
   :json `((reason . ,(or reason "")))
   :callback callback))

(defun neoment-api-set-read-markers (room-id markers &optional callback)
  "Set the read MARKERS of ROOM-ID, updating the local state first.
MARKERS is a plist with :fully-read, :read and :read-private event
ids.  CALLBACK, if non-nil, receives the result."
  (let ((room (neoment-has-room room-id))
        (fully-read (plist-get markers :fully-read))
        (read (or (plist-get markers :read) (plist-get markers :read-private))))
    (when room
      (when fully-read
        (setf (neoment-room-fully-read room) fully-read))
      (when read
        (let ((message (neoment-room-find-message room read)))
          (setf (neoment-room-read-receipt room)
                (list :event-id read
                      :ts (or (and message (neoment-message-timestamp message))
                              (neoment--now-ms))
                      :is-local t))))
      (setf (neoment-room-unread room) nil))
    (neoment-api-request
     'post (neoment-api-room-path room-id "read_markers")
     :json (delq nil (list (and fully-read (cons 'm.fully_read fully-read))
                           (and (plist-get markers :read)
                                (cons 'm.read (plist-get markers :read)))
                           (and (plist-get markers :read-private)
                                (cons 'm.read.private
                                      (plist-get markers :read-private)))))
     :callback (or callback #'ignore))))

(defun neoment-api-server-name ()
  "Return the server name of the current user."
  (let ((user (neoment-user-id)))
    (if (and user (string-match ":\\(.+\\)\\'" user))
        (match-string 1 user)
      (url-host (url-generic-parse-url
                 (neoment-client-homeserver neoment--client))))))

(defun neoment-api-join (id-or-alias via callback)
  "Join the room ID-OR-ALIAS through the servers VIA.
CALLBACK receives (:ok ROOM-ID) or (:error ERR)."
  (neoment-api-request
   'post (concat "/_matrix/client/v3/join/" (neoment-api-encode id-or-alias))
   :query `((via . ,(delete-dups (append (list (neoment-api-server-name) "matrix.org")
                                         via))))
   :callback (lambda (result)
               (if (plist-get result :error)
                   (funcall callback result)
                 (let ((room-id (alist-get 'room_id (plist-get result :ok))))
                   (when room-id
                     (remhash room-id (neoment-client-invited-rooms neoment--client)))
                   (funcall callback (list :ok room-id)))))))

(defun neoment-api-leave (room-id callback)
  "Leave ROOM-ID and call CALLBACK.
M_FORBIDDEN counts as success.  On success the room is forgotten."
  (neoment-api-request
   'post (neoment-api-room-path room-id "leave")
   :callback (lambda (result)
               (let ((err (plist-get result :error)))
                 (if (and err (not (equal (plist-get err :errcode) "M_FORBIDDEN")))
                     (funcall callback result)
                   (neoment-remove-room room-id)
                   (funcall callback (list :ok nil)))))))

(defun neoment-api-set-tag (room-id tag add callback)
  "Add (when ADD) or remove TAG on ROOM-ID and call CALLBACK."
  (neoment-api-request
   (if add 'put 'delete)
   (format "/_matrix/client/v3/user/%s/rooms/%s/tags/%s"
           (neoment-api-encode (neoment-user-id)) (neoment-api-encode room-id)
           (neoment-api-encode tag))
   :json (and add '((order . 0)))
   :callback callback))

(defun neoment-api-create-dm (user-id callback)
  "Create a direct message room with USER-ID.
CALLBACK receives (:ok ROOM-ID) or (:error ERR)."
  (neoment-api-request
   'post "/_matrix/client/v3/createRoom"
   :json `((invite . [,user-id]) (is_direct . t) (preset . "trusted_private_chat"))
   :callback (lambda (result)
               (funcall callback
                        (if (plist-get result :error)
                            result
                          (list :ok (alist-get 'room_id (plist-get result :ok))))))))

(provide 'neoment-http)
;;; neoment-http.el ends here
