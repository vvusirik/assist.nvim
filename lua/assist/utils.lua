local M = {}

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

-- Replace lines in buffer with new content (as a list of lines)
function M.replace_lines(buf, start_line, end_line, new_text)
	local new_lines = vim.split(new_text, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, start_line, end_line + 1, false, new_lines)
end

-- Extract the replacement from claude's JSON response.
-- Claude attempts an Edit or Write tool call which lands in permission_denials
-- since the subprocess has no write access. We pull the new content from that denial.
function M.parse_claude_response(raw)
	local ok, envelope = pcall(vim.json.decode, raw)
	if not ok or not envelope then
		return nil, "Failed to parse CLI JSON envelope"
	end

	local denials = envelope.permission_denials
	if not denials or #denials == 0 then
		return nil, "No permission_denials in response (did Claude attempt an Edit?)"
	end

	for _, denial in ipairs(denials) do
		local input = denial.tool_input
		if input then
			if denial.tool_name == "Edit" and input.new_string then
				return input.new_string, nil
			elseif denial.tool_name == "Write" and input.content then
				return input.content, nil
			end
		end
	end

	return nil, "No Edit or Write tool call found in permission_denials"
end

-- Get cursor position and surrounding lines for normal-mode insert.
function M.get_normal_insert_info(context_lines)
	context_lines = context_lines or 20
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local cursor_line = cursor[1] - 1 -- 0-indexed
	local total = vim.api.nvim_buf_line_count(buf)
	local above_start = math.max(0, cursor_line - context_lines)
	local below_end = math.min(total, cursor_line + context_lines + 1)
	local above = vim.api.nvim_buf_get_lines(buf, above_start, cursor_line, false)
	local below = vim.api.nvim_buf_get_lines(buf, cursor_line + 1, below_end, false)
	return {
		buf = buf,
		cursor_line = cursor_line,
		above = table.concat(above, "\n"),
		below = table.concat(below, "\n"),
	}
end

-- Parse all Edit/Write tool_use blocks from a stream-json response.
-- stream-json emits one JSON object per line; tool calls appear as tool_use
-- content blocks inside type="assistant" message events.
-- Returns a list of { name, input } or nil, err.
function M.parse_tool_uses_from_stream(raw)
	local results = {}
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			local ok, event = pcall(vim.json.decode, line)
			if ok and event and event.type == "assistant" then
				local content = event.message and event.message.content
				if type(content) == "table" then
					for _, block in ipairs(content) do
						if block.type == "tool_use" and (block.name == "Edit" or block.name == "Write") then
							table.insert(results, { name = block.name, input = block.input })
						end
					end
				end
			end
		end
	end
	if #results == 0 then
		return nil, "No Edit or Write tool_use blocks found in stream"
	end
	return results, nil
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

-- Apply an Edit tool replacement to file content.
-- Finds the first plain occurrence of old_string and replaces it with new_string.
-- Returns result, nil or nil, err.
function M.apply_edit_to_content(original, old_string, new_string)
	local start_idx, end_idx = original:find(old_string, 1, true)
	if not start_idx then
		return nil, "old_string not found in file content"
	end
	return original:sub(1, start_idx - 1) .. new_string .. original:sub(end_idx + 1), nil
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
