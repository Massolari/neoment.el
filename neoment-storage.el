;;; neoment-storage.el --- Files on disk for Neoment  -*- lexical-binding: t; -*-

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

;; Where Neoment keeps its files, and the JSON helpers to read and write
;; them:
;;
;; - neoment/data.json            session credentials (mode 0600)
;; - neoment/ui_state.json        fold state of the room list
;; - neoment/oauth_clients.json   OAuth client ids per issuer
;; - neoment/cache/cache.json     compact room cache
;; - neoment/cache/media/         downloaded media

;;; Code:

(require 'cl-lib)
(require 'neoment-http)

(defun neoment-storage-dir ()
  "Return the directory holding Neoment's data files."
  (file-name-as-directory (locate-user-emacs-file "neoment/")))

(defun neoment-storage-cache-dir ()
  "Return the directory holding Neoment's cache."
  (file-name-as-directory (expand-file-name "cache" (neoment-storage-dir))))

(defun neoment-storage-media-dir ()
  "Return the directory holding downloaded media, creating it."
  (let ((dir (file-name-as-directory
              (expand-file-name "media" (neoment-storage-cache-dir)))))
    (make-directory dir t)
    dir))

(defun neoment-storage-file (name)
  "Return the path of the data file NAME."
  (expand-file-name name (neoment-storage-dir)))

(defun neoment-storage-session-file ()
  "Return the path of `data.json'."
  (neoment-storage-file "data.json"))

(defun neoment-storage-ui-state-file ()
  "Return the path of `ui_state.json'."
  (neoment-storage-file "ui_state.json"))

(defun neoment-storage-oauth-clients-file ()
  "Return the path of `oauth_clients.json'."
  (neoment-storage-file "oauth_clients.json"))

(defun neoment-storage-cache-file ()
  "Return the path of `cache.json'."
  (expand-file-name "cache.json" (neoment-storage-cache-dir)))

(defun neoment-storage-read-json (file)
  "Read and parse the JSON FILE, or return nil when missing or invalid."
  (when (file-readable-p file)
    (condition-case nil
        (with-temp-buffer
          (set-buffer-multibyte t)
          (let ((coding-system-for-read 'utf-8))
            (insert-file-contents file))
          (neoment-json-decode (buffer-string)))
      (error nil))))

(defun neoment-storage-write-json (file object &optional private)
  "Write OBJECT as JSON to FILE.
With PRIVATE, the file is only readable by the user (mode 0600)."
  (make-directory (file-name-directory file) t)
  (let ((json (neoment-json-encode object))
        (coding-system-for-write 'utf-8-unix))
    (if private
        (with-file-modes #o600
          (write-region json nil file nil 'silent)
          (set-file-modes file #o600))
      (write-region json nil file nil 'silent))))

(defun neoment-storage-delete (file)
  "Delete FILE when it exists."
  (when (file-exists-p file)
    (delete-file file)))

;;;; UI state

(defun neoment-storage-load-ui-state ()
  "Return the saved UI state as a plist (:sections ALIST :spaces ALIST).
Each alist maps a name (string) to non-nil when folded."
  (let ((data (neoment-storage-read-json (neoment-storage-ui-state-file))))
    (cl-flet ((conv (alist)
                (mapcar (lambda (pair)
                          (cons (symbol-name (car pair)) (eq (cdr pair) t)))
                        alist)))
      (list :sections (conv (alist-get 'sections data))
            :spaces (conv (alist-get 'spaces data))))))

(defun neoment-storage-save-ui-state (sections spaces)
  "Save the fold state SECTIONS and SPACES (alists of NAME . FOLDED)."
  (cl-flet ((conv (alist)
              (mapcar (lambda (pair)
                        (cons (car pair) (if (cdr pair) t :false)))
                      alist)))
    (neoment-storage-write-json (neoment-storage-ui-state-file)
                                `((sections . ,(conv sections))
                                  (spaces . ,(conv spaces))))))

;;;; OAuth clients

(defun neoment-storage-oauth-client-id (issuer)
  "Return the saved OAuth client id for ISSUER, or nil."
  (let ((data (neoment-storage-read-json (neoment-storage-oauth-clients-file))))
    (cdr (assoc issuer (mapcar (lambda (p) (cons (symbol-name (car p)) (cdr p)))
                               data)))))

(defun neoment-storage-set-oauth-client-id (issuer client-id)
  "Save CLIENT-ID for ISSUER, or forget it when CLIENT-ID is nil."
  (let* ((data (mapcar (lambda (p) (cons (symbol-name (car p)) (cdr p)))
                       (neoment-storage-read-json
                        (neoment-storage-oauth-clients-file))))
         (data (assoc-delete-all issuer data)))
    (when client-id
      (setq data (append data (list (cons issuer client-id)))))
    (neoment-storage-write-json (neoment-storage-oauth-clients-file)
                                data)))

(provide 'neoment-storage)
;;; neoment-storage.el ends here
