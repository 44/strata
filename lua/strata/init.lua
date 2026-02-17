local M = {}

local function noop() end

local log_file = {
    debug = noop,
    info = noop,
    warn = noop,
    error = noop,
}

local notify_level = vim.log.levels.WARN

local log = {
    debug = function(msg)
        if notify_level <= vim.log.levels.DEBUG then
            vim.notify(msg, vim.log.levels.DEBUG)
        end
        log_file.debug(msg)
    end,
    info = function(msg)
        if notify_level <= vim.log.levels.INFO then
            vim.notify(msg, vim.log.levels.INFO)
        end
        log_file.info(msg)
    end,
    warn = function(msg)
        if notify_level <= vim.log.levels.WARN then
            vim.notify(msg, vim.log.levels.WARN)
        end
        log_file.warn(msg)
    end,
    error = function(msg)
        log_file.debug("Error: notify_level=" .. notify_level .. ", compared to ERROR=" .. vim.log.levels.ERROR)
        if notify_level <= vim.log.levels.ERROR then
            vim.notify(msg, vim.log.levels.ERROR)
        end
        log_file.error(msg)
    end,
}

local function init_log(lvl, console, ntf_lvl)
    local ok, pl = pcall(require, "plenary.log")
    if ok then
        log_file = pl.new({
            plugin = "strata",
            level = lvl,
            use_console = console,
        })
    end
    notify_level = ntf_lvl or vim.log.levels.WARN
    log.debug(
        "Logging initialized at level: "
            .. lvl
            .. ", console: "
            .. tostring(console)
            .. ", notify_level: "
            .. notify_level
    )
end

local ns = vim.api.nvim_create_namespace("strata")

local function run_ripgrep(pattern, files, context)
    context = context or 3

    local cmd = { "rg", "--line-number", "--context=" .. context, pattern }
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
                results[file] = { matches = {}, min_line = math.huge, max_line = 0 }
            end
            local n = tonumber(lineno)
            table.insert(results[file].matches, n)
            results[file].min_line = math.min(results[file].min_line, n)
            results[file].max_line = math.max(results[file].max_line, n)
        end
    end

    return results
end

local function get_sections(buf)
    return vim.b[buf].strata_sections or {}
end

local function set_sections(buf, sections)
    vim.b[buf].strata_sections = sections
end

local function update_sections_from_extmarks(buf)
    local sections = get_sections(buf)
    local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})

    table.sort(extmarks, function(a, b)
        return a[2] < b[2]
    end)

    local total_lines = vim.api.nvim_buf_line_count(buf)

    for i, section in ipairs(sections) do
        local mark = extmarks[i]
        if mark then
            -- mark is {id, row, col}
            section.start_line = mark[2] + 1 -- Convert 0-indexed to 1-indexed

            -- Determine end line (either next section start - 1 or end of buffer)
            if i < #sections then
                local next_mark = extmarks[i + 1]
                section.end_line = next_mark[2] -- Line before next section starts
            else
                section.end_line = total_lines
            end
        end
    end

    set_sections(buf, sections)
end

local function make_border(name_text)
    local name_len = #name_text
    local border_top = "╭" .. string.rep("─", name_len + 2) .. "╮"
    local border_mid = "│ " .. name_text .. " │"
    local border_bot = "╰" .. string.rep("─", name_len + 2) .. "╯"
    return {
        { { border_top, "Comment" } },
        { { border_mid, "Comment" } },
        { { border_bot, "Comment" } },
    }
end

function M.prev_section()
    local buf = vim.api.nvim_get_current_buf()
    local sections = get_sections(buf)
    if #sections == 0 then
        return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    -- Find current section
    local current_idx = 1
    for i, section in ipairs(sections) do
        if cursor_line >= section.start_line and cursor_line <= section.end_line then
            current_idx = i
            break
        elseif cursor_line < section.start_line then
            current_idx = i
            break
        end
    end

    local target_idx = math.max(1, current_idx - 1)
    local target_line = sections[target_idx].start_line
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
end

function M.next_section()
    local buf = vim.api.nvim_get_current_buf()
    local sections = get_sections(buf)
    if #sections == 0 then
        return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    -- Find current section
    local current_idx = #sections
    for i = #sections, 1, -1 do
        local section = sections[i]
        if cursor_line >= section.start_line and cursor_line <= section.end_line then
            current_idx = i
            break
        elseif cursor_line > section.end_line then
            current_idx = i
            break
        end
    end

    local target_idx = math.min(#sections, current_idx + 1)
    local target_line = sections[target_idx].start_line
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
end

local function get_current_section_idx(buf)
    local sections = get_sections(buf)
    if #sections == 0 then
        return nil
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    for i, section in ipairs(sections) do
        if cursor_line >= section.start_line and cursor_line <= section.end_line then
            return i
        end
    end

    return nil
end

local function is_closer_to_start(section, cursor_line)
    local section_mid = section.start_line + math.floor((section.end_line - section.start_line) / 2)
    return cursor_line <= section_mid
end

local function update_section_range(buf, section_idx, delta)
    local sections = get_sections(buf)
    local section = sections[section_idx]

    if not section or not section.is_partial then
        return false
    end

    -- Save cursor position relative to file content
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local file_line = section.file_start + (cursor_line - section.start_line)

    local closer_to_start = is_closer_to_start(section, cursor_line)

    -- Read file to get total lines
    local file_lines = vim.fn.readfile(section.filename)
    local total_lines = #file_lines

    -- Adjust range based on cursor position
    if closer_to_start then
        -- Expand/shrink from the beginning
        if delta > 0 then
            section.file_start = math.max(1, section.file_start - delta)
        else
            section.file_start = math.min(section.file_end, section.file_start - delta)
        end
    else
        -- Expand/shrink from the end
        if delta > 0 then
            section.file_end = math.min(total_lines, section.file_end + delta)
        else
            section.file_end = math.max(section.file_start, section.file_end + delta)
        end
    end

    -- Rebuild entire buffer from all sections
    local all_lines = { "# Strata" }
    local current_line = 1

    for i, s in ipairs(sections) do
        local lines = vim.fn.readfile(s.filename)
        local section_lines = {}

        for j = s.file_start, s.file_end do
            if lines[j] then
                table.insert(section_lines, lines[j])
            end
        end

        s.start_line = current_line + 1
        s.end_line = current_line + #section_lines
        s.orig_line_count = #section_lines

        for _, line in ipairs(section_lines) do
            table.insert(all_lines, line)
        end

        current_line = current_line + #section_lines
    end

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

    -- Recreate extmarks
    current_line = 1
    for i, s in ipairs(sections) do
        local name_text = s.filename
        if s.is_partial then
            name_text = s.filename .. " (lines " .. s.file_start .. "-" .. s.file_end .. ")"
        end
        local virt_lines = make_border(name_text)

        vim.api.nvim_buf_set_extmark(buf, ns, current_line, 0, {
            virt_lines = virt_lines,
            virt_lines_above = true,
            right_gravity = false,
        })

        current_line = current_line + s.orig_line_count
    end

    set_sections(buf, sections)

    -- Restore cursor to same file line
    local new_section = sections[section_idx]
    local new_cursor_line = new_section.start_line + (file_line - new_section.file_start)
    new_cursor_line = math.max(new_section.start_line, math.min(new_cursor_line, new_section.end_line))
    vim.api.nvim_win_set_cursor(0, { new_cursor_line, 0 })

    vim.bo[buf].modified = false

    return true
end

function M.expand_context()
    local buf = vim.api.nvim_get_current_buf()

    if vim.bo[buf].modified then
        log.error("Buffer has unsaved changes. Save first")
        return
    end

    local section_idx = get_current_section_idx(buf)

    if not section_idx then
        log.debug("No current section found for cursor line")
        return
    end

    local sections = get_sections(buf)
    local section = sections[section_idx]

    if not section.is_partial then
        log.debug("Cannot expand full file sections")
        return
    end

    if update_section_range(buf, section_idx, 5) then
        log.debug("Expanded to lines " .. section.file_start .. "-" .. section.file_end)
    end
end

function M.shrink_context()
    local buf = vim.api.nvim_get_current_buf()

    if vim.bo[buf].modified then
        log.error("Buffer has unsaved changes. Save first")
        return
    end

    local section_idx = get_current_section_idx(buf)

    if not section_idx then
        log.debug("No current section found for cursor line")
        return
    end

    local sections = get_sections(buf)
    local section = sections[section_idx]

    if not section.is_partial then
        log.debug("Cannot shrink full file sections")
        return
    end

    if update_section_range(buf, section_idx, -5) then
        log.debug("Shrunk to lines " .. section.file_start .. "-" .. section.file_end)
    end
end

local function setup_buffer_keymaps(buf)
    vim.keymap.set("n", "[f", M.prev_section, { buffer = buf, desc = "Previous strata section" })
    vim.keymap.set("n", "]f", M.next_section, { buffer = buf, desc = "Next strata section" })
    vim.keymap.set("n", "zo", M.expand_context, { buffer = buf, desc = "Expand strata context" })
    vim.keymap.set("n", "zc", M.shrink_context, { buffer = buf, desc = "Shrink strata context" })
end

local function close_existing(prefix)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local bufname = vim.api.nvim_buf_get_name(buf)
        if bufname:match("^" .. prefix) and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
            break
        end
    end
end

function M.open_files(filenames)
    close_existing("strata://files")

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)

    -- buftype=acwrite enables BufWriteCmd
    vim.bo[buf].buftype = "acwrite"

    local detected_ft = vim.filetype.match({ filename = filenames[1] })
    vim.bo[buf].filetype = detected_ft or "text"
    vim.bo[buf].buflisted = false -- Exclude from buffer list and sessions

    local sections = {}
    local all_lines = {}

    table.insert(all_lines, "# Strata")

    for _, filename in ipairs(filenames) do
        local lines = vim.fn.readfile(filename)
        if #lines == 0 then
            lines = { "" }
        end

        table.insert(sections, {
            filename = filename,
            lines = lines,
        })

        for _, line in ipairs(lines) do
            table.insert(all_lines, line)
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

    -- Now set extmarks at correct positions
    -- First file starts at line 1 (0-indexed) because line 0 is the header
    local current_line = 1
    for i = 1, #sections do
        local section = sections[i]
        section.start_line = current_line + 1 -- +1 because header is line 1
        section.end_line = current_line + #section.lines
        local line_count = #section.lines
        section.lines = nil -- Don't need to store content

        local virt_lines = make_border(section.filename)

        local ok, err = pcall(function()
            vim.api.nvim_buf_set_extmark(buf, ns, current_line, 0, {
                virt_lines = virt_lines,
                virt_lines_above = true,
                right_gravity = false,
            })
        end)
        if not ok then
            log.warn("Failed to set extmark for " .. section.filename .. ": " .. tostring(err))
        end

        current_line = current_line + line_count
    end

    set_sections(buf, sections)

    vim.api.nvim_buf_set_name(buf, "strata://files")
    vim.bo[buf].modified = false
    setup_buffer_keymaps(buf)
end

function M.open_grep(pattern, files, context)
    context = context or 3
    local grep_results = run_ripgrep(pattern, files, context)

    if vim.tbl_isempty(grep_results) then
        log.info("No matches found")
        return
    end

    close_existing("strata://grep")

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].buftype = "acwrite"

    local first_file = next(grep_results)
    local detected_ft = vim.filetype.match({ filename = first_file })
    vim.bo[buf].filetype = detected_ft or "text"

    vim.bo[buf].buflisted = false

    local sections = {}
    local all_lines = {}

    table.insert(all_lines, "# Strata Grep: " .. pattern)

    for filename, data in pairs(grep_results) do
        local file_lines = vim.fn.readfile(filename)
        if #file_lines == 0 then
            file_lines = { "" }
        end

        local file_start = math.max(1, data.min_line - context)
        local file_end = math.min(#file_lines, data.max_line + context)
        local section_lines = {}

        for i = file_start, file_end do
            table.insert(section_lines, file_lines[i])
        end

        table.insert(sections, {
            filename = filename,
            file_start = file_start, -- Original file line where section starts
            file_end = file_end, -- Original file line where section ends
            orig_line_count = file_end - file_start + 1,
            is_partial = true,
            orig_matches = data.matches,
        })

        for _, line in ipairs(section_lines) do
            table.insert(all_lines, line)
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

    local current_line = 1
    for i = 1, #sections do
        local section = sections[i]
        section.start_line = current_line + 1
        section.end_line = current_line + section.orig_line_count

        local name_text = section.filename .. " (lines " .. section.file_start .. "-" .. section.file_end .. ")"
        local virt_lines = make_border(name_text)

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
    vim.api.nvim_buf_set_name(buf, "strata://grep")
    vim.bo[buf].modified = false
    setup_buffer_keymaps(buf)
end

function M.open_quickfix(context)
    context = context or 3
    local qflist = vim.fn.getqflist()

    if #qflist == 0 then
        log.info("Quickfix list is empty")
        return
    end

    close_existing("strata://quickfix")

    -- Group by filename, collect line numbers
    local files = {}
    for _, item in ipairs(qflist) do
        local filename = item.filename or vim.api.nvim_buf_get_name(item.bufnr)
        if filename and filename ~= "" then
            if not files[filename] then
                files[filename] = { lines = {}, min_line = math.huge, max_line = 0 }
            end
            if item.lnum and item.lnum > 0 then
                table.insert(files[filename].lines, item.lnum)
                files[filename].min_line = math.min(files[filename].min_line, item.lnum)
                files[filename].max_line = math.max(files[filename].max_line, item.lnum)
            end
        end
    end

    if vim.tbl_isempty(files) then
        log.warn("No valid files in quickfix list")
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
        if #file_lines == 0 then
            file_lines = { "" }
        end

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
            orig_matches = data.lines,
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

        local name_text = section.filename .. " (lines " .. section.file_start .. "-" .. section.file_end .. ")"
        local virt_lines = make_border(name_text)

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
    vim.api.nvim_buf_set_name(buf, "strata://quickfix")
    vim.bo[buf].modified = false

    setup_buffer_keymaps(buf)
end

vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = "strata://*",
    callback = function(args)
        local buf = args.buf
        local bufname = vim.api.nvim_buf_get_name(buf)

        if not bufname:match("^strata%-?%a*://") then
            return
        end

        update_sections_from_extmarks(buf)

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local sections = get_sections(buf)
        local changed_files = {}

        for _, section in ipairs(sections) do
            local section_lines = {}
            for i = section.start_line, section.end_line do
                if lines[i] then
                    table.insert(section_lines, lines[i])
                end
            end

            local changed = false

            if section.is_partial then
                -- For partial files: read original, splice in changes, write back
                local original_lines = vim.fn.readfile(section.filename)
                local new_lines = {}

                for i = 1, section.file_start - 1 do
                    if original_lines[i] then
                        table.insert(new_lines, original_lines[i])
                    end
                end

                for _, line in ipairs(section_lines) do
                    table.insert(new_lines, line)
                end

                for i = section.file_end + 1, #original_lines do
                    if original_lines[i] then
                        table.insert(new_lines, original_lines[i])
                    end
                end

                if vim.deep_equal(original_lines, new_lines) then
                    changed = false
                else
                    vim.fn.writefile(new_lines, section.filename)
                    changed = true
                end
            else
                -- For full files: write directly
                local original_lines = vim.fn.readfile(section.filename)
                if vim.deep_equal(original_lines, section_lines) then
                    changed = false
                else
                    vim.fn.writefile(section_lines, section.filename)
                    changed = true
                end
            end

            if changed then
                table.insert(changed_files, section.filename)
            end
        end

        vim.bo[buf].modified = false

        if #changed_files > 0 then
            log.info("Saved " .. #changed_files .. " file(s): " .. table.concat(changed_files, ", "))
        end
    end,
})

function M.switch()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local bufname = vim.api.nvim_buf_get_name(buf)
        if bufname:match("^strata://") then
            vim.api.nvim_set_current_buf(buf)
            return
        end
    end
    log.debug("No strata buffer found to switch to")
end

function M.setup(opts)
    opts = opts or {}
    init_log(opts.log_level or "debug", opts.log_to_console or false, opts.notify_level or vim.log.levels.INFO)

    local function strata_complete(arglead, cmdline, cursorpos)
        local subcommands = { "files", "grep", "qf", "quickfix" }
        if #arglead == 0 then
            return subcommands
        end
        local matches = {}
        for _, cmd in ipairs(subcommands) do
            if cmd:find("^" .. arglead) then
                table.insert(matches, cmd)
            end
        end
        return matches
    end

    vim.api.nvim_create_user_command("Strata", function(cmd_args)
        local args = vim.split(cmd_args.args, "%s+")
        local subcmd = args[1]

        if subcmd == "files" or subcmd == "file" then
            local files = {}
            for i = 2, #args do
                if args[i] and args[i]:len() > 0 then
                    table.insert(files, args[i])
                end
            end
            if #files > 0 then
                M.open_files(files)
            else
                log.warn("Usage: Strata files <file1> <file2> ...")
            end
        elseif subcmd == "grep" then
            local pattern = args[2]
            if not pattern then
                log.warn("Usage: Strata grep [args...]")
                return
            end
            local files = {}
            for i = 3, #args do
                if args[i] and args[i]:len() > 0 then
                    table.insert(files, args[i])
                end
            end
            M.open_grep(pattern, files)
        elseif subcmd == "qf" or subcmd == "quickfix" then
            M.open_quickfix()
        elseif subcmd == "switch" then
            M.switch()
        else
            log.error("Usage: Strata files|grep|qf|quickfix|switch [args]")
        end
    end, { nargs = "*", complete = strata_complete })
end

return M
