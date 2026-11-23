;;; neoment-http-url-test.el --- Tests for the url.el HTTP backend  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task 12.6 of the port: `plz' is optional and requests fall back to
;; `url.el'.  These tests talk to a real HTTP server on the loopback
;; interface, so `url-retrieve' itself is exercised.

;;; Code:

(require 'test-helper)
(require 'neoment-http)

(defvar neoment-url-test--requests nil
  "Raw requests received by the test server, newest first.")

(defun neoment-url-test--complete-p (data)
  "Return non-nil when the raw request DATA is complete."
  (when (string-match "\r\n\r\n" data)
    (let ((header-end (match-end 0)))
      (if (string-match "^Content-Length: *\\([0-9]+\\)" data)
          (>= (- (length data) header-end) (string-to-number (match-string 1 data)))
        t))))

(defun neoment-url-test-server (handler)
  "Start an HTTP server answering with HANDLER.
HANDLER gets the raw request and returns (STATUS HEADERS BODY), or nil
to never answer.  Return the server process."
  (make-network-process
   :name "neoment-url-test" :server t :host "127.0.0.1" :service t :family 'ipv4
   :coding 'binary :noquery t
   :filter (lambda (proc chunk)
             (let ((data (concat (or (process-get proc 'data) "") chunk)))
               (process-put proc 'data data)
               (when (neoment-url-test--complete-p data)
                 (push data neoment-url-test--requests)
                 (pcase (funcall handler data)
                   (`(,status ,headers ,body)
                    (process-send-string
                     proc
                     (concat (format "HTTP/1.1 %s\r\n" status)
                             (mapconcat (lambda (h) (concat h "\r\n")) headers "")
                             (format "Content-Length: %d\r\nConnection: close\r\n\r\n"
                                     (length body))
                             body))
                    (process-send-eof proc))))))))

(defun neoment-url-test-port (server)
  "Return the port of SERVER."
  (process-contact server :service))

(defun neoment-url-test-wait (predicate &optional seconds)
  "Process input until PREDICATE returns non-nil or SECONDS pass."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(defmacro neoment-url-test (handler &rest body)
  "Run BODY with `port' bound to a test server answering with HANDLER."
  (declare (indent 1))
  `(let* ((neoment-url-test--requests nil)
          (neoment-http-backend 'url)
          (url-show-status nil)
          (server (neoment-url-test-server ,handler))
          (port (neoment-url-test-port server)))
     (unwind-protect (progn ,@body)
       (delete-process server))))

(defun neoment-url-test-request (&rest args)
  "Send `neoment-http-request' with ARGS and wait for its result."
  (let* ((result nil)
         (done nil))
    (apply #'neoment-http-request
           :callback (lambda (r) (setq result r done t))
           args)
    (neoment-url-test-wait (lambda () done))
    result))

;;;; Backend selection

(ert-deftest neoment-http-backend-selection ()
  (let ((neoment-http-backend 'url))
    (should (eq (neoment-http-backend) 'url)))
  (let ((neoment-http-backend 'plz))
    (should (eq (neoment-http-backend) 'plz)))
  (let ((neoment-http-backend 'auto))
    (should (eq (neoment-http-backend) 'plz))
    (cl-letf (((symbol-function 'featurep) (lambda (&rest _) nil))
              ((symbol-function 'require) (lambda (&rest _) nil)))
      (should (eq (neoment-http-backend) 'url))))
  ;; Forcing plz when it is missing gives an error, not a crash.
  (let ((neoment-http-backend 'plz) result)
    (cl-letf (((symbol-function 'fboundp) (lambda (f) (not (eq f 'plz)))))
      (neoment-http-request :url "http://127.0.0.1:1/x" :callback (lambda (r) (setq result r))))
    (should (equal (plist-get (plist-get result :error) :error)
                   "The plz package is not installed")))
  (should (memq 'neoment-http-backend
                (mapcar #'car neoment-config--choices))))

;;;; Requests

(ert-deftest neoment-http-url-success-json ()
  (neoment-url-test (lambda (_) '("200 OK" ("Content-Type: application/json")
                                  "{\"name\":\"caf\303\251\",\"n\":[1,2]}"))
    (let ((result (neoment-url-test-request
                   :method 'post :url (format "http://127.0.0.1:%d/a" port)
                   :query '((x . "a b")) :json '((k . "v")) :headers '(("X-Test" . "1")))))
      (should (equal result '(:ok ((name . "café") (n 1 2)))))
      (let ((raw (car neoment-url-test--requests)))
        (should (string-prefix-p "POST /a?x=a%20b HTTP/1.1" raw))
        (should (string-search "X-Test: 1" raw))
        (should (string-search "Content-Type: application/json" raw))
        (should (string-suffix-p "{\"k\":\"v\"}" raw))))))

(ert-deftest neoment-http-url-form-and-empty-post ()
  (neoment-url-test (lambda (_) '("200 OK" () "{}"))
    (neoment-url-test-request :method 'post :url (format "http://127.0.0.1:%d/t" port)
                              :form '((grant_type . "device_code") (scope . "a b")))
    (should (string-suffix-p "grant_type=device_code&scope=a%20b" (car neoment-url-test--requests)))
    (neoment-url-test-request :method 'put :url (format "http://127.0.0.1:%d/p" port))
    (should (string-prefix-p "PUT /p" (car neoment-url-test--requests)))
    (should (string-suffix-p "{}" (car neoment-url-test--requests)))))

(ert-deftest neoment-http-url-matrix-error ()
  (neoment-url-test (lambda (_) '("401 Unauthorized" ("Content-Type: application/json")
                                  "{\"errcode\":\"M_UNKNOWN_TOKEN\",\"error\":\"Bad\",\"soft_logout\":true}"))
    (let* ((result (neoment-url-test-request :url (format "http://127.0.0.1:%d/a" port)
                                             :headers '(("Authorization" . "Bearer T"))))
           (err (plist-get result :error)))
      (should (= (plist-get err :status) 401))
      (should (equal (plist-get err :errcode) "M_UNKNOWN_TOKEN"))
      (should (equal (plist-get err :error) "Bad"))
      (should (eq (plist-get err :soft-logout) t))
      (should-not (neoment-http-transient-p err))))
  (neoment-url-test (lambda (_) '("503 Service Unavailable" () "busy"))
    (let ((err (plist-get (neoment-url-test-request :url (format "http://127.0.0.1:%d/a" port))
                          :error)))
      (should (= (plist-get err :status) 503))
      (should (neoment-http-transient-p err)))))

(ert-deftest neoment-http-url-network-failure ()
  (let* ((neoment-http-backend 'url)
         (url-show-status nil)
         (server (neoment-url-test-server #'ignore))
         (port (neoment-url-test-port server)))
    (delete-process server)
    (let ((err (plist-get (neoment-url-test-request :url (format "http://127.0.0.1:%d/a" port))
                          :error)))
      (should err)
      (should-not (plist-get err :status))
      (should (stringp (plist-get err :error)))
      (should (neoment-http-transient-p err)))))

(ert-deftest neoment-http-url-timeout ()
  (neoment-url-test (lambda (_) nil)
    (let ((start (float-time))
          (result (neoment-url-test-request :url (format "http://127.0.0.1:%d/sync" port)
                                            :timeout 0.5)))
      (should (equal result '(:error (:status nil :error "Operation timed out"))))
      (should (neoment-http-transient-p (plist-get result :error)))
      (should (< (- (float-time) start) 4)))))

(ert-deftest neoment-http-url-no-exit-query ()
  (neoment-url-test (lambda (_) nil)
    (let ((process (neoment-http-request :url (format "http://127.0.0.1:%d/sync" port)
                                         :timeout 2 :callback #'ignore)))
      (should (processp process))
      (should-not (process-query-on-exit-flag process))
      (delete-process process))))

(ert-deftest neoment-http-url-binary-download-and-upload ()
  (let ((bytes (apply #'unibyte-string (number-sequence 0 255)))
        (dir (make-temp-file "neoment-url" t)))
    (unwind-protect
        (progn
          (neoment-url-test (lambda (_) (list "200 OK" '("Content-Type: image/png") bytes))
            (let* ((file (expand-file-name "out.bin" dir))
                   (result (neoment-url-test-request
                            :url (format "http://127.0.0.1:%d/media" port)
                            :as 'file :output-file file)))
              (should (equal result (list :ok file)))
              (should (equal (neoment-http--file-bytes file) bytes))))
          (neoment-url-test (lambda (_) '("200 OK" () "{\"content_uri\":\"mxc://s/u\"}"))
            (let ((file (expand-file-name "in.bin" dir)))
              (let ((coding-system-for-write 'binary))
                (write-region bytes nil file nil 'silent))
              (should (equal (neoment-url-test-request
                              :method 'post :url (format "http://127.0.0.1:%d/upload" port)
                              :body-file file :content-type "image/png")
                             '(:ok ((content_uri . "mxc://s/u")))))
              (let ((raw (car neoment-url-test--requests)))
                (should (string-search "Content-Type: image/png" raw))
                (should (string-suffix-p bytes raw))))))
      (delete-directory dir t))))

(provide 'neoment-http-url-test)
;;; neoment-http-url-test.el ends here
