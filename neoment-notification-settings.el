;;; neoment-notification-settings.el --- Push rule settings  -*- lexical-binding: t; -*-

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

;; Global and per-room notification settings, stored on the server as
;; push rules, and the pop-up windows that change them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'neoment-client)
(require 'neoment-http)
(require 'neoment-notify)

(defconst neoment-notification-settings-level-labels
  '((global . "Global settings") (all . "All messages")
    (mentions . "Mentions and replies only") (none . "None"))
  "Labels of the notification levels.")

(defconst neoment-notification-settings-category-rules
  '((one_to_one ".m.rule.room_one_to_one" ".m.rule.encrypted_room_one_to_one")
    (group ".m.rule.message" ".m.rule.encrypted"))
  "Underride rules of each global category.")

(defconst neoment-notification-settings-category-headers
  '((one_to_one . "One-to-one rooms (2 members)") (group . "Group rooms (3+ members)"))
  "Headers of the global categories.")

(defconst neoment-notification-settings--sound
  '((set_tweak . "sound") (value . "default"))
  "The default sound tweak.")

;;;; Reading

(defun neoment-notification-settings-find-rule (rules kind rule-id)
  "Return the rule RULE-ID of KIND (a symbol) in the push RULES, or nil."
  (seq-find (lambda (rule) (equal (alist-get 'rule_id rule) rule-id))
            (neoment-json-get rules 'global kind)))

(defun neoment-notification-settings--notifies-p (rule)
  "Return non-nil when RULE has the notify action."
  (member "notify" (alist-get 'actions rule)))

(defun neoment-notification-settings--enabled-p (rule)
  "Return non-nil when RULE is enabled."
  (eq (alist-get 'enabled rule) t))

(defun neoment-notification-settings-global-levels (rules)
  "Return an alist CATEGORY -> `all' or `mentions' from RULES."
  (mapcar (lambda (category)
            (let ((rule (neoment-notification-settings-find-rule
                         rules 'underride
                         (cadr (assq category neoment-notification-settings-category-rules)))))
              (cons category (if (and rule (neoment-notification-settings--enabled-p rule)
                                      (neoment-notification-settings--notifies-p rule))
                                 'all
                               'mentions))))
          '(one_to_one group)))

(defun neoment-notification-settings-room-level (rules room-id)
  "Return the level of ROOM-ID in RULES: `none', `all', `mentions' or `global'."
  (let ((override (neoment-notification-settings-find-rule rules 'override room-id))
        (room-rule (neoment-notification-settings-find-rule rules 'room room-id)))
    (cond
     ((and override (neoment-notification-settings--enabled-p override)
           (let ((conditions (alist-get 'conditions override)))
             (and (= (length conditions) 1)
                  (equal (alist-get 'kind (car conditions)) "event_match")
                  (equal (alist-get 'key (car conditions)) "room_id")
                  (equal (alist-get 'pattern (car conditions)) room-id)))
           (not (neoment-notification-settings--notifies-p override)))
      'none)
     ((and room-rule (neoment-notification-settings--enabled-p room-rule))
      (if (neoment-notification-settings--notifies-p room-rule) 'all 'mentions))
     (t 'global))))

(defun neoment-notification-settings-room-category (room)
  "Return the global category that applies to ROOM."
  (let ((count (neoment-room-joined-member-count room)))
    (if count
        (if (= count 2) 'one_to_one 'group)
      (if (neoment-room-is-direct room) 'one_to_one 'group))))

(defun neoment-notification-settings-applied-global-level (rules room)
  "Return the global level of RULES that applies to ROOM."
  (alist-get (neoment-notification-settings-room-category room)
             (neoment-notification-settings-global-levels rules)))

;;;; Writing

(defun neoment-notification-settings--url (kind rule-id &optional suffix)
  "Return the path of the push rule RULE-ID of KIND, plus SUFFIX."
  (concat "/_matrix/client/v3/pushrules/global/" (symbol-name kind) "/"
          (neoment-api-encode rule-id) (if suffix (concat "/" suffix) "")))

(defun neoment-notification-settings--put (path body)
  "Return a step that PUTs BODY to PATH."
  (lambda (callback)
    (neoment-api-request 'put path :json body :callback callback)))

(defun neoment-notification-settings--delete (path)
  "Return a step that DELETEs PATH."
  (lambda (callback)
    (neoment-api-request 'delete path :callback callback)))

(defun neoment-notification-settings--run (steps callback)
  "Run STEPS in order, stopping at the first error, then call CALLBACK."
  (if (null steps)
      (funcall callback (list :ok nil))
    (funcall (car steps)
             (lambda (result)
               (if (plist-get result :error)
                   (funcall callback result)
                 (neoment-notification-settings--run (cdr steps) callback))))))

(defun neoment-notification-settings-fetch (callback)
  "Fetch the push rules into the current client and call CALLBACK."
  (let ((client neoment--client))
    (neoment-api-request
     'get "/_matrix/client/v3/pushrules/"
     :callback (lambda (result)
                 (when (and (plist-get result :ok) (eq client neoment--client))
                   (setf (neoment-client-push-rules client) (plist-get result :ok)))
                 (funcall callback result)))))

(defun neoment-notification-settings--apply (steps callback)
  "Run STEPS, reload the rules and call CALLBACK.
An error of the reload alone has `:saved' set."
  (neoment-notification-settings--run
   steps
   (lambda (change)
     (neoment-notification-settings-fetch
      (lambda (fetch)
        (funcall callback
                 (cond
                  ((plist-get change :error) change)
                  ((plist-get fetch :error)
                   (list :error (append (list :saved t) (plist-get fetch :error))))
                  (t (list :ok nil)))))))))

(defun neoment-notification-settings-set-global (category level callback)
  "Set the global CATEGORY to LEVEL (`all' or `mentions') and call CALLBACK."
  (let* ((rules (neoment-client-push-rules neoment--client))
         (actions (if (eq level 'all)
                      (if (eq category 'one_to_one)
                          (vector "notify" neoment-notification-settings--sound)
                        (vector "notify"))
                    []))
         (steps nil))
    (dolist (rule-id (cdr (assq category neoment-notification-settings-category-rules)))
      (when (neoment-notification-settings-find-rule rules 'underride rule-id)
        (setq steps
              (append steps
                      (list (neoment-notification-settings--put
                             (neoment-notification-settings--url 'underride rule-id "actions")
                             `((actions . ,actions)))
                            (neoment-notification-settings--put
                             (neoment-notification-settings--url 'underride rule-id "enabled")
                             '((enabled . t))))))))
    (neoment-notification-settings--apply steps callback)))

(defun neoment-notification-settings-set-room (room-id level callback)
  "Set the notification LEVEL of ROOM-ID and call CALLBACK.
The new rule is created before the old ones are deleted."
  (let* ((rules (neoment-client-push-rules neoment--client))
         (steps nil))
    (cl-flet ((put-rule (kind body)
                (setq steps (append steps (list (neoment-notification-settings--put
                                                 (neoment-notification-settings--url kind room-id)
                                                 body))))
                (let ((existing (neoment-notification-settings-find-rule rules kind room-id)))
                  (when (and existing (eq (alist-get 'enabled existing) :false))
                    (setq steps (append steps (list (neoment-notification-settings--put
                                                     (neoment-notification-settings--url
                                                      kind room-id "enabled")
                                                     '((enabled . t))))))))))
      (pcase level
        ('none (put-rule 'override `((conditions . [((kind . "event_match") (key . "room_id")
                                                     (pattern . ,room-id))])
                                     (actions . []))))
        ((or 'all 'mentions)
         (put-rule 'room `((actions . ,(if (eq level 'all)
                                           (vector "notify" neoment-notification-settings--sound)
                                         [])))))))
    (when (and (not (eq level 'none))
               (neoment-notification-settings-find-rule rules 'override room-id))
      (setq steps (append steps (list (neoment-notification-settings--delete
                                       (neoment-notification-settings--url 'override room-id))))))
    (when (and (memq level '(none global))
               (neoment-notification-settings-find-rule rules 'room room-id))
      (setq steps (append steps (list (neoment-notification-settings--delete
                                       (neoment-notification-settings--url 'room room-id))))))
    (neoment-notification-settings--apply steps callback)))

;;;; Window

(defvar-local neoment-notification-settings--title nil
  "Title of the settings window.")

(defvar-local neoment-notification-settings--build nil
  "Function returning the option lines of the settings window.")

(defvar-local neoment-notification-settings--saving nil
  "Non-nil while a change is being saved.")

(defun neoment-notification-settings--option (selected label action)
  "Return an option line for LABEL, SELECTED or not, running ACTION."
  (propertize (concat (if selected "(•) " "( ) ") label)
              'neoment-option (list :selected selected :action action)))

(defun neoment-notification-settings-global-lines ()
  "Return the lines of the global settings window."
  (let ((levels (neoment-notification-settings-global-levels
                 (neoment-client-push-rules neoment--client)))
        (lines nil))
    (dolist (category '(one_to_one group))
      (when lines (push "" lines))
      (push (alist-get category neoment-notification-settings-category-headers) lines)
      (dolist (level '(all mentions))
        (let ((category category) (level level))
          (push (concat "  " (neoment-notification-settings--option
                              (eq (alist-get category levels) level)
                              (alist-get level neoment-notification-settings-level-labels)
                              (lambda (cb) (neoment-notification-settings-set-global
                                            category level cb))))
                lines))))
    (nreverse lines)))

(defun neoment-notification-settings-room-lines (room-id)
  "Return the lines of the settings window of ROOM-ID."
  (let* ((rules (neoment-client-push-rules neoment--client))
         (current (neoment-notification-settings-room-level rules room-id))
         (applied (neoment-notification-settings-applied-global-level
                   rules (neoment-get-room room-id))))
    (mapcar (lambda (level)
              (neoment-notification-settings--option
               (eq current level)
               (if (eq level 'global)
                   (format "Global settings (%s)"
                           (alist-get applied neoment-notification-settings-level-labels))
                 (alist-get level neoment-notification-settings-level-labels))
               (lambda (cb) (neoment-notification-settings-set-room room-id level cb))))
            '(global all mentions none))))

(defvar-keymap neoment-notification-settings-mode-map
  :doc "Keymap of `neoment-notification-settings-mode'."
  :parent special-mode-map
  "RET" #'neoment-notification-settings-apply
  "q" #'neoment-notification-settings-close
  "<escape>" #'neoment-notification-settings-close
  "?" #'describe-mode)

(defun neoment-notification-settings--header ()
  "Return the title shown in the settings window."
  (concat " " neoment-notification-settings--title
          (if neoment-notification-settings--saving " (Saving…)" "")
          " "))

(define-derived-mode neoment-notification-settings-mode special-mode "Neoment Notifications"
  "Major mode for the Neoment notification settings windows.

\\{neoment-notification-settings-mode-map}"
  (setq-local buffer-undo-list t
              cursor-type 'bar
              header-line-format '(:eval (neoment-notification-settings--header)))
  (hl-line-mode 1))

(defun neoment-notification-settings-render ()
  "Render the current settings buffer and move to the selected option."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (string-join (funcall neoment-notification-settings--build) "\n"))
    (goto-char (point-min))
    (let ((pos (point-min)) found)
      (while (and (not found) (< pos (point-max)))
        (if (plist-get (get-text-property pos 'neoment-option) :selected)
            (setq found pos)
          (setq pos (or (next-single-property-change pos 'neoment-option) (point-max)))))
      (when found
        (goto-char found)
        (forward-line 0)))))

(defun neoment-notification-settings--open (title build)
  "Open a settings window titled TITLE whose lines come from BUILD."
  (let ((buffer (get-buffer-create "*Neoment notification settings*")))
    (with-current-buffer buffer
      (neoment-notification-settings-mode)
      (setq neoment-notification-settings--title title
            neoment-notification-settings--build build
            neoment-notification-settings--saving nil)
      (neoment-notification-settings-render))
    (let ((window (display-buffer buffer '((display-buffer-at-bottom)
                                           (window-height . fit-window-to-buffer)))))
      (when window (select-window window)))
    buffer))

(defun neoment-notification-settings-apply ()
  "Apply the option on the current line."
  (interactive)
  (let* ((bol (line-beginning-position))
         (start (if (get-text-property bol 'neoment-option)
                    bol
                  (next-single-property-change bol 'neoment-option nil (line-end-position))))
         (option (and start (get-text-property start 'neoment-option)))
         (buffer (current-buffer)))
    (when (and option (not neoment-notification-settings--saving)
               (not (plist-get option :selected)))
      (setq neoment-notification-settings--saving t)
      (force-mode-line-update)
      (funcall (plist-get option :action)
               (lambda (result)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq neoment-notification-settings--saving nil)
                     (let ((err (plist-get result :error)))
                       (when err
                         (neoment-notify--error
                          (concat (if (plist-get err :saved)
                                      "Saved, but could not reload the notification settings: "
                                    "Could not change the notification settings: ")
                                  (neoment-http-error-message err)))))
                     (neoment-notification-settings-render))))))))

(defun neoment-notification-settings-close ()
  "Close the settings window."
  (interactive)
  (quit-window t))

(defun neoment-notification-settings--with-rules (function)
  "Call FUNCTION once the push rules are loaded."
  (if (neoment-client-push-rules neoment--client)
      (funcall function)
    (neoment-notification-settings-fetch
     (lambda (result)
       (if (plist-get result :error)
           (neoment-notify--error
            (concat "Could not load the notification settings: "
                    (neoment-http-error-message (plist-get result :error))))
         (funcall function))))))

;;;###autoload
(defun neoment-notification-settings ()
  "Open the global notification settings."
  (interactive)
  (if (not (neoment-logged-in-p))
      (neoment-notify--error "Not logged in")
    (neoment-notification-settings--with-rules
     (lambda ()
       (neoment-notification-settings--open "Notification settings"
                                            #'neoment-notification-settings-global-lines)))))

(defun neoment-notification-settings-room (room-id)
  "Open the notification settings of ROOM-ID."
  (neoment-notification-settings--with-rules
   (lambda ()
     (neoment-notification-settings--open
      (neoment-room-display-name-with-space room-id)
      (lambda () (neoment-notification-settings-room-lines room-id))))))

(provide 'neoment-notification-settings)
;;; neoment-notification-settings.el ends here
