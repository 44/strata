-- strata.nvim - Edit multiple files in a single buffer
-- Robust version using extmarks to track section boundaries

local M = {}

-- Namespace for extmarks
local ns = vim.api.nvim_create_namespace("strata")

-- Get sections from buffer-local storage
local function get_sections(buf)
  return vim.b[buf].strata_sections or {}
end

-- Set sections to buffer-local storage
local function set_sections(buf, sections)
  vim.b[buf].strata_sections = sections
end

-- Update section boundaries from extmark positions
local function update_sections_from_extmarks(buf)
  local sections = get_sections(buf)
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  
  -- Sort extmarks by line number
  table.sort(extmarks, function(a, b) return a[2] < b[2] end)
  
  local total_lines = vim.api.nvim_buf_line_count(buf)
  
  for i, section in ipairs(sections) do
    local mark = extmarks[i]
    if mark then
      -- mark is {id, row, col}
      section.start_line = mark[2] + 1  -- Convert 0-indexed to 1-indexed
      
      -- Determine end line (either next section start - 1 or end of buffer)
      if i < #sections then
        local next_mark = extmarks[i + 1]
        section.end_line = next_mark[2]  -- Line before next section starts
      else
        section.end_line = total_lines
      end
    end
  end
  
  set_sections(buf, sections)
end

function M.open_files(filenames)
  -- Create new scratch buffer with custom save
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  
  -- buftype=acwrite enables BufWriteCmd
  vim.bo[buf].buftype = "acwrite"
  
  -- Auto-detect filetype from first file
  local detected_ft = vim.filetype.match({ filename = filenames[1] })
  vim.bo[buf].filetype = detected_ft or "text"
  vim.bo[buf].buflisted = false  -- Exclude from buffer list and sessions
  
  local sections = {}
  local all_lines = {}
  
  -- Add header line (not part of any file, provides anchor for first section's virtual lines)
  table.insert(all_lines, "# Strata")
  
  -- First, collect all file contents
  for _, filename in ipairs(filenames) do
    local lines = vim.fn.readfile(filename)
    if #lines == 0 then lines = { "" } end
    
    table.insert(sections, {
      filename = filename,
      lines = lines
    })
    
    for _, line in ipairs(lines) do
      table.insert(all_lines, line)
    end
  end
  
  -- Set buffer content first
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  
  -- Now set extmarks at correct positions
  -- First file starts at line 1 (0-indexed) because line 0 is the header
  local current_line = 1
  for i = 1, #sections do
    local section = sections[i]
    section.start_line = current_line + 1  -- +1 because header is line 1
    section.end_line = current_line + #section.lines
    local line_count = #section.lines
    section.lines = nil  -- Don't need to store content
    
    -- Build virt_lines - separator lines for each file
    local virt_lines = {
      { { "──────────", "Comment" } },
      { { "▶ " .. section.filename, "Comment" } },
      { { "──────────", "Comment" } },
    }
    
    local ok, err = pcall(function()
      vim.api.nvim_buf_set_extmark(buf, ns, current_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        right_gravity = false,
      })
    end)
    if not ok then
      print("Error setting extmark for " .. section.filename .. ": " .. tostring(err))
    end
    
    current_line = current_line + line_count
  end
  
  -- Store sections
  set_sections(buf, sections)
  
  -- Set buffer name
  vim.api.nvim_buf_set_name(buf, "strata://" .. table.concat(filenames, ", "))
  
  -- Mark as not modified (setting content marks it as modified)
  vim.bo[buf].modified = false
end

-- Handle :w command
vim.api.nvim_create_autocmd("BufWriteCmd", {
  pattern = "*",
  callback = function(args)
    local buf = args.buf
    local bufname = vim.api.nvim_buf_get_name(buf)
    
    -- Only handle strata buffers
    if not bufname:match("^strata://") then
      return
    end
    
    -- Update section boundaries from current extmark positions
    update_sections_from_extmarks(buf)
    
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local sections = get_sections(buf)
    
    for _, section in ipairs(sections) do
      -- Extract lines for this file
      local file_lines = {}
      for i = section.start_line, section.end_line do
        if lines[i] then
          table.insert(file_lines, lines[i])
        end
      end
      
      -- Write to file
      vim.fn.writefile(file_lines, section.filename)
    end
    
    -- Mark buffer as not modified
    vim.bo[buf].modified = false
    print("Saved " .. #sections .. " files")
  end
})

-- Switch to an existing strata buffer or open a new one
function M.switch()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local bufname = vim.api.nvim_buf_get_name(buf)
    if bufname:match("^strata://") then
      vim.api.nvim_set_current_buf(buf)
      return
    end
  end
  print("No strata buffer found")
end

-- Setup function for user configuration
function M.setup(opts)
  opts = opts or {}
  
  -- Create user commands
  vim.api.nvim_create_user_command("Strata", function(cmd_args)
    local files = vim.split(cmd_args.args, " ")
    M.open_files(files)
  end, { nargs = "+", complete = "file" })
  
  vim.api.nvim_create_user_command("StrataSwitch", function()
    M.switch()
  end, {})
  
  -- Optional keymap for switching back to strata buffer
  if opts.switch_key then
    vim.keymap.set('n', opts.switch_key, M.switch, { desc = "Switch to strata buffer" })
  end
end

return M
