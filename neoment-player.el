;;; neoment-player.el --- Audio player controlled over mpv IPC  -*- lexical-binding: t; -*-

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

;; Plays audio with `mpv' and controls it from Emacs through mpv's JSON
;; IPC (a unix socket): pause, seek, speed, and forwarding of the keys
;; typed in the `*neoment-player*' buffer.  One player exists at a time.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'transient)
(require 'neoment-config)
(require 'neoment-notify)

(defconst neoment-player--buffer-name "*neoment-player*"
  "Name of the buffer that shows the playback state.")

(cl-defstruct (neoment-player--state (:constructor neoment-player--state-create))
  "State of the running player."
  process connection socket directory file timer output (partial "")
  pause time duration speed volume mute
  eof stopped done rendered)

(defvar neoment-player--connect-tries 100
  "How many times to connect to the mpv socket, 50 ms apart.")

(defvar neoment-player--state nil
  "The current `neoment-player--state', or nil when nothing plays.")

;;;; IPC

(defun neoment-player--send (state &rest command)
  "Send COMMAND (a list of strings and numbers) to mpv over STATE."
  (process-send-string
   (neoment-player--state-connection state)
   (concat (json-serialize (list :command (vconcat command))) "\n")))

(defun neoment-player--command (&rest command)
  "Send COMMAND to the current player, or signal `No audio playing'."
  (let ((state neoment-player--state))
    (unless (and state (neoment-player--state-connection state)
                 (process-live-p (neoment-player--state-connection state)))
      (user-error "No audio playing"))
    (apply #'neoment-player--send state command)))

(defun neoment-player--handle-line (state line)
  "Update STATE from the JSON LINE sent by mpv."
  (when-let* ((msg (ignore-errors
                     (json-parse-string line :object-type 'plist
                                        :false-object nil :null-object nil)))
              (event (plist-get msg :event)))
    (cond
     ((equal event "property-change")
      (let ((data (plist-get msg :data)))
        (pcase (plist-get msg :name)
          ("pause" (setf (neoment-player--state-pause state) data))
          ("time-pos" (setf (neoment-player--state-time state) data))
          ("duration" (setf (neoment-player--state-duration state) data))
          ("speed" (setf (neoment-player--state-speed state) data))
          ("volume" (setf (neoment-player--state-volume state) data))
          ("mute" (setf (neoment-player--state-mute state) data)))
        (neoment-player--render state)))
     ((and (equal event "end-file") (equal (plist-get msg :reason) "eof"))
      (setf (neoment-player--state-eof state) t)))))

(defun neoment-player--filter (state string)
  "Process filter: buffer STRING and handle the complete lines for STATE."
  (let ((data (concat (neoment-player--state-partial state) string)))
    (while (string-match "\n" data)
      (let ((line (substring data 0 (match-beginning 0))))
        (setq data (substring data (match-end 0)))
        (unless (string-empty-p line)
          (neoment-player--handle-line state line))))
    (setf (neoment-player--state-partial state) data)))

(defun neoment-player--attach (state socket)
  "Connect STATE to the mpv control SOCKET and observe its properties.
Signal an error when the socket cannot be opened."
  (let ((connection (make-network-process
                     :name "neoment-mpv-ipc" :family 'local :service socket
                     :coding 'utf-8 :noquery t
                     :filter (lambda (_proc string)
                               (neoment-player--filter state string)))))
    (setf (neoment-player--state-connection state) connection)
    (cl-loop for property in '("pause" "time-pos" "duration"
                               "speed" "volume" "mute")
             for id from 1
             do (neoment-player--send state "observe_property" id property))
    connection))

;;;; Lifecycle

(defun neoment-player--cleanup (state)
  "Release everything STATE owns.  Safe to call more than once."
  (unless (neoment-player--state-done state)
    (setf (neoment-player--state-done state) t)
    (when-let* ((timer (neoment-player--state-timer state)))
      (cancel-timer timer))
    (when-let* ((connection (neoment-player--state-connection state)))
      (delete-process connection))
    (when-let* ((process (neoment-player--state-process state)))
      (when (process-live-p process) (delete-process process)))
    (when-let* ((socket (neoment-player--state-socket state)))
      (ignore-errors (delete-file socket)))
    (when-let* ((directory (neoment-player--state-directory state)))
      (ignore-errors (delete-directory directory t)))
    (when-let* ((output (neoment-player--state-output state)))
      (when (buffer-live-p output) (kill-buffer output)))
    (when (eq neoment-player--state state)
      (setq neoment-player--state nil)
      (when-let* ((buffer (get-buffer neoment-player--buffer-name)))
        (quit-windows-on buffer t)
        (kill-buffer buffer)))))

(defun neoment-player--stop ()
  "Stop the player if there is one.  Return non-nil when one was stopped."
  (when-let* ((state neoment-player--state))
    (setf (neoment-player--state-stopped state) t)
    (neoment-player--cleanup state)
    t))

(defun neoment-player--sentinel (state process _event)
  "Handle the exit of the mpv PROCESS of STATE."
  (unless (process-live-p process)
    ;; The eof event may still be unread on the socket; read it first.
    (when-let* ((connection (neoment-player--state-connection state)))
      (when (process-live-p connection)
        (accept-process-output connection 0.05)))
    (let ((finished (and (neoment-player--state-eof state)
                         (not (neoment-player--state-stopped state))
                         (not (neoment-player--state-done state)))))
      (if (and (not (neoment-player--state-connection state))
               (not (neoment-player--state-done state)))
          (neoment-player--fail state "mpv exited")
        (neoment-player--cleanup state)
        (when finished (neoment-notify--message "Playback finished"))))))

(defun neoment-player--fail (state reason)
  "Clean up STATE and report that mpv could not start, with REASON."
  (let* ((output (neoment-player--state-output state))
         (text (and (buffer-live-p output)
                    (string-trim (with-current-buffer output (buffer-string))))))
    (neoment-player--cleanup state)
    (neoment-notify--message
     (format "Could not start mpv: %s"
             (if (and text (not (string-empty-p text))) text reason))
     'error)))

(defun neoment-player--connect-loop (state tries)
  "Try to connect STATE to its socket; give up after TRIES attempts.
A failed attempt is retried, since mpv may create the socket file
before it listens on it.  The state keeps a timer that calls this."
  (unless (or (neoment-player--state-done state)
              (neoment-player--state-connection state))
    (let ((err (when (file-exists-p (neoment-player--state-socket state))
                 (condition-case err
                     (progn
                       (neoment-player--attach state
                                               (neoment-player--state-socket state))
                       nil)
                   (error
                    (when-let* ((connection
                                 (neoment-player--state-connection state)))
                      (delete-process connection)
                      (setf (neoment-player--state-connection state) nil))
                    err)))))
      (cond
       ((neoment-player--state-connection state)
        (cancel-timer (neoment-player--state-timer state))
        (setf (neoment-player--state-timer state) nil))
       ((<= tries 0)
        (neoment-player--fail
         state
         (if err
             (error-message-string err)
           "timed out waiting for the control socket")))))))

(defun neoment-player--start-connect (state)
  "Start the retry timer that connects STATE to the mpv socket."
  (let ((tries neoment-player--connect-tries))
    (setf (neoment-player--state-timer state)
          (run-with-timer
           0.05 0.05
           (lambda ()
             (setq tries (1- tries))
             (neoment-player--connect-loop state tries))))))

;;;###autoload
(defun neoment-player-play (file)
  "Play the audio FILE with mpv, replacing any current player."
  (interactive "fAudio file: ")
  (neoment-player--stop)
  (let* ((directory (make-temp-file "neoment-mpv-" t))
         (socket (expand-file-name "ipc" directory))
         (output (generate-new-buffer " *neoment-mpv-output*"))
         (state (neoment-player--state-create
                 :socket socket :directory directory :file file :output output
                 :speed 1.0 :pause nil)))
    (setq neoment-player--state state)
    (condition-case err
        (setf (neoment-player--state-process state)
              (make-process
               :name "neoment-mpv" :buffer output :noquery t
               :command (append (list "mpv" "--no-input-terminal" "--no-video"
                                      "--msg-level=all=error" "--no-msg-color"
                                      "--pause=no" "--keep-open=no"
                                      (concat "--input-ipc-server=" socket))
                                neoment-player-mpv-arguments
                                (list "--" (expand-file-name file)))
               :sentinel (lambda (process event)
                           (neoment-player--sentinel state process event))))
      (error (neoment-player--fail state (error-message-string err))))
    (when (neoment-player--state-process state)
      (neoment-player--start-connect state)
      (neoment-player--render state)
      (display-buffer (get-buffer neoment-player--buffer-name)
                      '((display-buffer-below-selected)
                        (window-height . 3))))
    state))

(defun neoment-player-stop ()
  "Stop the audio player."
  (interactive)
  (unless (neoment-player--stop)
    (user-error "No audio playing")))

(defun neoment-player-quit ()
  "Stop the audio player and close its window."
  (interactive)
  (neoment-player--stop))

(add-hook 'kill-emacs-hook #'neoment-player--stop)

;;;; Controls

(defun neoment-player-toggle-pause ()
  "Pause or resume playback."
  (interactive)
  (neoment-player--command "cycle" "pause"))

(defun neoment-player-seek-backward ()
  "Seek backward by `neoment-player-seek-step' seconds."
  (interactive)
  (neoment-player--command "seek" (- neoment-player-seek-step) "relative"))

(defun neoment-player-seek-forward ()
  "Seek forward by `neoment-player-seek-step' seconds."
  (interactive)
  (neoment-player--command "seek" neoment-player-seek-step "relative"))

(defun neoment-player--set-speed (speed)
  "Set the playback speed to SPEED, never below 0.25."
  (neoment-player--command
   "set_property" "speed" (/ (round (* 100 (max 0.25 speed))) 100.0)))

(defun neoment-player--change-speed (delta)
  "Change the speed by DELTA relative to mpv's own current value.
This stays correct when several presses arrive before mpv reports back."
  (if (and (< delta 0) (< (+ (neoment-player--speed) delta) 0.25))
      (neoment-player--set-speed 0.25)
    (neoment-player--command "add" "speed" delta)))

(defun neoment-player--speed ()
  "Return the observed speed of the current player."
  (or (and neoment-player--state
           (neoment-player--state-speed neoment-player--state))
      1.0))

(defun neoment-player-speed-up ()
  "Increase the speed by `neoment-player-speed-step'."
  (interactive)
  (neoment-player--change-speed neoment-player-speed-step))

(defun neoment-player-speed-down ()
  "Decrease the speed by `neoment-player-speed-step'."
  (interactive)
  (neoment-player--change-speed (- neoment-player-speed-step)))

(defun neoment-player-speed-reset ()
  "Reset the speed to 1.0."
  (interactive)
  (neoment-player--set-speed 1.0))

;;;; Key forwarding

(defconst neoment-player--special-keys
  '((left . "LEFT") (right . "RIGHT") (up . "UP") (down . "DOWN")
    (home . "HOME") (end . "END") (prior . "PGUP") (next . "PGDWN")
    (return . "ENTER") (tab . "TAB") (backspace . "BS") (delete . "DEL")
    (f1 . "F1") (f2 . "F2") (f3 . "F3") (f4 . "F4") (f5 . "F5") (f6 . "F6")
    (f7 . "F7") (f8 . "F8") (f9 . "F9") (f10 . "F10") (f11 . "F11")
    (f12 . "F12"))
  "Function key events and the mpv key names they map to.")

(defun neoment-player--key-name (event)
  "Return the mpv key name for the input EVENT, or nil to not forward it."
  (cond
   ((symbolp event) (cdr (assq event neoment-player--special-keys)))
   ((not (characterp event)) nil)
   (t (pcase event
        (?\s "SPACE")
        (13 "ENTER")
        (9 "TAB")
        (127 "BS")
        ((pred (lambda (c) (or (< c 32) (= c 127)))) nil)
        (_ (char-to-string event))))))

(defun neoment-player-forward-key ()
  "Send the key that invoked this command to mpv."
  (interactive)
  (let ((name (neoment-player--key-name last-command-event)))
    (unless name (user-error "Key not supported by the player"))
    (neoment-player--command "keypress" name)))

(defun neoment-player--make-map ()
  "Return the keymap of the player buffer for `neoment-player-forward-keys'."
  (let ((map (make-sparse-keymap)))
    (if neoment-player-forward-keys
        (progn
          (define-key map [remap self-insert-command] #'neoment-player-forward-key)
          (dolist (char (number-sequence 32 126))
            (define-key map (vector char) #'neoment-player-forward-key))
          (dolist (key '([left] [right] [up] [down] [home] [end] [prior] [next]
                         [f1] [f2] [f3] [f4] [f5] [f6] [f7] [f8] [f9] [f10]
                         [f11] [f12]))
            (define-key map key #'neoment-player-forward-key))
          (define-key map (kbd "RET") #'neoment-player-forward-key)
          (define-key map (kbd "TAB") #'neoment-player-forward-key)
          (define-key map (kbd "DEL") #'neoment-player-forward-key))
      (define-key map [remap self-insert-command] #'ignore)
      (define-key map (kbd "SPC") #'neoment-player-toggle-pause)
      (define-key map [left] #'neoment-player-seek-backward)
      (define-key map [right] #'neoment-player-seek-forward)
      (define-key map "[" #'neoment-player-speed-down)
      (define-key map "]" #'neoment-player-speed-up)
      (define-key map "=" #'neoment-player-speed-reset))
    (define-key map "q" #'neoment-player-quit)
    map))

;;;; Display

(defun neoment-player--format-time (seconds)
  "Format SECONDS as m:ss."
  (let ((total (max 0 (floor (or seconds 0)))))
    (format "%d:%02d" (/ total 60) (% total 60))))

(defun neoment-player--format (state)
  "Return the one-line description of STATE."
  (let ((speed (neoment-player--state-speed state))
        (volume (neoment-player--state-volume state)))
    (string-join
     (delq nil
           (list (if (neoment-player--state-pause state) "⏸" "▶")
                 (file-name-nondirectory (or (neoment-player--state-file state) ""))
                 (format "%s / %s"
                         (neoment-player--format-time
                          (neoment-player--state-time state))
                         (neoment-player--format-time
                          (neoment-player--state-duration state)))
                 (and speed (> (abs (- speed 1.0)) 0.001)
                      (format "%gx" speed))
                 (and volume (format "vol %d" (round volume)))
                 (and (neoment-player--state-mute state) "muted")))
     "  ")))

(define-derived-mode neoment-player-mode nil "Neoment Player"
  "Major mode of the audio player buffer.
Keys are forwarded to mpv while `neoment-player-forward-keys' is non-nil."
  (use-local-map (neoment-player--make-map))
  (add-hook 'kill-buffer-hook #'neoment-player--stop nil t)
  (setq-local buffer-read-only t
              truncate-lines t
              cursor-type nil
              mode-line-format nil))

(defun neoment-player--render (state)
  "Show STATE in the player buffer when the displayed text changed."
  (let ((text (neoment-player--format state)))
    (unless (equal text (neoment-player--state-rendered state))
      (setf (neoment-player--state-rendered state) text)
      (with-current-buffer (get-buffer-create neoment-player--buffer-name)
        (unless (derived-mode-p 'neoment-player-mode)
          (neoment-player-mode))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert text))
        (goto-char (point-min))))))

;;;; Menu

;;;###autoload (autoload 'neoment-player-menu "neoment-player" nil t)
(transient-define-prefix neoment-player-menu ()
  "Audio player controls."
  [["Playback"
    ("SPC" "Pause/resume" neoment-player-toggle-pause :transient t)
    ("<left>" "Seek back" neoment-player-seek-backward :transient t)
    ("<right>" "Seek forward" neoment-player-seek-forward :transient t)]
   ["Speed"
    ("[" "Slower" neoment-player-speed-down :transient t)
    ("]" "Faster" neoment-player-speed-up :transient t)
    ("=" "Reset" neoment-player-speed-reset :transient t)]
   ["Player"
    ("s" "Stop" neoment-player-stop)]])

(provide 'neoment-player)
;;; neoment-player.el ends here
