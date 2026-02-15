-- Minimal init.lua for testing strata.nvim
-- Usage: nvim -u minimal.lua

-- Add strata to runtime path
vim.opt.runtimepath:prepend('/home/au/w/strata')

-- Load and setup strata
require('strata').setup()

-- Optional: open strata automatically
-- vim.defer_fn(function()
--   require('strata').open_files({'tests/todo.md', 'tests/someday.md', 'tests/done.md'})
-- end, 100)
