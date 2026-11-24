;;; neoment-player-test.el --- Tests for the audio player  -*- lexical-binding: t; -*-

;;; Commentary:

;; The IPC layer is tested against a fake mpv: a local-socket server
;; created in the test.  No real mpv is started.

;;; Code:

(require 'test-helper)
(require 'neoment-player)

(defvar neoment-player-test--received nil
  "Lines the fake mpv server received, oldest first.")

(defun neoment-player-test--wait (predicate &optional seconds)
  "Wait until PREDICATE is non-nil, for at most SECONDS (default 2)."
  (let ((deadline (+ (float-time) (or seconds 2))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall predicate)))

(defun neoment-player-test--socket-path ()
  "Return a fresh socket path."
  (make-temp-name (expand-file-name "neoment-test-" temporary-file-directory)))

(defmacro neoment-player-test-with-server (&rest body)
  "Run BODY connected to a fake mpv server.
The received JSON commands are in `neoment-player-test--received'; the
player state is installed as `neoment-player--state'."
  (declare (indent 0))
  `(let* ((socket (neoment-player-test--socket-path))
          (neoment-player-test--received nil)
          (server (make-network-process
                   :name "fake-mpv" :server t :family 'local :service socket
                   :noquery t
                   :filter (lambda (_p s)
                             (dolist (line (split-string s "\n" t))
                               (setq neoment-player-test--received
                                     (append neoment-player-test--received
                                             (list line)))))))
          (neoment-player--state
           (neoment-player--state-create :socket socket :file "/tmp/voice.ogg"
                                         :speed 1.0)))
     (unwind-protect
         (progn
           (neoment-player--attach neoment-player--state socket)
           (neoment-player-test--wait
            (lambda () (>= (length neoment-player-test--received) 6)))
           (setq neoment-player-test--received nil)
           ,@body)
       (neoment-player--stop)
       (delete-process server)
       (ignore-errors (delete-file socket)))))

(defun neoment-player-test--last ()
  "Wait for and return the last command the fake server received."
  (neoment-player-test--wait (lambda () neoment-player-test--received))
  (car (last neoment-player-test--received)))

;;;; IPC

(ert-deftest neoment-player-property-updates ()
  (let ((state (neoment-player--state-create)))
    (neoment-player--filter
     state "{\"event\":\"property-change\",\"name\":\"pause\",\"data\":true}\n")
    (should (neoment-player--state-pause state))
    (neoment-player--filter
     state "{\"event\":\"property-change\",\"name\":\"speed\",\"data\":1.5}\n")
    (should (= (neoment-player--state-speed state) 1.5))))

(ert-deftest neoment-player-partial-line-buffered ()
  (let ((state (neoment-player--state-create)))
    (neoment-player--filter
     state "{\"event\":\"property-change\",\"name\":\"time-p")
    (should-not (neoment-player--state-time state))
    (neoment-player--filter state "os\",\"data\":42.5}\n{\"event\":\"property-change\"")
    (should (= (neoment-player--state-time state) 42.5))
    (neoment-player--filter state ",\"name\":\"mute\",\"data\":true}\n")
    (should (neoment-player--state-mute state))))

(ert-deftest neoment-player-observes-properties ()
  (let* ((socket (neoment-player-test--socket-path))
         (received nil)
         (client nil)
         (server (make-network-process
                  :name "fake-mpv" :server t :family 'local :service socket
                  :noquery t
                  :filter (lambda (p s) (setq client p received (concat received s)))))
         (state (neoment-player--state-create :socket socket)))
    (unwind-protect
        (progn
          (neoment-player--attach state socket)
          (neoment-player-test--wait (lambda () (>= (length (split-string (or received "") "\n" t)) 6)))
          (dolist (property '("pause" "time-pos" "duration" "speed" "volume" "mute"))
            (should (string-match-p
                     (format "\"observe_property\",[0-9]+,\"%s\"" property) received)))
          ;; Updates sent by the server reach the state.
          (process-send-string client
                               "{\"event\":\"property-change\",\"name\":\"volume\",\"data\":80.0}\n")
          (should (neoment-player-test--wait
                   (lambda () (neoment-player--state-volume state)))))
      (neoment-player--cleanup state)
      (delete-process server)
      (ignore-errors (delete-file socket)))))

;;;; Lifecycle

(defconst neoment-player-test--real-make-process (symbol-function 'make-process)
  "The real `make-process', for stubs that still need to start a process.")

(defun neoment-player-test--stub-make-process (&optional create-socket)
  "Return a `make-process' replacement that starts `sleep' instead of mpv.
With CREATE-SOCKET, create a plain file at the requested socket path."
  (lambda (&rest args)
    (when create-socket
      (let ((arg (cl-find-if (lambda (a) (string-prefix-p "--input-ipc-server=" a))
                             (plist-get args :command))))
        (write-region "" nil (substring arg (length "--input-ipc-server=")))))
    (funcall neoment-player-test--real-make-process :name "fake-mpv-proc" :command '("sleep" "30") :noquery t
                  :buffer (plist-get args :buffer)
                  :sentinel (plist-get args :sentinel))))

(ert-deftest neoment-player-start-failure-no-socket ()
  (neoment-test-with-messages
    (let ((neoment-player--connect-tries 3)
          process)
      (cl-letf (((symbol-function 'make-process)
                 (let ((stub (neoment-player-test--stub-make-process)))
                   (lambda (&rest args)
                     (setq process (apply stub args))
                     process)))
                ((symbol-function 'display-buffer) #'ignore))
        (neoment-player-play "/tmp/a.ogg")
        (should (neoment-player-test--wait
                 (lambda () (null neoment-player--state))))
        (should (cl-some (lambda (m) (string-prefix-p "[Neoment] Could not start mpv" m))
                         neoment-test--messages))
        (should-not (process-live-p process))))))

(ert-deftest neoment-player-socket-removed-on-failure ()
  "A socket file that cannot be connected to is deleted."
  (neoment-test-with-messages
    (let (socket)
      (cl-letf (((symbol-function 'make-process)
                 (let ((stub (neoment-player-test--stub-make-process t)))
                   (lambda (&rest args)
                     (setq socket (substring
                                   (cl-find-if (lambda (a) (string-prefix-p "--input-ipc-server=" a))
                                               (plist-get args :command))
                                   (length "--input-ipc-server=")))
                     (apply stub args))))
                ((symbol-function 'display-buffer) #'ignore))
        (neoment-player-play "/tmp/a.ogg")
        (should (neoment-player-test--wait (lambda () (null neoment-player--state))))
        (should-not (file-exists-p socket))
        (should (cl-some (lambda (m) (string-prefix-p "[Neoment] Could not start mpv" m))
                         neoment-test--messages))))))

(ert-deftest neoment-player-eof-shows-finished ()
  (neoment-test-with-messages
    (let* ((socket (neoment-player-test--socket-path))
           (process (make-process :name "dead" :command '("true") :noquery t))
           (neoment-player--state
            (neoment-player--state-create :socket socket :process process :eof t
                                          :file "/tmp/a.ogg" :connection t)))
      (write-region "" nil socket)
      (cl-letf (((symbol-function 'delete-process) #'ignore))
        (neoment-player-test--wait (lambda () (not (process-live-p process))))
        (neoment-player--sentinel neoment-player--state process "finished\n"))
      (should (neoment-test-message-p "Playback finished"))
      (should-not neoment-player--state)
      (should-not (file-exists-p socket)))))

(ert-deftest neoment-player-stop-kills-process ()
  (let* ((socket (neoment-player-test--socket-path))
         (process (make-process :name "sleeper" :command '("sleep" "30") :noquery t))
         (neoment-player--state
          (neoment-player--state-create :socket socket :process process
                                        :file "/tmp/a.ogg")))
    (write-region "" nil socket)
    (should (neoment-player--stop))
    (should-not (process-live-p process))
    (should-not (file-exists-p socket))
    (should-not neoment-player--state)
    (should-not (neoment-player--stop))))

(ert-deftest neoment-player-kill-emacs-hook ()
  (should (memq #'neoment-player--stop kill-emacs-hook)))

;;;; Controls

(ert-deftest neoment-player-no-audio ()
  (let ((neoment-player--state nil))
    (dolist (command '(neoment-player-toggle-pause neoment-player-seek-backward
                       neoment-player-seek-forward neoment-player-speed-up
                       neoment-player-speed-down neoment-player-speed-reset
                       neoment-player-stop))
      (let ((err (should-error (funcall command) :type 'user-error)))
        (should (equal (cadr err) "No audio playing"))))))

(ert-deftest neoment-player-commands-sent ()
  (neoment-player-test-with-server
    (let ((neoment-player-seek-step 10)
          (neoment-player-speed-step 0.25))
      (neoment-player-toggle-pause)
      (should (equal (neoment-player-test--last) "{\"command\":[\"cycle\",\"pause\"]}"))
      (setq neoment-player-test--received nil)
      (neoment-player-seek-backward)
      (should (equal (neoment-player-test--last) "{\"command\":[\"seek\",-10,\"relative\"]}"))
      (setq neoment-player-test--received nil)
      (neoment-player-seek-forward)
      (should (equal (neoment-player-test--last) "{\"command\":[\"seek\",10,\"relative\"]}"))
      (setq neoment-player-test--received nil)
      (neoment-player-speed-up)
      (should (equal (neoment-player-test--last)
                     "{\"command\":[\"set_property\",\"speed\",1.25]}"))
      (setq neoment-player-test--received nil)
      (neoment-player-speed-reset)
      (should (equal (neoment-player-test--last)
                     "{\"command\":[\"set_property\",\"speed\",1.0]}")))))

(ert-deftest neoment-player-speed-clamped ()
  (neoment-player-test-with-server
    (setf (neoment-player--state-speed neoment-player--state) 0.25)
    (neoment-player-speed-down)
    (should (equal (neoment-player-test--last)
                   "{\"command\":[\"set_property\",\"speed\",0.25]}"))))

;;;; Key forwarding

(ert-deftest neoment-player-key-names ()
  (pcase-dolist (`(,event . ,name)
                 `((?a . "a") (?\] . "]") (?\s . "SPACE") (13 . "ENTER")
                   (9 . "TAB") (127 . "BS") (left . "LEFT") (prior . "PGUP")
                   (next . "PGDWN") (f5 . "F5") (?é . "é")
                   (,(aref (kbd "C-x") 0) . nil)
                   (,(aref (kbd "M-x") 0) . nil)
                   (C-left . nil)))
    (should (equal (neoment-player--key-name event) name))))

(ert-deftest neoment-player-forward-key-sends-keypress ()
  (neoment-player-test-with-server
    (let ((last-command-event ?\]))
      (neoment-player-forward-key)
      (should (equal (neoment-player-test--last)
                     "{\"command\":[\"keypress\",\"]\"]}")))
    (setq neoment-player-test--received nil)
    (let ((last-command-event 'left))
      (neoment-player-forward-key)
      (should (equal (neoment-player-test--last)
                     "{\"command\":[\"keypress\",\"LEFT\"]}")))))

;;;; Buffer

(ert-deftest neoment-player-render ()
  (let ((state (neoment-player--state-create
                :file "/tmp/voice.ogg" :time 42.4 :duration 75.0 :speed 1.5
                :volume 80.0 :mute t)))
    (let ((text (neoment-player--format state)))
      (should (string-match-p "▶" text))
      (should (string-match-p "voice.ogg" text))
      (should (string-match-p "0:42 / 1:15" text))
      (should (string-match-p "1\\.5x" text))
      (should (string-match-p "vol 80" text))
      (should (string-match-p "muted" text)))
    (setf (neoment-player--state-pause state) t
          (neoment-player--state-speed state) 1.0
          (neoment-player--state-mute state) nil)
    (let ((text (neoment-player--format state)))
      (should (string-match-p "⏸" text))
      (should-not (string-match-p "[0-9]x" text))
      (should-not (string-match-p "muted" text)))))

(ert-deftest neoment-player-buffer-updates ()
  (let ((neoment-player--state (neoment-player--state-create :file "/tmp/v.ogg")))
    (unwind-protect
        (progn
          (neoment-player--filter
           neoment-player--state
           "{\"event\":\"property-change\",\"name\":\"time-pos\",\"data\":5.0}\n")
          (with-current-buffer neoment-player--buffer-name
            (should (string-match-p "0:05" (buffer-string)))
            (should buffer-read-only)))
      (kill-buffer neoment-player--buffer-name))))

(ert-deftest neoment-player-map-forwarding ()
  (let ((map (let ((neoment-player-forward-keys t)) (neoment-player--make-map))))
    (should-not (keymap-parent map))
    (should (eq (lookup-key map "]") 'neoment-player-forward-key))
    (should (eq (lookup-key map " ") 'neoment-player-forward-key))
    (should (eq (lookup-key map [left]) 'neoment-player-forward-key))
    (should (eq (lookup-key map [f12]) 'neoment-player-forward-key))
    (should (eq (lookup-key map (kbd "RET")) 'neoment-player-forward-key))
    (should (eq (lookup-key map "q") 'neoment-player-quit))
    (should-not (lookup-key map (kbd "C-x")))
    (should-not (lookup-key map (kbd "M-x")))))

(ert-deftest neoment-player-map-no-forwarding ()
  (let ((map (let ((neoment-player-forward-keys nil)) (neoment-player--make-map))))
    (should (eq (lookup-key map " ") 'neoment-player-toggle-pause))
    (should (eq (lookup-key map [left]) 'neoment-player-seek-backward))
    (should (eq (lookup-key map [right]) 'neoment-player-seek-forward))
    (should (eq (lookup-key map "[") 'neoment-player-speed-down))
    (should (eq (lookup-key map "]") 'neoment-player-speed-up))
    (should (eq (lookup-key map "=") 'neoment-player-speed-reset))
    (should (eq (lookup-key map "q") 'neoment-player-quit))
    (should-not (lookup-key map "m"))))

(ert-deftest neoment-player-quit-stops ()
  (let* ((process (make-process :name "sleeper" :command '("sleep" "30") :noquery t))
         (neoment-player--state
          (neoment-player--state-create :process process :file "/tmp/a.ogg")))
    (neoment-player--render neoment-player--state)
    (with-current-buffer neoment-player--buffer-name
      (should (eq (key-binding "q") 'neoment-player-quit))
      (call-interactively (key-binding "q")))
    (should-not neoment-player--state)
    (should-not (process-live-p process))
    (should-not (get-buffer neoment-player--buffer-name))))

(ert-deftest neoment-player-command-line ()
  (let (command)
    (cl-letf (((symbol-function 'make-process)
               (let ((stub (neoment-player-test--stub-make-process)))
                 (lambda (&rest args)
                   (setq command (plist-get args :command))
                   (apply stub args))))
              ((symbol-function 'display-buffer) #'ignore)
              (neoment-player--state nil)
              (neoment-player-mpv-arguments '("--volume=70")))
      (unwind-protect
          (progn
            (neoment-player-play "/tmp/-a.ogg")
            (should (equal (car command) "mpv"))
            (dolist (arg '("--no-terminal" "--no-video" "--keep-open=no"))
              (should (member arg command)))
            (should (cl-some (lambda (a) (string-prefix-p "--input-ipc-server=" a))
                             command))
            ;; Extra arguments come after the defaults so they can override.
            (should (< (cl-position "--keep-open=no" command :test #'equal)
                       (cl-position "--volume=70" command :test #'equal)))
            ;; The file follows `--' so a leading dash is not an option.
            (should (equal (last command 2) '("--" "/tmp/-a.ogg"))))
        (neoment-player--stop)))))

(ert-deftest neoment-player-second-play-replaces-first ()
  (let (processes)
    (cl-letf (((symbol-function 'make-process)
               (let ((stub (neoment-player-test--stub-make-process)))
                 (lambda (&rest args)
                   (let ((p (apply stub args))) (push p processes) p))))
              ((symbol-function 'display-buffer) #'ignore)
              (neoment-player--state nil))
      (unwind-protect
          (progn
            (neoment-player-play "/tmp/a.ogg")
            (neoment-player-play "/tmp/b.ogg")
            (should (= (length processes) 2))
            (should-not (process-live-p (cadr processes)))
            (should (process-live-p (car processes)))
            (should (equal (neoment-player--state-file neoment-player--state)
                           "/tmp/b.ogg")))
        (neoment-player--stop)))))

;;;; Menu

(ert-deftest neoment-player-menu-suffixes ()
  (should (commandp 'neoment-player-menu))
  (let (commands)
    (cl-labels ((walk (x)
                  (cond ((and (listp x) (plist-get (cdr-safe x) :command))
                         (push (plist-get (cdr x) :command) commands))
                        ((vectorp x) (mapc #'walk x))
                        ((consp x) (mapc #'walk x)))))
      (walk (get 'neoment-player-menu 'transient--layout)))
    (dolist (command '(neoment-player-toggle-pause neoment-player-seek-backward
                       neoment-player-seek-forward neoment-player-speed-up
                       neoment-player-speed-down neoment-player-speed-reset
                       neoment-player-stop))
      (should (memq command commands)))))

(ert-deftest neoment-player-room-key ()
  (require 'neoment-room)
  (should (eq (lookup-key neoment-room-mode-map "O") 'neoment-player-menu)))

(provide 'neoment-player-test)
;;; neoment-player-test.el ends here
