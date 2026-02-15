-- strata.nvim - Edit multiple files in a single buffer
-- Robust version using extmarks to track section boundaries

local M = {}

-- Namespace for extmarks
local ns = vim.api.nvim_create_namespace("strata")

-- Run ripgrep and parse results
local function run_ripgrep(pattern, files, context)
  context = context or 3
  
  local cmd = {"rg", "--line-number", "--context=" .. context, pattern}
  if files and #files > 0 then
    for _, f in ipairs(files) do
      table.insert(cmd, f)
    end
  else
    table.insert(cmd, ".")
  end
  
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 and #output == 0 then
    return {}
  end
  
  -- Parse output: filename:line:content or filename-line-content (for context)
  local results = {}
  local current_file = nil
  
  for line in output:gmatch("[^\r\n]+") do
    local file, lineno, text = line:match("^([^:]+):(%d+):(.*)$")
    if file then
      current_file = file
      if not results[file] then
        results[file] = {matches = {}, min_line = math.huge, max_line = 0}
      end
      local n = tonumber(lineno)
      table.insert(results[file].matches, n)
      results[file].min_line = math.min(results[file].min_line, n)
      results[file].max_line = math.max(results[file].max_line, n)
    end
  end
  
  return results
end

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

-- Open files with grep matches - one section per file covering all matches
function M.open_grep(pattern, files, context)
  context = context or 3
  local grep_results = run_ripgrep(pattern, files, context)
  
  if vim.tbl_isempty(grep_results) then
    print("No matches found for: " .. pattern)
    return
  end
  
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].buftype = "acwrite"
  
  -- Auto-detect filetype from first matched file
  local first_file = next(grep_results)
  local detected_ft = vim.filetype.match({ filename = first_file })
  vim.bo[buf].filetype = detected_ft or "text"
  
  vim.bo[buf].buflisted = false
  
  local sections = {}
  local all_lines = {}
  
  table.insert(all_lines, "# Strata Grep: " .. pattern)
  
  for filename, data in pairs(grep_results) do
    local file_lines = vim.fn.readfile(filename)
    if #file_lines == 0 then file_lines = { "" } end
    
    -- Calculate section boundaries with context
    local file_start = math.max(1, data.min_line - context)
    local file_end = math.min(#file_lines, data.max_line + context)
    local section_lines = {}
    
    for i = file_start, file_end do
      table.insert(section_lines, file_lines[i])
    end
    
    table.insert(sections, {
      filename = filename,
      file_start = file_start,  -- Original file line where section starts
      file_end = file_end,      -- Original file line where section ends
      orig_line_count = file_end - file_start + 1,
      is_partial = true,
    })
    
    for _, line in ipairs(section_lines) do
      table.insert(all_lines, line)
    end
  end
  
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  
  -- Set extmarks
  local current_line = 1
  for i = 1, #sections do
    local section = sections[i]
    section.start_line = current_line + 1
    section.end_line = current_line + section.orig_line_count
    
    local virt_lines = {
      { { "──────────", "Comment" } },
      { { "▶ " .. section.filename .. " (lines " .. section.file_start .. "-" .. section.file_end .. ")", "Comment" } },
      { { "──────────", "Comment" } },
    }
    
    pcall(function()
      vim.api.nvim_buf_set_extmark(buf, ns, current_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        right_gravity = false,
      })
    end)
    
    current_line = current_line + section.orig_line_count
  end
  
  set_sections(buf, sections)
  vim.api.nvim_buf_set_name(buf, "strata-grep://" .. pattern)
  vim.bo[buf].modified = false
end

-- Open from quickfix list - collect all files and line ranges
function M.open_quickfix(context)
  context = context or 3
  local qflist = vim.fn.getqflist()
  
  if #qflist == 0 then
    print("Quickfix list is empty")
    return
  end
  
  -- Group by filename, collect line numbers
  local files = {}
  for _, item in ipairs(qflist) do
    local filename = item.filename or vim.api.nvim_buf_get_name(item.bufnr)
    if filename and filename ~= "" then
      if not files[filename] then
        files[filename] = {lines = {}, min_line = math.huge, max_line = 0}
      end
      if item.lnum and item.lnum > 0 then
        table.insert(files[filename].lines, item.lnum)
        files[filename].min_line = math.min(files[filename].min_line, item.lnum)
        files[filename].max_line = math.max(files[filename].max_line, item.lnum)
      end
    end
  end
  
  if vim.tbl_isempty(files) then
    print("No valid files in quickfix list")
    return
  end
  
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].buftype = "acwrite"
  
  -- Auto-detect filetype from first file
  local first_file = next(files)
  local detected_ft = vim.filetype.match({ filename = first_file })
  vim.bo[buf].filetype = detected_ft or "text"
  
  vim.bo[buf].buflisted = false
  
  local sections = {}
  local all_lines = {}
  
  table.insert(all_lines, "# Strata Quickfix")
  
  for filename, data in pairs(files) do
    local file_lines = vim.fn.readfile(filename)
    if #file_lines == 0 then file_lines = { "" } end
    
    -- Calculate section boundaries with context
    local file_start = math.max(1, data.min_line - context)
    local file_end = math.min(#file_lines, data.max_line + context)
    local section_lines = {}
    
    for i = file_start, file_end do
      table.insert(section_lines, file_lines[i])
    end
    
    table.insert(sections, {
      filename = filename,
      file_start = file_start,
      file_end = file_end,
      orig_line_count = file_end - file_start + 1,
      is_partial = true,
    })
    
    for _, line in ipairs(section_lines) do
      table.insert(all_lines, line)
    end
  end
  
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  
  -- Set extmarks
  local current_line = 1
  for i = 1, #sections do
    local section = sections[i]
    section.start_line = current_line + 1
    section.end_line = current_line + section.orig_line_count
    
    local virt_lines = {
      { { "──────────", "Comment" } },
      { { "▶ " .. section.filename .. " (lines " .. section.file_start .. "-" .. section.file_end .. ")", "Comment" } },
      { { "──────────", "Comment" } },
    }
    
    pcall(function()
      vim.api.nvim_buf_set_extmark(buf, ns, current_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        right_gravity = false,
      })
    end)
    
    current_line = current_line + section.orig_line_count
  end
  
  set_sections(buf, sections)
  vim.api.nvim_buf_set_name(buf, "strata-quickfix://qf")
  vim.bo[buf].modified = false
end

-- Handle :w command
vim.api.nvim_create_autocmd("BufWriteCmd", {
  pattern = "*",
  callback = function(args)
    local buf = args.buf
    local bufname = vim.api.nvim_buf_get_name(buf)
    
    -- Only handle strata buffers (including strata-grep://)
    if not bufname:match("^strata%-?%a*://") then
      return
    end
    
    -- Update section boundaries from current extmark positions
    update_sections_from_extmarks(buf)
    
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local sections = get_sections(buf)
    
    for _, section in ipairs(sections) do
      -- Extract lines for this file
      local section_lines = {}
      for i = section.start_line, section.end_line do
        if lines[i] then
          table.insert(section_lines, lines[i])
        end
      end
      
      if section.is_partial then
        -- For partial files: read original, splice in changes, write back
        local original_lines = vim.fn.readfile(section.filename)
        local new_lines = {}
        
        -- Lines before the section
        for i = 1, section.file_start - 1 do
          if original_lines[i] then
            table.insert(new_lines, original_lines[i])
          end
        end
        
        -- The edited section
        for _, line in ipairs(section_lines) do
          table.insert(new_lines, line)
        end
        
        -- Lines after the section
        for i = section.file_end + 1, #original_lines do
          if original_lines[i] then
            table.insert(new_lines, original_lines[i])
          end
        end
        
        vim.fn.writefile(new_lines, section.filename)
      else
        -- For full files: write directly
        vim.fn.writefile(section_lines, section.filename)
      end
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
  
  vim.api.nvim_create_user_command("StrataGrep", function(cmd_args)
    local args = vim.split(cmd_args.args, " ")
    local pattern = args[1]
    local files = {}
    
    -- Separate pattern from files
    for i = 2, #args do
      table.insert(files, args[i])
    end
    
    M.open_grep(pattern, files)
  end, { nargs = "+", complete = "file" })
  
  vim.api.nvim_create_user_command("StrataQuickfix", function()
    M.open_quickfix()
  end, {})
  
  -- Optional keymap for switching back to strata buffer
  if opts.switch_key then
    vim.keymap.set('n', opts.switch_key, M.switch, { desc = "Switch to strata buffer" })
  end
end

return M
