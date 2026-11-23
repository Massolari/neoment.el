;;; lint.el --- Run checkdoc and package-lint  -*- lexical-binding: t; -*-

;;; Commentary:

;; Usage: emacs -Q --batch -L . -l test/lint.el FILE...
;; Exits with a non-zero status when checkdoc or package-lint report
;; anything.

;;; Code:

(require 'checkdoc)
(require 'package-lint)

(defvar neoment-lint--errors 0
  "Number of problems found.")

(setq package-lint-main-file "neoment.el")

(let ((files command-line-args-left))
  (setq command-line-args-left nil)
  (dolist (file files)
    ;; checkdoc
    (with-current-buffer (find-file-noselect file)
      (let* ((checkdoc-autofix-flag 'never)
             (checkdoc-diagnostic-buffer "*checkdoc-lint*")
             (output nil)
             (checkdoc-create-error-function
              (lambda (text start _end &optional _unfixable)
                (push (format "%s:%d: %s" file (line-number-at-pos start) text)
                      output)
                nil)))
        (checkdoc-current-buffer t)
        (dolist (line (nreverse output))
          (setq neoment-lint--errors (1+ neoment-lint--errors))
          (message "checkdoc: %s" line)))
      ;; package-lint
      (let ((errors (package-lint-buffer)))
        (dolist (err errors)
          (pcase-let ((`(,line ,col ,type ,message) err))
            (setq neoment-lint--errors (1+ neoment-lint--errors))
            (message "package-lint: %s:%d:%d: %s: %s"
                     file line col type message)))))))

(message "Lint: %d problem(s)" neoment-lint--errors)
(kill-emacs (if (zerop neoment-lint--errors) 0 1))

;;; lint.el ends here
