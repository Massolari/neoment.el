;;; neoment-markdown.el --- Markdown and HTML conversion  -*- lexical-binding: t; -*-

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

;; A lightweight markdown -> HTML converter used when sending, and an
;; HTML -> markdown converter used to display formatted messages.  They
;; are regexp based, not CommonMark: code spans and blocks are replaced
;; by placeholders first, the rest is processed, and the placeholders
;; are put back.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst neoment-markdown--any "\\(?:.\\|\n\\)*?"
  "Regexp matching any text, including newlines, as little as possible.")

(defconst neoment-markdown-mention-regexp "@[a-zA-Z0-9_-]+:[^[:space:]]+"
  "Regexp matching a Matrix user id mention.")

(defun neoment-markdown--gsub (regexp string function)
  "Replace each match of REGEXP in STRING with the result of FUNCTION.
FUNCTION is called with the list of the match and its groups.
Matches do not overlap and are searched left to right."
  (let ((case-fold-search nil)
        (start 0)
        (parts nil))
    (while (and (<= start (length string)) (string-match regexp string start))
      (let* ((mb (match-beginning 0))
             (me (match-end 0))
             (groups (cl-loop for i from 0 below (/ (length (match-data)) 2)
                              collect (match-string i string))))
        (push (substring string start mb) parts)
        (push (funcall function groups) parts)
        (if (= me mb)
            (progn
              (when (< me (length string))
                (push (substring string me (1+ me)) parts))
              (setq start (1+ me)))
          (setq start me))))
    (when (< start (length string))
      (push (substring string start) parts))
    (apply #'concat (nreverse parts))))

(defun neoment-markdown--replace (regexp string template)
  "Replace each match of REGEXP in STRING with TEMPLATE.
In TEMPLATE, %N stands for group N."
  (neoment-markdown--gsub
   regexp string
   (lambda (groups)
     (replace-regexp-in-string
      "%\\([0-9]\\)"
      (lambda (m) (or (nth (string-to-number (substring m 1)) groups) ""))
      template t t))))

(defun neoment-markdown--literal (from to string)
  "Replace every occurrence of the literal FROM by TO in STRING."
  (string-replace from to string))

(defun neoment-markdown--escape (text)
  "Escape &, < and > in TEXT."
  (thread-last text
               (string-replace "&" "&amp;")
               (string-replace "<" "&lt;")
               (string-replace ">" "&gt;")))

(defun neoment-markdown--numeric-entity (code)
  "Return the character of the numeric entity CODE, or an empty string."
  (let ((n (string-to-number code)))
    (if (and (> n 0) (characterp n)) (char-to-string n) "")))

(defun neoment-markdown--decode-entities (text)
  "Decode the HTML entities in TEXT."
  (let ((text (thread-last text
                           (string-replace "&lt;" "<")
                           (string-replace "&gt;" ">")
                           (string-replace "&amp;" "&")
                           (string-replace "&quot;" "\"")
                           (string-replace "&#39;" "'")
                           (string-replace "&#x27;" "'"))))
    (neoment-markdown--gsub "&#\\([0-9]+\\);" text
                            (lambda (g) (neoment-markdown--numeric-entity (nth 1 g))))))

;;;; Markdown -> HTML

(defconst neoment-markdown--patterns
  (let ((any neoment-markdown--any))
    `((,(concat "\\*\\*\\(" any "\\)\\*\\*") . "<strong>%1</strong>")
      (,(concat "__\\(" any "\\)__") . "<strong>%1</strong>")
      (,(concat "\\([^_]\\)_\\([^_]" any "\\)_\\([^_]\\)") . "%1<em>%2</em>%3")
      (,(concat "_\\([^_]" any "\\)_") . "<em>%1</em>")
      ("\\*\\([^*\n]*?\\)\\*" . "<em>%1</em>")
      (,(concat "`\\(" any "\\)`") . "<code>%1</code>")
      (,(concat "```\\(" any "\\)```") . "<code>%1</code>")
      (,(concat "```\\([[:alnum:]]+\\)\n\\(" any "\\)\n```")
       . "<pre><code class=\"language-%1\">%2</code></pre>")
      ("\\`[[:space:]]*[-*][[:space:]]+\\([^\n]+\\)" . "<li>%1</li>")
      ("\n[[:space:]]*[-*][[:space:]]+\\([^\n]+\\)" . "\n<li>%1</li>")
      ("\\`[[:space:]]*#[[:space:]]+\\([^\n]+\\)" . "<h1>%1</h1>")
      ("\n[[:space:]]*#[[:space:]]+\\([^\n]+\\)" . "\n<h1>%1</h1>")
      ("\\`[[:space:]]*##[[:space:]]+\\([^\n]+\\)" . "<h2>%1</h2>")
      ("\n[[:space:]]*##[[:space:]]+\\([^\n]+\\)" . "\n<h2>%1</h2>")
      ("\\`[[:space:]]*###[[:space:]]+\\([^\n]+\\)" . "<h3>%1</h3>")
      ("\n[[:space:]]*###[[:space:]]+\\([^\n]+\\)" . "\n<h3>%1</h3>")))
  "Inline and line patterns of the markdown -> HTML converter.")

(defun neoment-markdown--apply-patterns (text)
  "Apply `neoment-markdown--patterns' to TEXT."
  (dolist (pattern neoment-markdown--patterns text)
    (setq text (neoment-markdown--replace (car pattern) text (cdr pattern)))))

(defun neoment-markdown--quotes-and-spoilers (text)
  "Convert the blockquote and spoiler lines of TEXT, escaping the rest."
  (let ((lines nil) (quote nil))
    (cl-flet ((flush ()
                (when quote
                  (push (concat "<blockquote>" (string-join (nreverse quote) "\n")
                                "</blockquote>")
                        lines)
                  (setq quote nil))))
      (dolist (line (split-string text "\n"))
        (cond
         ((string-match "\\`[[:space:]]*>[[:space:]]" line)
          (push (neoment-markdown--escape
                 (replace-regexp-in-string "\\`[[:space:]]*>[[:space:]]*" "" line))
                quote))
         ((string-match-p (concat ">!" neoment-markdown--any "<!") line)
          (flush)
          (push (neoment-markdown--gsub
                 (concat ">![[:space:]]*\\(" neoment-markdown--any "\\)<!") line
                 (lambda (g)
                   (concat "<span data-mx-spoiler>"
                           (neoment-markdown--escape (nth 1 g)) "</span>")))
                lines))
         ((string-match "\\`[[:space:]]*>![[:space:]]*\\(.*\\)" line)
          (flush)
          (push (concat "<span data-mx-spoiler>"
                        (neoment-markdown--escape (match-string 1 line)) "</span>")
                lines))
         (t
          (flush)
          (push (neoment-markdown--escape line) lines))))
      (flush))
    (string-join (nreverse lines) "\n")))

(defun neoment-markdown-to-html (markdown)
  "Convert the MARKDOWN text to Matrix HTML."
  (if (or (null markdown) (string-empty-p markdown))
      ""
    (let* ((html (neoment-markdown--quotes-and-spoilers markdown))
           (preserved nil)
           (count 0)
           (any neoment-markdown--any))
      (cl-flet ((preserve (kind value)
                  (setq count (1+ count))
                  (let ((placeholder (format "{{%s%d}}" kind count)))
                    (push (cons placeholder value) preserved)
                    placeholder)))
        (setq html (neoment-markdown--gsub
                    (concat "```\\([[:alnum:]]+\\)\n\\(" any "\\)\n```") html
                    (lambda (g)
                      (preserve "CODEBLOCK"
                                (format "<pre><code class=\"language-%s\">%s</code></pre>"
                                        (nth 1 g) (nth 2 g))))))
        (setq html (neoment-markdown--gsub
                    (concat "```\\(" any "\\)```") html
                    (lambda (g)
                      (preserve "CODEBLOCK" (format "<pre><code>%s</code></pre>" (nth 1 g))))))
        (setq html (neoment-markdown--gsub
                    (concat "`\\(" any "\\)`") html
                    (lambda (g)
                      (preserve "INLINECODE" (format "<code>%s</code>" (nth 1 g))))))
        (setq html (neoment-markdown--gsub
                    neoment-markdown-mention-regexp html
                    (lambda (g) (preserve "MENTION" (nth 0 g)))))
        (let ((links nil) (link-count 0))
          (setq html (neoment-markdown--gsub
                      (concat "\\[\\(" any "\\)\\](\\(" any "\\))") html
                      (lambda (g)
                        (setq link-count (1+ link-count))
                        (let ((placeholder (format "LINKPLACEHOLDER%dLINKPLACEHOLDER"
                                                   link-count)))
                          (push (cons placeholder
                                      (format "<a href=\"%s\">%s</a>" (nth 2 g)
                                              (neoment-markdown--apply-patterns (nth 1 g))))
                                links)
                          placeholder))))
          (setq html (neoment-markdown--apply-patterns html))
          (dolist (link links)
            (setq html (string-replace (car link) (cdr link) html))))
        (setq html (string-replace "\n" "<br />" html))
        (dolist (block preserved)
          (setq html (string-replace (car block) (cdr block) html)))
        (setq html (neoment-markdown--replace
                    (concat "\\(<li>" any "</li>\\)[[:space:]]*\\(<li>\\)") html "%1%2"))
        (setq html (neoment-markdown--replace "\\(<li>\\(?:.\\|\n\\)*</li>\\)" html
                                              "<ul>%1</ul>"))
        (string-replace "\\n" "<br />" html)))))

;;;; HTML -> markdown

(defun neoment-markdown--plain-code (code)
  "Return the converted CODE, inline or fenced, without its markup."
  (cond
   ((string-match "\\`\n```[^\n]*\n\\(\\(?:.\\|\n\\)*?\\)\n```\n\\'" code)
    (match-string 1 code))
   ((string-match "\\``\\(\\(?:.\\|\n\\)*\\)`\\'" code) (match-string 1 code))
   (t code)))

(defun neoment-markdown--spoiler (description content &optional codes)
  "Return the markdown of a spoiler with DESCRIPTION and CONTENT.
CONTENT is HTML: its tags are dropped, its entities decoded and its
code placeholders, keys of the alist CODES, replaced by the plain code.
It always goes within `<…>', so the room styler can tell it apart, with `\\',
`<' and `>' escaped by a backslash and newlines written as `\\n'.
DESCRIPTION, also HTML, has its brackets, backticks and newlines replaced so it
stays a valid link text."
  (let* ((text (replace-regexp-in-string
                "{{CODEBLOCK[0-9]+}}"
                (lambda (p)
                  (save-match-data
                    (neoment-markdown--plain-code (or (cdr (assoc p codes)) p))))
                (neoment-markdown--decode-entities
                 (replace-regexp-in-string "<[^>]*>" "" content))
                t t))
         (content (format "<%s>"
                          (string-replace
                           "\n" "\\n"
                           (replace-regexp-in-string "[\\<>]" "\\\\\\&" text))))
         (description
          (and description
               (replace-regexp-in-string
                "[ \t\n]+" " "
                (string-replace
                 "`" "'"
                 (string-replace "[" "(" (string-replace "]" ")" (neoment-markdown--decode-entities
                                                                 description))))))))
    (if description
        (format "[Spoiler for %s](%s)" description content)
      (format "[Spoiler](%s)" content))))

(defun neoment-markdown--replace-spoilers (html function)
  "Replace the spoiler spans of HTML with the result of FUNCTION.
FUNCTION is called with the spoiler description, or nil, and content.
Nested spans are kept in the content.  An unclosed spoiler is left as is."
  (let ((case-fold-search nil)
        (start 0)
        (parts nil))
    (while (string-match "<span data-mx-spoiler\\(?:=\"\\([^\"]*\\)\"\\)?>" html start)
      (let ((mb (match-beginning 0))
            (cb (match-end 0))
            (description (match-string 1 html))
            (depth 1)
            (pos (match-end 0))
            (ce nil))
        (while (and (null ce) (string-match "<span\\b[^>]*>\\|</span>" html pos))
          (setq pos (match-end 0))
          (if (string-prefix-p "</" (match-string 0 html))
              (when (zerop (setq depth (1- depth)))
                (setq ce (match-beginning 0)))
            (setq depth (1+ depth))))
        (push (substring html start mb) parts)
        (if ce
            (progn
              (push (funcall function description (substring html cb ce)) parts)
              (setq start pos))
          (push (substring html mb cb) parts)
          (setq start cb))))
    (push (substring html start) parts)
    (apply #'concat (nreverse parts))))

(defun neoment-markdown-from-html (html)
  "Convert the Matrix HTML to markdown for display."
  (if (or (null html) (string-empty-p html))
      ""
    (let* ((any neoment-markdown--any)
           (md html)
           (preserved nil)
           (count 0))
      (cl-flet ((preserve (text)
                  (setq count (1+ count))
                  (let ((placeholder (format "{{CODEBLOCK%d}}" count)))
                    (push (cons placeholder text) preserved)
                    placeholder)))
        ;; Paragraphs and line breaks
        (setq md (neoment-markdown--replace (concat "<p>\\(" any "\\)</p>\n?") md "%1\n"))
        (setq md (replace-regexp-in-string "\n\\'" "" md))
        (setq md (replace-regexp-in-string "\\`\n" "" md))
        (setq md (thread-last md
                              (string-replace "<br>" "\n")
                              (string-replace "<br/>" "\n")
                              (string-replace "<br />" "\n")))
        ;; Code
        (setq md (neoment-markdown--gsub
                  (concat "<pre><code class=[\"']language-\\([^\"']+\\)[\"']>\\("
                          any "\\)</code></pre>")
                  md (lambda (g)
                       (preserve (concat "\n```" (nth 1 g) "\n"
                                         (neoment-markdown--decode-entities (nth 2 g))
                                         "\n```\n")))))
        (setq md (neoment-markdown--gsub
                  (concat "<pre><code>\\(" any "\\)</code></pre>") md
                  (lambda (g)
                    (preserve (concat "\n```\n"
                                      (neoment-markdown--decode-entities (nth 1 g))
                                      "\n```\n")))))
        (setq md (neoment-markdown--gsub
                  (concat "<code class=[\"']language-\\([^\"]+\\)[\"']>\\(" any "\\)</code>")
                  md (lambda (g)
                       (preserve (concat "\n```" (nth 1 g) "\n" (nth 2 g) "\n```\n")))))
        (setq md (neoment-markdown--gsub
                  (concat "<code>\\(" any "\\)</code>") md
                  (lambda (g)
                    (preserve (concat "`" (neoment-markdown--decode-entities (nth 1 g)) "`")))))
        ;; Rich reply fallback
        (setq md (neoment-markdown--replace
                  (concat "<mx-reply>[[:space:]]*<blockquote>" any
                          "</blockquote>[[:space:]]*</mx-reply>")
                  md ""))
        (setq md (neoment-markdown--replace (concat "<mx-reply>" any "</mx-reply>") md ""))
        ;; Forwarded notice
        (setq md (neoment-markdown--replace
                  (concat "<p data-mx-forwarded-notice>" any "</p>")
                  md "_↪️ Forwarded:_\n\n"))
        ;; Spoilers
        (setq md (neoment-markdown--replace-spoilers
                  md (lambda (description content)
                       (preserve (neoment-markdown--spoiler description content preserved)))))
        ;; Blockquotes
        (setq md (neoment-markdown--gsub
                  (concat "<blockquote[^>]*>\\(" any "\\)</blockquote>") md
                  (lambda (g)
                    (mapconcat (lambda (line) (concat "┃ " line "\n"))
                               (split-string (nth 1 g) "\n" t) ""))))
        ;; Emoticons
        (setq md (neoment-markdown--gsub
                  "<img\\([^>]+\\)>" md
                  (lambda (g)
                    (let ((attrs (nth 1 g)))
                      (if (not (string-match-p "data-mx-emoticon" attrs))
                          (nth 0 g)
                        (format "[img: %s](%s)"
                                (or (and (string-match "title=\"\\([^\"]+\\)\"" attrs)
                                         (match-string 1 attrs))
                                    (and (string-match "alt=\"\\([^\"]+\\)\"" attrs)
                                         (match-string 1 attrs))
                                    "")
                                (or (and (string-match "src=\"\\([^\"]+\\)\"" attrs)
                                         (match-string 1 attrs))
                                    "")))))))
        ;; data-md
        (setq md (neoment-markdown--gsub
                  (concat "<\\([[:alnum:]]+\\)[[:space:]]+data-md=[\"']\\(" any
                          "\\)[\"']>\\(" any "\\)</\\([[:alnum:]]+\\)>")
                  md (lambda (g)
                       (let ((value (string-replace "\\" "" (nth 2 g)))
                             (content (nth 3 g)))
                         (if (and (equal (nth 1 g) (nth 4 g))
                                  (not (string-empty-p value)))
                             (concat value content value)
                           content)))))
        ;; Inline formatting, headers, links and lists
        (dolist (rule `(("<strong>\\(%s\\)</strong>" . "**%%1**")
                        ("<b>\\(%s\\)</b>" . "**%%1**")
                        ("<em>\\(%s\\)</em>" . "*%%1*")
                        ("<i>\\(%s\\)</i>" . "*%%1*")
                        ("<del>\\(%s\\)</del>" . "~~%%1~~")
                        ("<s>\\(%s\\)</s>" . "~~%%1~~")
                        ("<strike>\\(%s\\)</strike>" . "~~%%1~~")
                        ("<h1>\\(%s\\)</h1>" . "# %%1")
                        ("<h2>\\(%s\\)</h2>" . "## %%1")
                        ("<h3>\\(%s\\)</h3>" . "### %%1")
                        ("<a href=[\"']\\(%s\\)[\"']>\\(%s\\)</a>" . "[%%2](%%1)")
                        ("\n?<li>\\(%s\\)</li>" . "\n- %%1")
                        ("<ul>\\(%s\\)</ul>" . "%%1")
                        ("<[^>]+>\\(%s\\)</[^>]+>" . "%%1")))
          (setq md (neoment-markdown--replace
                    (replace-regexp-in-string "%s" any (car rule) t t)
                    md (format (cdr rule)))))
        ;; Entities
        (setq md (thread-last md
                              (string-replace "&#39;" "'")
                              (string-replace "&#x27;" "'")
                              (string-replace "&#27;" "\"")
                              (string-replace "&lt;" "<")
                              (string-replace "&gt;" ">")
                              (string-replace "&amp;" "&")
                              (string-replace "&quot;" "\"")))
        (setq md (neoment-markdown--gsub
                  "&#\\([0-9]+\\);" md
                  (lambda (g) (neoment-markdown--numeric-entity (nth 1 g)))))
        ;; Restore code
        (dolist (block preserved)
          (setq md (if (string-prefix-p "\n" (cdr block))
                       (neoment-markdown--gsub (concat " *" (regexp-quote (car block)))
                                               md (lambda (_) (cdr block)))
                     (string-replace (car block) (cdr block) md))))
        md))))

(provide 'neoment-markdown)
;;; neoment-markdown.el ends here
