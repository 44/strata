# strata.nvim

Edit multiple files in a single buffer with seamless saving.

## Overview

**strata.nvim** is a Neovim plugin that allows you to open and edit multiple files simultaneously in one unified buffer. Each file's content is displayed with visual separators, and changes are automatically saved back to their respective files.

## Features

- **Unified Editing**: Open multiple files in a single buffer
- **Grep Results Editing**: Edit ripgrep search results across multiple files
- **Visual Separators**: Clear dividers between file sections with filename indicators
- **Seamless Saving**: `:w` saves all files automatically
- **Buffer Management**: Quick switching between strata buffers and regular buffers
- **Extmark-based Tracking**: Robust section boundary tracking using Neovim's extmarks API

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "yourusername/strata.nvim",
  config = function()
    require("strata").setup()
  end
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "yourusername/strata.nvim",
  config = function()
    require("strata").setup()
  end
}
```

### Manual Installation

1. Clone this repository to your Neovim runtime path:
   ```bash
   git clone https://github.com/yourusername/strata.nvim.git ~/.config/nvim/lua/strata
   ```

2. Add to your `init.lua`:
   ```lua
   require("strata").setup()
   ```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Strata files <file1> <file2> ...` | Open multiple files in a strata buffer |
| `:Strata grep <pattern> [files...]` | Open files with matching lines in a strata buffer |
| `:Strata qf` or `:Strata quickfix` | Open files from quickfix list |
| `:Strata switch` | Switch to an existing strata buffer |

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
- Visual separator shows filename and line numbers: `▶ filename (lines 5-25)`
- Edit the matches and surrounding context, then `:w` to save changes back to original files
- Non-matching lines outside the section remain untouched

### Configuration

```lua
require("strata").setup({
  switch_key = "<leader>ss"  -- Optional: keymap to switch to strata buffer
})
```

## How It Works

1. **Opening Files**: The plugin creates a new buffer and loads content from all specified files
2. **Visual Separation**: Each file section is preceded by a visual separator showing the filename
3. **Section Tracking**: Uses Neovim's extmarks API to track where each file's content begins and ends
4. **Saving**: When you run `:w`, the plugin extracts each section and writes it back to the corresponding file

## Development

### Testing

Use the included `minimal.lua` for testing:

```bash
nvim -u minimal.lua
```

Then run:
```vim
:Strata files tests/todo.md tests/someday.md tests/done.md
:Strata grep "\\[ \\x20\\]" tests/*.md
:Strata qf
```

## Requirements

- Neovim 0.7+ (for extmarks and lua API support)

## License

MIT

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
