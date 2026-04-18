local config = require("assist.config")
local utils = require("assist.utils")
local diff = require("assist.diff")

local M = {}

-- Session state: persists between quickfix population and accept/reject.
-- Cleared when a new :AssistMulti run starts.
local _session = nil

local function build_multi_prompt(user_prompt)
	local cwd = vim.fn.getcwd()
	local parts = {
		"<task>Analyze the project and make all changes required by the instructions. "
			.. "Use your tools to read and explore any files you need. "
			.. "When ready, respond with ONLY a raw JSON array — no explanation, no markdown, no code fences. "
			.. "Each element must be an object with exactly these fields: "
			.. '"file_path" (path relative to cwd), '
			.. '"start_line" (1-indexed first line of the region to replace, inclusive), '
			.. '"end_line" (1-indexed last line of the region to replace, inclusive), '
			.. '"new_content" (the text that will replace lines start_line through end_line entirely). '
			.. "IMPORTANT: new_content replaces the specified lines completely — do NOT include the "
			.. "text of lines outside [start_line, end_line] in new_content, or those lines will be duplicated. "
			.. "To insert new lines after line N without removing anything: "
			.. 'set start_line=N, end_line=N, new_content="<exact text of line N>\\n<new lines to insert>". '
			.. "One object per contiguous changed region. Do not merge unrelated changes into one object.</task>",
		string.format("<cwd>%s</cwd>", cwd),
		string.format("<instructions>%s</instructions>", user_prompt),
	}
	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

-- Build session state from a list of line-number edit objects.
-- Chains multiple edits to the same file in top-to-bottom order,
-- adjusting line numbers after each application to account for line count changes.
local function build_session(line_edits)
	local cwd = vim.fn.getcwd()
	local changes = {}

	-- Group and sort edits by file, then by start_line ascending.
	local by_path = {}
	for _, edit in ipairs(line_edits) do
		local path = edit.file_path
		if not vim.startswith(path, "/") then
			path = cwd .. "/" .. path
		end
		if not by_path[path] then
			by_path[path] = {}
		end
		table.insert(by_path[path], { path = path, edit = edit })
	end

	-- Process each file's edits in order.
	for path, path_edits in pairs(by_path) do
		table.sort(path_edits, function(a, b)
			return a.edit.start_line < b.edit.start_line
		end)

		local original_full = utils.read_file_or_empty(path)
		local uv = vim.uv or vim.loop
		local is_new_file = uv.fs_stat(path) == nil
		local current = original_full
		local offset = 0 -- tracks cumulative line count delta from prior edits

		for _, item in ipairs(path_edits) do
			local edit = item.edit
			local adj_start = edit.start_line + offset
			local adj_end = edit.end_line + offset

			local change = {
				path = path,
				original_full = original_full,
				is_new_file = is_new_file,
				start_line = edit.start_line,
				end_line = edit.end_line,
				new_content = edit.new_content,
			}

			local result, err = utils.apply_line_edit(current, adj_start, adj_end, edit.new_content)
			if err then
				change.error = err
				change.proposed_full = current
			else
				change.proposed_full = result
				current = result
				local old_count = edit.end_line - edit.start_line + 1
				local new_count = #vim.split(edit.new_content, "\n", { plain = true })
				offset = offset + (new_count - old_count)
			end

			table.insert(changes, change)
		end
	end

	return { changes = changes }
end

local function populate_quickfix(session)
	local cwd = vim.fn.getcwd()
	local qf_items = {}

	for _, change in ipairs(session.changes) do
		local rel_path = change.path
		if vim.startswith(rel_path, cwd .. "/") then
			rel_path = rel_path:sub(#cwd + 2)
		end

		local text
		if change.error then
			text = "[ERROR] " .. rel_path .. ": " .. change.error
		else
			local first_line = (change.new_content or ""):match("([^\n]*)")
			text = string.format(
				"[Edit] %s lines %d-%d: %s",
				rel_path,
				change.start_line,
				change.end_line,
				first_line or ""
			)
		end

		table.insert(qf_items, {
			filename = change.path,
			lnum = change.start_line,
			col = 1,
			text = text,
		})
	end

	vim.fn.setqflist({}, "r", { title = "AssistMulti Changes", items = qf_items })
	vim.cmd("copen")

	-- Install a buffer-local <CR> handler in the quickfix window.
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].buftype == "quickfix" then
			vim.keymap.set("n", "<CR>", function()
				M.on_qf_select()
			end, { buffer = buf, noremap = true, silent = true })
			break
		end
	end
end

function M.on_qf_select()
	if not _session then
		vim.notify("[assist.nvim] No active AssistMulti session.", vim.log.levels.WARN)
		return
	end
	local idx = vim.api.nvim_win_get_cursor(0)[1]
	local change = _session.changes[idx]
	if not change then
		vim.notify("[assist.nvim] No change at index " .. idx, vim.log.levels.WARN)
		return
	end
	diff.open_diff(change)
end

local function run_multi(user_prompt)
	local opts = config.options
	local prompt = build_multi_prompt(user_prompt)
	local stdout_lines = {}
	local stderr_lines = {}

	local cmd = { opts.claude_cmd, "--print", "--output-format", "json", prompt }
	utils.log("=== AssistMulti command: " .. table.concat(cmd, " "))
	local job_id = vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, lines)
			for _, line in ipairs(lines) do
				if line ~= "" then
					table.insert(stdout_lines, line)
				end
			end
		end,
		on_stderr = function(_, lines)
			for _, line in ipairs(lines) do
				if line ~= "" then
					table.insert(stderr_lines, line)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				local raw = table.concat(stdout_lines, "\n")
				local stderr_out = table.concat(stderr_lines, "\n")
				utils.log("=== AssistMulti exit code: " .. code)
				utils.log("=== stdout:\n" .. raw)
				if stderr_out ~= "" then
					utils.log("=== stderr:\n" .. stderr_out)
				end

				if code ~= 0 then
					vim.notify(
						"[assist.nvim] claude exited with code "
							.. code
							.. (stderr_out ~= "" and (": " .. stderr_out) or ""),
						vim.log.levels.ERROR
					)
					return
				end

				local line_edits, err = utils.parse_line_edits(raw)
				if err then
					vim.notify("[assist.nvim] " .. err, vim.log.levels.WARN)
					return
				end

				_session = build_session(line_edits)
				populate_quickfix(_session)
			end)
		end,
	})

	if job_id <= 0 then
		vim.notify("[assist.nvim] Failed to start claude (job_id=" .. job_id .. ")", vim.log.levels.ERROR)
		return
	end

	vim.fn.chanclose(job_id, "stdin")
end

function M.assist_multi()
	utils.prompt_and_run(" Assist Multi ", function(input)
		run_multi(input)
	end)
end

return M
