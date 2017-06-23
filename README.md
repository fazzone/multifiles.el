# multifiles.el

An initial attempt at "multifiles" as defined
[here](http://www.reddit.com/r/emacs/comments/10gc9u/can_i_have_multiple_parts_of_buffers_in_one_super/)
-- with special support for editing Clojure in conjunction with cider-mode!

## Setup

    (require 'multifiles)
	Or simply:
	(load-file "/path/to/multifiles.el")

## Usage (with cider-mode additions)

This mode is designed to allow you to edit *functions* - as opposed to the conventional way of editing *files*.
It works by creating copies of forms which are linked bidirectionally with their definition in a source file buffer.
Edits to either the original defintion apply to the mirror, and edits to the mirror actually modify the backing buffer.

To add a mirror of the current top-level form to the multifile buffer, use `M-x mf--mirror-defun`.
That is mainly only useful for starting a session.  Once you are editing the mirrored form, `mf--pull-definition`  
(bound to `M-z`) will add the definition of the symbol under point to the bottom of the multifile buffer.
Forms pulled in like this have headers which show the fully-qualified name of the symbol.
With the point over the header, you can do a couple things with the form below:

| Key | Action |
| --- | ------ |
| `q` | Delete this mirror |
| `TAB` | Hide/show the definition |
| `n` | Go to the next header |
| `p` | Go to the previous header |
| `g` | Go to the original definition | 

From within a mirror, you can use `C-c n` and `C-c p` to jump to the next and previous headers in the multifile buffer.
You can edit the headers only becuase I don't know how to make them read-only - changing them will break stuff. 

Saving the \*multifile\* buffer will save all the original files.

## Gotchas 

Loading the edited definitions into your repl can be tricky. The cider functions which use overlays to show the result of an
eval inline tend to break things, so you might want to use the cider functions that pprint their result to a popup buffer.
This means that the metadata of the def will say it was defined in the multifile buffer, which can be annoying 
if you get an exception, for example, becuase that same location may now be showing a different thing.

Another unfortunate aspect of a mode like this is that it tends to confuse undo. Undo within a mirror is remapped to undo within the region defined by the mirror.
This is supposed to behave as if you have independent undo for each form but it is very fragile and especially does not like when you
hide/show other forms or move things around. In fact, attempting to move things around within the multifile
buffer, or really doing anything at to parts of the buffer that are not mirrors, tends to cause confusing behavior. When this happens I suggest
collapsing all of the form definitions and then showing them again. This is also recommended when the gutter next to the mirror
turns blue, which means the link between mirror and backing buffer is not working.

**Warning** This API and functionality is highly volatile.

## License

Copyright (C) 2011 Magnar Sveen

Author: Magnar Sveen <magnars@gmail.com>
Keywords: multiple files

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
