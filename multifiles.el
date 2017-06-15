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

(defun delete-orphan-overlays ()
  (--each (overlays-in (point-min) (point-max))
    (-when-let (twin (overlay-get it 'twin))
      (when (overlay-buffer twin)
	(delete-overlay it)))))

(defun clear-garbage-overlays ()
  ;;remove any unlinked overlays from the buffer and our data structures
  (setq mf--changed-overlays (-filter #'overlay-buffer mf--changed-overlays)))

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
        (beginning-of-line)
        (search-forward "/")
        (overlay-put o 'mirror (mirror-definition t))))))

(defun mf--header-next ()
  (interactive)
  (let ((bol (save-excursion (beginning-of-line) (point))))
    (when (= bol (point))
      (forward-char))
    (when (search-forward ";; ==" nil t)
      (beginning-of-line))))

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
         (contents (buffer-substring beg end))
         (twin (overlay-get o 'twin))
         (buffer (overlay-buffer twin))
         (beg (overlay-start twin))
         (end (overlay-end twin)))
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

(provide 'multifiles)

;;; multifiles.el ends here
