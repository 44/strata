# strata.nvim

Edit multiple files in a single buffer.

## Overview

**strata.nvim** is a Neovim plugin that allows you to open and edit multiple files simultaneously
in one unified buffer. Each file's content is displayed with visual separators, and changes are
automatically saved back to their respective files.
This is project for my personal use, use on your own risk.

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Strata files <file1> <file2> ...` | Open multiple files |
| `:Strata grep <pattern> [files...]` | Open files with matching lines |
| `:Strata qf` or `:Strata quickfix` | Open files from quickfix list |

### Examples

```vim
" Open multiple files in one buffer
:Strata files todo.md someday.md done.md

" Find and edit matching lines
:Strata grep "TODO" *.md
:Strata grep "function" lua/*.lua

" Edit quickfix results
:grep "pattern" .
:Strata qf

" Switch to existing strata buffer
:Strata switch
```

Or in Lua:

```lua
require("strata").open_files({"todo.md", "someday.md", "done.md"})
require("strata").open_grep("TODO", {"todo.md", "someday.md"})
```

**How it works:**
- Each file with matches appears as one continuous section
- Section spans from `first_match - 3` to `last_match + 3` lines (context lines)
- Edit the matches and surrounding context, then `:w` to save changes back to original files
- Non-matching lines outside the section remain untouched
