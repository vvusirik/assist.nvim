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
