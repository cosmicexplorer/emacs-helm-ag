;;; helm-ag.el --- the silver searcher with helm interface -*- lexical-binding: t; -*-

;; Copyright (C) 2017 by Syohei YOSHIDA

;; Author: Syohei YOSHIDA <syohex@gmail.com>
;; URL: https://github.com/syohex/emacs-helm-ag
;; Version: 0.58
;; Package-Requires: ((emacs "24.4") (helm "2.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; helm-ag provides interfaces of the silver searcher(Other search programs can be used
;; such as the platinum searcher, ack). And helm-ag provides wgrep like features which
;; users can edit from searched result.

;;; Code:

(eval-when-compile
  (require 'grep)
  (defvar helm-help-message))

(require 'cl-lib)
(require 'helm)
(require 'helm-grep)
(require 'helm-utils)
(require 'compile)
(require 'subr-x)

(declare-function helm-read-file-name "helm-mode")
(declare-function helm-grep-get-file-extensions "helm-grep")
(declare-function helm-help "helm-help")

(defgroup helm-ag nil
  "the silver searcher with helm interface"
  :group 'helm)

(defsubst helm-ag--windows-p ()
  (memq system-type '(ms-dos windows-nt)))

(defsubst helm-ag--has-drive-letter-p (path)
  (string-match-p "\\`[a-zA-Z]:" path))

(defcustom helm-ag-base-command
  (if (helm-ag--windows-p)
      "ag --vimgrep"
    "ag --nocolor --nogroup")
  "Base command of `ag'"
  :type 'string
  :group 'helm-ag)

(defcustom helm-ag-command-option nil
  "Command line option of `ag'. This is appended after `helm-ag-base-command'"
  :type 'string
  :group 'helm-ag)

(defcustom helm-ag-insert-at-point nil
  "Insert thing at point as search pattern.
   You can set value same as `thing-at-point'"
  :type 'symbol
  :group 'helm-ag)

(defcustom helm-ag-ignore-patterns nil
  "Ignore patterns for `ag'. This parameters are specified as --ignore"
  :type '(repeat string)
  :group 'helm-ag)

(defcustom helm-ag-use-grep-ignore-list nil
  "Use `grep-find-ignored-files' and `grep-find-ignored-directories' as ignore pattern.
They are specified to `--ignore' options."
  :type 'boolean
  :group 'helm-ag)

(defcustom helm-ag-always-set-extra-option nil
  "Always set `ag' options of `helm-do-ag'."
  :type 'boolean
  :group 'helm-ag)

(defcustom helm-ag-fuzzy-match nil
  "Enable fuzzy match"
  :type 'boolean
  :group 'helm-ag)

(defcustom helm-ag-edit-save t
  "Save buffers you edit at completed."
  :type 'boolean
  :group 'helm-ag)

(defcustom helm-ag-use-emacs-lisp-regexp nil
  "[Experimental] Use Emacs Lisp regexp instead of PCRE."
  :type 'boolean
  :group 'helm-ag)

(defcustom helm-ag-use-agignore nil
  "Use .agignore where is at project root if it exists."
  :type 'boolean
  :group 'helm-ag)

(defcustom helm-ag-use-temp-buffer nil
  "Use temporary buffer for persistent action."
  :type 'boolean
  :group 'helm-ag)

(defcustom helm-ag-ignore-buffer-patterns nil
  "Use temporary buffer for persistent action."
  :type '(repeat regexp))

(defcustom helm-ag-show-status-function 'helm-ag-show-status-default-mode-line
  "Function called after that `ag' process is finished after `helm-do-ag'.
Default behaviour shows finish and result in mode-line."
  :type 'function)

(defcustom helm-ag--preview-highlight-matches 'any
  "Whether to highlight `helm-ag' matches inline in matched buffers. Can be
`let'-bound dynamically or used as a file-local variable to turn off
highlighting for large buffers. If set to nil, no highlighting or previewing is
performed. If set to 'line-only, the line that the current match points to is
highlighted, and a preview of the match is displayed. If set to
'highlight-matches-current-line, the matched text is highlighted, along with the
current line. Finally, if set to 'any, highlights all matches in the matched
buffer."
  :type 'symbol
  :options '(nil line-only highlight-matches-current-line any)
  :safe t
  :group 'helm-ag)

(defcustom helm-ag--preview-max-matches 100
  "Number of matches to highlight with overlays in preview, by default. Can be
`let'-bound or used as a file-local variable to reduce number of searches for
large buffers."
  :type 'integer
  :safe t
  :group 'helm-ag)

(defcustom helm-ag-delete-opened-buffers t
  "`helm-ag--display-preview' opens files with `find-file-noselect' to display a
preview of them. When this option is non-nil, these buffers will be killed after
a `helm-ag' or `helm-do-ag' session.")

(defface helm-ag-edit-deleted-line
  '((t (:inherit font-lock-comment-face :strike-through t)))
  "Face of deleted line in edit mode."
  :group 'helm-ag)

(defface helm-ag-preview-line
  '((t (:background "green" :foreground "black")))
  "Face of preview line."
  :group 'helm-ag)

(defface helm-ag-process-pattern-match
  '((t (:background "purple" :foreground "white")))
  "Face of the text matched by the pattern given to the ag process."
  :group 'helm-ag)

(defface helm-ag-minibuffer-match
  '((t (:background "blue" :foreground "yellow")))
  "Face of the text matched for the pattern given in the minibuffer."
  :group 'helm-ag)

(defvar helm-ag--command-history '())
(defvar helm-ag--helm-history '())
(defvar helm-ag--context-stack nil)
(defvar helm-ag--default-directory nil)
(defvar helm-ag--last-default-directory nil)
(defvar helm-ag--last-query nil)
(defvar helm-ag--last-command nil)
(defvar helm-ag--elisp-regexp-query nil)
(defvar helm-ag--valid-regexp-for-emacs nil)
(defvar helm-ag--extra-options nil)
(defvar helm-ag--extra-options-history nil)
(defvar helm-ag--original-window nil)
(defvar helm-ag--original-buffer nil)
(defvar helm-ag--search-this-file-p nil)
(defvar helm-ag--default-target nil)
(defvar helm-ag--buffer-search nil)
(defvar helm-ag--command-features '())
(defvar helm-ag--ignore-case nil)
(defvar helm-ag--converted-patterns nil)
(defvar helm-do-ag--extensions nil)
(defvar helm-do-ag--commands nil)

(defun helm-ag--ignore-case-p (cmds input)
  (cl-loop for cmd in cmds
           when (member cmd '("-i" "--ignore-case"))
           return t

           when (member cmd '("-s" "--case-sensitive"))
           return nil

           finally
           return (let ((case-fold-search nil))
                    (not (string-match-p "[A-Z]" input)))))

(defun helm-ag--save-current-context ()
  (let ((curpoint (with-helm-current-buffer
                    (point))))
    (helm-aif (buffer-file-name helm-current-buffer)
        (push (list :file it :point curpoint) helm-ag--context-stack)
      (push (list :buffer helm-current-buffer :point curpoint) helm-ag--context-stack))))

(defun helm-ag--insert-thing-at-point (thing)
  (helm-aif (thing-at-point thing)
      (substring-no-properties it)
    ""))

(defun helm-ag--searched-word ()
  (if helm-ag-insert-at-point
      (helm-ag--insert-thing-at-point helm-ag-insert-at-point)
    ""))

(defun helm-ag--construct-ignore-option (pattern)
  (concat "--ignore=" pattern))

(defun helm-ag--grep-ignore-list-to-options ()
  (require 'grep)
  (cl-loop for ignore in (append grep-find-ignored-files
                                 grep-find-ignored-directories)
           collect (helm-ag--construct-ignore-option ignore)))

(defun helm-ag--parse-options-and-query (input)
  ;; NOTE: we don't attempt to interpret any options
  (cons nil input))

(defun helm-ag--flip-regex-type (converted to-type)
  (if helm-ag-use-emacs-lisp-regexp
      (cl-ecase to-type
        (elisp converted)
        (pcre (helm-ag--plist-map
               (lambda (res)
                 (cl-mapcar #'helm-ag--elisp-regexp-to-pcre res))
               converted)))
    (cl-ecase to-type
      (pcre converted)
      (elisp (helm-ag--plist-map
              (lambda (res)
                (cl-mapcar #'helm-ag--pcre-to-elisp-regexp res))
              converted)))))

(defun helm-ag--parse-query (input)
  (cl-destructuring-bind (options . query)
      (helm-ag--parse-options-and-query input)
    (setq helm-ag--last-query input
          helm-ag--converted-patterns
          (helm-ag--convert-invert-pattern query)
          helm-ag--elisp-regexp-query
          (helm-ag--flip-regex-type helm-ag--converted-patterns 'elisp)
          helm-ag--valid-regexp-for-emacs
          (cl-every #'helm-ag--validate-regexp
                    (plist-get helm-ag--elisp-regexp-query :positive)))
    (append options
            (list
             (helm-ag--join-patterns
              (helm-ag--flip-regex-type helm-ag--converted-patterns 'pcre))))))

(defsubst helm-ag--search-buffer-p (bufname)
  (cl-loop for regexp in helm-ag-ignore-buffer-patterns
           never (string-match-p regexp bufname)))

(defun helm-ag--file-visited-buffers ()
  (let ((bufs (cl-loop for buf in (buffer-list)
                       when (buffer-file-name buf)
                       collect it)))
    (if (not helm-ag-ignore-buffer-patterns)
        bufs
      (cl-loop for buf in bufs
               when (helm-ag--search-buffer-p buf)
               collect buf))))

(defun helm-ag--construct-targets (targets)
  (let ((default-directory helm-ag--default-directory))
    (cl-loop for target in targets
             collect (file-relative-name target))))

(defun helm-ag--root-agignore ()
  (let ((root (helm-ag--project-root)))
    (when root
      (let ((default-directory root))
        (when (file-exists-p ".agignore")
          (expand-file-name (concat default-directory ".agignore")))))))

(defun helm-ag--construct-command (this-file)
  (let* ((commands (split-string helm-ag-base-command nil t))
         (command (car commands))
         (args (cdr commands)))
    (when helm-ag-command-option
      (let ((ag-options (split-string helm-ag-command-option nil t)))
        (setq args (append args ag-options))))
    (when helm-ag-use-agignore
      (helm-aif (helm-ag--root-agignore)
          (setq args (append args (list "-p" it)))))
    (when helm-ag-ignore-patterns
      (setq args (append args (mapcar 'helm-ag--construct-ignore-option
                                      helm-ag-ignore-patterns))))
    (when helm-ag-use-grep-ignore-list
      (setq args (append args (helm-ag--grep-ignore-list-to-options))))
    (setq args (append args (helm-ag--parse-query helm-ag--last-query)))
    (when this-file
      (setq args (append args (list this-file))))
    (when helm-ag--buffer-search
      (setq args (append args (helm-ag--file-visited-buffers))))
    (when helm-ag--default-target
      (setq args (append args (helm-ag--construct-targets helm-ag--default-target))))
    (cons command args)))

(defun helm-ag--remove-carriage-returns ()
  (when (helm-ag--windows-p)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\xd" nil t)
        (replace-match "")))))

(defun helm-ag--abbreviate-file-name ()
  (unless (helm-ag--windows-p)
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (while (re-search-forward "^\\([^:]+\\)" nil t)
        (replace-match (abbreviate-file-name (match-string-no-properties 1)))))))

(defun helm-ag--init ()
  (let ((buf-coding buffer-file-coding-system))
    (helm-attrset 'recenter t)
    (with-current-buffer (helm-candidate-buffer 'global)
      (let* ((default-directory (or helm-ag--default-directory
                                    default-directory))
             (cmds (helm-ag--construct-command (helm-attr 'search-this-file)))
             (coding-system-for-read buf-coding)
             (coding-system-for-write buf-coding))
        (setq helm-ag--ignore-case (helm-ag--ignore-case-p cmds helm-ag--last-query)
              helm-ag--last-command cmds)
        (let ((ret (apply #'process-file (car cmds) nil t nil (cdr cmds))))
          (if (zerop (length (buffer-string)))
              (error "No ag output: '%s'" helm-ag--last-query)
            (unless (zerop ret)
              (unless (executable-find (car cmds))
                (error "'ag' is not installed."))
              (error "Failed: '%s'" helm-ag--last-query))))
        (when helm-ag--buffer-search
          (helm-ag--abbreviate-file-name))
        (helm-ag--remove-carriage-returns)
        (helm-ag--save-current-context)))))

(add-to-list 'debug-ignored-errors "^No ag output: ")

(defun helm-ag--search-only-one-file-p ()
  (when (and helm-ag--default-target (= (length helm-ag--default-target) 1))
    (let ((target (car helm-ag--default-target)))
      (unless (file-directory-p target)
        target))))

(defun helm-ag--find-file-action (candidate find-func this-file &optional persistent)
  (when (memq 'pt helm-ag--command-features)
    ;; 'pt' always show filename if matched file is only one.
    (setq this-file nil))
  (let* ((file-line (helm-grep-split-line candidate))
         (filename (or this-file (cl-first file-line) candidate))
         (line (if this-file
                   (cl-first (split-string candidate ":"))
                 (cl-second file-line)))
         (default-directory (or helm-ag--default-directory
                                helm-ag--last-default-directory
                                default-directory)))
    (unless persistent
      (setq helm-ag--last-default-directory default-directory))
    (funcall find-func filename)
    (goto-char (point-min))
    (when line
      (forward-line (1- (string-to-number line))))
    (ignore-errors
      (and (re-search-forward helm-ag--last-query (line-end-position) t)
           (goto-char (match-beginning 0))))))

(defun helm-ag--open-file-with-temp-buffer (filename)
  (let ((search-directory default-directory))
    (switch-to-buffer (get-buffer-create " *helm-ag persistent*"))
    (setq default-directory search-directory)
    (fundamental-mode)
    (erase-buffer)
    (insert-file-contents filename)
    (let ((buffer-file-name filename))
      (set-auto-mode)
      (font-lock-fontify-region (point-min) (point-max)))))

(defsubst helm-ag--vimgrep-option ()
  (member "--vimgrep" helm-ag--last-command))

(defun helm-ag--search-this-file-p ()
  (unless (helm-ag--vimgrep-option)
    (if (eq (helm-get-current-source) 'helm-source-do-ag)
        (helm-ag--search-only-one-file-p)
      (helm-attr 'search-this-file))))

(defun helm-ag--persistent-action (candidate)
  (let ((find-func (if helm-ag-use-temp-buffer
                       #'helm-ag--open-file-with-temp-buffer
                     #'find-file)))
    (helm-ag--find-file-action candidate find-func (helm-ag--search-this-file-p) t)
    (helm-highlight-current-line)))

(defun helm-ag--validate-regexp (regexp)
  (and
   (not (string-empty-p regexp))
   (condition-case nil
       (progn
         (string-match-p regexp "")
         t)
     (invalid-regexp nil))))

(defconst helm-ag--parse-join-regexp
  (concat
   "\\`\\\\(\\?="
   "\\(\\^\\\\(\\?!\\)?\\(?:\\.\\*\\)?"
   "\\(\\(?:.\\|\n\\)+?\\)"
   "\\(?:\\\\)\\.\\+\\$\\)?\\(?:\\.\\*\\)?\\\\)"))

(defsubst helm-ag--join-regexps (reg-list)
  (if reg-list (string-join reg-list "\\|") "[^[:ascii:][:nonascii:]]"))

(defun helm-ag--collect-lookaround-regexps (regexp-list)
  (cl-loop with pos-results = nil
           with neg-results = nil
           for reg-pair in regexp-list
           do (cl-destructuring-bind (type . reg) reg-pair
                (when (helm-ag--validate-regexp reg)
                  (push reg
                        (if (eq type 'positive) pos-results neg-results))))
           finally (return
                    (list :positive pos-results
                          :negative neg-results))))

(defconst helm-ag--sole-negative-lookaround-regexp
  "\\`\\^\\\\(\\?!\\.\\*\\(\\(?:.\\|\n\\)+?\\)\\\\)\\.\\+\\$\\'")

(defun helm-ag--parse-sole-negative-lookaround (regexp)
  (if (string-match helm-ag--sole-negative-lookaround-regexp regexp)
      (list :positive nil
            :negative (list
                       (substring regexp (match-beginning 1) (match-end 1))))
    (list :positive (list regexp)
          :negative nil)))

(defun helm-ag--replace-lookarounds (regexp)
  "`helm-ag--join-patterns' converts helm-like patterns into PCRE, but the
conversation isn't two-way through `helm-ag--pcre-to-elisp-regexp' due to the
addition of lookarounds. This turns REGEXP into a (hopefully) valid elisp
regexp by inserting alternation (\\|) in between top-level groups."
  ;; only process regexps which were created by `helm-ag--join-patterns'
  (if (not (string-match-p helm-ag--parse-join-regexp regexp))
      (helm-ag--parse-sole-negative-lookaround regexp)
    (cl-loop
     while (string-match helm-ag--parse-join-regexp regexp)
     for (beg end neg-beg neg-end text-beg text-end) = (match-data)
     collecting (cons (if (and neg-beg neg-end) 'negative 'positive)
                      (substring regexp text-beg text-end))
     into results
     do (setq regexp (substring regexp end))
     finally return (helm-ag--collect-lookaround-regexps results))))

(defun helm-ag--pcre-to-elisp-regexp (pcre)
  ;; This is very simple conversion
  (with-temp-buffer
    (insert pcre)
    (goto-char (point-min))
    ;; convert (, ), {, }, |
    (while (re-search-forward "[(){}|]" nil t)
      (backward-char 1)
      (cond ((looking-back "\\\\\\\\" nil))
            ((looking-back "\\\\" nil)
             (delete-char -1))
            (t
             (insert "\\")))
      (forward-char 1))
    ;; convert \s and \S -> \s- \S-
    (goto-char (point-min))
    (while (re-search-forward "\\(\\\\s\\)" nil t)
      (unless (looking-back "\\\\\\\\s" nil)
        (insert "-")))
    (buffer-string)))

(defun helm-ag--elisp-regexp-to-pcre (regexp)
  (with-temp-buffer
    (insert regexp)
    (goto-char (point-min))
    (while (re-search-forward "[(){}|]" nil t)
      (backward-char 1)
      (cond ((looking-back "\\\\\\\\" nil))
            ((looking-back "\\\\" nil)
             (delete-char -1))
            (t
             (insert "\\")))
      (forward-char 1))
    (buffer-string)))

(defun helm-ag--highlight-candidate (candidate)
  (let ((limit (1- (length candidate)))
        (last-pos 0)
        (case-fold-search helm-ag--ignore-case)
        (joined-query
         (helm-ag--join-regexps
          (plist-get
           (helm-ag--plist-map
            #'helm-ag--filter-helm-patterns helm-ag--elisp-regexp-query)
           :positive))))
    (when helm-ag--valid-regexp-for-emacs
      (while (and (< last-pos limit)
                  (string-match joined-query candidate last-pos))
        (let ((start (match-beginning 0))
              (end (match-end 0)))
          (if (= start end)
              (cl-incf last-pos)
            (put-text-property start end 'face 'helm-match candidate)
            (setq last-pos (1+ (match-end 0)))))))
    candidate))

(defun helm-ag--candidate-transform-for-files (candidate)
  (helm-aif (helm-grep-split-line candidate)
      (format "%s:%s:%s"
              (propertize (cl-first it) 'face 'helm-moccur-buffer)
              (propertize (cl-second it) 'face 'helm-grep-lineno)
              (helm-ag--highlight-candidate (cl-third it)))))

(defun helm-ag--candidate-transformer (candidate)
  (or (if (helm-attr 'search-this-file)
          (helm-ag--candidate-transform-for-this-file candidate)
        (helm-ag--candidate-transform-for-files candidate))
      candidate))

(defun helm-ag--action-find-file (candidate)
  (helm-ag--find-file-action candidate 'find-file (helm-ag--search-this-file-p)))

(defun helm-ag--action-find-file-other-window (candidate)
  (helm-ag--find-file-action candidate 'find-file-other-window (helm-ag--search-this-file-p)))

(defvar helm-ag--actions
  (helm-make-actions
   "Open file"              #'helm-ag--action-find-file
   "Open file other window" #'helm-ag--action-find-file-other-window
   "Save results in buffer" #'helm-ag--action-save-buffer
   "Edit search results"    #'helm-ag--edit))

(defun helm-ag--matches-all-regexps (regexp-list str &optional no)
  (cond ((string-match-p "\\`[[:space:]]*\\'" str) nil)
        (no (cl-every (lambda (reg) (not (string-match-p reg str)))
                      regexp-list))
        (t (cl-every (lambda (reg) (string-match-p reg str)) regexp-list))))

(defun helm-ag--search-next-match-pos-neg (pos-reg neg-reg)
  ;; this is similar to `helm-ag--find-next-match-overlays', but that one needs
  ;; to highlight all matches, while this one only needs to determine whether a
  ;; line is matched (which requires matching every single regexp in pos-reg,
  ;; for example
  (ignore-errors
    (cl-block found
      (while (re-search-forward (or (car pos-reg) ".") nil t)
        (let ((this-line (helm-ag--get-string-at-line)))
          (when (and (helm-ag--matches-all-regexps (cdr pos-reg) this-line)
                     (helm-ag--matches-all-regexps neg-reg this-line t))
            (cl-return-from found t)))))))

(defvar helm-ag--buffer-search-cache (make-hash-table :test 'equal))
(defconst helm-ag--cache-size 10000)

(cl-defun helm-ag--filter-helm-patterns (patterns &optional (helm-buf t))
  (cl-remove-if
   #'null
   (cl-mapcar
    (lambda (pat) (helm-ag--add-header-for-carat pat helm-buf))
    patterns)))

(defun helm-ag--plist-map (fn plist)
  (cl-loop for el in plist
           for counter = 0 then (1+ counter)
           collect (if (zerop (% counter 2)) el
                     (funcall fn el))))

(defun helm-ag--add-header-for-carat (pattern &optional helm-buf)
  (cond
   ((string-match-p "\\`\\(?:\\^\\|\\$\\|\\)\\'" pattern)
    nil)
   ((and helm-buf (string-match "\\`\\^\\(.*\\)\\'" pattern))
    (concat "^[^:]+:[0-9]+:" (match-string 1 pattern)))
   (t pattern)))

;;;###autoload
(defun helm-ag-pop-stack ()
  (interactive)
  (let ((context (pop helm-ag--context-stack)))
    (unless context
      (error "Context stack is empty !"))
    (helm-aif (plist-get context :file)
        (find-file it)
      (let ((buf (plist-get context :buffer)))
        (if (buffer-live-p buf)
            (switch-to-buffer buf)
          (error "The buffer is already killed."))))
    (goto-char (plist-get context :point))))

;;;###autoload
(defun helm-ag-clear-stack ()
  (interactive)
  (setq helm-ag--context-stack nil))

(defun helm-ag--marked-input (escape)
  (when (use-region-p)
    (let ((input (buffer-substring-no-properties (region-beginning) (region-end))))
      (deactivate-mark)
      (if (not escape)
          input
        (replace-regexp-in-string " " "\\\\ " input)))))

(defun helm-ag--query (&optional previous-query)
  (let* ((searched-word (helm-ag--searched-word))
         (marked-word (helm-ag--marked-input nil))
         (query (or previous-query
                    (read-from-minibuffer "Pattern: "
                                      (or marked-word searched-word)
                                      nil
                                      nil
                                      'helm-ag--command-history
                                      (helm-aif (symbol-at-point)
                                          (symbol-name it))))))
    (when (string-empty-p query)
      (error "Input is empty!!"))
    (setq helm-ag--last-query query)))

(defsubst helm-ag--clear-variables ()
  (setq helm-ag--last-default-directory nil))

;;;###autoload
(defun helm-ag-this-file ()
  (interactive)
  (helm-ag--clear-variables)
  (let ((filename (file-name-nondirectory (buffer-file-name))))
    (helm-ag--query)
    (helm-attrset 'search-this-file (buffer-file-name) helm-ag-source)
    (helm-attrset 'name (format "Search at %s" filename) helm-ag-source)
    (let ((helm-ag--ag-or-do-ag 'ag))
      (helm-ag--safe-do-helm
       (helm :sources '(helm-ag-source) :buffer "*helm-ag*")))))

(defsubst helm-ag--init-state ()
  (setq helm-ag--original-buffer (current-buffer)
        helm-ag--original-window (selected-window)
        helm-ag--last-default-directory nil))

(defun helm-ag--get-default-directory ()
  (let ((prefix-val (and current-prefix-arg (abs (prefix-numeric-value current-prefix-arg)))))
    (cond ((not prefix-val) default-directory)
          ((= prefix-val 4)
           (file-name-as-directory
            (read-directory-name "Search directory: " nil nil t)))
          ((= prefix-val 16)
           (let ((dirs (list (read-directory-name "Search directory: " nil nil t))))
             (while (y-or-n-p "More directories ?")
               (push (read-directory-name "Search directory: " nil nil t) dirs))
             (reverse dirs))))))

(defsubst helm-ag--helm-header (dir &optional regex)
  (if helm-ag--buffer-search
      "Search Buffers"
    (concat "Search " (helm-aif regex (concat it " ") "") "at "
            (abbreviate-file-name dir))))

(defun helm-ag--run-other-window-action ()
  (interactive)
  (with-helm-alive-p
    (helm-exit-and-execute-action #'helm-ag--action-find-file-other-window)))

(defun helm-ag--exit-from-edit-mode ()
  (when (window-live-p helm-ag--original-window)
    (select-window helm-ag--original-window))
  (kill-buffer (get-buffer "*helm-ag-edit*")))

(defun helm-ag--match-line-regexp ()
  ;; $1: file name
  ;; $2: line
  ;; $3: match body
  ;; $4: file attributes part(filename, line, column)
  (cond ((helm-ag--vimgrep-option)
         "^\\(?4:\\(?1:[^:]+\\):\\(?2:[1-9][0-9]*\\):[^:]+:\\)\\(?3:.*\\)$")
        (helm-ag--search-this-file-p
         "^\\(?4:\\(?2:[1-9][0-9]*\\)[:-]\\)\\(?3:.*\\)$")
        (t
         "^\\(?4:\\(?1:[^:]+\\):\\(?2:[1-9][0-9]*\\)[:-]\\)\\(?3:.*\\)$")))

(defun helm-ag--edit-commit ()
  (interactive)
  (goto-char (point-min))
  (let ((read-only-files 0)
        (saved-buffers nil)
        (regexp (helm-ag--match-line-regexp))
        (default-directory helm-ag--default-directory)
        (line-deletes (make-hash-table :test #'equal))
        (kept-buffers (buffer-list))
        open-buffers)
    (while (re-search-forward regexp nil t)
      (let* ((file (or (match-string-no-properties 1) helm-ag--search-this-file-p))
             (line (string-to-number (match-string-no-properties 2)))
             (body (match-string-no-properties 3))
             (ovs (overlays-at (line-beginning-position))))
        (with-current-buffer (find-file-noselect file)
          (cl-pushnew (current-buffer) open-buffers)
          (if buffer-read-only
              (cl-incf read-only-files)
            (goto-char (point-min))
            (let ((deleted-lines (gethash file line-deletes 0))
                  (deleted (and ovs (overlay-get (car ovs) 'helm-ag-deleted))))
              (forward-line (- line 1 deleted-lines))
              (delete-region (line-beginning-position) (line-end-position))
              (if (not deleted)
                  (insert body)
                (let ((beg (point)))
                  (forward-line 1)
                  (delete-region beg (point))
                  (puthash file (1+ deleted-lines) line-deletes)))
              (cl-pushnew (current-buffer) saved-buffers))))))
    (when helm-ag-edit-save
      (dolist (buf saved-buffers)
        (with-current-buffer buf
          (save-buffer))))
    (dolist (buf open-buffers)
      (unless (memq buf kept-buffers)
        (kill-buffer buf)))
    (helm-ag--exit-from-edit-mode)
    (if (not (zerop read-only-files))
        (message "%d files are read-only and not editable." read-only-files)
      (message "Success update"))))

(defun helm-ag--edit-abort ()
  (interactive)
  (when (y-or-n-p "Discard changes ?")
    (helm-ag--exit-from-edit-mode)
    (message "Abort edit")))

(defun helm-ag--mark-line-deleted ()
  (interactive)
  (let* ((beg (line-beginning-position))
         (end (line-end-position))
         (ov (make-overlay beg end)))
    (overlay-put ov 'face 'helm-ag-edit-deleted-line)
    (overlay-put ov 'helm-ag-deleted t)))

(defun helm-ag--unmark ()
  (interactive)
  (dolist (ov (overlays-in (line-beginning-position) (line-end-position)))
    (when (overlay-get ov 'helm-ag-deleted)
      (delete-overlay ov))))

(defvar helm-ag-edit-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") 'helm-ag--edit-commit)
    (define-key map (kbd "C-c C-k") 'helm-ag--edit-abort)
    (define-key map (kbd "C-c C-d") 'helm-ag--mark-line-deleted)
    (define-key map (kbd "C-c C-u") 'helm-ag--unmark)
    map))

(defsubst helm-ag--edit-func-to-keys (func)
  (key-description (car-safe (where-is-internal func helm-ag-edit-map))))

(defun helm-ag--edit (_candidate)
  (let* ((helm-buf-dir (or helm-ag--default-directory
                           helm-ag--last-default-directory
                           default-directory))
         (default-directory helm-buf-dir))
    (with-current-buffer (get-buffer-create "*helm-ag-edit*")
      (erase-buffer)
      (setq-local helm-ag--default-directory helm-buf-dir)
      (unless (helm-ag--vimgrep-option)
        (setq-local helm-ag--search-this-file-p
                    (assoc-default 'search-this-file (helm-get-current-source))))
      (let (buf-content)
        (with-current-buffer (get-buffer "*helm-ag*")
          (goto-char (point-min))
          (forward-line 1)
          (let* ((body-start (point))
                 (marked-lines (cl-loop for ov in (overlays-in body-start (point-max))
                                        when (eq 'helm-visible-mark (overlay-get ov 'face))
                                        return (helm-marked-candidates))))
            (if (not marked-lines)
                (setq buf-content (buffer-substring-no-properties
                                   body-start (point-max)))
              (setq buf-content (concat (string-join marked-lines "\n") "\n")))))
        (insert buf-content)
        (add-text-properties (point-min) (point-max)
                             '(read-only t rear-nonsticky t front-sticky t))
        (let ((inhibit-read-only t)
              (regexp (helm-ag--match-line-regexp)))
          (setq header-line-format
                (format "[%s] %s: Commit, %s: Abort"
                        (abbreviate-file-name helm-ag--default-directory)
                        (helm-ag--edit-func-to-keys #'helm-ag--edit-commit)
                        (helm-ag--edit-func-to-keys #'helm-ag--edit-abort)))
          (goto-char (point-min))
          (while (re-search-forward regexp nil t)
            (let ((file-line-begin (match-beginning 4))
                  (file-line-end (match-end 4))
                  (body-begin (match-beginning 3))
                  (body-end (match-end 3)))
              (add-text-properties file-line-begin file-line-end
                                   '(face font-lock-function-name-face
                                          intangible t))
              (remove-text-properties body-begin body-end '(read-only t))
              (set-text-properties body-end (1+ body-end)
                                   '(read-only t rear-nonsticky t))))))))
  (other-window 1)
  (switch-to-buffer (get-buffer "*helm-ag-edit*"))
  (goto-char (point-min))
  (setq next-error-function 'compilation-next-error-function)
  (setq-local compilation-locs (make-hash-table :test 'equal :weakness 'value))
  (use-local-map helm-ag-edit-map))

(defun helm-ag-edit ()
  (interactive)
  (helm-exit-and-execute-action 'helm-ag--edit))

(defconst helm-ag--help-message
  "\n* Helm Ag\n

\n** Specific commands for Helm Ag:\n
\\<helm-ag-map>
\\[helm-ag--run-other-window-action]\t\t-> Open result in other buffer
\\[helm-ag--up-one-level]\t\t-> Search in parent directory.
\\[helm-ag-edit]\t\t-> Edit search results.
\\[helm-ag-help]\t\t-> Show this help.
\n** Helm Ag Map\n
\\{helm-map}")

(defun helm-ag-help ()
  (interactive)
  (let ((helm-help-message helm-ag--help-message))
    (helm-help)))

(defun helm-ag-mode-jump ()
  (interactive)
  (let ((line (helm-current-line-contents)))
    (helm-ag--find-file-action line 'find-file helm-ag--search-this-file-p)))

(defun helm-ag-mode-jump-other-window ()
  (interactive)
  (let ((line (helm-current-line-contents)))
    (helm-ag--find-file-action line 'find-file-other-window helm-ag--search-this-file-p)))

(defvar helm-ag-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'helm-ag-mode-jump)
    (define-key map (kbd "C-o") 'helm-ag-mode-jump-other-window)
    (define-key map (kbd "g") 'helm-ag--update-save-results)
    map))

(define-derived-mode helm-ag-mode special-mode "helm-ag"
  "Major mode to provide actions in helm grep saved buffer.

Special commands:
\\{helm-ag-mode-map}")

(defun helm-ag--put-result-in-save-buffer (result search-this-file-p)
  (setq buffer-read-only t)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "-*- mode: helm-ag -*-\n\n"
            (format "Ag Results for `%s':\n\n" helm-ag--last-query))
    (save-excursion
      (insert result)))
  (helm-ag-mode)
  (unless (helm-ag--vimgrep-option)
    (setq-local helm-ag--search-this-file-p search-this-file-p))
  (setq-local helm-ag--default-directory default-directory))

(defun helm-ag--save-results (use-other-buf)
  (let* ((search-this-file-p nil)
         (result (with-current-buffer helm-buffer
                   (goto-char (point-min))
                   (forward-line 1)
                   (buffer-substring (point) (point-max))))
         (default-directory helm-ag--default-directory)
         (buf (if use-other-buf
                  (read-string "Results buffer name: "
                               (format "*helm ag results for '%s'*" helm-ag--last-query))
                "*helm ag results*")))
    (when (buffer-live-p (get-buffer buf))
      (kill-buffer buf))
    (with-current-buffer (get-buffer-create buf)
      (helm-ag--put-result-in-save-buffer result search-this-file-p)
      (pop-to-buffer buf)
      (message "Helm Ag Results saved in `%s' buffer" buf))))

(defun helm-ag--update-save-results ()
  (interactive)
  (let* ((default-directory helm-ag--default-directory)
         (result (with-temp-buffer
                   (apply #'process-file (car helm-ag--last-command) nil t nil
                          (cdr helm-ag--last-command))
                   (when helm-ag--buffer-search
                     (helm-ag--abbreviate-file-name))
                   (helm-ag--remove-carriage-returns)
                   (helm-ag--propertize-candidates helm-ag--last-query)
                   (buffer-string))))
    (helm-ag--put-result-in-save-buffer result helm-ag--search-this-file-p)
    (message "Update Results")))

(defun helm-ag--action-save-buffer (_arg)
  (helm-ag--save-results nil))

(defun helm-ag--run-save-buffer ()
  (interactive)
  (let ((use-other-buf-p current-prefix-arg))
    (with-helm-alive-p
      (helm-exit-and-execute-action
       (lambda (_arg)
         (helm-ag--save-results use-other-buf-p))))))

(defun helm-ag--insert-space ()
  (interactive)
  (insert "[[:space:]]"))

(defun helm-ag--file-lineno-of-current-file ()
  (let ((line (helm-current-line-contents)))
    (when (string-match helm-grep-split-line-regexp line)
      (list :file (match-string-no-properties 1 line)
            :line-number (match-string-no-properties 2 line)))))

(defun helm-ag--move-file-common (wrap-pred move-fn wrap-fn)
  (with-helm-window
    (let* ((helm-move-to-line-cycle-in-source t)
           (file-lineno (helm-ag--file-lineno-of-current-file))
           (file (plist-get file-lineno :file))
           (lineno (string-to-number (plist-get file-lineno :line-number))))
      (if (funcall wrap-pred) (funcall wrap-fn) (funcall move-fn))
      (cl-loop
       for new-file-lineno = (helm-ag--file-lineno-of-current-file)
       for new-file = (plist-get new-file-lineno :file)
       for new-lineno = (string-to-number
                         (plist-get new-file-lineno :line-number))
       while (and (string= file new-file)
                  (not (= lineno new-lineno)))
       do (progn (if (funcall wrap-pred) (funcall wrap-fn) (funcall move-fn))
                 (setq lineno new-lineno)))
      (let ((helm-swoop-move-to-line-cycle t))
        (call-interactively #'helm-next-line)
        (call-interactively #'helm-previous-line)))))

(defun helm-ag--previous-line () (forward-line -1))

(defun helm-ag--previous-file ()
  (interactive)
  (helm-ag--move-file-common
   #'helm-beginning-of-source-p #'helm-ag--previous-line #'helm-end-of-buffer))

(defun helm-ag--next-file ()
  (interactive)
  (helm-ag--move-file-common
   #'helm-end-of-source-p #'forward-line #'helm-beginning-of-buffer))

(defmacro helm-ag--get-dir-query-and-switch (to-dir-form &rest body)
  (declare (indent 1))
  (let ((tmp-sym (cl-gensym))
        (to-dir-sym (cl-first to-dir-form)))
    `(let* ((,tmp-sym ,(cl-second to-dir-form))
            (,to-dir-sym (if (symbolp ,tmp-sym) ,tmp-sym
                           (expand-file-name ,tmp-sym))))
       (if (eq ,to-dir-sym 'query-user)
           (helm-run-after-exit
            (lambda ()
              (let ((,to-dir-sym
                     (expand-file-name
                      (read-directory-name
                       "Directory to search: " nil nil t))))
                ,@body)))
         (helm-run-after-exit (lambda () ,@body))))))

(defun helm-ag--switch-dir (to-directory)
  (interactive (list 'query-user))
  (let* ((initial-input helm-input)
         (cur-src (helm-get-current-source))
         (cur-buf (with-helm-buffer (current-buffer))))
    (helm-ag--get-dir-query-and-switch (dir to-directory)
      (let ((default-directory dir)
            (helm-ag--default-directory dir))
        (setq helm-ag--last-default-directory default-directory)
        (helm-attrset 'name (helm-ag--helm-header dir) cur-src)
        (helm-ag--safe-do-helm
         (helm :sources (list cur-src) :buffer cur-buf
               :input initial-input))))))

(defconst helm-ag--file-line-regexp "\\([^:]+\\):\\([0-9]+\\):")
(defun helm-ag--goto-file-dir ()
  (interactive)
  (with-helm-buffer
    (save-excursion
      (goto-char (line-beginning-position))
      (if (re-search-forward helm-ag--file-line-regexp nil t)
          (let ((file (match-string 1)))
            (helm-ag--switch-dir (file-name-directory file)))
        (error "no file on current line")))))

(defmacro helm-ag--get-dir-query-and-switch (to-dir-form &rest body)
  (declare (indent 1))
  (let ((tmp-sym (cl-gensym))
        (to-dir-sym (cl-first to-dir-form)))
    `(let* ((,tmp-sym ,(cl-second to-dir-form))
            (,to-dir-sym (if (symbolp ,tmp-sym) ,tmp-sym
                           (expand-file-name ,tmp-sym))))
       (if (eq ,to-dir-sym 'query-user)
           (helm-run-after-exit
            (lambda ()
              (let ((,to-dir-sym
                     (expand-file-name
                      (read-directory-name
                       "Directory to search: " nil nil t))))
                ,@body)))
         (helm-run-after-exit (lambda () ,@body))))))

(defun helm-ag--switch-dir (to-directory)
  (interactive (list 'query-user))
  (let* ((initial-input helm-input)
         (cur-src (helm-get-current-source))
         (cur-buf (with-helm-buffer (buffer-name))))
    (helm-ag--get-dir-query-and-switch (dir to-directory)
      (let ((default-directory dir)
            (helm-ag--default-directory dir))
        (setq helm-ag--last-default-directory default-directory)
        (helm-attrset 'name (helm-ag--helm-header dir helm-ag--last-query)
                      cur-src)
        (helm :sources (list cur-src) :buffer cur-buf
              :input initial-input)))))

(defconst helm-ag--file-line-regexp "\\([^:]+\\):\\([0-9]+\\):")
(defun helm-ag--goto-file-dir ()
  (interactive)
  (with-helm-buffer
    (save-excursion
      (goto-char (line-beginning-position))
      (if (re-search-forward helm-ag--file-line-regexp nil t)
          (let ((file (match-string 1)))
            (helm-ag--switch-dir (or (file-name-directory file) ".")))
        (error "no file on current line")))))

(defvar helm-ag-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map helm-map)
    (define-key map (kbd "C-c o") 'helm-ag--run-other-window-action)
    (define-key map (kbd "C-l") 'helm-ag--up-one-level)
    (define-key map (kbd "C-c d") 'helm-ag--switch-dir)
    (define-key map (kbd "C-c f") 'helm-ag--goto-file-dir)
    (define-key map (kbd "C-c C-e") 'helm-ag-edit)
    (define-key map (kbd "C-x C-s") 'helm-ag--run-save-buffer)
    (define-key map (kbd "C-c ?") 'helm-ag-help)
    (define-key map (kbd "C-c s") #'helm-ag--insert-space)
    (define-key map (kbd "C-s") #'helm-ag--ag-switch-to-do-ag)
    (define-key map (kbd "C-c >") 'helm-ag--next-file)
    (define-key map (kbd "<right>") 'helm-ag--next-file)
    (define-key map (kbd "C-c <") 'helm-ag--previous-file)
    (define-key map (kbd "<left>") 'helm-ag--previous-file)
    map)
  "Keymap for `helm-ag'.")

(defsubst helm-ag--root-directory-p ()
  (cl-loop for dir in '(".git/" ".hg/")
           thereis (file-directory-p dir)))

(defun helm-ag--up-one-level ()
  (interactive)
  (if (or (not (helm-ag--root-directory-p))
          (y-or-n-p "Current directory might be the project root. \
Continue searching the parent directory? "))
      (helm-ag--switch-dir
       (file-name-directory (directory-file-name default-directory)))
    (message nil)))

(defvar helm-ag--ag-or-do-ag nil)

;;;###autoload
(defun helm-ag-this-file ()
  (interactive)
  (helm-ag--init-state)
  (let ((filename (file-name-nondirectory (buffer-file-name)))
        (helm-ag--default-directory default-directory))
    (helm-ag--query)
    (helm-ag--set-command-feature)
    (helm-attrset 'search-this-file (file-relative-name (buffer-file-name))
                  helm-ag-source)
    (helm-attrset 'name (format "Search at %s" filename) helm-ag-source)
    (helm :sources '(helm-ag-source) :buffer "*helm-ag*")))

;;;###autoload
(defun helm-ag (&optional basedir query)
  (interactive)
  (helm-ag--init-state)
  (let ((dir (helm-ag--get-default-directory))
        targets)
    (when (listp dir)
      (setq basedir default-directory
            targets dir))
    (let ((helm-ag--default-directory (or basedir dir))
          (helm-ag--default-target targets))
      (helm-ag--query query)
      (helm-attrset 'search-this-file nil helm-ag-source)
      (helm-attrset
       'name
       (helm-ag--helm-header
        helm-ag--default-directory
        (or helm-ag--previous-last-query helm-ag--last-query))
       helm-ag-source)
      (let ((helm-ag--ag-or-do-ag 'ag))
        (helm-ag--safe-do-helm
         (helm :sources '(helm-ag-source) :buffer "*helm-ag*"))))))

(defun helm-ag--split-string (str)
  (with-temp-buffer
    (insert str)
    (goto-char (point-min))
    (let ((prev (point))
          patterns)
      (while (search-forward " " nil 'move)
        (cond ((looking-back "\\\\\\\\ " nil)
               (push (buffer-substring-no-properties prev (1- (point))) patterns)
               (skip-chars-forward " ")
               (setq prev (point)))
              ((looking-back "\\\\ " nil)
               (replace-match " "))
              (t (push (buffer-substring-no-properties prev (1- (point))) patterns)
                 (skip-chars-forward " ")
                 (setq prev (point)))))
      (push (buffer-substring-no-properties prev (point)) patterns)
      (reverse (cl-loop for p in patterns unless (string= p "") collect p)))))

(defsubst helm-ag--add-anchor-tags (pattern &optional no-end-dot-star)
  (let ((pattern (if (char-equal (aref pattern 0) ?^) pattern
                        (concat ".*" pattern))))
    (if (or no-end-dot-star
            (char-equal (aref pattern (1- (length pattern))) ?$))
        pattern
      (concat pattern ".*"))))

(defun helm-ag--convert-invert-pattern (pattern)
  (cl-loop for pat in (helm-ag--split-string pattern)
           do (string-match "\\`\\(!\\)?\\(.*\\)\\'" pat)
           for res = (match-string 2 pat)
           if (match-string 1 pat)
           collect res into neg
           else collect res into pos
           finally return (list :positive pos :negative neg)))

(defun helm-ag--join-patterns (converted)
  (let ((pos-pats
         (cl-loop for p-pat in (plist-get converted :positive)
                  collect (format "(?=.*%s.*)" p-pat)))
        (neg-pats
         (cl-loop for n-pat in (plist-get converted :negative)
                  collect (format "(?!.*%s.*)" n-pat))))
    (mapconcat #'identity (append pos-pats neg-pats) "")))

(defun helm-ag--propertize-candidates (input)
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (cl-loop
     with patterns = (plist-get helm-ag--elisp-regexp-query :positive)
     with one-file-p = (and (not (helm-ag--vimgrep-option))
                            (helm-ag--search-only-one-file-p))
     while (not (eobp))
     for num upfrom 1
     for start = (point)
     for bound = (line-end-position)
     do (progn
          (if (and one-file-p (search-forward ":" bound t))
              (set-text-properties (line-beginning-position) (1- (point))
                                   '(face helm-grep-lineno))
            (when (re-search-forward helm-grep-split-line-regexp bound t)
              (set-text-properties
               (match-beginning 1) (match-end 1) '(face helm-moccur-buffer))
              (set-text-properties
               (match-beginning 2) (match-end 2) '(face helm-grep-lineno))
              (goto-char (match-beginning 3))))
          (let ((curpoint (point))
                (case-fold-search helm-ag--ignore-case))
            (cl-loop
             for pattern in patterns
             for last-point = (point)
             unless (string-empty-p pattern)
             do (progn
                  (condition-case _
                      (if (char-equal (aref pattern 0) ?^)
                          (save-excursion
                            (goto-char curpoint)
                            (when (looking-at (substring pattern 1))
                              (set-text-properties
                               (match-beginning 0) (match-end 0)
                               '(face helm-match))))
                        (while (re-search-forward pattern bound t)
                          (set-text-properties (match-beginning 0) (match-end 0)
                                               '(face helm-match))
                          (when (= last-point (point))
                            (forward-char 1))
                          (setq last-point (point))))
                    (invalid-regexp nil))
                  (goto-char curpoint))))
          (put-text-property start bound 'helm-cand-num num)
          (forward-line 1)))))

(defun helm-ag-show-status-default-mode-line ()
  (setq mode-line-format
        '(" " mode-line-buffer-identification " "
          (:eval (propertize
                  (format
                   "[AG process finished - (%s results)] "
                   (helm-get-candidate-number))
                  'face 'helm-grep-finish)))))

(defun helm-ag--do-ag-propertize (input)
  (with-helm-window
    (when helm-ag--buffer-search
      (helm-ag--abbreviate-file-name))
    (helm-ag--remove-carriage-returns)
    (helm-ag--propertize-candidates input)
    (when helm-ag-show-status-function
      (funcall helm-ag-show-status-function)
      (force-mode-line-update))))

(defun helm-ag--construct-extension-options ()
  (cl-loop for ext in helm-do-ag--extensions
           unless (string= ext "*")
           collect
           (concat "-G" (replace-regexp-in-string
                         "\\*" ""
                         (replace-regexp-in-string "\\." "\\\\." ext)))))

(defun helm-ag--do-ag-set-command ()
  (let ((cmd-opts (split-string helm-ag-base-command nil t)))
    (when helm-ag-command-option
      (setq cmd-opts (append cmd-opts (split-string helm-ag-command-option nil t))))
    (when helm-ag--extra-options
      (setq cmd-opts (append cmd-opts (split-string helm-ag--extra-options))))
    (when helm-ag-ignore-patterns
      (setq cmd-opts
            (append cmd-opts
                    (mapcar #'helm-ag--construct-ignore-option
                            helm-ag-ignore-patterns))))
    (when helm-ag-use-agignore
      (helm-aif (helm-ag--root-agignore)
          (setq cmd-opts (append cmd-opts (list "-p" it)))))
    (when helm-do-ag--extensions
      (setq cmd-opts (append cmd-opts (helm-ag--construct-extension-options))))
    (let (targets)
      (when helm-ag--buffer-search
        (setq targets (helm-ag--file-visited-buffers)))
      (setq helm-do-ag--commands
            (cons cmd-opts
                  (if helm-ag--default-target
                      (append targets (helm-ag--construct-targets helm-ag--default-target))
                    targets))))))

(defun helm-ag--do-ag-candidate-process ()
  (let* ((non-essential nil)
         (default-directory (or helm-ag--default-directory
                                helm-ag--last-default-directory
                                default-directory))
         (cmd-args (append (car helm-do-ag--commands)
                           (helm-ag--parse-query helm-pattern))))
    (when cmd-args
      (let ((proc (apply #'start-file-process "helm-do-ag" nil cmd-args)))
        (setq helm-ag--last-query helm-pattern
              helm-ag--last-command cmd-args
              helm-ag--ignore-case (helm-ag--ignore-case-p cmd-args helm-pattern)
              helm-ag--last-default-directory default-directory)
        (prog1 proc
          (set-process-sentinel
           proc
           (lambda (process event)
             (helm-process-deferred-sentinel-hook
              process event (helm-default-directory))
             (when (string= event "finished\n")
               (helm-ag--do-ag-propertize helm-input)))))))))

(defconst helm-do-ag--help-message
  "\n* Helm Do Ag\n

\n** Specific commands for Helm Ag:\n
\\<helm-do-ag-map>
\\[helm-ag--run-other-window-action]\t\t-> Open result in other buffer
\\[helm-ag--do-ag-up-one-level]\t\t-> Search in parent directory.
\\[helm-ag-edit]\t\t-> Edit search results.
\\[helm-ag--do-ag-help]\t\t-> Show this help.
\n** Helm Ag Map\n
\\{helm-map}")

(defun helm-ag--do-ag-help ()
  (interactive)
  (let ((helm-help-message helm-do-ag--help-message))
    (helm-help)))

(defsubst helm-ag--get-string-at-line ()
  (buffer-substring-no-properties (point-at-bol) (point-at-eol)))
(defsubst helm-ag--recenter () (recenter (/ (window-height) 2)))
(defsubst helm-ag--delete-overlays (olays) (mapc #'delete-overlay olays))

(defun helm-ag--find-next-match-overlays (end pos-reg neg-reg)
  (condition-case _
      (cl-loop
       while (re-search-forward pos-reg end t)
       when (not (string-match-p neg-reg (helm-ag--get-string-at-line)))
       return t
       finally return nil)
    (invalid-regexp nil)))

(defun helm-ag--make-overlays (beg end regexp face)
  "Apply an overlay to all matches between BEG and END of REGEXP with face
FACE."
  (let* ((is-helm-buf (string= (buffer-name) (helm-buffer-get)))
        (reg-list
         (if (not is-helm-buf) regexp
           (helm-ag--plist-map #'helm-ag--filter-helm-patterns regexp)))
        (pos-reg (helm-ag--join-regexps (plist-get reg-list :positive)))
        (neg-reg (helm-ag--join-regexps (plist-get reg-list :negative))))
    (unless (string-empty-p pos-reg)
      (save-excursion
        (goto-char beg)
        (cl-loop
         while (helm-ag--find-next-match-overlays end pos-reg neg-reg)
         for i from 1 to helm-ag--preview-max-matches
         collect (let* ((reg-beg (match-beginning 0))
                        (reg-end (match-end 0))
                        (olay (make-overlay reg-beg reg-end)))
                   (overlay-put olay 'face face)
                   olay))))))

(defun helm-ag--apply-first-second-overlays (olays regexp face)
  "To all lines on which a member of OLAYS begins on, search for REGEXP and
apply an overlay with face FACE."
  (when regexp
    (apply
     #'append
     (cl-loop for olay in olays
              collect (save-excursion
                        (goto-char (overlay-start olay))
                        (helm-ag--make-overlays
                         (line-beginning-position) (line-end-position)
                         regexp face))))))

(defun helm-ag--clean-add-overlays
    (beg end primary-regexp primary-face secondary-regexp secondary-face)
  "Add overlays between BEG and END for text matching PRIMARY-REGEXP. Put
PRIMARY-FACE on those overlays. On lines which match PRIMARY-REGEXP, add
overlays covering text matching SECONDARY-REGEXP, with face
SECONDARY-FACE. SECONDARY-REGEXP is a helm minibuffer regexp, so it is split
into components based on whitespace."
  (let* ((case-fold-search t)
         (primary-overlays
          (helm-ag--make-overlays beg end primary-regexp primary-face))
         (secondary-overlays
          (helm-ag--apply-first-second-overlays
           primary-overlays secondary-regexp secondary-face)))
    (append primary-overlays secondary-overlays)))

(defmacro helm-ag--conditional-let (condition bindings &rest body)
  (declare (indent 2))
  `(if ,condition (let ,bindings ,@body) ,@body))

(defun helm-ag--refresh-overlay-list
    (prev-list beg end primary-regexp primary-face
               secondary-regexp secondary-face)
  "Delete old overlays from PREV-LIST and return new ones between BEG and
END. PRIMARY-REGEXP, PRIMARY-FACE, SECONDARY-REGEXP, and SECONDARY-FACE work as
described in `helm-ag--clean-add-overlays'."
  (helm-ag--conditional-let (string= helm-ag--last-query helm-pattern)
      ;; doesn't match anything
      ((secondary-regexp nil))
    (helm-ag--delete-overlays prev-list)
    (helm-ag--clean-add-overlays beg end primary-regexp primary-face
                                 secondary-regexp secondary-face)))

(defvar-local helm-ag--process-preview-overlays nil
  "Buffer-local variable containing the overlays temporarily assigned to each
buffer as `helm-ag' highlights their matches.")

(defun helm-ag--refresh-overlays-in-region (beg end)
  "Refresh match overlays in a region of the buffer."
  (setq helm-ag--process-preview-overlays
        (helm-ag--refresh-overlay-list
         helm-ag--process-preview-overlays beg end
         (let* ((primary-reg
                 (cl-ecase helm-ag--ag-or-do-ag
                   (ag (or helm-ag--last-query ""))
                   (do-ag helm-pattern))))
           (helm-ag--flip-regex-type
            (helm-ag--convert-invert-pattern primary-reg)
            'elisp))
         'helm-ag-process-pattern-match
         (when (eq helm-ag--ag-or-do-ag 'ag)
           (helm-ag--flip-regex-type
            (helm-ag--convert-invert-pattern helm-pattern)
            'elisp))
         'helm-ag-minibuffer-match)))

(defun helm-ag--refresh-listing-overlays ()
  "Refresh overlays in *helm-ag* buffer."
  (with-helm-window
    (cond ((eq helm-ag--preview-highlight-matches
               'highlight-matches-current-line)
           (helm-ag--refresh-overlays-in-region
            (line-beginning-position) (line-end-position)))
          ((eq helm-ag--preview-highlight-matches 'any)
           (helm-ag--refresh-overlays-in-region
            (point-min) (point-max)))
          (t nil))))

(defvar helm-ag--preview-overlay nil
  "Overlay covering the current line `helm-ag' is highlighting.")

(defun helm-ag--display-preview-line-overlay (olay buf line)
  "Display overlay highlighting current line of match."
  (with-current-buffer buf
    (goto-char (point-min))
    (forward-line (1- line))
    (let ((beg (line-beginning-position))
          (end (1+ (line-end-position))))
      (move-overlay olay beg end buf))))

(defvar helm-ag--previous-preview-buffer nil
  "Sentinel used in `helm-ag--display-preview' to tell whether the match has
changed.")
(defvar helm-ag--previous-minibuffer-pattern nil
  "Sentinel used in `helm-ag--display-preview' to tell whether the match has
changed.")
(defvar helm-ag--previous-line nil
  "Sentinel used in `helm-ag--display-preview' to tell whether the match has
changed.")
(defvar helm-ag--buffers-displayed nil
  "List of all buffers displayed during a session so that their overlays can be
deleted afterwards.")
(defvar helm-ag--new-buffers-opened-for-preview nil
  "List of all buffers newly opened with `find-file-noselect' within
`helm-ag--display-preview' so that they can be killed afterwards.")

(defcustom helm-ag-do-display-preview t
  "Whether to display a preview immediately upon visiting a line using
`helm-ag--display-preview'."
  :safe 'booleanp
  :group 'helm-ag)

(defun helm-ag-toggle-display-preview ()
  "Toggle the value of `helm-ag-do-display-preview'."
  (interactive)
  (let ((new
         (setq helm-ag-do-display-preview (not helm-ag-do-display-preview))))
    (message "displaying preview in helm-ag: %s"
             (if helm-ag-do-display-preview "on" "off"))))

(defun helm-ag--display-preview ()
  "Display a preview of some sort of the selected match. Create or refresh
overlays highlighting text of matches in the matching buffer."
  (when (with-current-buffer helm-ag--original-buffer
          helm-ag-do-display-preview)
    (with-helm-window
      (let* ((str (helm-ag--get-string-at-line))
             (match (string-match "^\\([^:]+\\):\\([0-9]+\\):" str)))
        (when match
          (let* ((file (match-string 1 str))
                 (line (string-to-number (match-string 2 str)))
                 (buf-displaying-file
                  (or (get-file-buffer file)
                      (let ((buf (find-file-noselect file)))
                        (push buf helm-ag--new-buffers-opened-for-preview)
                        buf))))
            (add-to-list 'helm-ag--buffers-displayed buf-displaying-file)
            (with-selected-window helm-ag--original-window
              (switch-to-buffer buf-displaying-file)
              (goto-char (point-min))
              (forward-line (1- line))
              (when helm-ag--preview-highlight-matches
                (helm-ag--display-preview-line-overlay
                 helm-ag--preview-overlay buf-displaying-file line))
              (unless (or (and (eq helm-ag--previous-preview-buffer
                                   buf-displaying-file)
                               (string-equal helm-ag--previous-minibuffer-pattern
                                             helm-pattern)
                               (and helm-ag--previous-line
                                    (= helm-ag--previous-line line)))
                          (memq helm-ag--preview-highlight-matches
                                `(nil line-only)))
                (cond ((eq helm-ag--preview-highlight-matches
                           'highlight-matches-current-line)
                       (helm-ag--refresh-overlays-in-region
                        (line-beginning-position) (line-end-position)))
                      ((eq helm-ag--preview-highlight-matches 'any)
                       (helm-ag--refresh-overlays-in-region
                        (point-min) (point-max)))
                      (t (error "Invalid selection for
helm-ag--preview-highlight-matches!"))))
              (helm-ag--recenter))
            (setq helm-ag--previous-preview-buffer buf-displaying-file
                  helm-ag--previous-minibuffer-pattern helm-pattern
                  helm-ag--previous-line line)))))))

(defvar helm-ag--disabled-advices-alist nil
  "List of disabled advices enabled during a `helm-ag' session, and disabled at
the end.")

(defmacro helm-ag--display-preview-advice (helm-function helm-ag-function)
  "Advise a `helm' function to call `helm-ag--display-preview' and be toggled
through `helm-ag--disabled-advices-alist'."
  `(progn
     (defadvice ,helm-function (around ,helm-ag-function disable)
       (let ((helm-move-to-line-cycle-in-source t))
         ad-do-it
         (when (called-interactively-p 'interactive)
           (helm-ag--display-preview))))
     (add-to-list 'helm-ag--disabled-advices-alist
                  (list ',helm-function ',helm-ag-function))))

(helm-ag--display-preview-advice helm-next-line helm-ag--next-line)
(helm-ag--display-preview-advice helm-previous-line helm-ag--previous-line)
(helm-ag--display-preview-advice
 helm-toggle-visible-mark helm-ag--toggle-visible-mark)

(defadvice helm-highlight-current-line (around helm-ag--fix-face disable)
  (ad-set-args 0 '(nil nil nil helm-ag-process-pattern-match))
  ad-do-it)
(add-to-list 'helm-ag--disabled-advices-alist
             '(helm-highlight-current-line helm-ag--fix-face))

(defun helm-ag--reset-variables ()
  (setq helm-ag--preview-overlay nil
        helm-ag--previous-preview-buffer nil
        helm-ag--previous-minibuffer-pattern nil
        helm-ag--buffers-displayed nil
        helm-ag--new-buffers-opened-for-preview nil
        helm-ag--previous-line nil))
(defun helm-ag--setup-advice ()
  (helm-ag--reset-variables)
  (cl-loop for el in helm-ag--disabled-advices-alist
           do (progn (ad-enable-advice (cl-first el) 'around (cl-second el))
                     (ad-activate (cl-first el))))
  (add-hook 'helm-update-hook #'helm-ag--refresh-listing-overlays)
  (add-hook 'helm-after-update-hook #'helm-ag--display-preview))
(defsubst helm-ag--setup-overlays ()
  (setq helm-ag--preview-overlay (make-overlay (point) (point)))
  (overlay-put helm-ag--preview-overlay 'face 'helm-ag-preview-line))
(defun helm-ag--teardown-advice ()
  (cl-loop for el in helm-ag--disabled-advices-alist
           do (progn (ad-disable-advice (cl-first el) 'around (cl-second el))
                     (ad-activate (cl-first el))))
  (remove-hook 'helm-update-hook #'helm-ag--refresh-listing-overlays)
  (remove-hook 'helm-after-update-hook #'helm-ag--display-preview))
(defun helm-ag--delete-temporaries ()
  (when helm-ag--preview-overlay (delete-overlay helm-ag--preview-overlay))
  (cl-loop for buf in helm-ag--buffers-displayed
           do (with-current-buffer buf
                (cl-loop for olay in helm-ag--process-preview-overlays
                         do (when olay (delete-overlay olay)))
                (setq helm-ag--process-preview-overlays nil)))
  (when helm-ag-delete-opened-buffers
    (cl-loop for buf in helm-ag--new-buffers-opened-for-preview
             do (unless (eq (current-buffer) buf) (kill-buffer buf))))
  (helm-ag--reset-variables))

(defmacro helm-ag--safe-do-helm (&rest body)
  "Wraps calls to `helm' with setup and teardown forms to make sure no overlays,
advices, buffers, or hooks leak from the preview."
  `(progn
     (helm-ag--delete-temporaries)
     (helm-ag--setup-advice)
     (helm-ag--setup-overlays)
     (let ((helm-fuzzy-matching-highlight-fn #'identity))
       (unwind-protect (progn ,@body)
         (when (= helm-exit-status 0)
           ;; move match to center
           (helm-ag--recenter))
         (helm-ag--teardown-advice)
         (helm-ag--delete-temporaries)))))

(defvar helm-do-ag-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map helm-ag-map)
    (define-key map (kbd "C-c ?") 'helm-ag--do-ag-help)
    (define-key map (kbd "C-s") 'helm-ag--do-ag-switch-to-ag)
    map)
  "Keymap for `helm-do-ag'.")

(defvar helm-source-do-ag
  (helm-build-async-source "The Silver Searcher"
    :init 'helm-ag--do-ag-set-command
    :candidates-process 'helm-ag--do-ag-candidate-process
    :persistent-action  'helm-ag--persistent-action
    :action helm-ag--actions
    :nohighlight t
    :requires-pattern 3
    :history 'helm-ag--helm-history
    :candidate-number-limit 9999
    :keymap helm-do-ag-map
    :follow (and helm-follow-mode-persistent 1)))

(defvar helm-ag--previous-last-query nil)

(defun helm-ag--do-ag-switch-to-ag (dir query)
  (interactive (list default-directory helm-pattern))
  (let ((real-query
         (if helm-ag-use-emacs-lisp-regexp (helm-ag--elisp-regexp-to-pcre query)
           query)))
    (setq helm-ag--previous-last-query query)
    (helm-run-after-exit
     (lambda ()
       (helm-ag
        dir
        (helm-ag--join-patterns
         (cdr (helm-ag--parse-options-and-query real-query))))))))

(defun helm-ag--set-do-ag-option ()
  (when (or (< (prefix-numeric-value current-prefix-arg) 0)
            helm-ag-always-set-extra-option)
    (let ((option (read-string "Extra options: " (or helm-ag--extra-options "")
                               'helm-ag--extra-options-history)))
      (setq helm-ag--extra-options option))))

(defun helm-ag--set-command-features ()
  (let ((cmd (intern (car (split-string helm-ag-base-command)))))
    (setq helm-ag--command-features (list cmd))
    (cl-case cmd
      (ack (add-to-list 'helm-ag--command-features
                        (if (string-match-p "-\\(?:Q\\|-literal\\)\\>" helm-ag-base-command)
                            'fixed
                          'pcre)))
      (ag (add-to-list 'helm-ag--command-features
                       (if (string-match-p "-\\(?:[QF]\\|-literal\\|-fixed-strings\\)\\>" helm-ag-base-command)
                           'fixed
                         'pcre)))
      (pt (add-to-list 'helm-ag--command-features
                       (if (string-match-p "-e\\>" helm-ag-base-command)
                           're2
                         'fixed)))
      (rg (add-to-list 'helm-ag--command-features
                       (if (string-match-p "-\\(?:F\\|-fixed-strings\\)\\>" helm-ag-base-command)
                           'fixed
                         're2))))))

(defun helm-ag--do-ag-searched-extensions ()
  (when (and current-prefix-arg (= (abs (prefix-numeric-value current-prefix-arg)) 4))
    (helm-grep-get-file-extensions helm-ag--default-target)))

(defsubst helm-do-ag--target-one-directory-p (targets)
  (and (listp targets) (= (length targets) 1) (file-directory-p (car targets))))

(defun helm-do-ag--helm (&optional query)
  (let ((search-dir
         (cond ((not (helm-ag--windows-p)) helm-ag--default-directory)
               ((helm-do-ag--target-one-directory-p helm-ag--default-target)
                (car helm-ag--default-target))
               (t helm-ag--default-directory))))
    (helm-attrset 'name (helm-ag--helm-header search-dir) helm-source-do-ag)
    (let ((helm-ag--ag-or-do-ag 'do-ag))
      (helm-ag--safe-do-helm
       (helm :sources '(helm-source-do-ag) :buffer "*helm-ag*"
             :input (or query
                        (helm-ag--marked-input t)
                        (helm-ag--insert-thing-at-point
                         helm-ag-insert-at-point)))))))

;;;###autoload
(defun helm-do-ag-this-file ()
  (interactive)
  (helm-aif (buffer-file-name)
      (helm-do-ag default-directory (list it))
    (error "Error: This buffer is not visited file.")))

(defun helm-ag--ag-switch-to-do-ag (dir query)
  (interactive (list default-directory
                     (or helm-ag--previous-last-query helm-ag--last-query)))
  ;; if we just converted from a helm regex to enter helm-ag from helm-do-ag
  (helm-run-after-exit (lambda () (helm-do-ag dir dir query))))

;;;###autoload
(defun helm-do-ag (&optional basedir targets query)
  (interactive)
  (require 'helm-mode)
  (helm-ag--init-state)
  (let* ((helm-ag--default-directory (or basedir default-directory))
         (helm-ag--default-target (cond (targets targets)
                                        ((and (helm-ag--windows-p) basedir) (list basedir))
                                        (t
                                         (when (and (not basedir) (not helm-ag--buffer-search))
                                           (helm-read-file-name
                                            "Search in file(s): "
                                            :default default-directory
                                            :marked-candidates t :must-match t)))))
         (helm-do-ag--extensions (when helm-ag--default-target
                                   (helm-ag--do-ag-searched-extensions)))
         (one-directory-p (helm-do-ag--target-one-directory-p
                           helm-ag--default-target)))
    (helm-ag--set-do-ag-option)
    (helm-ag--set-command-features)
    (helm-ag--save-current-context)
    (helm-attrset 'search-this-file
                  (and (= (length helm-ag--default-target) 1)
                       (not (file-directory-p (car helm-ag--default-target)))
                       (car helm-ag--default-target))
                  helm-source-do-ag)
    (if (or (helm-ag--windows-p) (not one-directory-p)) ;; Path argument must be specified on Windows
        (helm-do-ag--helm query)
      (let* ((helm-ag--default-directory
              (file-name-as-directory (car helm-ag--default-target)))
             (helm-ag--default-target nil))
        (helm-do-ag--helm query)))))

(defun helm-ag--project-root ()
  (cl-loop for dir in '(".git/" ".hg/" ".svn/" ".git")
           when (locate-dominating-file default-directory dir)
           return it))

;;;###autoload
(defun helm-ag-project-root ()
  (interactive)
  (let ((rootdir (helm-ag--project-root)))
    (unless rootdir
      (error "Could not find the project root. Create a git, hg, or svn repository there first. "))
    (helm-ag rootdir)))

;;;###autoload
(defun helm-do-ag-project-root ()
  (interactive)
  (let ((rootdir (helm-ag--project-root)))
    (unless rootdir
      (error "Could not find the project root. Create a git, hg, or svn repository there first. "))
    (helm-do-ag rootdir)))

;;;###autoload
(defun helm-ag-buffers ()
  (interactive)
  (let ((helm-ag--buffer-search t))
    (helm-ag)))

;;;###autoload
(defun helm-do-ag-buffers ()
  (interactive)
  (let ((helm-ag--buffer-search t))
    (helm-do-ag)))

(provide 'helm-ag)

;;; helm-ag.el ends here
