;;; neoment-finishing-test.el --- Tests for the dispatcher and docs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Group 12 of the port: the command dispatcher, mode help keys and the
;; README symbol list.

;;; Code:

(require 'test-helper)
(require 'neoment)

(ert-deftest neoment-command-dispatches ()
  (let ((called nil))
    (cl-letf (((symbol-function 'neoment-logout) (lambda () (interactive) (setq called 'logout)))
              ((symbol-function 'neoment--init) #'ignore))
      (neoment-command "logout"))
    (should (eq called 'logout)))
  (dolist (pair neoment-subcommands)
    (should (commandp (cdr pair)))))

(ert-deftest neoment-help-key-in-every-mode ()
  (dolist (map (list neoment-rooms-mode-map neoment-room-mode-map neoment-space-mode-map
                     neoment-room-info-mode-map neoment-notification-settings-mode-map))
    (should (eq (keymap-lookup map "?") 'describe-mode))))

(ert-deftest neoment-menu-defined ()
  (should (commandp 'neoment-menu)))

(defun neoment-finishing-test--readme-symbols ()
  "Return the `neoment-' symbols mentioned in backquotes in README.md."
  (let ((file (expand-file-name "../README.md"
                                (file-name-directory (or load-file-name buffer-file-name
                                                         (locate-library "neoment-finishing-test")))))
        (symbols nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "`\\(neoment\\(?:-[a-z0-9-]+\\)?\\)`" nil t)
        (cl-pushnew (match-string 1) symbols :test #'equal)))
    symbols))

(ert-deftest neoment-readme-symbols-exist ()
  (let ((symbols (neoment-finishing-test--readme-symbols)))
    (should (> (length symbols) 60))
    (dolist (name symbols)
      (let ((symbol (intern name)))
        (should (or (fboundp symbol) (boundp symbol)
                    (and (string-suffix-p "-mode" name) (fboundp symbol))
                    (custom-group-of-mode symbol)))))
    ;; Every user option is documented.
    (mapatoms (lambda (symbol)
                (when (and (custom-variable-p symbol)
                           (string-prefix-p "neoment-" (symbol-name symbol)))
                  (should (member (symbol-name symbol) symbols)))))
    ;; Every autoloaded command is documented.
    (dolist (command '(neoment neoment-command neoment-menu neoment-join neoment-logout
                               neoment-pick-room neoment-pick-open-room neoment-sync-start
                               neoment-sync-stop neoment-reload-config neoment-clear-cache
                               neoment-toggle-rooms-list neoment-notification-settings
                               neoment-quit))
      (should (member (symbol-name command) symbols)))))

(provide 'neoment-finishing-test)
;;; neoment-finishing-test.el ends here
