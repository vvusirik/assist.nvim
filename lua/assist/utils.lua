local config = require("assist.config")

local M = {}

local ns = vim.api.nvim_create_namespace("assist_loading")
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Start an animated spinner on one or more extmarks.
-- positions: list of { line = N, above = bool (default false) }
-- message:   text shown after the spinner frame (e.g. "Generating...")
-- Returns a handle with:
--   handle.stop()       -- stops the timer and clears the loading namespace
--   handle.positions()  -- current { line, col } for each mark, in input order
function M.start_spinner(buf, positions, message)
	local mark_ids = {}
	for i, pos in ipairs(positions) do
		mark_ids[i] = vim.api.nvim_buf_set_extmark(buf, ns, pos.line, 0, {
			virt_lines = { { { SPINNER_FRAMES[1] .. " " .. message, "Comment" } } },
			virt_lines_above = pos.above or false,
		})
	end

	local frame = 1
	local uv = vim.uv or vim.loop
	local timer = uv.new_timer()
	timer:start(
		80,
		80,
		vim.schedule_wrap(function()
			frame = (frame % #SPINNER_FRAMES) + 1
			local animated = SPINNER_FRAMES[frame] .. " " .. message
			for i, id in ipairs(mark_ids) do
				local cur = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
				if #cur > 0 then
					vim.api.nvim_buf_set_extmark(buf, ns, cur[1], cur[2], {
						id = id,
						virt_lines = { { { animated, "Comment" } } },
						virt_lines_above = positions[i].above or false,
					})
				end
			end
		end)
	)

	return {
		stop = function()
			if not timer:is_closing() then
				timer:stop()
				timer:close()
			end
			vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		end,
		positions = function()
			local result = {}
			for i, id in ipairs(mark_ids) do
				result[i] = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
			end
			return result
		end,
	}
end

-- on_submit receives the user's prompt string
function M.prompt_and_run(title, on_submit)
	local opts = config.options
	local width = opts.prompt_buf.width
	local height = opts.prompt_buf.height
	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		width = width,
		height = height,
		col = 0,
		row = 1,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
	})
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true

	vim.cmd("startinsert")

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function submit()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local input = vim.trim(table.concat(lines, "\n"))
		close()
		if input == "" then
			return
		end
		vim.notify("[assist.nvim] Running" .. title, vim.log.levels.INFO)
		on_submit(input)
	end

	local map_opts = { noremap = true, silent = true, buffer = buf }
	vim.keymap.set("n", "<CR>", submit, map_opts)
	vim.keymap.set("n", "q", close, map_opts)
	vim.keymap.set("n", "<Esc>", close, map_opts)
end

function M.get_normal_insert_info()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor[1] - 1 -- 0-indexed
	return { buf = buf, cursor_line = cursor_line }
end

-- Get the visual selection range and text from the current buffer.
-- line1 and line2 are 1-indexed and come from the command range — more
-- reliable than re-reading '< / '> marks which can be stale after edits.
function M.get_visual_selection(line1, line2)
	local buf = vim.api.nvim_get_current_buf()
	local start_line = line1 - 1 -- 0-indexed
	local end_line = line2 - 1 -- 0-indexed

	local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)
	return {
		buf = buf,
		start_line = start_line,
		end_line = end_line,
		text = table.concat(lines, "\n"),
	}
end

-- Extract the first Write/Edit tool_use from a stream-json response.
-- Returns { content, old_string } where old_string is only present for Edit,
-- or nil + err string on failure.
function M.parse_edit_write_tool_response(raw)
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			local ok, event = pcall(vim.json.decode, line)
			if ok and event and event.type == "assistant" then
				local content = event.message and event.message.content
				if type(content) == "table" then
					for _, block in ipairs(content) do
						if block.type == "tool_use" then
							local input = block.input or {}
							if block.name == "Write" and input.content then
								return { content = input.content }, nil
							elseif block.name == "Edit" and input.new_string then
								return { content = input.new_string, old_string = input.old_string }, nil
							end
						end
					end
				end
			end
		end
	end
	return nil, "No Write or Edit tool_use block found in stream-json response"
end

-- Collect all Edit tool_use blocks from a stream-json response.
-- Deduplicates by (file_path, old_string) to handle Claude retrying after permission denials.
-- Returns a list of { file_path, old_string, new_string } or nil + err string if none found.
function M.parse_all_file_tool_uses(raw)
	local results = {}
	local seen = {}
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			local ok, event = pcall(vim.json.decode, line)
			if ok and event and event.type == "assistant" then
				local content = event.message and event.message.content
				if type(content) == "table" then
					for _, block in ipairs(content) do
						if block.type == "tool_use" and block.name == "Edit" then
							local input = block.input or {}
							if input.file_path and input.old_string and input.new_string then
								local key = input.file_path .. "\0" .. input.old_string
								if not seen[key] then
									seen[key] = true
									table.insert(results, {
										file_path = input.file_path,
										old_string = input.old_string,
										new_string = input.new_string,
									})
								end
							end
						end
					end
				end
			end
		end
	end
	if #results == 0 then
		return nil, "No Edit tool_use blocks found in stream-json response"
	end
	return results, nil
end

-- Extract the final text answer from a stream-json response.
-- Returns the result string or nil + err string on failure.
function M.parse_result_text(raw)
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			local ok, event = pcall(vim.json.decode, line)
			if ok and event and event.type == "result" and not event.is_error and type(event.result) == "string" then
				return event.result, nil
			end
		end
	end
	return nil, "No result found in stream-json response"
end

-- Replace lines in buffer with new content (as a list of lines)
function M.replace_lines(buf, start_line, end_line, new_text)
	local new_lines = vim.split(new_text, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, start_line, end_line + 1, false, new_lines)
end

-- Read a file's contents, returning "" if the file does not exist.
function M.read_file_or_empty(path)
	local f = io.open(path, "r")
	if not f then
		return ""
	end
	local content = f:read("*a")
	f:close()
	return content
end

function M.log(msg)
	local f = io.open("/tmp/assist.log", "a")
	if not f then
		vim.notify("assist.nvim: could not open log file /tmp/assist.log", vim.log.levels.WARN)
		return
	end
	f:write(os.date("%H:%M:%S") .. " " .. vim.inspect(msg) .. "\n")
	f:close()
end

return M
