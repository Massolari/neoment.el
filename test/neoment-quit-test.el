;;; neoment-quit-test.el --- Tests for neoment-quit  -*- lexical-binding: t; -*-

;;; Commentary:

;; The teardown helpers, `neoment-quit' and the room list `Q' wrapper.

;;; Code:

(require 'test-helper)
(require 'neoment)

(defmacro neoment-quit-test--capturing (&rest body)
  "Run BODY and return the messages it showed."
  `(let ((shown nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args) shown))))
       ,@body)
     (nreverse shown)))

(defun neoment-quit-test--sleep-process (name)
  "Start a long running process called NAME."
  (make-process :name name :command (list "sleep" "60") :noquery t))

(ert-deftest neoment-ui-cancel-timer-stops-render ()
  (let ((neoment-ui--dirty (make-hash-table :test 'eq))
        (neoment-ui--timer nil)
        (ran nil))
    (with-temp-buffer
      (neoment-ui-schedule (current-buffer) (lambda () (setq ran t)))
      (should (timerp neoment-ui--timer))
      (neoment-ui-cancel-timer)
      (should-not neoment-ui--timer)
      (should (zerop (hash-table-count neoment-ui--dirty)))
      (sleep-for 0.3)
      (should-not ran))))

(ert-deftest neoment-rooms-refresh-skipped-while-quitting ()
  (let ((neoment--quitting t)
        (buffer (generate-new-buffer " *neoment-rooms-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'neoment-rooms--buffer) (lambda () buffer))
                  ((symbol-function 'neoment-rooms-render)
                   (lambda (&rest _) (error "rendered"))))
          (neoment-rooms-refresh))
      (kill-buffer buffer))))

(ert-deftest neoment-media-shutdown-removes-mpv ()
  (let ((buffer (get-buffer-create "*neoment-mpv*"))
        (process (neoment-quit-test--sleep-process "neoment-mpv"))
        (neoment-media--popup-timer (run-with-idle-timer 100 nil #'ignore)))
    (get-buffer-create neoment-media--posframe-buffer)
    (let ((timer neoment-media--popup-timer))
      (neoment-media-shutdown)
      (should-not (memq timer timer-idle-list)))
    (should-not neoment-media--popup-timer)
    (should-not (process-live-p process))
    (should-not (buffer-live-p buffer))
    (should-not (get-buffer neoment-media--posframe-buffer))))

(ert-deftest neoment-notify-shutdown-removes-process ()
  (let ((process (neoment-quit-test--sleep-process "neoment-notify")))
    (neoment-notify-shutdown)
    (should-not (process-live-p process))))

(ert-deftest neoment-event-buffer-is-marked ()
  (neoment-test-with-temp-dir
    (let ((neoment--client nil))
      (neoment-test-new-client)
      (let* ((room (neoment-get-room "!r:s"))
             (event (list (cons 'event_id "$e") (cons 'type "m.room.message")))
             (message 'fake))
        (puthash "$e" event (neoment-room-events room))
        (with-temp-buffer
          (setq neoment--room-id "!r:s")
          (cl-letf (((symbol-function 'neoment-room-message-at-point) (lambda (&rest _) message))
                    ((symbol-function 'neoment-message-effective-id) (lambda (_) "$e"))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (neoment-room-show-event))
          (let ((buffer (get-buffer "*Event: $e*")))
            (unwind-protect
                (progn (should buffer)
                       (should (buffer-local-value 'neoment-room--event-buffer-p buffer)))
              (when buffer (kill-buffer buffer)))))))))

(ert-deftest neoment-quit-kills-everything-and-keeps-session ()
  (neoment-test-with-temp-dir
    (neoment-test-with-messages
      (let ((neoment--client nil) (neoment--quitting nil)
            (stopped nil) (buffers nil) (shown nil)
            (file (expand-file-name "data.json" user-emacs-directory)))
        (with-temp-file file (insert "{}"))
        (dolist (mode '(neoment-room-mode neoment-rooms-mode neoment-compose-mode
                        neoment-space-mode neoment-room-info-mode
                        neoment-notification-settings-mode))
          (with-current-buffer (generate-new-buffer " *neoment-quit-test*")
            (let ((neoment-room-mode-hook nil) (neoment-compose-mode-hook nil))
              (cl-letf (((symbol-function mode) (lambda () (setq major-mode mode))))
                (funcall mode)))
            (insert "unsent")
            (push (current-buffer) buffers)))
        (with-current-buffer (generate-new-buffer " *neoment-quit-event*")
          (setq neoment-room--event-buffer-p t)
          (push (current-buffer) buffers))
        (let ((other (generate-new-buffer " *neoment-other*")))
          (setq shown
                (neoment-quit-test--capturing
                 (cl-letf (((symbol-function 'neoment-sync-stop)
                            (lambda (&optional silent) (setq stopped (list 'silent silent)))))
                   (neoment-quit))))
          (should (equal stopped '(silent t)))
          (dolist (buffer buffers) (should-not (buffer-live-p buffer)))
          (should (buffer-live-p other))
          (kill-buffer other))
        (should (file-exists-p file))
        (should (equal shown '("Neoment closed")))
        (should neoment--quitting)
        (sleep-for 0.1)
        (should-not neoment--quitting)))))

(ert-deftest neoment-quit-with-nothing-open ()
  (let ((neoment--client nil) (neoment--quitting nil))
    (should (equal (neoment-quit-test--capturing (neoment-quit))
                   '("Neoment closed")))))

(ert-deftest neoment-rooms-quit-confirmed ()
  (let ((ran nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'neoment-quit) (lambda () (setq ran t))))
      (neoment-rooms-quit))
    (should ran)))

(ert-deftest neoment-rooms-quit-declined ()
  (let ((ran nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil))
              ((symbol-function 'neoment-quit) (lambda () (setq ran t))))
      (should (equal (neoment-quit-test--capturing (neoment-rooms-quit))
                     '("Operation canceled"))))
    (should-not ran)))

(ert-deftest neoment-rooms-quit-key ()
  (should (eq (keymap-lookup neoment-rooms-mode-map "Q") 'neoment-rooms-quit)))

(provide 'neoment-quit-test)
;;; neoment-quit-test.el ends here
