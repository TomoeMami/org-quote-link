;;; org-quote-link.el --- Turn an Org link into a quoted block -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Riko

;; Author: Riko
;; Version: 0.5.0
;; Package-Requires: ((emacs "27.1") (org "9.3"))
;; Keywords: hypermedia, org, outlines
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; 把光标放在一个 Org 链接上，执行 `org-quote-link-at-point'，这个链接
;; 就会变成下面这样的 Org quote-block（“引用块”）：
;;
;;     #+HEADER: :transclude [[file:~/notes.org::*标题]]
;;     #+begin_quote
;;     ,* 标题
;;     标题的正文……
;;     #+end_quote
;;
;; 也就是说：
;;
;;   - 链接被放进 quote-block 的 header（`#+HEADER: :transclude ...'，
;;     本包自己的约定，`org-quote-link-refresh' 会读取它）；
;;   - 块的内容是链接所指向的对象的一份快照；
;;   - 如果链接指向 heading，则插入 heading 本身以及它的子树（包括正文、
;;     子标题、子标题的正文），并按照 Org 语法进行转义（行首的 `*'、
;;     `#+' 等前面加逗号），这样它才不会在 quote-block 里被误认为真正的
;;     标题或关键字；
;;   - 如果链接指向其他对象（Org 文件正文、某个 target / name 元素、
;;     其它文件、行内文字搜索等），也按来源类型转义后插入。
;;
;; 依赖：
;;
;;   本包只依赖 Org 本身（`org'、`org-element'、`org-id'、`ol'），不会
;;   require、加载或调用 org-transclusion / org-transclusion-blocks。
;;   生成块里的 `#+HEADER: :transclude [[LINK]]' 行是本包自己的文本约定，
;;   `org-quote-link-refresh' 靠它找到链接；如果你另外安装了
;;   org-transclusion-blocks，它碰巧也能识别这个格式，但那只是可选的
;;   互操作，不是依赖。
;;
;; 支持哪些链接类型：
;;
;;   本包只转换 `org-store-link' 能够生成的链接（见 Org 手册
;;   “Handling Links”），也就是：
;;
;;   1. `file:' 链接 —— 这是 `org-store-link' 在 Org buffer 里生成的主
;;      要形式，覆盖：
;;        - `[[file:foo.org::*标题]]'        heading
;;        - `[[file:foo.org::<<target>>]]'   命名 target
;;        - `[[file:foo.org::#custom-id]]'   CUSTOM_ID
;;        - `[[file:foo.org::block-name]]'   #+name: 命名的元素
;;        - `[[file:foo.org::某行文字]]'     行/区域文字搜索
;;        - `[[file:foo.org]]'               整个 Org 文件
;;        - `[[file:foo.txt]]'               其它文本文件
;;   2. `id:' 链接 —— 由 org-id 的 store 函数生成，例如
;;      `[[id:1234-abcd]]'；Org 9.7+ 还支持 `[[id:1234-abcd::*Heading]]'。
;;   3. 任何注册了 `:store' 链接参数的第三方链接类型 —— 只要该类型能通
;;      过 `org-store-link' 保存，本包就会打开它并引用它打开的文本
;;      buffer（或其中的 heading）。例如 denote、gnus、rmail、bbdb、
;;      irc、eww、orgit、mu4e 等；具体能引用到什么内容，取决于对应
;;      链接的 follow 函数。
;;
;;   手动输入的、`org-store-link' 不会生成的链接类型（例如 fringe
;;   `[[标题]]'、`[[#custom-id]]'、`https://...' 等）默认会被拒绝。
;;   如果确实要支持，可以往 `org-quote-link-link-handlers' 里加一个
;;   handler，见下面的“扩展接口”。
;;
;; 扩展接口：
;;
;;   `org-quote-link-link-handlers' 是一个 (链接类型 . handler) 的
;;   alist。handler 接收链接元素，返回下列值之一：
;;
;;     - nil：交给默认解析器处理；
;;     - 一个链接字符串（如 "file:~/note.org::*标题"）：先把它当作
;;       新链接再解析。适合把自定义链接类型映射成 file: 链接；
;;     - 一个 plist (:content STRING :org-p BOOL)：直接把 STRING 作为
;;       原始内容（:org-p 决定要不要做 Org 转义）。
;;
;;   默认的 handler 覆盖 denote：
;;
;;     ([[denote:IDENTIFIER]] / [[denote:IDENTIFIER::*标题]] /
;;      [[denote:IDENTIFIER::#custom-id]])
;;
;;   给自定义类型加支持的例子：
;;
;;     (defun my/quote-orgit (link)
;;       (let ((path (org-element-property :path link)))
;;         (format "file:%s" path)))
;;     (add-to-list 'org-quote-link-link-handlers
;;                  '("orgit" . my/quote-orgit))
;;
;;   或者直接提供内容：
;;
;;     (defun my/quote-mu4e (link)
;;       (list :content (my/mu4e-body link) :org-p nil))
;;     (add-to-list 'org-quote-link-link-handlers
;;                  '("mu4e" . my/quote-mu4e))
;;
;; 统一入口：
;;
;;   `org-quote-link' 是推荐的单命令入口，按光标位置分派：
;;
;;     - 在带 `#+HEADER: :transclude [[LINK]]' 的块内 → 刷新该块；
;;     - 在单行 Org 链接上 → 转换成引用块；
;;     - 其它位置 → `user-error'，不改 buffer。
;;
;;   想强制某个动作时，仍然可以直接用 `org-quote-link-at-point' 和
;;   `org-quote-link-refresh'。刷新只依赖 Org，读取块里的 header 行重新抓取
;;   内容；如果你另外使用 org-transclusion-blocks，它的 add 命令也可能识别
;;   这个格式（可选互操作，不是本包的依赖）。
;;
;; 自动刷新：
;;
;;   `org-quote-link-auto-refresh-mode' 是一个全局次模式。开启后每次打开
;;   （`find-file'）Org 文件时，只要 buffer 里有带
;;   `#+HEADER: :transclude [[LINK]]' 的块，就会自动刷新这些块的内容：
;;
;;       (org-quote-link-auto-refresh-mode 1)
;;
;;   刷新是同步的，只处理 Org buffer 里带有此 header 的块；块内容没有变化
;;   时不会把 buffer 标记为已修改。某个块抓取失败（例如目标文件不存在）
;;   不会中止其它块。想手动刷新当前 buffer 的所有块，用
;;   `org-quote-link-refresh-buffer'。
;;
;; 使用方式：
;;
;;     (use-package org-quote-link
;;       :ensure nil
;;       :bind (("C-c q" . org-quote-link)
;;              :map org-mode-map
;;              ("C-c Q" . org-quote-link-refresh))
;;       :config
;;       (org-quote-link-auto-refresh-mode 1))
;;
;; 或者把本文件放到 `load-path' 里 `(require 'org-quote-link)'。
;;
;; 注意：
;;
;;   - 链接必须单独占据一行（只允许行首有空白）。把句子中间的链接变成
;;     quote-block 没有合理语义，所以本包会直接报错而不是自作主张。
;;   - 转义只针对 Org 来源；非 Org 文件默认原样插入，可以用
;;     `org-quote-link-escape-non-org-syntax' 打开对所有来源的转义。
;;     如果转义决定与“Org 来源转义、非 Org 来源不转义”的默认不同，
;;     块里会自动多一行 `#+HEADER: :transclude-escape-org t/no' 记录本次
;;     决定，`org-quote-link-refresh' 刷新时会读取它。这只是一个普通的
;;     Org affiliated keyword，不依赖任何外部包。
;;   - heading 的 property drawer（`:PROPERTIES:' … `:END:'）默认会被
;;     去掉，可以用 `org-quote-link-exclude-elements' 调整。
;;   - 如果链接指向的 heading 正好包含这个链接（或包含要刷新的块），
;;     插入/刷新会形成自我嵌套，本包会拒绝。
;;   - 目标文件不存在、链接打不开、类型不支持等情况都会给出 `user-error'，
;;     不会破坏原来的链接。

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-id)
(require 'ol nil t)
(require 'subr-x)
(require 'cl-lib)

(declare-function org-link-get-parameter "ol" (type parameter))
(declare-function org-link-set-parameters "ol" (type &rest parameters))
(declare-function denote-get-path-by-id "denote" (identifier))

(defgroup org-quote-link nil
  "Turn an Org link into a quoted block."
  :group 'org
  :prefix "org-quote-link-")

(defcustom org-quote-link-block-type "quote"
  "The block type used for the generated quote block.
The value is the name that goes after `#+begin_' and `#+end_'."
  :type '(choice (const "quote")
                 (const "example")
                 (const "verse")
                 (string :tag "Custom block type"))
  :group 'org-quote-link)

(defcustom org-quote-link-include-headline t
  "Whether to include the headline line when the target is a heading.

When non-nil (the default), the target heading itself is inserted
together with its subtree, which is then escaped so that it stays
literal text inside the block.

When nil, the headline line of the target is omitted; its contents,
including nested headlines, are still inserted."
  :type 'boolean
  :group 'org-quote-link)

(defcustom org-quote-link-escape-org-syntax t
  "Whether to escape Org syntax in content coming from Org sources.

Escaping is done with `org-escape-code-in-region': lines starting
with `*' or `#+' get a leading comma.  This keeps the transcluded
text from being reparsed as headlines or keywords inside the
quote block.

This applies to Org sources only.  See also
`org-quote-link-escape-non-org-syntax'."
  :type 'boolean
  :group 'org-quote-link)

(defcustom org-quote-link-escape-non-org-syntax nil
  "Whether to escape Org syntax in content coming from non-Org sources.

Default is nil: content of plain text files, source files, etc. is
inserted verbatim, because Org escaping is only meaningful for Org
content.

Beware that a non-Org file whose line starts with `*' or `#+end_'
can break the surrounding quote block; enable this option if you
quote such files."
  :type 'boolean
  :group 'org-quote-link)

(defcustom org-quote-link-exclude-elements '(property-drawer)
  "Org element types to exclude from inserted Org content.

The default removes property drawers, which are rarely useful in a
quote.  Set to nil to keep everything."
  :type '(repeat symbol)
  :group 'org-quote-link)

(defcustom org-quote-link-link-handlers
  '(("denote" . org-quote-link-denote-handler))
  "Alist of (LINK-TYPE . HANDLER) for extending `org-quote-link'.

The keys are link type strings, as returned by
`org-element-property :type'.  Handlers are tried before the
built-in resolver.  A HANDLER is called with the Org link element
and must return one of:

  - nil, to fall back to the built-in resolver;
  - a link string such as \"file:~/note.org::*Heading\", to be
    resolved as that link instead (use this to map a custom link
    type to a `file:' link);
  - a plist (:content STRING :org-p BOOL), where STRING is used as
    the raw content of the block and :org-p says whether Org
    syntax should be escaped.

The default entry covers `denote:' links, resolving the identifier
with `denote-get-path-by-id' and keeping any `::search' option.

A link type is also accepted out of the box when its Org link
parameters define a `:store' function, because such links can be
created by `org-store-link' (this includes gnus, rmail, bbdb, irc,
eww, orgit, mu4e, … — whatever the respective package registers)."
  :type '(alist :key-type string :value-type function)
  :group 'org-quote-link)

(defconst org-quote-link-core-link-types '("file" "id")
  "Link types produced by `org-store-link' that this package resolves itself.
`file:' is what `org-store-link' creates for headings, targets,
lines, and files; `id:' is created by org-id's store function.
Other link types are supported when they define a `:store' link
parameter, or when a handler is added to
`org-quote-link-link-handlers'.")

(defvar org-quote-link--block-types
  (mapcar (lambda (name) (intern (concat name "-block")))
          '("quote" "example" "verse" "center" "special" "export"
            "comment" "src"))
  "Element types that are considered block elements when refreshing.")

(defvar org-quote-link--inhibit-auto-refresh nil
  "Non-nil while a file is opened internally to fetch a snapshot.
Bind this around link resolution so that files opened only to
fetch a snapshot are not auto-refreshed as a side effect of
`org-quote-link-auto-refresh-mode' or of a command that resolves
another link.")

;;;; Link at point

(defun org-quote-link--link-at-point ()
  "Return the Org link element at point.
Signal a `user-error' when point is not on a link."
  (unless (derived-mode-p 'org-mode)
    (user-error "Point is not in an Org buffer"))
  (let ((context (org-element-context)))
    (cond
     ((eq (org-element-type context) 'link) context)
     (t (user-error "Point is not on an Org link")))))

(defun org-quote-link--link-at-point-p ()
  "Return non-nil when point is on an Org link in an Org buffer."
  (and (derived-mode-p 'org-mode)
       (eq (org-element-type (ignore-errors (org-element-context))) 'link)))

(defun org-quote-link--link-string (link)
  "Return the bracket form of LINK as a string.
When LINK is a plain (non-bracket) link, wrap it with brackets.
Signal a `user-error' if the link spans multiple lines."
  (let* ((raw (string-trim
               (buffer-substring-no-properties
                (org-element-property :begin link)
                (org-element-property :end link))))
         (string (if (string-match-p "\\`\\[\\[" raw)
                     raw
                   (org-link-make-string (org-element-property :raw-link link)))))
    (when (string-match-p "\n" string)
      (user-error "Cannot quote a link that spans multiple lines"))
    (unless (string-match-p "\\`\\[\\[.+\\]\\]\\'" string)
      (user-error "Cannot determine the link string to quote"))
    string))

(defun org-quote-link--line-indent (position)
  "Return the leading whitespace string of the line containing POSITION.
Unlike `current-indentation', the return value is a string made of
the exact characters (spaces and TABs) before POSITION's line text,
so it can safely be re-inserted in front of other lines."
  (save-excursion
    (goto-char position)
    (let ((beg (line-beginning-position)))
      (goto-char beg)
      (skip-chars-forward " \t")
      (buffer-substring-no-properties beg (point)))))

(defun org-quote-link--alone-on-line-p (link)
  "Return non-nil when LINK is the only non-whitespace text on its line."
  (save-excursion
    (goto-char (org-element-property :begin link))
    (and (string-match-p "\\`[ \t]*\\'"
                         (buffer-substring-no-properties
                          (line-beginning-position) (point)))
         (progn
           (goto-char (org-element-property :end link))
           (string-match-p "\\`[ \t]*\\'"
                           (buffer-substring-no-properties
                            (point) (line-end-position)))))))

;;;; Link types and extension interface

(defun org-quote-link--parse-link (string)
  "Parse STRING as an Org link and return the link element."
  (with-temp-buffer
    (insert string)
    (delay-mode-hooks (org-mode))
    (goto-char (point-min))
    (let ((element (org-element-context)))
      (when (eq (org-element-type element) 'link)
        element))))

(defun org-quote-link--effective-type (link)
  "Return the effective link type of LINK.
Some link types are only recognized after their library is
loaded.  Until then Org parses them as fuzzy links.  When the raw
link nevertheless starts with a supported type prefix (for example
`denote:'), report that type so the right handler can run."
  (let ((type (org-element-property :type link))
        (raw (org-element-property :raw-link link)))
    (if (not (member type '("fuzzy" "")))
        type
      (if (and (stringp raw)
               (string-match "\\`\\([[:alnum:]_+-]+\\):" raw))
          (let ((prefix (match-string 1 raw)))
            (if (or (member prefix org-quote-link-core-link-types)
                    (assoc prefix org-quote-link-link-handlers))
                prefix
              type))
        type))))

(defun org-quote-link--search-option (link)
  "Return the search option of LINK, if any.
For `file:' links Org exposes it as `:search-option'.  Other link
types (notably `id:' in older Org versions) keep the `::SEARCH'
part inside `:path'."
  (or (org-element-property :search-option link)
      (let ((path (org-element-property :path link)))
        (when (and (stringp path)
                   (string-match "::\\(.+\\)\\'" path))
          (match-string 1 path)))))

(defun org-quote-link--type-supported-p (type)
  "Return non-nil when TYPE can be created by `org-store-link'.
This is true for the core types (`file', `id'), for any type with
a registered `:store' link parameter, and for types covered by
`org-quote-link-link-handlers'."
  (or (member type org-quote-link-core-link-types)
      (assoc type org-quote-link-link-handlers)
      (and (fboundp 'org-link-get-parameter)
           (org-link-get-parameter type :store))))

;;;; Built-in handler for denote

(defun org-quote-link--denote-target (link)
  "Return (FILE . SEARCH) for denote LINK, or signal an error."
  (require 'denote nil t)
  (unless (fboundp 'denote-get-path-by-id)
    (user-error "This is a `denote:' link but Denote is not loaded"))
  (let* ((raw (or (org-element-property :raw-link link) ""))
         (body (if (string-match "\\`denote:" raw)
                   (substring raw (match-end 0))
                 raw))
         (split (string-match "::\\(.*\\)\\'" body))
         (id (if split (substring body 0 split) body))
         (search (and split (match-string 1 body)))
         (file (ignore-errors (denote-get-path-by-id id))))
    (unless (and (stringp file) (file-exists-p file))
      (user-error "Cannot find the note for denote identifier %S" id))
    (cons (expand-file-name file) search)))

(defun org-quote-link-denote-handler (link)
  "Quote the note referenced by a `denote:' LINK.
This is the handler installed for the \"denote\" link type in
`org-quote-link-link-handlers'.  It resolves the identifier with
`denote-get-path-by-id' and returns an equivalent `file:' link,
keeping any `::*Heading' or `::#custom-id' search option."
  (let* ((target (org-quote-link--denote-target link))
         (file (car target))
         (search (cdr target)))
    (org-link-make-string
     (concat "file:" file (when search (concat "::" search))))))

;;;; Opening links

(defun org-quote-link--target-file (link)
  "Check and expand the file name of LINK when it is a file link."
  (when (equal (org-element-property :type link) "file")
    (let ((path (org-element-property :path link)))
      (when (stringp path)
        (let* ((expanded (expand-file-name path))
               (unescaped (expand-file-name (org-link-unescape path)))
               (file (cond ((file-exists-p expanded) expanded)
                           ((file-exists-p unescaped) unescaped)
                           (t nil))))
          (unless file
            (user-error "Target file does not exist: %s" path))
          file)))))

(defun org-quote-link--open-link (link)
  "Open LINK without displaying it and return (BUFFER . POSITION).

`org-link-open' is used so that Org's own link resolution (heading
search, custom IDs, id: links, search options, third-party link
types) keeps working.  It is bound to not switch windows, to open
files in Emacs instead of external applications, and to never ask
\"create this as a new heading?\"."
  (org-quote-link--target-file link)
  (let ((display-buffer-alist
         '((".*" display-buffer-no-window (allow-no-window t))))
        ;; nil means: no query-to-create prompt, but plain text search
        ;; is still allowed (needed for file::line-text links created
        ;; by `org-store-link').
        (org-link-search-must-match-exact-headline nil)
        (org-file-apps '((t . emacs)))
        (inhibit-message t)
        (message-log-max nil)
        ;; The target buffer may be a new file: do not let the auto-refresh
        ;; hook treat this internal visit as a user-visible file visit.
        (org-quote-link--inhibit-auto-refresh t)
        (origin (current-buffer))
        (origin-point (point))
        result target)
    (condition-case err
        (save-window-excursion
          (save-excursion
            (setq result (org-link-open link))
            (setq target
                  (cond
                   ;; The follow function switched buffers (the usual case).
                   ((not (eq (current-buffer) origin))
                    (cons (current-buffer) (point)))
                   ;; The follow function returned a buffer without
                   ;; switching to it (some third-party link types do this).
                   ((and (bufferp result) (buffer-live-p result))
                    (cons result (with-current-buffer result (point))))
                   ;; A marker from a follow function.
                   ((markerp result)
                    (cons (marker-buffer result) (marker-position result)))
                   ;; Same-buffer targets (e.g. an id: link into the current
                   ;; file) leave point at the target.
                   (t (cons origin (point)))))))
      (error
       (user-error "Cannot open link %s: %s"
                   (or (org-element-property :raw-link link) "?")
                   (error-message-string err))))
    (unless (and (bufferp (car target)) (buffer-live-p (car target)))
      (user-error "Cannot determine the target buffer for link %s"
                  (or (org-element-property :raw-link link) "?")))
    ;; A follow function that neither opens a buffer nor moves point would
    ;; otherwise silently quote the link itself.
    (when (and (eq (car target) origin)
               (= (cdr target) origin-point)
               (not (equal (org-element-property :type link) "file")))
      (user-error
       "The follow function for link type %S did not open a buffer or move point"
       (org-element-property :type link)))
    target))

(defun org-quote-link--text-buffer-p (buffer)
  "Return non-nil when BUFFER holds text that can safely be quoted."
  (with-current-buffer buffer
    (and (not (derived-mode-p 'image-mode 'doc-view-mode 'pdf-view-mode
                              'tar-mode 'archive-mode 'dired-mode))
         (or (derived-mode-p 'org-mode 'text-mode 'prog-mode 'conf-mode
                             'special-mode 'fundamental-mode
                             'emacs-lisp-mode)
             (null buffer-file-name)))))

;;;; Target resolution

(defun org-quote-link--resolve-by-opening (link type)
  "Resolve LINK of TYPE by opening it and inspecting the target buffer."
  (unless (org-quote-link--type-supported-p type)
    (user-error
     "Link type %S is not created by `org-store-link'; add a handler to \
`org-quote-link-link-handlers'"
     type))
  (let* ((search (org-quote-link--search-option link))
         (buffer+pos (org-quote-link--open-link link))
         (buffer (car buffer+pos))
         (pos (cdr buffer+pos)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char pos)
        (let* ((org-p (derived-mode-p 'org-mode))
               (file-type-p (equal type "file"))
               (kind (cond
                      ;; file: without search option quotes the whole file,
                      ;; even when point happens to be on a headline.
                      ((and file-type-p (null search)) 'file)
                      ((and org-p (org-at-heading-p)) 'heading)
                      ((and org-p (or search (not file-type-p))) 'element)
                      (org-p 'file)
                      (t 'file))))
          (unless (or org-p (org-quote-link--text-buffer-p buffer))
            (user-error
             "The target of %s is not a text buffer (%s); add a handler to \
`org-quote-link-link-handlers'"
             (or (org-element-property :raw-link link) "link")
             (buffer-name buffer)))
          (list :buffer buffer
                :pos pos
                :kind kind
                :org-p org-p))))))

(defun org-quote-link--resolve (link &optional seen)
  "Resolve LINK and return a plist describing the content to quote.

The handler registered for LINK's type in
`org-quote-link-link-handlers' is tried first.  It may rewrite the
link or provide the content directly.  Otherwise the link is
opened and its target buffer is inspected.

The returned plist has either `:kind content' and `:content', or
`:buffer', `:pos', `:kind' (`heading', `element' or `file') and
`:org-p'.  SEEN is an internal list of link types already handled,
used to detect handlers that do not actually change the link."
  (let* ((type (org-quote-link--effective-type link))
         (handler (cdr (assoc type org-quote-link-link-handlers))))
    (cond
     ((null handler)
      (org-quote-link--resolve-by-opening link type))
     (t
      (let ((result (funcall handler link)))
        (cond
         ((null result)
          (org-quote-link--resolve-by-opening link type))
         ((stringp result)
          (when (member type seen)
            (user-error
             "The handler for link type %S did not change the link" type))
          (let ((replacement (or (org-quote-link--parse-link result)
                                 (user-error
                                  "Handler for %S returned an unparsable link: %s"
                                  type result))))
            (org-quote-link--resolve replacement (cons type seen))))
         ((and (listp result) (plist-member result :content))
          (list :kind 'content
                :content (or (plist-get result :content) "")
                :org-p (and (plist-get result :org-p) t)))
         (t
          (user-error
           "Handler for link type %S returned an invalid value: %S"
           type result))))))))

;;;; Content extraction

(defun org-quote-link--org-content (beg end &optional drop-headline)
  "Return the Org text between BEG and END as a plain string.
Elements whose type is in `org-quote-link-exclude-elements' are
removed before the text is interpreted.

When DROP-HEADLINE is non-nil, BEG..END is expected to cover a
whole heading; the headline line (and its planning line) is
omitted while its contents are kept.  Parsing the whole heading
first is important: on older Org versions `:contents-begin' starts
before the property drawer, so parsing only the contents region
would no longer recognize the drawer and could not exclude it."
  (save-restriction
    (narrow-to-region beg end)
    (let* ((data (org-element-parse-buffer)))
      (when drop-headline
        ;; The planning line belongs to the headline; drop it together with
        ;; the headline line when only the contents are wanted.
        (org-element-map data 'planning
          (lambda (element)
            (org-element-extract-element element))))
      (dolist (type org-quote-link-exclude-elements)
        (when (memq type org-element-all-elements)
          (org-element-map data type
            (lambda (element)
              (org-element-extract-element element)))))
      (substring-no-properties
       (if drop-headline
           (let ((headline (car-safe (org-element-contents data))))
             (if (eq (org-element-type headline) 'headline)
                 (mapconcat #'org-element-interpret-data
                            (org-element-contents headline)
                            "")
               (org-element-interpret-data data)))
         (org-element-interpret-data data))))))

(defun org-quote-link--element-at (pos)
  "Return the element to quote at POS in the current Org buffer."
  (save-excursion
    (goto-char pos)
    (let ((element (org-element-at-point)))
      ;; A dedicated target: quote the paragraph containing it.
      (when (and (eq (org-element-type element) 'target)
                 (eq (org-element-type (org-element-property :parent element))
                     'paragraph))
        (setq element (org-element-property :parent element)))
      (when (memq (org-element-type element) '(section org-data))
        (setq element (org-element-context)))
      element)))

(defun org-quote-link--heading-content (pos)
  "Return the content of the heading at POS.
The headline line is included when `org-quote-link-include-headline'
is non-nil.  The whole heading is always parsed so that excluded
elements (such as property drawers) are recognized on all Org
versions."
  (save-excursion
    (goto-char pos)
    (let* ((heading (org-element-at-point))
           (beg (org-element-property :begin heading))
           (end (org-element-property :end heading)))
      (if (or (null beg) (null end))
          ""
        (org-quote-link--org-content
         beg end (not org-quote-link-include-headline))))))

(defun org-quote-link--element-content (pos)
  "Return the Org text of the element at POS."
  (save-excursion
    (goto-char pos)
    (let ((element (org-quote-link--element-at pos)))
      (if (not element)
          ""
        (org-quote-link--org-content
         (org-element-property :begin element)
         (org-element-property :end element))))))

(defun org-quote-link--plain-content (buffer)
  "Return the raw text of BUFFER."
  (with-current-buffer buffer
    (unless (org-quote-link--text-buffer-p buffer)
      (user-error "Target buffer is not a text buffer: %s"
                  (buffer-name buffer)))
    (let ((content (buffer-substring-no-properties (point-min) (point-max))))
      (unless (multibyte-string-p content)
        (user-error "Target buffer does not contain text: %s"
                    (buffer-name buffer)))
      content)))

(defun org-quote-link--target-content (target)
  "Return the raw (not yet escaped) content described by TARGET."
  (if (eq (plist-get target :kind) 'content)
      (or (plist-get target :content) "")
    (with-current-buffer (plist-get target :buffer)
      (org-with-wide-buffer
       (pcase (plist-get target :kind)
         ('heading (org-quote-link--heading-content (plist-get target :pos)))
         ('element (org-quote-link--element-content (plist-get target :pos)))
         ('file (if (plist-get target :org-p)
                    (org-quote-link--org-content (point-min) (point-max))
                  (org-quote-link--plain-content (current-buffer))))
         (_ (user-error "Unknown target kind")))))))

;;;; Escaping and formatting

(defun org-quote-link--escape-org-syntax (content)
  "Escape Org syntax in CONTENT with leading commas.
This uses Org's own `org-escape-code-in-region'."
  (with-temp-buffer
    (insert content)
    (org-escape-code-in-region (point-min) (point-max))
    (buffer-string)))

(defun org-quote-link--normalize-content (content)
  "Trim blank lines at both ends of CONTENT and end it with a newline."
  (setq content (replace-regexp-in-string "\\`\n+" "" content))
  (setq content (replace-regexp-in-string "\n+\\'" "" content))
  (if (string-empty-p content)
      ""
    (concat content "\n")))

(defun org-quote-link--escape-source-p (target)
  "Return non-nil when TARGET's content should be Org-escaped."
  (if (plist-get target :org-p)
      org-quote-link-escape-org-syntax
    org-quote-link-escape-non-org-syntax))

(defun org-quote-link--escaped-content (target &optional escape)
  "Return the final, escaped and normalized content for TARGET.
ESCAPE is t or nil to force the escaping decision, or `:default'
to use `org-quote-link-escape-org-syntax' /
`org-quote-link-escape-non-org-syntax' according to TARGET."
  (let* ((content (org-quote-link--target-content target))
         (content (org-quote-link--normalize-content content))
         (escape (if (eq escape :default)
                     (org-quote-link--escape-source-p target)
                   escape)))
    (if escape
        (org-quote-link--escape-org-syntax content)
      content)))

(defun org-quote-link--escape-header (org-p escaped-p)
  "Return an explicit `:transclude-escape-org' header line, or nil.

The natural escaping decision is to escape Org content and to
leave non-Org content alone.  When ORG-P and ESCAPED-P disagree
with that, the block records the decision in a plain affiliated
keyword so `org-quote-link-refresh' reproduces the same content.
This is a self-contained convention of this package; it never
loads or calls another package."
  (cond
   ((eq (and org-p t) (and escaped-p t)) nil)
   (escaped-p "#+HEADER: :transclude-escape-org t")
   (t "#+HEADER: :transclude-escape-org no")))

(defun org-quote-link--block-text (link-string content indent escape-header)
  "Return the text of a quote block for LINK-STRING and CONTENT.
INDENT is a string prepended to the keywords and block delimiters.
ESCAPE-HEADER, when non-nil, is an additional affiliated keyword
line recording the escaping decision (without INDENT)."
  (concat indent "#+HEADER: :transclude " link-string "\n"
          (if escape-header (concat indent escape-header "\n") "")
          indent "#+begin_" org-quote-link-block-type "\n"
          content
          indent "#+end_" org-quote-link-block-type "\n"))

;;;; Self-reference check

(defun org-quote-link--self-reference-p (target pos)
  "Return non-nil when TARGET contains POS in the current buffer.

POS is a position in the current buffer.  Quoting a heading, an
element or the whole current buffer into itself would insert the
link (or the block) into its own content, so both commands refuse
to do it."
  (when (eq (plist-get target :buffer) (current-buffer))
    (pcase (plist-get target :kind)
      ('file t)
      ((or 'heading 'element)
       (save-excursion
         (goto-char (plist-get target :pos))
         (let* ((element (org-element-at-point))
                (beg (org-element-property :begin element))
                (end (org-element-property :end element)))
           (and beg end (<= beg pos) (< pos end)))))
      (_ nil))))

;;;; Commands

;;;###autoload
(defun org-quote-link-at-point ()
  "Replace the Org link at point with a quote block containing its target.

The link must be the only non-whitespace text on its line.  The
result looks like this:

    #+HEADER: :transclude [[file:notes.org::*Heading]]
    #+begin_quote
    ,* Heading
    Contents of the heading…
    #+end_quote

Only link types that `org-store-link' can produce are accepted by
default.  See `org-quote-link-link-handlers' for extending this to
other link types.

See also `org-quote-link' for a single command that picks the
right action based on the position of point."
  (interactive)
  (let* ((link (org-quote-link--link-at-point))
         (link-string (org-quote-link--link-string link)))
    (unless (org-quote-link--alone-on-line-p link)
      (user-error "The link must be alone on its line"))
    ;; Resolve and fetch first: if anything fails, the original link is left
    ;; untouched.
    (let* ((target (org-quote-link--resolve link))
           (line-begin (save-excursion
                         (goto-char (org-element-property :begin link))
                         (line-beginning-position)))
           (indent (org-quote-link--line-indent line-begin)))
      (when (org-quote-link--self-reference-p
             target (org-element-property :begin link))
        (user-error
         "The link target contains this link; refusing to quote it into itself"))
      (let* ((escaped-p (org-quote-link--escape-source-p target))
             (content (org-quote-link--escaped-content target escaped-p))
             (escape-header (org-quote-link--escape-header
                             (plist-get target :org-p) escaped-p))
             (text (org-quote-link--block-text
                    link-string content indent escape-header)))
        (atomic-change-group
          (save-excursion
            (goto-char line-begin)
            (delete-region line-begin (line-end-position))
            ;; TEXT ends with a newline; reuse the original line's newline
            ;; instead of adding a second one.
            (insert (if (string-suffix-p "\n" text)
                        (substring text 0 -1)
                      text))
            (unless (looking-at "\n")
              (insert "\n")))
          (goto-char line-begin))
        (message "Quoted link into a %s block" org-quote-link-block-type)))))

;;;; Refresh

(defun org-quote-link--block-at-point ()
  "Return the block element around point, or nil."
  (let ((element (org-element-at-point)))
    (while (and element
                (not (memq (org-element-type element)
                           org-quote-link--block-types)))
      (setq element (org-element-property :parent element)))
    element))

(defun org-quote-link--block-link-string (block)
  "Return the `:transclude' link string in BLOCK, or nil."
  (or (let ((headers (org-element-property :header block))
            found)
        (dolist (header headers)
          (when (and (not found)
                     (string-match
                      ":transclude[ \t]+\\(\\[\\[.*?\\]\\]\\)" header))
            (setq found (match-string 1 header))))
        found)
      ;; Fallback for Org versions that do not expose HEADER as an
      ;; affiliated keyword: scan the lines between point and the block's
      ;; #+begin_ delimiter.
      (save-excursion
        (goto-char (org-element-property :begin block))
        (let ((limit (or (org-element-property :post-affiliated block)
                         (line-end-position))))
          (when (re-search-forward
                 "^[ \t]*#\\+HEADER:[ \t]*:transclude[ \t]+\\(\\[\\[.*?\\]\\]\\)[ \t]*$"
                 limit t)
            (match-string-no-properties 1))))))

(defun org-quote-link--block-escape-setting (block)
  "Return the explicit `:transclude-escape-org' setting of BLOCK.
The value is t, nil, or `:default' when the block does not say."
  (let ((headers (org-element-property :header block))
        found)
    (dolist (header headers)
      (when (and (not found)
                 (string-match
                  ":transclude-escape-org[ \t]+\\([^ \t\n]+\\)" header))
        (setq found (downcase (match-string 1 header)))))
    (cond
     ((null found) :default)
     ((member found '("nil" "no" "false" "0")) nil)
     (t t))))

(defun org-quote-link--block-content-bounds (block)
  "Return (BEG . END) of the content area of BLOCK."
  (let ((beg (org-element-property :contents-begin block))
        (end (org-element-property :contents-end block)))
    (if (and beg end)
        (cons beg end)
      (save-excursion
        (goto-char (org-element-property :begin block))
        ;; Use the block's own #+begin_NAME / #+end_NAME delimiters.  The
        ;; block may have been written by hand with a type that differs from
        ;; the current `org-quote-link-block-type', and raw-value blocks
        ;; (example, src, comment, export) do not expose contents bounds.
        (unless (re-search-forward "^[ \t]*#\\+begin_\\([^ \t\n]+\\)" nil t)
          (user-error "Cannot find the beginning of the block"))
        (let ((name (match-string-no-properties 1)))
          (forward-line 1)
          (let ((beg (point)))
            (unless (re-search-forward
                     (concat "^[ \t]*#\\+end_" (regexp-quote name))
                     nil t)
              (user-error "Cannot find the end of the block"))
            (forward-line 0)
            (cons beg (point))))))))

(defun org-quote-link--refresh-block (block)
  "Refresh BLOCK and return its new content.
BLOCK must carry a `#+HEADER: :transclude [[LINK]]' line.  Signal
a `user-error' when the link cannot be resolved or when the target
contains BLOCK itself.  Replace the content only when the fetched
text differs from what is already there, so refreshing an
up-to-date block does not mark the buffer as modified."
  (let* ((link-string (or (org-quote-link--block-link-string block)
                          (user-error
                           "This block has no `#+HEADER: :transclude [[LINK]]' line")))
         (link (or (org-quote-link--parse-link link-string)
                   (user-error "Cannot parse link %s" link-string)))
         (bounds (org-quote-link--block-content-bounds block))
         (target (org-quote-link--resolve link)))
    (when (org-quote-link--self-reference-p
           target (org-element-property :begin block))
      (user-error
       "The link target contains this block; refusing to embed it into itself"))
    (let ((content (org-quote-link--escaped-content
                    target (org-quote-link--block-escape-setting block))))
      (unless (equal content
                     (buffer-substring-no-properties (car bounds) (cdr bounds)))
        (atomic-change-group
          (save-excursion
            (goto-char (car bounds))
            (delete-region (car bounds) (cdr bounds))
            (insert content))))
      content)))

;;;###autoload
(defun org-quote-link-refresh ()
  "Re-fetch the content of the org-quote-link block at point.

The block is recognized by its `#+HEADER: :transclude [[LINK]]'
line, so blocks created by `org-quote-link-at-point' as well as
equivalent blocks written by hand can be refreshed.  The content
is replaced with a fresh, escaped snapshot of the link target.

See also `org-quote-link' for a single command that picks the
right action based on the position of point, and
`org-quote-link-refresh-buffer' to refresh every block in the
current buffer at once."
  (interactive)
  (let* ((block (or (org-quote-link--block-at-point)
                    (user-error "Point is not in a block")))
         (content (org-quote-link--refresh-block block)))
    (message "Refreshed org-quote-link block")
    content))

(defun org-quote-link--buffer-has-transclude-p ()
  "Return non-nil when the current buffer may contain a transclude block.
This is a cheap pre-check before the buffer is parsed: it only
looks for a `#+HEADER: :transclude [[LINK]]' line anywhere in the
buffer."
  (org-with-wide-buffer
   (goto-char (point-min))
   (let ((case-fold-search t))
     (re-search-forward
      "^[ \t]*#\\+HEADER:[ \t]*:transclude[ \t]+\\[\\[" nil t))))

(defun org-quote-link--buffer-blocks ()
  "Return all org-quote-link blocks in the current buffer, in buffer order.
A block belongs to this package when it has a
`#+HEADER: :transclude [[LINK]]' line.  Return nil when there is
no such block."
  (when (org-quote-link--buffer-has-transclude-p)
    (org-with-wide-buffer
     (org-element-map (org-element-parse-buffer)
         org-quote-link--block-types
       (lambda (block)
         (when (org-quote-link--block-link-string block)
           block))))))

;;;###autoload
(defun org-quote-link-refresh-buffer ()
  "Refresh every org-quote-link block in the current buffer.

Each block is refreshed as if `org-quote-link-refresh' had been
called inside it.  Blocks whose target cannot be fetched (missing
file, unsupported link type, self-reference, ...) are left
unchanged and do not prevent the other blocks from being
refreshed; a summary is echoed at the end.

Return the number of blocks that were refreshed successfully.
Unlike the automatic refresh done by
`org-quote-link-auto-refresh-mode', this command signals a
`user-error' in a non-Org buffer."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Point is not in an Org buffer"))
  (let ((blocks (org-quote-link--buffer-blocks))
        (refreshed 0)
        (failed 0)
        failure)
    (org-with-wide-buffer
     ;; Refresh from the end of the buffer so that the positions of the
     ;; blocks still to be processed are not shifted by the edits.
     (dolist (block (reverse blocks))
       (condition-case err
           (progn
             (org-quote-link--refresh-block block)
             (setq refreshed (1+ refreshed)))
         (error
          (setq failed (1+ failed))
          (unless failure
            (setq failure
                  (format "line %d: %s"
                          (line-number-at-pos (org-element-property :begin block))
                          (error-message-string err)))))))
     (cond
      ((> failed 0)
       (message "Refreshed %d org-quote-link block(s); %d failed (%s)"
                refreshed failed failure))
      ((called-interactively-p 'interactive)
       (if (> refreshed 0)
           (message "Refreshed %d org-quote-link block(s)" refreshed)
         (message "No org-quote-link blocks in this buffer")))))
    refreshed))

;;;###autoload
(defun org-quote-link ()
  "Quote the Org link at point, or refresh the quote block at point.

This is the recommended command to bind to a key.  It dispatches on
the position of point:

- inside a block that has a `#+HEADER: :transclude [[LINK]]' line:
  refresh that block, like `org-quote-link-refresh';
- on an Org link (which should be alone on its line): replace the
  link with a quote block, like `org-quote-link-at-point';
- anywhere else: signal a `user-error' without modifying the buffer.

The explicit commands `org-quote-link-at-point' and
`org-quote-link-refresh' remain available when you want to force a
specific action regardless of context."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Point is not in an Org buffer"))
  (let ((block (org-quote-link--block-at-point)))
    (cond
     ((and block (org-quote-link--block-link-string block))
      (org-quote-link-refresh))
     ((org-quote-link--link-at-point-p)
      (org-quote-link-at-point))
     (t
      (user-error
       "Point is neither on an Org link nor in an org-quote-link block")))))

;;;; Auto-refresh mode

;; Defined below by `define-minor-mode'; declared here so that the
;; following hook function byte-compiles without a free-variable warning.
(defvar org-quote-link-auto-refresh-mode)

(defun org-quote-link--auto-refresh-find-file ()
  "Refresh all org-quote-link blocks in the buffer just visited.
This is the `find-file-hook' function installed by
`org-quote-link-auto-refresh-mode'.  Nothing happens outside Org
buffers, in buffers without transclude blocks, or when a file is
being opened internally to fetch a snapshot."
  (when (and org-quote-link-auto-refresh-mode
             (derived-mode-p 'org-mode)
             (not org-quote-link--inhibit-auto-refresh))
    (let ((org-quote-link--inhibit-auto-refresh t))
      (condition-case err
          (org-quote-link-refresh-buffer)
        (error
         (message "org-quote-link auto-refresh failed: %s"
                  (error-message-string err)))))))

;;;###autoload
(define-minor-mode org-quote-link-auto-refresh-mode
  "Automatically refresh org-quote-link blocks when visiting Org files.

When this global minor mode is enabled, `find-file-hook' checks
every visited Org buffer.  If the buffer contains blocks with a
`#+HEADER: :transclude [[LINK]]' line, their contents are fetched
again with the same rules as `org-quote-link-refresh'.  A block
whose target cannot be fetched is left unchanged and is reported
without preventing the other blocks from being refreshed.

The refresh runs synchronously.  A buffer is marked as modified
only when at least one block's content actually changed, so merely
visiting an up-to-date file leaves it unmodified.  Buffers opened
indirectly as link targets are not auto-refreshed themselves.

Use `org-quote-link-refresh-buffer' to refresh all blocks in the
current buffer on demand."
  :global t
  :group 'org-quote-link
  :lighter nil
  (if org-quote-link-auto-refresh-mode
      (add-hook 'find-file-hook #'org-quote-link--auto-refresh-find-file)
    (remove-hook 'find-file-hook #'org-quote-link--auto-refresh-find-file)))

(provide 'org-quote-link)
;;; org-quote-link.el ends here
