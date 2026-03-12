local M = {}

-- Get the visual selection range and text from the current buffer
function M.get_visual_selection()
	local buf = vim.api.nvim_get_current_buf()
	local start_line = vim.fn.line("'<") - 1 -- 0-indexed
	local end_line = vim.fn.line("'>") - 1 -- 0-indexed

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

-- Extract the code block from claude's JSON response
function M.parse_claude_response(raw)
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or not decoded then
		return nil, "Failed to parse JSON response"
	end

	-- Claude Code JSON output has a 'result' field
	local result = decoded.result
	if not result then
		return nil, "No result field in response"
	end

	-- Strip markdown code fences if present
	result = result:gsub("^```%w*\n", ""):gsub("\n```$", "")
	return result, nil
end

function M.log(msg)
	local f = io.open("/tmp/assist.log", "a")
	f:write(os.date("%H:%M:%S") .. " " .. vim.inspect(msg) .. "\n")
	f:close()
end

return M
