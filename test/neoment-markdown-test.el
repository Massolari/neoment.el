;;; neoment-markdown-test.el --- Tests for markdown conversion  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tasks 6.1 and 6.2 of the port.  The cases come from the original
;; tests/markdown_spec.lua plus the markdown-conversion spec scenarios.

;;; Code:

(require 'test-helper)
(require 'neoment-markdown)

(defmacro neoment-markdown-test-cases (function &rest cases)
  "Check that FUNCTION maps each (INPUT EXPECTED) of CASES."
  (declare (indent 1))
  `(progn
     ,@(mapcar (lambda (c) `(should (equal (,function ,(car c)) ,(cadr c)))) cases)))

(ert-deftest neoment-markdown-to-html-cases ()
  (neoment-markdown-test-cases neoment-markdown-to-html
    ("**bold** __text__" "<strong>bold</strong> <strong>text</strong>")
    ("this is an *italic* _text_" "this is an <em>italic</em> <em>text</em>")
    ("_↪️ Forwarded:_\n\n[@r_neovim](https://with_underline.com)"
     "<em>↪️ Forwarded:</em><br /><br /><a href=\"https://with_underline.com\">@r_neovim</a>")
    ("this is an *italic123* _text_" "this is an <em>italic123</em> <em>text</em>")
    ("[this is a_link](https://an_link.com)" "<a href=\"https://an_link.com\">this is a_link</a>")
    ("[this is a _link_](https://an_link.com)"
     "<a href=\"https://an_link.com\">this is a <em>link</em></a>")
    ("`inline code`" "<code>inline code</code>")
    ("```inline code```" "<pre><code>inline code</code></pre>")
    ("```lua\nprint('Hello, World!')\n```"
     "<pre><code class=\"language-lua\">print('Hello, World!')</code></pre>")
    ("- Item 1\n- Item 2\n- Item 3"
     "<ul><li>Item 1</li><br /><li>Item 2</li><br /><li>Item 3</li></ul>")
    ("* Item 1\n* Item 2\n* Item 3"
     "<ul><li>Item 1</li><br /><li>Item 2</li><br /><li>Item 3</li></ul>")
    ("[Matrix](https://matrix.org)" "<a href=\"https://matrix.org\">Matrix</a>")
    ("# Header 1\n## Header 2\n### Header 3"
     "<h1>Header 1</h1><br /><h2>Header 2</h2><br /><h3>Header 3</h3>")
    (">! This is a spoiler <! >! Another spoiler <!"
     "<span data-mx-spoiler>This is a spoiler </span> <span data-mx-spoiler>Another spoiler </span>")
    ("This is a line.\n\nThis is another line." "This is a line.<br /><br />This is another line.")
    ("```\nThis is a line.\n\nThis is another line.\n```"
     "<pre><code>\nThis is a line.\n\nThis is another line.\n</code></pre>")
    ("```\nThis_is_a_test\n```" "<pre><code>\nThis_is_a_test\n</code></pre>")
    ("this is_: `print('a_test')`" "this is_: <code>print('a_test')</code>")
    ("@user_name:server.com how are_you?" "@user_name:server.com how are_you?")
    ("```lua\n:luado return line:gsub(\"(%a+), (%a+)\", \"%2 %1\")\n```"
     "<pre><code class=\"language-lua\">:luado return line:gsub(\"(%a+), (%a+)\", \"%2 %1\")</code></pre>")
    ;; Spec scenarios
    ("`**x**`" "<code>**x**</code>")
    ("hi @foo_bar_baz:s" "hi @foo_bar_baz:s")
    ("> a\n> b" "<blockquote>a<br />b</blockquote>")
    (">! secret" "<span data-mx-spoiler>secret</span>")
    ("a < b & c > d" "a &lt; b &amp; c &gt; d")
    ("" "")))

(ert-deftest neoment-markdown-from-html-cases ()
  (neoment-markdown-test-cases neoment-markdown-from-html
    ("<strong>bold text</strong> and <b>more bold</b>" "**bold text** and **more bold**")
    ("<em>italic text</em> and <i>more italic</i>" "*italic text* and *more italic*")
    ("<em>italic123 text</em> and <i>more italic456</i>" "*italic123 text* and *more italic456*")
    ("<code>inline code</code>" "`inline code`")
    ("<pre><code>code block</code></pre>" "\n```\ncode block\n```\n")
    ("<pre><code class=\"language-lua\">print(\"Hello\")</code></pre>"
     "\n```lua\nprint(\"Hello\")\n```\n")
    ("<pre><code class=\"language-lua\">print(\"<div>bold</div>\")</code></pre>"
     "\n```lua\nprint(\"<div>bold</div>\")\n```\n")
    ("<h1>Header 1</h1><h2>Header 2</h2><h3>Header 3</h3>" "# Header 1## Header 2### Header 3")
    ("<a href=\"https://matrix.org\">Matrix</a>" "[Matrix](https://matrix.org)")
    ("<ul><li>Item 1</li><li>Item 2</li><li>Item 3</li></ul>" "\n- Item 1\n- Item 2\n- Item 3")
    ("<ul>\n<li>Item 1</li>\n<li>Item 2</li>\n<li>Item 3</li>\n</ul>"
     "\n- Item 1\n- Item 2\n- Item 3\n")
    ("Line 1<br>Line 2<br/>Line 3<br />Line 4" "Line 1\nLine 2\nLine 3\nLine 4")
    ("Text before\n<p>Paragraph 2</p>" "Text before\nParagraph 2")
    ("<p>Paragraph 1</p>Text after" "Paragraph 1\nText after")
    ("<p>Paragraph 1</p><p>Paragraph 2</p>" "Paragraph 1\nParagraph 2")
    ("<p>\nParagraph 1</p><p>Paragraph 2</p>" "Paragraph 1\nParagraph 2")
    ("&lt;tag&gt; &amp; &quot;quotes&quot;" "<tag> & \"quotes\"")
    ("<span data-mx-spoiler>This is a spoiler</span>" "[Spoiler](<This is a spoiler>)")
    ("<span data-mx-spoiler=\"ending\">The character dies</span>"
     "[Spoiler for ending](<The character dies>)")
    ("<blockquote>This is a quote\nWith multiple lines</blockquote>"
     "┃ This is a quote\n┃ With multiple lines\n")
    ("<mx-reply><blockquote>Original message</blockquote></mx-reply>Reply content" "Reply content")
    ("<em data-md=\"_\">italic text</em>" "_italic text_")
    ("<span data-md=\"\\\"\">quoted text</span>" "\"quoted text\"")
    ("" "")
    (nil "")
    ("<div>content</div><span>more content</span>" "contentmore content")
    ("<p>This is <strong>bold</strong> and <em>italic</em> text with <code>code</code> and a <a href=\"https://example.com\">link</a>.</p>"
     "This is **bold** and *italic* text with `code` and a [link](https://example.com).")
    ("Line 1\n\n\nLine 2\n\n\n\nLine 3" "Line 1\n\n\nLine 2\n\n\n\nLine 3")
    ("Line 1<br /><br /><br />Line 2<br /><br /><br /><br />Line 3"
     "Line 1\n\n\nLine 2\n\n\n\nLine 3")
    ("<pre><code class=\"language-lua\">:luado return line:gsub(\"(%a+), (%a+)\", \"%2 %1\")</code></pre>"
     "\n```lua\n:luado return line:gsub(\"(%a+), (%a+)\", \"%2 %1\")\n```\n")
    ("<img data-mx-emoticon height=\"24\" src=\"mxc://example.com/image\" alt=\"\" title=\"My Emoji\">"
     "[img: My Emoji](mxc://example.com/image)")
    ("<ul><li><img data-mx-emoticon height=\"24\" src=\"mxc://server.com/img\" alt=\"\" title=\"Guild\"> Devs (<code>123</code>)</li></ul>"
     "\n- [img: Guild](mxc://server.com/img) Devs (`123`)")
    ("This is a test with a slash &#47; in the text." "This is a test with a slash / in the text.")
    ("This is a &lt;message&gt;&lt;/message&gt; with &quot;quotes&quot; outside code and inside <pre><code>{ title = &quot;Code&quot;}</code></pre>"
     "This is a <message></message> with \"quotes\" outside code and inside\n```\n{ title = \"Code\"}\n```\n")
    ("Test <code>-&gt;</code>" "Test `->`")
    ("<p>Paragraph</p>\n<p>Another paragraph</p>\n" "Paragraph\nAnother paragraph")
    ;; Spec scenarios
    ("<img data-mx-emoticon src=\"mxc://s/a\" title=\":party:\">" "[img: :party:](mxc://s/a)")
    ("<span data-mx-spoiler>a b</span>" "[Spoiler](<a b>)")
    ("<p data-mx-forwarded-notice>Forwarded message</p>hello" "_↪️ Forwarded:_\n\nhello")
    ("<mx-reply><blockquote><a href=\"x\">In reply to</a> <a href=\"y\">@a:s</a><br>quoted</blockquote></mx-reply>answer"
     "answer")))

(provide 'neoment-markdown-test)
;;; neoment-markdown-test.el ends here
