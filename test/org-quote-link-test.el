;;; org-quote-link-test.el --- Tests for org-quote-link  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Riko

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for org-quote-link.el.  Run them with:
;;
;;   emacs -Q -batch -L . -l test/org-quote-link-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; They are written to pass both with the Org version bundled in older
;; Emacs releases and with a current Org (e.g. 9.7/10.0pre).

;;; Code:

;; Prefer the source so a byte-compiled file from another Emacs
;; version cannot shadow it during development.
(setq load-prefer-newer t)

(require 'ert)
(require 'org)
(require 'org-element)
(require 'org-id)
(require 'org-quote-link)

;;;; Test helpers

(defmacro org-quote-link-test--with-dir (&rest body)
  "Run BODY with `dir' bound to a fresh temporary directory.
Buffers visiting files under DIR are killed afterwards."
  (declare (indent 0) (debug t))
  `(let ((dir (make-temp-file "org-quote-link-test" t)))
     (unwind-protect
         (progn ,@body)
       (let ((truename (file-truename dir)))
         (dolist (buffer (buffer-list))
           (let ((file (buffer-file-name buffer)))
             (when (and file
                        (string-prefix-p truename (file-truename file)))
               (with-current-buffer buffer
                 (set-buffer-modified-p nil))
               (kill-buffer buffer)))))
       (delete-directory dir t))))

(defun org-quote-link-test--write (dir name content)
  "Write CONTENT to NAME inside DIR and return the file name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert content))
    file))

(defun org-quote-link-test--visit (dir name)
  "Visit NAME inside DIR and return its buffer."
  (find-file-noselect (expand-file-name name dir)))

(defun org-quote-link-test--block (link content &optional indent)
  "Build the expected quote block for LINK and CONTENT."
  (let ((indent (or indent "")))
    (concat indent "#+HEADER: :transclude " link "\n"
            indent "#+begin_quote\n"
            content
            indent "#+end_quote\n")))

(defun org-quote-link-test--at (buffer needle)
  "Move point in BUFFER to the beginning of NEEDLE."
  (with-current-buffer buffer
    (goto-char (point-min))
    (unless (search-forward needle nil t)
      (error "Text %S not found" needle))
    (goto-char (match-beginning 0))))

(defun org-quote-link-test--convert (buffer needle)
  "Run `org-quote-link-at-point' on NEEDLE in BUFFER and return its text."
  (with-current-buffer buffer
    (goto-char (point-min))
    (unless (search-forward needle nil t)
      (error "Text %S not found" needle))
    (goto-char (match-beginning 0))
    (org-quote-link-at-point)
    (buffer-string)))

(defun org-quote-link-test--quote-target (dir name content)
  "Return a quote block for NAME in DIR with CONTENT.
The link uses the file name relative to DIR."
  (org-quote-link-test--block
   (org-link-make-string (concat "file:" name)) content))

;;;; Conversion of org-store-link style links

(ert-deftest org-quote-link-test-file-heading ()
  "A file::*heading link quotes the headline and its subtree, escaped."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "* Target Heading\nTarget body.\n\n** Sub\nSub body.\n")
    (org-quote-link-test--write
     dir "main.org"
     "[[file:target.org::*Target Heading][Target Heading]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal
               result
               (org-quote-link-test--block
                "[[file:target.org::*Target Heading][Target Heading]]"
                ",* Target Heading\nTarget body.\n\n,** Sub\nSub body.\n"))))))

(ert-deftest org-quote-link-test-file-custom-id ()
  "A file::#custom-id link quotes the heading."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "* Target Heading\n:PROPERTIES:\n:CUSTOM_ID: cid-1\n:END:\nBody.\n")
    (org-quote-link-test--write
     dir "main.org" "[[file:target.org::#cid-1]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[file:target.org::#cid-1]]"
                      ",* Target Heading\nBody.\n"))))))

(ert-deftest org-quote-link-test-file-target ()
  "A file::target link quotes the paragraph containing the target."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "* Heading\nA paragraph with <<mytarget>> inside.\n")
    (org-quote-link-test--write
     dir "main.org" "[[file:target.org::mytarget]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[file:target.org::mytarget]]"
                      "A paragraph with <<mytarget>> inside.\n"))))))

(ert-deftest org-quote-link-test-file-named-block ()
  "A file::name link quotes the named element, escaped."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "#+name: myblock\n#+begin_src elisp\n(+ 1 2)\n#+end_src\n")
    (org-quote-link-test--write
     dir "main.org" "[[file:target.org::myblock]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (string-match-p "^#\\+HEADER: :transclude \\[\\[file:target.org::myblock\\]\\]$"
                              result))
      (should (string-match-p (regexp-quote ",#+name: myblock") result))
      (should (string-match-p (regexp-quote ",#+begin_src elisp") result))
      (should (string-match-p (regexp-quote "(+ 1 2)") result))
      (should (string-match-p (regexp-quote ",#+end_src") result)))))

(ert-deftest org-quote-link-test-file-text-search ()
  "A file::text link quotes the element at the match."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "* Heading\ntarget line text\n")
    (org-quote-link-test--write
     dir "main.org" "[[file:target.org::target line text]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[file:target.org::target line text]]"
                      "target line text\n"))))))

(ert-deftest org-quote-link-test-file-whole-org ()
  "A file link without search option quotes the whole Org file."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "* Heading\n:PROPERTIES:\n:CUSTOM_ID: cid\n:END:\nBody.\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[file:target.org]]"
                      ",* Heading\nBody.\n"))))))

(ert-deftest org-quote-link-test-file-plain-text ()
  "A link to a non-Org file quotes it verbatim."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "plain.txt" "line one\nline two\n")
    (org-quote-link-test--write dir "main.org" "[[file:plain.txt]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[file:plain.txt]]" "line one\nline two\n"))))))

(ert-deftest org-quote-link-test-id-link ()
  "An id: link quotes the referenced heading."
  (org-quote-link-test--with-dir
    (let* ((target (org-quote-link-test--write
                    dir "target.org"
                    "* ID Heading\n:PROPERTIES:\n:ID: 1234-abcd\n:END:\nid body\n"))
           (org-id-locations-file (expand-file-name ".org-id-locations" dir)))
      (org-id-add-location "1234-abcd" target)
      (org-quote-link-test--write dir "main.org" "[[id:1234-abcd]]\n")
      (let* ((buffer (org-quote-link-test--visit dir "main.org"))
             (result (org-quote-link-test--convert buffer "[[id:")))
        (should (equal result
                       (org-quote-link-test--block
                        "[[id:1234-abcd]]"
                        ",* ID Heading\nid body\n")))))))

(ert-deftest org-quote-link-test-store-link-roundtrip ()
  "Links captured with `org-store-link' can be quoted."
  (org-quote-link-test--with-dir
    (let ((target (org-quote-link-test--write
                   dir "target.org" "* Target Heading\nTarget body.\n")))
      (let* ((target-buffer (org-quote-link-test--visit dir "target.org"))
             (link (with-current-buffer target-buffer
                     (goto-char (point-min))
                     (org-store-link nil nil))))
        (should (stringp link))
        (org-quote-link-test--write
         dir "main.org" (concat link "\n"))
        (let* ((buffer (org-quote-link-test--visit dir "main.org"))
               (result (org-quote-link-test--convert buffer "[[file:")))
          (should (string-match-p
                   (regexp-quote
                    (concat "#+begin_quote\n,* Target Heading\nTarget body.\n#+end_quote\n"))
                   result))
          (should (string-match-p
                   (concat "^#\\+HEADER: :transclude "
                           (regexp-quote link) "$")
                   result)))
        (ignore target)))))

;;;; Escaping

(ert-deftest org-quote-link-test-escapes-org-syntax ()
  "Headlines and keywords inside the quoted subtree are comma-escaped."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "* Heading\n#+custom: value\nText\n** Sub\nSub text\n")
    (org-quote-link-test--write
     dir "main.org" "[[file:target.org::*Heading]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (string-match-p
               (regexp-quote
                ",* Heading\n,#+custom: value\nText\n,** Sub\nSub text\n")
               result))
      ;; The block must stay a quote block after the insertion.
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "#+begin_quote")
        (goto-char (match-beginning 0))
        (should (eq (org-element-type (org-element-at-point)) 'quote-block))))))

(ert-deftest org-quote-link-test-non-org-not-escaped-by-default ()
  "Non-Org content is inserted verbatim by default."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "plain.txt" "* star line\n")
    (org-quote-link-test--write dir "main.org" "[[file:plain.txt]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (string-match-p (regexp-quote "\n* star line\n") result)))))

(ert-deftest org-quote-link-test-non-org-escaped-when-enabled ()
  "Non-Org content is escaped when the option says so."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "plain.txt" "* star line\n")
    (org-quote-link-test--write dir "main.org" "[[file:plain.txt]]\n")
    (let* ((org-quote-link-escape-non-org-syntax t)
           (buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (string-match-p (regexp-quote "\n,* star line\n") result))
      ;; blocks-add must make the same escaping decision when refreshing.
      (should (string-match-p
               (regexp-quote "#+HEADER: :transclude-escape-org t")
               result)))))

;;;; Customization

(ert-deftest org-quote-link-test-without-headline ()
  "With `org-quote-link-include-headline' nil the headline line is omitted."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* Heading\nBody.\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org::*Heading]]\n")
    (let* ((org-quote-link-include-headline nil)
           (buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[file:target.org::*Heading]]" "Body.\n"))))))

(ert-deftest org-quote-link-test-preserves-indentation ()
  "The block delimiters keep the indentation of the replaced link line."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* Heading\nBody.\n")
    (org-quote-link-test--write dir "main.org" "before\n\n  [[file:target.org::*Heading]]\n\nafter\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (concat "before\n\n"
                             (org-quote-link-test--block
                              "[[file:target.org::*Heading]]"
                              ",* Heading\nBody.\n"
                              "  ")
                             "\nafter\n")))
      ;; Still parsed as a quote block whose contents include the body.
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward ",* Heading")
        (let* ((element (org-element-at-point))
               (block (or (and (eq (org-element-type element) 'quote-block) element)
                          (org-element-property :parent element))))
          (should (eq (org-element-type block) 'quote-block))
          (should (string-match-p
                   "Body\\."
                   (buffer-substring-no-properties
                    (org-element-property :contents-begin block)
                    (org-element-property :contents-end block)))))))))

;;;; Refusal of unsupported input

(ert-deftest org-quote-link-test-refuses-non-store-link-types ()
  "Fuzzy, custom-id and https links are refused without changing the buffer."
  (org-quote-link-test--with-dir
    (dolist (link '("[[*Heading]]" "[[#cid]]" "[[https://example.com][Example]]"))
      (let* ((content (concat "* Heading\nbody\n\n" link "\n"))
             (file (org-quote-link-test--write dir "main.org" content))
             (buffer (org-quote-link-test--visit dir "main.org")))
        (with-current-buffer buffer
          (goto-char (point-min))
          (search-forward link)
          (goto-char (match-beginning 0))
          (should-error (org-quote-link-at-point) :type 'user-error)
          (should (equal (buffer-string) content)))
        (kill-buffer buffer)
        (ignore file)))))

(ert-deftest org-quote-link-test-refuses-inline-link ()
  "A link that is not alone on its line is refused."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* Heading\nBody.\n")
    (let* ((content "see [[file:target.org::*Heading]] here\n")
           (buffer (progn
                     (org-quote-link-test--write dir "main.org" content)
                     (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "[[file:")
        (goto-char (match-beginning 0))
        (should-error (org-quote-link-at-point) :type 'user-error)
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-test-refuses-point-not-on-link ()
  "Point that is not on a link is refused."
  (org-quote-link-test--with-dir
    (let ((buffer (progn
                    (org-quote-link-test--write dir "main.org" "plain text\n")
                    (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (should-error (org-quote-link-at-point) :type 'user-error)))))

(ert-deftest org-quote-link-test-refuses-self-reference ()
  "Quoting a heading into itself is refused."
  (org-quote-link-test--with-dir
    (let* ((content "* Target\nbody\n\n[[file:main.org::*Target]]\n")
           (buffer (progn
                     (org-quote-link-test--write dir "main.org" content)
                     (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "[[file:")
        (goto-char (match-beginning 0))
        (should-error (org-quote-link-at-point) :type 'user-error)
        (should (equal (buffer-string) content))))))

;;;; Extension interface

(ert-deftest org-quote-link-test-handler-rewrites-to-file-link ()
  "A handler may return another link to resolve."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* Heading\nBody.\n")
    (let* ((target (expand-file-name "target.org" dir))
           (org-quote-link-link-handlers
            (cons (cons "custom-id"
                        (lambda (_link)
                          (org-link-make-string
                           (concat "file:" target "::*Heading"))))
                  org-quote-link-link-handlers))
           (buffer (progn
                     (org-quote-link-test--write dir "main.org" "[[#cid]]\n")
                     (org-quote-link-test--visit dir "main.org")))
           (result (org-quote-link-test--convert buffer "[[#cid]]")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[#cid]]" ",* Heading\nBody.\n"))))))

(ert-deftest org-quote-link-test-handler-provides-content ()
  "A handler may provide the raw content directly."
  (org-quote-link-test--with-dir
    (org-link-set-parameters
     "org-quote-link-test-content"
     :follow #'ignore
     :store #'ignore)
    (let* ((org-quote-link-link-handlers
            (cons (cons "org-quote-link-test-content"
                        (lambda (_link)
                          (list :content "provided content\n" :org-p nil)))
                  org-quote-link-link-handlers))
           (buffer (progn
                     (org-quote-link-test--write
                      dir "main.org"
                      "[[org-quote-link-test-content:whatever]]\n")
                     (org-quote-link-test--visit dir "main.org")))
           (result (org-quote-link-test--convert
                    buffer "[[org-quote-link-test-content:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[org-quote-link-test-content:whatever]]"
                      "provided content\n"))))))

(ert-deftest org-quote-link-test-store-registered-type ()
  "A type with a :store parameter is resolved by opening the link."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "plain.txt" "opened file content\n")
    (let ((target (expand-file-name "plain.txt" dir)))
      (org-link-set-parameters
       "org-quote-link-test-store"
       :follow (lambda (_path &optional _arg)
                 (set-buffer (find-file-noselect target)))
       :store #'ignore)
      (let* ((buffer (progn
                       (org-quote-link-test--write
                        dir "main.org"
                        "[[org-quote-link-test-store:whatever]]\n")
                       (org-quote-link-test--visit dir "main.org")))
             (result (org-quote-link-test--convert
                      buffer "[[org-quote-link-test-store:")))
        (should (equal result
                       (org-quote-link-test--block
                        "[[org-quote-link-test-store:whatever]]"
                        "opened file content\n")))))))

;;;; Refresh

(ert-deftest org-quote-link-test-refresh-generated-block ()
  "`org-quote-link-refresh' updates a block generated by the command."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* Heading\nold body\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org::*Heading]]\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (target-buffer (org-quote-link-test--visit dir "target.org")))
      (org-quote-link-test--convert buffer "[[file:")
      (with-current-buffer target-buffer
        (erase-buffer)
        (insert "* Heading\nnew body\n"))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "#+begin_quote")
        (org-quote-link-refresh))
      (with-current-buffer buffer
        (should (string-match-p (regexp-quote ",* Heading\nnew body\n")
                                (buffer-string)))
        (should-not (string-match-p (regexp-quote "old body")
                                    (buffer-string)))))))

(ert-deftest org-quote-link-test-refresh-hand-written-block ()
  "`org-quote-link-refresh' works on an equivalent hand-written block."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* Heading\nbody\n")
    (let* ((buffer (progn
                     (org-quote-link-test--write
                      dir "main.org"
                      (concat "#+HEADER: :transclude [[file:target.org::*Heading]]\n"
                              "#+begin_quote\n"
                              "stale content\n"
                              "#+end_quote\n"))
                     (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "stale content")
        (org-quote-link-refresh))
      (with-current-buffer buffer
        (should (string-match-p
                 (regexp-quote
                  "#+begin_quote\n,* Heading\nbody\n#+end_quote\n")
                 (buffer-string)))
        (should-not (string-match-p (regexp-quote "stale content")
                                    (buffer-string)))))))

(ert-deftest org-quote-link-test-refresh-refuses-outside-block ()
  "`org-quote-link-refresh' refuses when point is not in a block."
  (org-quote-link-test--with-dir
    (let ((buffer (progn
                    (org-quote-link-test--write dir "main.org" "text\n")
                    (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (should-error (org-quote-link-refresh) :type 'user-error)))))


;;;; Regression tests (edge cases reported during review)

(ert-deftest org-quote-link-test-tab-indentation ()
  "TAB indentation of the link line is preserved verbatim."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* H\nbody\n")
    (org-quote-link-test--write dir "main.org" "before\n\n\t[[file:target.org::*H]]\nafter\n")
    (let* ((buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (concat "before\n\n"
                             "\t#+HEADER: :transclude [[file:target.org::*H]]\n"
                             "\t#+begin_quote\n"
                             ",* H\nbody\n"
                             "\t#+end_quote\n"
                             "after\n"))))))

(ert-deftest org-quote-link-test-follow-returning-buffer ()
  "A :follow function that returns a buffer without switching is honored."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "plain.txt" "returned buffer content\n")
    (let ((target (expand-file-name "plain.txt" dir)))
      (org-link-set-parameters
       "org-quote-link-test-return"
       :follow (lambda (_path &optional _arg) (find-file-noselect target))
       :store #'ignore)
      (let* ((buffer (progn
                       (org-quote-link-test--write
                        dir "main.org" "[[org-quote-link-test-return:x]]\n")
                       (org-quote-link-test--visit dir "main.org")))
             (result (org-quote-link-test--convert
                      buffer "[[org-quote-link-test-return:")))
        (should (equal result
                       (org-quote-link-test--block
                        "[[org-quote-link-test-return:x]]"
                        "returned buffer content\n")))))))

(ert-deftest org-quote-link-test-no-op-follow-errors ()
  "A :follow function that does nothing must not quote the link itself."
  (org-quote-link-test--with-dir
    (org-link-set-parameters
     "org-quote-link-test-noop"
     :follow #'ignore
     :store #'ignore)
    (let* ((content "[[org-quote-link-test-noop:x]]\n")
           (buffer (progn
                     (org-quote-link-test--write dir "main.org" content)
                     (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "[[org-quote-link-test-noop:")
        (goto-char (match-beginning 0))
        (should-error (org-quote-link-at-point) :type 'user-error)
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-test-refresh-other-block-type ()
  "Refresh works on hand-written blocks whose type is not the current default."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* H\nbody\n")
    (let* ((buffer (progn
                     (org-quote-link-test--write
                      dir "main.org"
                      (concat "#+HEADER: :transclude [[file:target.org::*H]]\n"
                              "#+begin_example\n"
                              "stale\n"
                              "#+end_example\n"))
                     (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "stale")
        (org-quote-link-refresh))
      (with-current-buffer buffer
        (should (string-match-p
                 (regexp-quote
                  "#+begin_example\n,* H\nbody\n#+end_example\n")
                 (buffer-string)))
        (should-not (string-match-p (regexp-quote "stale")
                                    (buffer-string)))))))

(ert-deftest org-quote-link-test-refuses-whole-file-self-reference ()
  "Quoting the current file into itself is refused."
  (org-quote-link-test--with-dir
    (let* ((content "[[file:main.org]]\n")
           (buffer (progn
                     (org-quote-link-test--write dir "main.org" content)
                     (org-quote-link-test--visit dir "main.org"))))
      (org-quote-link-test--at buffer "[[file:")
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "[[file:")
        (goto-char (match-beginning 0))
        (should-error (org-quote-link-at-point) :type 'user-error)
        (should (equal (buffer-string) content))))))


(ert-deftest org-quote-link-test-without-headline-excludes-drawer ()
  "With `org-quote-link-include-headline' nil, property drawers are excluded."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "* PDH\n:PROPERTIES:\n:CUSTOM_ID: pd\n:END:\npbody\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org::*PDH]]\n")
    (let* ((org-quote-link-include-headline nil)
           (buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[file:target.org::*PDH]]" "pbody\n")))
      (should-not (string-match-p (regexp-quote ":PROPERTIES:") result)))))

(ert-deftest org-quote-link-test-explicit-escape-header-when-disabled ()
  "Disabling Org escaping records `:transclude-escape-org no' in the block."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* H\nbody\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org::*H]]\n")
    (let* ((org-quote-link-escape-org-syntax nil)
           (buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (string-match-p
               (regexp-quote "#+HEADER: :transclude-escape-org no")
               result)))))

(ert-deftest org-quote-link-test-refresh-honors-escape-header ()
  "Refresh uses the explicit `:transclude-escape-org' setting of the block."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "star.txt" "* star line\nsecond\n")
    (let* ((buffer (progn
                     (org-quote-link-test--write
                      dir "main.org"
                      (concat "#+HEADER: :transclude [[file:star.txt]]\n"
                              "#+HEADER: :transclude-escape-org t\n"
                              "#+begin_quote\n"
                              "stale\n"
                              "#+end_quote\n"))
                     (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "stale")
        (org-quote-link-refresh))
      (with-current-buffer buffer
        (should (string-match-p (regexp-quote "\n,* star line\n") (buffer-string)))
        (should-not (string-match-p (regexp-quote "\n* star line\n")
                                    (buffer-string)))))))


(ert-deftest org-quote-link-test-without-headline-drops-planning-line ()
  "With `org-quote-link-include-headline' nil the planning line is dropped too."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write
     dir "target.org"
     "* H\nSCHEDULED: <2026-01-01 Thu>\n:PROPERTIES:\n:CUSTOM_ID: p\n:END:\nbody\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org::*H]]\n")
    (let* ((org-quote-link-include-headline nil)
           (buffer (org-quote-link-test--visit dir "main.org"))
           (result (org-quote-link-test--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-test--block
                      "[[file:target.org::*H]]" "body\n")))
      (should-not (string-match-p (regexp-quote "SCHEDULED") result)))))


;;;; Unified `org-quote-link' command (dispatch on point)

(ert-deftest org-quote-link-test-dispatch-converts-link ()
  "On a link, `org-quote-link' converts it."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* H\nbody\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org::*H]]\n")
    (let ((buffer (org-quote-link-test--visit dir "main.org")))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "[[file:")
        (goto-char (match-beginning 0))
        (org-quote-link)
        (should (equal (buffer-string)
                       (org-quote-link-test--block
                        "[[file:target.org::*H]]" ",* H\nbody\n")))))))

(ert-deftest org-quote-link-test-dispatch-refreshes-block ()
  "Inside an org-quote-link block, `org-quote-link' refreshes it."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* H\nold body\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org::*H]]\n")
    (let ((buffer (org-quote-link-test--visit dir "main.org"))
          (target-buffer (org-quote-link-test--visit dir "target.org")))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "[[file:")
        (goto-char (match-beginning 0))
        (org-quote-link))
      (with-current-buffer target-buffer
        (erase-buffer)
        (insert "* H\nnew body\n"))
      ;; Point inside the block body.
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "old body")
        (org-quote-link)
        (should (string-match-p (regexp-quote ",* H\nnew body\n")
                                (buffer-string)))
        (should-not (string-match-p (regexp-quote "old body")
                                    (buffer-string)))
        ;; Point on the #+HEADER line also refreshes.
        (goto-char (point-min))
        (search-forward "#+HEADER")
        (org-quote-link)
        (should (string-match-p (regexp-quote ",* H\nnew body\n")
                                (buffer-string)))))))

(ert-deftest org-quote-link-test-dispatch-refuses-elsewhere ()
  "`org-quote-link' refuses to act where neither action applies."
  (org-quote-link-test--with-dir
    (let* ((content "plain text\n")
           (buffer (progn
                     (org-quote-link-test--write dir "main.org" content)
                     (org-quote-link-test--visit dir "main.org"))))
      (with-current-buffer buffer
        (goto-char (point-min))
        (should-error (org-quote-link) :type 'user-error)
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-test-explicit-commands-still-work ()
  "The explicit convert/refresh commands remain usable directly."
  (org-quote-link-test--with-dir
    (org-quote-link-test--write dir "target.org" "* H\nbody\n")
    (org-quote-link-test--write dir "main.org" "[[file:target.org::*H]]\n")
    (let ((buffer (org-quote-link-test--visit dir "main.org")))
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "[[file:")
        (goto-char (match-beginning 0))
        (org-quote-link-at-point)
        (goto-char (point-min))
        (search-forward "#+begin_quote")
        (org-quote-link-refresh)
        (should (string-match-p (regexp-quote ",* H\nbody\n")
                                (buffer-string)))))))


(ert-deftest org-quote-link-test-dispatch-refuses-non-org-buffer ()
  "`org-quote-link' in a non-Org buffer gives a clear error."
  (let ((buffer (find-file-noselect (make-temp-file "org-quote-link-test" nil ".txt"))))
    (unwind-protect
        (with-current-buffer buffer
          (insert "plain text\n")
          (goto-char (point-min))
          (should-error (org-quote-link) :type 'user-error))
      (kill-buffer buffer))))

(provide 'org-quote-link-test)
;;; org-quote-link-test.el ends here
