;;; multifiles.el --- View and edit parts of multiple files in one buffer

;; Copyright (C) 2011 Magnar Sveen

;; Author: Magnar Sveen <magnars@gmail.com>
;; Keywords: multiple files

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

;; Bind a key to `mf/mirror-region-in-multifile`, let's say `C-!`. Now
;; mark a part of the buffer and press it. A new \*multifile\* buffer pops
;; up. Mark some other part of another file, and press `C-!` again. This
;; is added to the \*multifile\*.

;; You can now edit the \*multifile\* buffer, and watch the original files change.
;; Or you can edit the original files and watch the \*multifile\* buffer change.

;; **Warning** This API and functionality is highly volatile.

;;; Code:

(require 'dash)

(defvar mf--changed-overlays nil)
(make-variable-buffer-local 'mf--changed-overlays)

(defun mf--defun-at-point (&optional bounds)
  (save-excursion (while (not (save-excursion (backward-up-list 1 't) (looking-at "(comment")))
		    (backward-up-list 1 't))
		  (let ((begin (point)))
		    (clojure-forward-logical-sexp)
		    (funcall (if bounds #'list #'buffer-substring-no-properties) begin (point)))))

(defun mf--mirror-defun ()
  "Mirror the top-level form at point in the multifile buffer.  Useful for starting a multifile session."
  (interactive)
  (when (not cider-mode)
    (error "cider connection required"))
  (let ((rgn (mf--defun-at-point t)))
    (mf/mirror-region-in-multifile (car rgn) (cadr rgn))))

(defun mf--pull-definition (&optional mirror)
  "Add a mirror of the definition of the form at point to the bottom of the multifile buffer."
  (interactive "P")
  (if (or mirror (string= "*multifile*" (buffer-name)))
      (mirror-definition (sexp-at-point))
    (cider-find-var)))

(defun mf--adv-cider-current-ns (origfn &rest args)
  "Allows cider functions to work in the namespace of the code overlay at point"
  (let ((bbuf (-some-> (overlays-at (point))
		       car
		       (overlay-get 'backing-buffer))))
    (if bbuf
	(with-current-buffer bbuf (funcall origfn))
      (funcall origfn))))

(advice-add 'cider-current-ns :around #'mf--adv-cider-current-ns)

(defun delete-orphan-overlays ()
  (--each (overlays-in (point-min) (point-max))
    (-when-let (twin (overlay-get it 'twin))
      (when (null (overlay-buffer twin))
	(delete-overlay it)))))

(defun clear-garbage-overlays ()
  ;;remove any unlinked overlays from the buffer and our data structures
  (setq mf--changed-overlays (-filter #'overlay-buffer mf--changed-overlays)))

(defun fancify (str width)
  (let ((bar (make-string (/ (- width (length str)) 2) ?=)))
    (concat ";; " bar " " str " " bar)))

(defun mirror-definition (sym &optional right-here)
  (let* ((varinfo (cider-var-info sym))
	 (file (nrepl-dict-get varinfo "file"))
	 (line (nrepl-dict-get varinfo "line"))
	 (name (or
		(nrepl-dict-get varinfo "name")
		(error (format "Can't get info for %s.  Is the ns loaded?" sym))))
	 ;;sometimes cider--find-buffer-for-file doesn't work the first time?
	 (defbuf (or
		  (cider--find-buffer-for-file file)
		  (cider--find-buffer-for-file file)
		  (error (format "Can't find buffer for %s" file))))
	 (qualname (format "%s/%s"
			   (with-current-buffer defbuf (cider-current-ns))
			   name))
	 (def-form-bounds (with-current-buffer defbuf
			    (save-excursion
			      (goto-char (point-min))
			      (forward-line (- line 1))
			      (list (point) (progn (forward-sexp) (point)))))))

    (setq first-mirror (null (get-buffer "*multifile*")))
    (when first-mirror
      (let ((mode major-mode))
        (with-current-buffer (get-buffer-create "*multifile*")
          (funcall mode)
          (multifiles-minor-mode 1))))
    (prog1
        (with-current-buffer (get-buffer-create "*multifile*")
          (save-excursion
            (mf--add-mirror
             defbuf
             (car def-form-bounds)
             (cadr def-form-bounds)
             (fancify qualname 80)
             right-here)))
      (when first-mirror (switch-to-buffer-other-window "*multifile*")))))

(defun mf/mirror-region-in-multifile (beg end &optional multifile-buffer &optional heading)
  (interactive (list (region-beginning) (region-end)
                     (when current-prefix-arg
                       (read-buffer "Mirror into buffer: " "*multifile*"))))

  (when (string= "*multifile*" (buffer-name (current-buffer)))
    (error "you probably don't want to mirror a mirror into the same buffer"))

  (deactivate-mark)

  ;;sometimes deleted overlays accumulate in mf--changed-overlays and cause Bad Things to Happen
  (clear-garbage-overlays)
  ;;when there is no multifile buffer, any overlays we have are garbage
  (when (not (get-buffer "*multifile*"))
    (setq mf--changed-overlays nil)
    (remove-overlays))

  (let ((buffer (current-buffer))
        (mode major-mode))
    (switch-to-buffer-other-window (or multifile-buffer "*multifile*"))
    (funcall mode)
    (multifiles-minor-mode 1)
    (mf--add-mirror buffer beg end)
    (switch-to-buffer-other-window buffer)))

(defvar multifiles-minor-mode-map nil
  "Keymap for multifiles minor mode.")

(unless multifiles-minor-mode-map
  (setq multifiles-minor-mode-map (make-sparse-keymap)))

(defun mf--limited-undo ()
  (interactive)
  (-if-let (o (-some-> (point) (overlays-at) (car)))
      (save-excursion
        (deactivate-mark)
        (goto-char (overlay-start o))
        (mark)
        (goto-char (overlay-end o))
        (undo))
    (error "Undo in no overlay is probably not what you want")))

(define-key multifiles-minor-mode-map [remap undo] 'mf--limited-undo)
(define-key multifiles-minor-mode-map (vector 'remap 'save-buffer) 'mf/save-original-buffers)
(define-key multifiles-minor-mode-map (kbd "M-z") 'mf--pull-definition)

(defun mf/save-original-buffers ()
  (interactive)
  (when (yes-or-no-p "Are you sure you want to save all original files?")
    (--each (mf--original-buffers)
      (with-current-buffer it
        (when buffer-file-name
          (save-buffer))))))

(defun mf--original-buffers ()
  (->> (overlays-in (point-min) (point-max))
    (--filter (equal 'mf-mirror (overlay-get it 'type)))
    (--map (overlay-buffer (overlay-get it 'twin)))
    (-distinct)))

(define-minor-mode multifiles-minor-mode
  "A minor mode for the *multifile* buffer."
  nil "" multifiles-minor-mode-map)

(defvar multifiles-heading-map nil)
(unless multifiles-heading-map
  (setq multifiles-heading-map (make-sparse-keymap)))

;;from the header, delete both the mirrored section and the header itself
(defun mf--header-delete ()
  (interactive)
  (let ((o (-some-> (point) overlays-at car)))
    (-some-> o
             (overlay-get 'mirror)
             (mf--remove-mirror))
    (delete-overlay o)
    (beginning-of-line)
    (delete-region (point) (line-end-position))))

;;pretty hacky - clojure-mode sexp movement does not work with fully qualified names (it chokes on the dots)
(defun mf--symbol-from-header ()
  (beginning-of-line)
  (search-forward "= ")
  (let ((name-begin (point))
        (name-end (progn
                    (search-forward " =")
                    (backward-char 2)
                    (point))))
    (buffer-substring-no-properties name-begin name-end)))

;;delete/resurrect the mirror below this header
(defun mf--header-cycle ()
  (interactive)
  (let* ((o (-some-> (point) overlays-at car))
         (mirror (overlay-get o 'mirror)))
    (if (and mirror (overlay-buffer mirror))
        (progn
          (mf--remove-mirror mirror)
          (overlay-put o 'mirror nil))
      (save-excursion
        (overlay-put o 'mirror (mirror-definition (mf--symbol-from-header) t))
        (overlay-put (overlay-get o 'mirror) 'header o)))))

(defun mf--header-next ()
  (interactive)
  (let ((bol (save-excursion (beginning-of-line) (point))))
    (when (= bol (point))
      (forward-char))
    (search-forward ";; ==" nil t)
    (beginning-of-line)))

(defun mf--header-prev ()
  (interactive)
  (let ((orig-point (point)))
    (when
        (save-excursion
          (beginning-of-line)
          (looking-at ";; =="))
      (previous-line))
    (when (not (search-backward ";; ==" nil t))
      (goto-char orig-point))))

(defun mf--header-goto-source ()
  (interactive)
  (-when-let (o (-some-> (point) overlays-at car (overlay-get 'mirror)))
    (switch-to-buffer-other-window (overlay-get o 'backing-buffer))
    (goto-char (overlay-start (overlay-get o 'twin)))))

(define-key multifiles-heading-map (kbd "q") 'mf--header-delete)
(define-key multifiles-heading-map (kbd "TAB") 'mf--header-cycle)
(define-key multifiles-heading-map (kbd "n") 'mf--header-next)
(define-key multifiles-heading-map (kbd "p") 'mf--header-prev)
(define-key multifiles-heading-map (kbd "g") 'mf--header-goto-source)

(define-key multifiles-minor-mode-map (kbd "C-c n") 'mf--header-next)
(define-key multifiles-minor-mode-map (kbd "C-c p") 'mf--header-prev)

(defun create-header-overlay (beg end)
  (let ((o (make-overlay beg end nil nil nil)))
    (overlay-put o 'type 'mf-heading)
    (overlay-put o 'evaporate t)
    (overlay-put o 'face font-lock-keyword-face)
    (overlay-put o 'keymap multifiles-heading-map)
    o))

(defun mf--add-mirror (buffer beg end &optional heading &optional right-here)
  (let (contents original-overlay mirror-overlay heading-overlay)
    (mf--add-hook-if-necessary)
    (with-current-buffer buffer
      (delete-orphan-overlays)
      (mf--add-hook-if-necessary)
      (setq contents (buffer-substring beg end))
      (setq original-overlay (create-original-overlay beg end)))
    (if right-here
        (progn (end-of-line) (newline))
      (end-of-buffer)
      ;;right-here means a restore, so we already have a heading
      (when heading
        (setq heading-overlay (mf--insert-heading heading))))
    (mf---insert-contents)
    (setq mirror-overlay (create-mirror-overlay beg end))
    (overlay-put mirror-overlay 'backing-buffer buffer)
    (overlay-put mirror-overlay 'twin original-overlay)
    (overlay-put original-overlay 'twin mirror-overlay)
    (when heading-overlay
      (overlay-put heading-overlay 'mirror mirror-overlay))
    mirror-overlay))

(defun mf--insert-heading (heading)
  (let ((hdr-begin (point))
        (hdr-end (progn (insert heading) (point))))
    (prog1
        (create-header-overlay hdr-begin hdr-end)
      (newline))))

(defun mf---insert-contents ()
  ;(end-of-buffer)
  ;(newline)
  (setq beg (point))
  (insert contents)
  (setq end (point))
  (newline 2))

(defun mf--any-overlays-in-buffer ()
  (--any? (memq (overlay-get it 'type) '(mf-original mf-mirror))
          (overlays-in (point-min) (point-max))))

(defun mf--add-hook-if-necessary ()
  (unless (mf--any-overlays-in-buffer)
    (add-hook 'post-command-hook 'mf--update-twins)))

(defun mf--remove-hook-if-necessary ()
  (unless (mf--any-overlays-in-buffer)
    (remove-hook 'post-command-hook 'mf--update-twins)))

(defun create-original-overlay (beg end)
  (let ((o (make-overlay beg end nil nil t)))
    (overlay-put o 'type 'mf-original)
    (overlay-put o 'modification-hooks '(mf--on-modification))
    (overlay-put o 'insert-in-front-hooks '(mf--on-modification))
    (overlay-put o 'insert-behind-hooks '(mf--on-modification))
    o))

(defun create-mirror-overlay (beg end)
  (let ((o (make-overlay beg end nil nil t)))
    (overlay-put o 'type 'mf-mirror)
    (overlay-put o 'line-prefix mf--mirror-indicator)
    (overlay-put o 'modification-hooks '(mf--on-modification))
    (overlay-put o 'insert-in-front-hooks '(mf--on-modification))
    (overlay-put o 'insert-behind-hooks '(mf--on-modification))
    o))

(defun mf--on-modification (o after? beg end &optional delete-length)
  (when (not after?)
    (when (mf---removed-entire-overlay)
      (mf--remove-mirror o)))

  (when (and after? (not (null (overlay-start o))))
    (when (not (mf--is-original o))
      (overlay-put o 'line-prefix mf--mirror-changed-indicator))
    (add-to-list 'mf--changed-overlays o)))

(defun mf---removed-entire-overlay ()
  (and (<= beg (overlay-start o))
       (>= end (overlay-end o))))

(defun mf--update-twins ()
  (when mf--changed-overlays
    (-each mf--changed-overlays
      (lambda (o)
        (when (and o (overlay-buffer o))
          (mf--update-twin o))))
    (setq mf--changed-overlays nil)))

(defun mf--remove-mirror (o)
  (let* ((twin (overlay-get o 'twin))
         (original (if (mf--is-original o) o twin))
         (mirror (if (mf--is-original o) twin o))
         (mirror-beg (overlay-start mirror))
         (mirror-end (overlay-end mirror)))
    (with-current-buffer (overlay-buffer mirror)
      (save-excursion
        (delete-overlay mirror)
        (delete-region mirror-beg mirror-end)
        (goto-char mirror-beg)
        (delete-blank-lines)
        (mf--remove-hook-if-necessary)))
    (delete-overlay original)
    (mf--remove-hook-if-necessary)))

(defun mf--is-original (o)
  (equal 'mf-original (overlay-get o 'type)))

(defun mf--update-twin (o)
  (let* ((beg (overlay-start o))
         (end (overlay-end o))
         (contents (buffer-substring-no-properties beg end))
         (twin (overlay-get o 'twin))
         (buffer (overlay-buffer twin))
         (beg (overlay-start twin))
         (end (overlay-end twin)))
    (when (not (mf--is-original o))
      (overlay-put o 'line-prefix mf--mirror-indicator))
    (with-current-buffer buffer
      (save-excursion
        (goto-char beg)
        (insert contents)
        (delete-char (- end beg))))))

(defvar mf--mirror-indicator "| ")
(add-text-properties
 0 1
 `(face (:foreground ,(format "#%02x%02x%02x" 128 128 128)
                     :background ,(format "#%02x%02x%02x" 128 128 128)))
 mf--mirror-indicator)

(defvar mf--mirror-changed-indicator "| ")
(add-text-properties
 0 1
 `(face (:foreground ,(format "#%02x%02x%02x" 1 1 128)
                     :background ,(format "#%02x%02x%02x" 1 1 128)))
 mf--mirror-changed-indicator)

(provide 'multifiles)

;;; multifiles.el ends here
