;;; test-helper.el --- Helpers for the Neoment tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared fixtures: a temporary `user-emacs-directory', a fresh client,
;; captured messages and a fake HTTP layer.

;;; Code:

(require 'ert)
(require 'cl-lib)

(setq load-prefer-newer t)

(defvar neoment-test--messages nil
  "Messages captured by `neoment-test-with-messages'.")

(defmacro neoment-test-with-temp-dir (&rest body)
  "Run BODY with `user-emacs-directory' bound to a new temporary directory."
  (declare (indent 0))
  `(let* ((user-emacs-directory (file-name-as-directory
                                 (make-temp-file "neoment-test" t))))
     (unwind-protect (progn ,@body)
       (delete-directory user-emacs-directory t))))

(defmacro neoment-test-with-messages (&rest body)
  "Run BODY capturing Neoment messages in `neoment-test--messages'.
The messages are in the order they were shown."
  (declare (indent 0))
  `(let ((neoment-test--messages nil)
         (neoment-notifier (lambda (msg _level)
                             (setq neoment-test--messages
                                   (append neoment-test--messages (list msg))))))
     ,@body))

(defun neoment-test-message-p (text)
  "Return non-nil when \"[Neoment] TEXT\" was shown."
  (member (concat "[Neoment] " text) neoment-test--messages))

(defvar neoment-test--requests nil
  "Requests captured by `neoment-test-with-http', newest last.")

(defmacro neoment-test-with-http (handler &rest body)
  "Run BODY with `neoment-http-request' replaced by HANDLER.
HANDLER is called with the request plist and returns the result
passed to the callback, or the symbol `pending' to keep the request
unanswered.  Requests are recorded in `neoment-test--requests'."
  (declare (indent 1))
  `(let ((neoment-test--requests nil)
         (handler ,handler))
     (cl-letf (((symbol-function 'neoment-http-request)
                (lambda (&rest args)
                  (setq neoment-test--requests
                        (append neoment-test--requests (list args)))
                  (let ((result (funcall handler args)))
                    (unless (eq result 'pending)
                      (funcall (plist-get args :callback) result)))
                  nil)))
       ,@body)))

(defun neoment-test-request-urls ()
  "Return the URLs of the captured requests."
  (mapcar (lambda (r) (plist-get r :url)) neoment-test--requests))

(defun neoment-test-new-client (&optional user-id)
  "Install a fresh logged-in client for USER-ID (default @me:s)."
  (require 'neoment-client)
  (setq neoment--client
        (neoment-client--create :homeserver "https://hs.example"
                                :user-id (or user-id "@me:s")
                                :access-token "TOKEN")))

(defun neoment-test-event (type &rest props)
  "Build an event alist of TYPE from the plist PROPS.
PROPS keys are :id, :sender, :ts, :content, :state-key, :unsigned."
  (let ((event `((type . ,type)
                 (event_id . ,(or (plist-get props :id) (format "$%s" (random 100000000))))
                 (sender . ,(or (plist-get props :sender) "@alice:s"))
                 (origin_server_ts . ,(or (plist-get props :ts) 1000))
                 (content . ,(plist-get props :content)))))
    (when (plist-member props :state-key)
      (setq event (append event `((state_key . ,(plist-get props :state-key))))))
    (when (plist-get props :unsigned)
      (setq event (append event `((unsigned . ,(plist-get props :unsigned))))))
    event))

(defun neoment-test-margin (line)
  "Return the left-margin string of LINE, or nil when it has none.
LINE is a rendered room line; its margin comes from a display property
on its first character."
  (let ((spec (and (> (length line) 0) (get-text-property 0 'display line))))
    (and (consp spec) (equal (car spec) '(margin left-margin))
         (cadr spec))))

(defun neoment-test-display (line)
  "Return LINE as a window shows it: its margin string, then its text.
The margin anchor character is left out.  The result has no properties."
  (let ((margin (neoment-test-margin line)))
    (substring-no-properties
     (if margin (concat margin (substring line 1)) line))))

(defun neoment-test-display-current-line ()
  "Return the current buffer line as a window shows it."
  (neoment-test-display (buffer-substring (line-beginning-position) (line-end-position))))

(provide 'test-helper)
;;; test-helper.el ends here
