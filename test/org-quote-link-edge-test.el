;;; org-quote-link-edge-test.el --- Edge-case tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Riko

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Adversarial edge-case tests for org-quote-link.el.  They are
;; deliberately separate from test/org-quote-link-test.el and focus on
;; boundary conditions, buffer/point side effects, the extension
;; interface, refresh corner cases and version differences.
;;
;; Run them with:
;;
;;   emacs -Q -batch -L . -l test/org-quote-link-edge-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; They pass both with a recent Org (9.7/10.x) and with the Org 9.3
;; bundled in Emacs 27.  A few tests are explicitly version-guarded:
;;
;;   - `...-id-link-with-search' needs Org >= 9.7 (id: search options
;;     are an Org 9.7 feature);
;;   - the single `...-blocks-add-...' test is an optional interop
;;     check: it skips when org-transclusion-blocks is unavailable.
;;     The rest of this file only needs Org.
;;
;; No file outside a per-test temporary directory is written.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)
(require 'org-id)
(require 'org-quote-link)

;;;; Test helpers

(defmacro org-quote-link-edge--with-dir (&rest body)
  "Run BODY with `dir' bound to a fresh temporary directory.
Buffers visiting files under DIR are killed afterwards."
  (declare (indent 0) (debug t))
  `(let ((dir (make-temp-file "org-quote-link-edge" t)))
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

(defun org-quote-link-edge--write (dir name content)
  "Write CONTENT to NAME inside DIR and return the file name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert content))
    file))

(defun org-quote-link-edge--visit (dir name)
  "Visit NAME inside DIR and return its buffer."
  (find-file-noselect (expand-file-name name dir)))

(defun org-quote-link-edge--at (buffer needle)
  "Move point in BUFFER to the beginning of NEEDLE."
  (with-current-buffer buffer
    (goto-char (point-min))
    (unless (search-forward needle nil t)
      (error "Text %S not found" needle))
    (goto-char (match-beginning 0))))

(defun org-quote-link-edge--convert (buffer needle)
  "Run `org-quote-link-at-point' on NEEDLE in BUFFER and return its text."
  (org-quote-link-edge--at buffer needle)
  (with-current-buffer buffer
    (org-quote-link-at-point)
    (buffer-string)))

(defun org-quote-link-edge--refresh (buffer needle)
  "Run `org-quote-link-refresh' at NEEDLE in BUFFER and return its text."
  (org-quote-link-edge--at buffer needle)
  (with-current-buffer buffer
    (org-quote-link-refresh)
    (buffer-string)))

(defun org-quote-link-edge--block (link content &optional indent)
  "Build the expected quote block for LINK and CONTENT with INDENT."
  (let ((indent (or indent "")))
    (concat indent "#+HEADER: :transclude " link "\n"
            indent "#+begin_quote\n"
            content
            indent "#+end_quote\n")))

(defun org-quote-link-edge--skip (reason)
  "Skip the current test with REASON (or pass on very old Emacs)."
  (if (fboundp 'ert-skip)
      (ert-skip reason)
    ;; ERT before 29 has no `ert-skip'; count the test as passed instead
    ;; of failing the suite on an unsupported-version guard.
    (ert-pass)))

(defun org-quote-link-edge--blocks-available-p ()
  "Return non-nil when org-transclusion-blocks can be required."
  (and (require 'org-transclusion nil t)
       (require 'org-transclusion-blocks nil t)
       t))

(defmacro org-quote-link-edge--unless (condition reason &rest body)
  "Run BODY unless CONDITION is non-nil; in that case skip with REASON."
  (declare (indent 2) (debug t))
  `(if ,condition
       (org-quote-link-edge--skip ,reason)
     (progn ,@body)))

;;;; Indentation of the replaced line

(ert-deftest org-quote-link-edge-tab-indentation ()
  "A TAB-indented link line yields a TAB-indented block.
Regression test: `current-indentation' returns COLUMNS, so using it as
a character count used to duplicate the first characters of the link
line inside the generated keywords."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write
     dir "main.org" "before\n\n\t[[file:target.org::*H]]\nafter\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (concat "before\n\n"
                             (org-quote-link-edge--block
                              "[[file:target.org::*H]]"
                              ",* H\nbody\n"
                              "\t")
                             "after\n"))))))

(ert-deftest org-quote-link-edge-mixed-space-tab-indentation ()
  "Mixed space+TAB indentation is preserved literally, not expanded."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write
     dir "main.org" " \t[[file:target.org::*H]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-edge--block
                      "[[file:target.org::*H]]"
                      ",* H\nbody\n"
                      " \t"))))))

(ert-deftest org-quote-link-edge-indentation-does-not-eat-link-text ()
  "The generated block must not contain fragments of the original link line."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write dir "main.org" "\t[[file:target.org::*H]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      ;; Exactly one occurrence of the link, on the HEADER line.
      (let ((start 0)
            (count 0))
        (while (string-match "\\[\\[file:target\\.org::\\*H\\]\\]" result start)
          (setq count (1+ count)
                start (match-end 0)))
        (should (= count 1)))
      (should (string-match-p
               "\\`\t#\\+HEADER: :transclude \\[\\[file:target\\.org::\\*H\\]\\]\\'"
               (car (split-string result "\n")))))))

;;;; Link shapes and positions

(ert-deftest org-quote-link-edge-link-on-last-line-without-newline ()
  "A link on the last line of a buffer without a final newline converts."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write
     dir "main.org" "before\n[[file:target.org::*H]]")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (concat "before\n"
                             (org-quote-link-edge--block
                              "[[file:target.org::*H]]" ",* H\nbody\n")))))))

(ert-deftest org-quote-link-edge-link-at-buffer-start ()
  "A link on the very first line converts and keeps the following text."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write
     dir "main.org" "[[file:target.org::*H]]\nrest\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (concat (org-quote-link-edge--block
                              "[[file:target.org::*H]]" ",* H\nbody\n")
                             "rest\n"))))))

(ert-deftest org-quote-link-edge-trailing-spaces-after-link ()
  "Trailing blanks after a lone link are accepted and dropped."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write
     dir "main.org" "[[file:target.org::*H]]   \n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-edge--block
                      "[[file:target.org::*H]]" ",* H\nbody\n"))))))

(ert-deftest org-quote-link-edge-plain-link-without-brackets ()
  "A plain `file:' link is accepted and the HEADER gets a bracketed link."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write dir "main.org" "file:target.org::*H\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "file:")))
      (should (equal result
                     (org-quote-link-edge--block
                      "[[file:target.org::*H]]" ",* H\nbody\n"))))))

(ert-deftest org-quote-link-edge-description-kept-in-header ()
  "A link description is kept verbatim in the generated HEADER."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write
     dir "main.org" "[[file:target.org::*H][Some description]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-edge--block
                      "[[file:target.org::*H][Some description]]"
                      ",* H\nbody\n"))))))

(ert-deftest org-quote-link-edge-link-with-multiline-description-refused ()
  "A link whose description spans lines is refused before any change."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (let* ((content "[[file:target.org::*H][multi\nline]]\n")
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (org-quote-link-edge--visit dir "main.org")))
      (ignore file)
      (org-quote-link-edge--at buffer "[[file:")
      (should-error (org-quote-link-at-point) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-edge-point-at-link-description-converts ()
  "Conversion works when point is inside the link description."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write
     dir "main.org" "[[file:target.org::*H][Some description]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "Some description")))
      (should (string-match-p
               (regexp-quote "#+begin_quote\n,* H\nbody\n#+end_quote")
               result)))))

;;;; Content extraction boundaries

(ert-deftest org-quote-link-edge-empty-non-org-file ()
  "An empty non-Org target produces an empty (but well-formed) block."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "empty.txt" "")
    (org-quote-link-edge--write dir "main.org" "[[file:empty.txt]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-edge--block "[[file:empty.txt]]" ""))))))

(ert-deftest org-quote-link-edge-empty-heading-and-idempotent-refresh ()
  "A heading without body gives an empty block; refresh stays idempotent."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H2\n")
    (org-quote-link-edge--write dir "main.org" "[[file:target.org::*H2]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org")))
      (should (equal (org-quote-link-edge--convert buffer "[[file:")
                     (org-quote-link-edge--block
                      "[[file:target.org::*H2]]" ",* H2\n")))
      (let ((once (org-quote-link-edge--refresh buffer "#+begin_quote")))
        (should (equal once
                       (org-quote-link-edge--block
                        "[[file:target.org::*H2]]" ",* H2\n")))
        (let ((twice (org-quote-link-edge--refresh buffer "#+begin_quote")))
          (should (equal twice once)))))))

(ert-deftest org-quote-link-edge-whitespace-only-non-org-file ()
  "A whitespace-only non-Org target keeps its (trimmed) whitespace."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "ws.txt" "\n \n\t\n")
    (org-quote-link-edge--write dir "main.org" "[[file:ws.txt]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-edge--block
                      "[[file:ws.txt]]" " \n\t\n"))))))

(ert-deftest org-quote-link-edge-whole-org-file-with-preamble ()
  "Quoting a whole Org file keeps text before the first heading, escaped."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "pre.org" "preamble text\n\n* H\nbody\n")
    (org-quote-link-edge--write dir "main.org" "[[file:pre.org]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-edge--block
                      "[[file:pre.org]]"
                      "preamble text\n\n,* H\nbody\n"))))))

(ert-deftest org-quote-link-edge-include-headline-nil-keeps-children ()
  "With `org-quote-link-include-headline' nil the subtree is still quoted."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write
     dir "tree.org" "* Top\nbody\n** Child A\na\n** Child B\nb\n")
    (org-quote-link-edge--write dir "main.org" "[[file:tree.org::*Top]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (org-quote-link-include-headline nil)
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-edge--block
                      "[[file:tree.org::*Top]]"
                      "body\n,** Child A\na\n,** Child B\nb\n"))))))

(ert-deftest org-quote-link-edge-exclude-elements-nil-keeps-drawer ()
  "Setting `org-quote-link-exclude-elements' to nil keeps the drawer."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write
     dir "pd.org" "* PDH\n:PROPERTIES:\n:CUSTOM_ID: pd\n:END:\npbody\n")
    (org-quote-link-edge--write dir "main.org" "[[file:pd.org::*PDH]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (org-quote-link-exclude-elements nil)
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (string-match-p (regexp-quote ":PROPERTIES:\n:CUSTOM_ID: pd\n:END:")
                              result)))))

(ert-deftest org-quote-link-edge-id-link-with-include-headline-nil ()
  "An id: link to a heading honors `org-quote-link-include-headline' nil."
  (org-quote-link-edge--with-dir
    (let* ((target (org-quote-link-edge--write
                    dir "target.org" "* ID Heading\n:PROPERTIES:\n:ID: edge-id-1\n:END:\nid body\n"))
           (org-id-locations-file (expand-file-name ".org-id-locations" dir)))
      (org-id-add-location "edge-id-1" target)
      (org-quote-link-edge--write dir "main.org" "[[id:edge-id-1]]\n")
      (let ((buffer (org-quote-link-edge--visit dir "main.org"))
            (org-quote-link-include-headline nil))
        (org-quote-link-edge--at buffer "[[id:")
        (with-current-buffer buffer
          (org-quote-link-at-point)
          (should (equal (buffer-string)
                         (org-quote-link-edge--block
                          "[[id:edge-id-1]]" "id body\n"))))))))

;;;; Narrowed / read-only / special buffers

(ert-deftest org-quote-link-edge-narrowed-main-buffer ()
  "Conversion works when the main buffer is narrowed around the link line."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write dir "main.org" "x\n[[file:target.org::*H]]\ny\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (result
            (with-current-buffer buffer
              (org-quote-link-edge--at buffer "[[file:")
              (save-restriction
                (narrow-to-region (line-beginning-position) (line-end-position))
                (org-quote-link-at-point)
                (buffer-string)))))
      (should (string-match-p "\\`#\\+HEADER: :transclude \\[\\[file:target\\.org::\\*H\\]\\]"
                              result))
      (should (string-match-p (regexp-quote "#+begin_quote\n,* H\nbody\n#+end_quote")
                              result))
      (should-not (string-match-p "\\[\\[file:target.org::\\*H\\]\\]\n.*\\[\\[" result)))))

(ert-deftest org-quote-link-edge-narrowed-target-buffer ()
  "A heading outside a narrowed target buffer is still quoted."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "tn.org" "* Out\noutside\n* In\ninside\n")
    (org-quote-link-edge--write dir "main.org" "[[file:tn.org::*Out]]\n")
    (let ((target-buffer (org-quote-link-edge--visit dir "tn.org")))
      (with-current-buffer target-buffer
        (goto-char (point-min))
        (search-forward "* In")
        (goto-char (match-beginning 0))
        (org-narrow-to-subtree))
      (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
             (result (org-quote-link-edge--convert buffer "[[file:")))
        (should (equal result
                       (org-quote-link-edge--block
                        "[[file:tn.org::*Out]]" ",* Out\noutside\n")))))))

(ert-deftest org-quote-link-edge-read-only-buffer-unchanged ()
  "A read-only main buffer signals an error and is left unchanged."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (let* ((content "[[file:target.org::*H]]\n")
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (org-quote-link-edge--visit dir "main.org")))
      (ignore file)
      (with-current-buffer buffer
        (read-only-mode 1)
        (goto-char (point-min))
        (should-error (org-quote-link-at-point) :type 'buffer-read-only)
        (read-only-mode -1)
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-edge-non-org-buffer-refused ()
  "`org-quote-link-at-point' refuses to run outside `org-mode'."
  (let ((buffer (get-buffer-create "*org-quote-link-edge-nonorg*")))
    (unwind-protect
        (with-current-buffer buffer
          (erase-buffer)
          (insert "some text\n")
          (fundamental-mode)
          (goto-char (point-min))
          (should-error (org-quote-link-at-point) :type 'user-error)
          (should (equal (buffer-string) "some text\n")))
      (kill-buffer buffer))))

;;;; Refusals that must not touch the buffer

(ert-deftest org-quote-link-edge-refuses-unsupported-elisp-link ()
  "An `elisp:' link (registered :follow, no :store) is refused untouched."
  (org-quote-link-edge--with-dir
    (let* ((content "[[elisp:(+ 1 2)]]\n")
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (org-quote-link-edge--visit dir "main.org")))
      (ignore file)
      (org-quote-link-edge--at buffer "[[elisp:")
      (should-error (org-quote-link-at-point) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-edge-missing-target-file-unchanged ()
  "A file link to a missing file is refused before changing the buffer."
  (org-quote-link-edge--with-dir
    (let* ((content "[[file:/tmp/org-quote-link-edge-does-not-exist.org]]\n")
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (org-quote-link-edge--visit dir "main.org")))
      (ignore file)
      (org-quote-link-edge--at buffer "[[file:")
      (should-error (org-quote-link-at-point) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-edge-non-text-target-refused ()
  "A `:store' link whose follow opens a non-text buffer is refused."
  (org-quote-link-edge--with-dir
    (org-link-set-parameters
     "org-quote-link-edge-dired"
     :follow (lambda (_path &optional _arg)
               (let ((buffer (get-buffer-create "*org-quote-link-edge-dired*")))
                 (with-current-buffer buffer
                   (dired-mode dir))
                 (set-buffer buffer)
                 buffer))
     :store #'ignore)
    (let* ((content "[[org-quote-link-edge-dired:whatever]]\n")
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (org-quote-link-edge--visit dir "main.org")))
      (ignore file)
      (unwind-protect
          (progn
            (org-quote-link-edge--at buffer "[[org-quote-link-edge-dired:")
            (should-error (org-quote-link-at-point) :type 'user-error)
            (with-current-buffer buffer
              (should (equal (buffer-string) content))))
        (let ((fake (get-buffer "*org-quote-link-edge-dired*")))
          (when fake (kill-buffer fake)))))))

;;;; Extension interface: `:store' types and handlers

(ert-deftest org-quote-link-edge-follow-returns-buffer-without-switching ()
  "A follow that returns a buffer without switching is still resolved.
Regression test: `org-quote-link--open-link' used to ignore the value
returned by `org-link-open' and to quote the source link line itself."
  (org-quote-link-edge--with-dir
    (let ((target (org-quote-link-edge--write dir "target.txt" "target text\n")))
      (org-link-set-parameters
       "org-quote-link-edge-noswitch"
       :follow (lambda (_path &optional _arg) (find-file-noselect target))
       :store #'ignore)
      (org-quote-link-edge--write
       dir "main.org" "[[org-quote-link-edge-noswitch:x]]\n")
      (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
             (result (org-quote-link-edge--convert
                      buffer "[[org-quote-link-edge-noswitch:")))
        (should (equal result
                       (org-quote-link-edge--block
                        "[[org-quote-link-edge-noswitch:x]]"
                        "target text\n")))))))

(ert-deftest org-quote-link-edge-follow-does-nothing-refused ()
  "A follow that neither opens a buffer nor moves point is refused."
  (org-quote-link-edge--with-dir
    (org-link-set-parameters
     "org-quote-link-edge-noop"
     :follow (lambda (_path &optional _arg) nil)
     :store #'ignore)
    (let* ((content "[[org-quote-link-edge-noop:x]]\n")
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (org-quote-link-edge--visit dir "main.org")))
      (ignore file)
      (org-quote-link-edge--at buffer "[[org-quote-link-edge-noop:")
      (should-error (org-quote-link-at-point) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-edge-handler-nil-falls-back ()
  "A handler returning nil falls back to the generic `:store' resolver."
  (org-quote-link-edge--with-dir
    (let ((target (org-quote-link-edge--write dir "fallback.txt" "fallback text\n")))
      (org-link-set-parameters
       "org-quote-link-edge-fallback"
       :follow (lambda (_path &optional _arg)
                 (set-buffer (find-file-noselect target))
                 (goto-char (point-min)))
       :store #'ignore)
      (let ((org-quote-link-link-handlers
             (cons (cons "org-quote-link-edge-fallback"
                         (lambda (_link) nil))
                   org-quote-link-link-handlers)))
        (org-quote-link-edge--write
         dir "main.org" "[[org-quote-link-edge-fallback:x]]\n")
        (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
               (result (org-quote-link-edge--convert
                        buffer "[[org-quote-link-edge-fallback:")))
          (should (equal result
                         (org-quote-link-edge--block
                          "[[org-quote-link-edge-fallback:x]]"
                          "fallback text\n"))))))))

(ert-deftest org-quote-link-edge-handler-content-org-p-escapes ()
  "Handler content with :org-p t is escaped like other Org content."
  (org-quote-link-edge--with-dir
    (org-link-set-parameters
     "org-quote-link-edge-content"
     :follow #'ignore :store #'ignore)
    (let ((org-quote-link-link-handlers
           (cons (cons "org-quote-link-edge-content"
                       (lambda (_link)
                         (list :content "* star\n#+end_quote\nplain\n"
                               :org-p t)))
                 org-quote-link-link-handlers)))
      (org-quote-link-edge--write dir "main.org" "[[org-quote-link-edge-content:x]]\n")
      (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
             (result (org-quote-link-edge--convert
                      buffer "[[org-quote-link-edge-content:")))
        ;; The handler's content is Org, which is the natural case for
        ;; escaping, so no extra escape header is needed.
        (should (equal result
                       (concat
                        "#+HEADER: :transclude [[org-quote-link-edge-content:x]]\n"
                        "#+begin_quote\n,* star\n,#+end_quote\nplain\n#+end_quote\n")))))))

(ert-deftest org-quote-link-edge-handler-same-type-loop-refused ()
  "A handler that returns a link of its own type is refused (no recursion)."
  (org-quote-link-edge--with-dir
    (org-link-set-parameters
     "org-quote-link-edge-loop" :follow #'ignore :store #'ignore)
    (let ((org-quote-link-link-handlers
           (cons (cons "org-quote-link-edge-loop"
                       (lambda (_link) "[[org-quote-link-edge-loop:y]]"))
                 org-quote-link-link-handlers)))
      (let* ((content "[[org-quote-link-edge-loop:x]]\n")
             (file (org-quote-link-edge--write dir "main.org" content))
             (buffer (org-quote-link-edge--visit dir "main.org")))
        (ignore file)
        (org-quote-link-edge--at buffer "[[org-quote-link-edge-loop:")
        (should-error (org-quote-link-at-point) :type 'user-error)
        (with-current-buffer buffer
          (should (equal (buffer-string) content)))))))

(ert-deftest org-quote-link-edge-handler-invalid-values-refused ()
  "Handlers returning invalid values or unparsable links are refused."
  (org-quote-link-edge--with-dir
    (org-link-set-parameters
     "org-quote-link-edge-invalid" :follow #'ignore :store #'ignore)
    (dolist (return-value '(42 "not a link"))
      (let* ((org-quote-link-link-handlers
              (cons (cons "org-quote-link-edge-invalid"
                          (lambda (_link) return-value))
                    org-quote-link-link-handlers))
             (content "[[org-quote-link-edge-invalid:x]]\n")
             (file (org-quote-link-edge--write dir "main.org" content))
             (buffer (org-quote-link-edge--visit dir "main.org")))
        (ignore file)
        (org-quote-link-edge--at buffer "[[org-quote-link-edge-invalid:")
        (should-error (org-quote-link-at-point) :type 'user-error)
        (with-current-buffer buffer
          (should (equal (buffer-string) content)))
        (kill-buffer buffer)))))

(ert-deftest org-quote-link-edge-denote-unresolved-refused ()
  "An unresolvable denote: link is refused without buffer changes."
  (org-quote-link-edge--with-dir
    (let* ((content "[[denote:org-quote-link-edge-no-such-id]]\n")
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (org-quote-link-edge--visit dir "main.org")))
      (ignore file)
      (org-quote-link-edge--at buffer "[[denote:")
      (should-error (org-quote-link-at-point) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) content))))))

(ert-deftest org-quote-link-edge-handler-rewritten-block-refreshable ()
  "A block created through a rewriting handler can be refreshed."
  (org-quote-link-edge--with-dir
    (let* ((target (org-quote-link-edge--write
                    dir "cid.org"
                    "* CidH\n:PROPERTIES:\n:CUSTOM_ID: edge-cid\n:END:\ncid body\n"))
           (org-quote-link-link-handlers
            (cons (cons "custom-id"
                        (lambda (link)
                          (org-link-make-string
                           (concat "file:" target "::#"
                                   (org-element-property :path link)))))
                  org-quote-link-link-handlers)))
      (org-quote-link-edge--write dir "main.org" "[[#edge-cid]]\n")
      (let ((buffer (org-quote-link-edge--visit dir "main.org")))
        (should (equal (org-quote-link-edge--convert buffer "[[#edge-cid]]")
                       (org-quote-link-edge--block
                        "[[#edge-cid]]" ",* CidH\ncid body\n")))
        (should (equal (org-quote-link-edge--refresh buffer "#+begin_quote")
                       (org-quote-link-edge--block
                        "[[#edge-cid]]" ",* CidH\ncid body\n")))))))

;;;; Refresh corner cases

(ert-deftest org-quote-link-edge-refresh-from-any-position-in-block ()
  "Refresh works with point on HEADER, BEGIN, body or END lines."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (let ((index 0))
      (dolist (needle '("#+HEADER:" "#+begin_quote" "stale" "#+end_quote"))
        (setq index (1+ index))
        (let* ((content (concat
                         "#+HEADER: :transclude [[file:target.org::*H]]\n"
                         "#+begin_quote\nstale\n#+end_quote\n"))
               (file (org-quote-link-edge--write
                      dir (format "r-%d.org" index) content))
               (buffer (find-file-noselect file)))
          (ignore file)
          (should (equal (org-quote-link-edge--refresh buffer needle)
                         (org-quote-link-edge--block
                          "[[file:target.org::*H]]" ",* H\nbody\n")))
          (kill-buffer buffer))))))

(ert-deftest org-quote-link-edge-refresh-multiple-header-lines ()
  "Refresh finds :transclude among several affiliated HEADER lines."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (let* ((content (concat
                     "#+HEADER: :tangle no\n"
                     "#+HEADER: :transclude [[file:target.org::*H]]\n"
                     "#+begin_quote\nstale\n#+end_quote\n"))
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (find-file-noselect file)))
      (ignore file)
      (should (equal (org-quote-link-edge--refresh buffer "stale")
                     (concat "#+HEADER: :tangle no\n"
                             (org-quote-link-edge--block
                              "[[file:target.org::*H]]" ",* H\nbody\n"))))
      (kill-buffer buffer))))

(ert-deftest org-quote-link-edge-refresh-header-with-extra-arguments ()
  "Refresh works when the HEADER carries arguments after the link."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (let* ((content (concat
                     "#+HEADER: :transclude [[file:target.org::*H]] :foo bar\n"
                     "#+begin_quote\nstale\n#+end_quote\n"))
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (find-file-noselect file)))
      (ignore file)
      (should (equal (org-quote-link-edge--refresh buffer "stale")
                     (concat "#+HEADER: :transclude [[file:target.org::*H]] :foo bar\n"
                             "#+begin_quote\n,* H\nbody\n#+end_quote\n")))
      (kill-buffer buffer))))

(ert-deftest org-quote-link-edge-refresh-empty-handwritten-block ()
  "Refresh fills a hand-written empty block."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (let* ((content (concat
                     "#+HEADER: :transclude [[file:target.org::*H]]\n"
                     "#+begin_quote\n#+end_quote\n"))
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (find-file-noselect file)))
      (ignore file)
      (should (equal (org-quote-link-edge--refresh buffer "#+begin_quote")
                     (org-quote-link-edge--block
                      "[[file:target.org::*H]]" ",* H\nbody\n")))
      (kill-buffer buffer))))

(ert-deftest org-quote-link-edge-refresh-custom-block-type ()
  "Conversion and refresh work with `org-quote-link-block-type' changed."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write dir "main.org" "[[file:target.org::*H]]\n")
    (let ((org-quote-link-block-type "example")
          (buffer (org-quote-link-edge--visit dir "main.org")))
      (should (equal (org-quote-link-edge--convert buffer "[[file:")
                     (concat "#+HEADER: :transclude [[file:target.org::*H]]\n"
                             "#+begin_example\n,* H\nbody\n#+end_example\n")))
      (should (equal (org-quote-link-edge--refresh buffer "#+begin_example")
                     (concat "#+HEADER: :transclude [[file:target.org::*H]]\n"
                             "#+begin_example\n,* H\nbody\n#+end_example\n"))))))

(ert-deftest org-quote-link-edge-refresh-handwritten-example-block ()
  "Refresh works on a hand-written example block with the default type.
Regression test: the content-bounds fallback used to search for the
defcustom'd block type instead of the block's own delimiter."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (let* ((content (concat
                     "#+HEADER: :transclude [[file:target.org::*H]]\n"
                     "#+begin_example\nstale\n#+end_example\n"))
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (find-file-noselect file)))
      (ignore file)
      (should (equal (org-quote-link-edge--refresh buffer "stale")
                     (concat "#+HEADER: :transclude [[file:target.org::*H]]\n"
                             "#+begin_example\n,* H\nbody\n#+end_example\n")))
      (kill-buffer buffer))))

(ert-deftest org-quote-link-edge-refresh-self-reference-refused ()
  "A block inside the heading it quotes is refused, unchanged."
  (org-quote-link-edge--with-dir
    (let* ((content (concat
                     "* Self\nbody\n\n"
                     "#+HEADER: :transclude [[file:self.org::*Self]]\n"
                     "#+begin_quote\nstale\n#+end_quote\n"))
           (file (org-quote-link-edge--write dir "self.org" content))
           (buffer (find-file-noselect file)))
      (ignore file)
      (org-quote-link-edge--at buffer "stale")
      (should-error (org-quote-link-refresh) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) content)))
      (kill-buffer buffer))))

(ert-deftest org-quote-link-edge-refresh-whole-file-self-reference-refused ()
  "A whole-file block in the file it quotes is refused, unchanged."
  (org-quote-link-edge--with-dir
    (let* ((content (concat
                     "#+HEADER: :transclude [[file:self-whole.org]]\n"
                     "#+begin_quote\nstale\n#+end_quote\n"))
           (file (org-quote-link-edge--write dir "self-whole.org" content))
           (buffer (find-file-noselect file)))
      (ignore file)
      (org-quote-link-edge--at buffer "stale")
      (should-error (org-quote-link-refresh) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) content)))
      (kill-buffer buffer))))

(ert-deftest org-quote-link-edge-convert-whole-file-self-reference-refused ()
  "Quoting the current whole file into itself is refused, unchanged."
  (org-quote-link-edge--with-dir
    (let* ((content "text\n\n[[file:whole-self.org]]\n")
           (file (org-quote-link-edge--write dir "whole-self.org" content))
           (buffer (find-file-noselect file)))
      (ignore file)
      (org-quote-link-edge--at buffer "[[file:")
      (should-error (org-quote-link-at-point) :type 'user-error)
      (with-current-buffer buffer
        (should (equal (buffer-string) content)))
      (kill-buffer buffer))))

(ert-deftest org-quote-link-edge-refresh-missing-target-keeps-block ()
  "Refresh with a now-missing target signals and keeps the block intact."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write dir "main.org" "[[file:target.org::*H]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org")))
      (org-quote-link-edge--convert buffer "[[file:")
      (delete-file (expand-file-name "target.org" dir))
      (let ((before (with-current-buffer buffer (buffer-string))))
        (org-quote-link-edge--at buffer "#+begin_quote")
        (should-error (org-quote-link-refresh) :type 'user-error)
        (with-current-buffer buffer
          (should (equal (buffer-string) before)))))))

(ert-deftest org-quote-link-edge-conversion-leaves-point-at-block-start ()
  "Conversion leaves point on the HEADER line (org-transclusion-blocks-add)."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "target.org" "* H\nbody\n")
    (org-quote-link-edge--write dir "main.org" "[[file:target.org::*H]]\n")
    (let ((buffer (org-quote-link-edge--visit dir "main.org")))
      (org-quote-link-edge--at buffer "[[file:")
      (with-current-buffer buffer
        (org-quote-link-at-point)
        (should (looking-at "#\\+HEADER: :transclude"))))))

;;;; Version-guarded tests

(ert-deftest org-quote-link-edge-property-drawer-without-headline ()
  "With `org-quote-link-include-headline' nil the drawer is still excluded.
Regression test for Org 9.3: narrowing to `:contents-begin' there starts
before the property drawer and loses the headline context, so the parser
no longer recognised `:PROPERTIES:' as a property-drawer and the drawer
used to leak into the quote."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write
     dir "pd.org" "* PDH\n:PROPERTIES:\n:CUSTOM_ID: pd\n:END:\npbody\n")
    (org-quote-link-edge--write dir "main.org" "[[file:pd.org::*PDH]]\n")
    (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
           (org-quote-link-include-headline nil)
           (result (org-quote-link-edge--convert buffer "[[file:")))
      (should (equal result
                     (org-quote-link-edge--block
                      "[[file:pd.org::*PDH]]" "pbody\n")))
      (should-not (string-match-p "PROPERTIES" result)))))

(ert-deftest org-quote-link-edge-id-link-with-search ()
  "An id:UUID::*heading link quotes the child heading (Org >= 9.7)."
  (org-quote-link-edge--unless
      (version< org-version "9.7")
      "id: links with a search option need Org >= 9.7"
    (org-quote-link-edge--with-dir
      (let* ((target (org-quote-link-edge--write
                      dir "target.org"
                      (concat "* Parent\n:PROPERTIES:\n:ID: edge-parent\n:END:\n"
                              "parent body\n\n** Child\nchild body\n")))
             (org-id-locations-file (expand-file-name ".org-id-locations" dir)))
        (org-id-add-location "edge-parent" target)
        (org-quote-link-edge--write dir "main.org" "[[id:edge-parent::*Child]]\n")
        (let* ((buffer (org-quote-link-edge--visit dir "main.org"))
               (result (org-quote-link-edge--convert buffer "[[id:")))
          (should (equal result
                         (org-quote-link-edge--block
                          "[[id:edge-parent::*Child]]"
                          ",** Child\nchild body\n"))))))))

(ert-deftest org-quote-link-edge-blocks-add-keeps-escaped-non-org ()
  "A block for escaped non-Org content stays valid after blocks-add.
With `org-quote-link-escape-non-org-syntax' the generated block must
tell org-transclusion-blocks to escape as well (a literal `* ' line
would otherwise truncate the quote block on refresh)."
  (org-quote-link-edge--unless
      (not (org-quote-link-edge--blocks-available-p))
      "org-transclusion-blocks is not available"
    (org-quote-link-edge--with-dir
      (org-quote-link-edge--write dir "star.txt" "* star line\nsecond\n")
      (org-quote-link-edge--write dir "main.org" "[[file:star.txt]]\n")
      (let* ((org-quote-link-escape-non-org-syntax t)
             (buffer (org-quote-link-edge--visit dir "main.org")))
        (should (equal (org-quote-link-edge--convert buffer "[[file:")
                       (concat
                        "#+HEADER: :transclude [[file:star.txt]]\n"
                        "#+HEADER: :transclude-escape-org t\n"
                        "#+begin_quote\n,* star line\nsecond\n#+end_quote\n")))
        (with-current-buffer buffer
          (goto-char (point-min))
          (should (org-transclusion-blocks-add))
          (should (string-match-p (regexp-quote ",* star line")
                                  (buffer-string)))
          (should-not (string-match-p "^\\* star line" (buffer-string))))))))

;;;; org-transclusion-blocks escaping handshake

(ert-deftest org-quote-link-edge-escape-header-decision-table ()
  "The explicit `:transclude-escape-org' header is only emitted on a mismatch.
Org targets (blocks default: escape) with default settings and non-Org
targets without `org-quote-link-escape-non-org-syntax' need no explicit
header; a non-Org target that we escape and an Org source whose escaping
we disabled do."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "t.org" "* H\nbody\n")
    (org-quote-link-edge--write dir "star.txt" "* raw star\n")
    (let ((cases
           '(;; (file contents, settings thunk, expect escape header)
             ("org-default.org" "[[file:t.org::*H]]\n"
              (lambda () (setq org-quote-link-escape-org-syntax t))
              nil)
             ("plain-default.org" "[[file:star.txt]]\n"
              (lambda () (setq org-quote-link-escape-non-org-syntax nil))
              nil)
             ("plain-escaped.org" "[[file:star.txt]]\n"
              (lambda () (setq org-quote-link-escape-non-org-syntax t))
              ":transclude-escape-org t")
             ("org-unescaped.org" "[[file:t.org::*H]]\n"
              (lambda () (setq org-quote-link-escape-org-syntax nil))
              ":transclude-escape-org no"))))
      (dolist (case cases)
        (let* ((name (nth 0 case))
               (contents (nth 1 case))
               (settings (nth 2 case))
               (expected (nth 3 case))
               (file (org-quote-link-edge--write dir name contents))
               (buffer (find-file-noselect file))
               result)
          (ignore file)
          (let ((org-quote-link-escape-org-syntax t)
                (org-quote-link-escape-non-org-syntax nil))
            (funcall settings)
            (setq result (org-quote-link-edge--convert buffer "[[file:")))
          (if expected
              (should (string-match-p (regexp-quote expected) result))
            (should-not (string-match-p ":transclude-escape-org" result)))
          (kill-buffer buffer))))))

(ert-deftest org-quote-link-edge-refresh-honors-escape-header ()
  "Refresh honors an explicit `:transclude-escape-org t' header.
A hand-written block for a non-Org source that asks blocks to escape
must be refreshed escaped, matching what blocks-add would insert."
  (org-quote-link-edge--with-dir
    (org-quote-link-edge--write dir "star.txt" "* raw star\nsecond\n")
    (let* ((content (concat
                     "#+HEADER: :transclude [[file:star.txt]]\n"
                     "#+HEADER: :transclude-escape-org t\n"
                     "#+begin_quote\nplaceholder\n#+end_quote\n"))
           (file (org-quote-link-edge--write dir "main.org" content))
           (buffer (find-file-noselect file)))
      (ignore file)
      (should (equal (org-quote-link-edge--refresh buffer "placeholder")
                     (concat
                      "#+HEADER: :transclude [[file:star.txt]]\n"
                      "#+HEADER: :transclude-escape-org t\n"
                      "#+begin_quote\n,* raw star\nsecond\n#+end_quote\n")))
      (kill-buffer buffer))))

(provide 'org-quote-link-edge-test)
;;; org-quote-link-edge-test.el ends here
