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
		"<task>Propose changes across one or more files in the project. "
			.. "You MUST apply every change using the Edit or Write tool — "
			.. "do not print code as text.</task>",
		string.format("<cwd>%s</cwd>", cwd),
		string.format("<instructions>%s</instructions>", user_prompt),
	}
	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

-- Build session state from a list of { name, input } tool_use blocks.
local function build_session(tool_uses)
	local cwd = vim.fn.getcwd()
	local changes = {}
	-- Track per-path proposed content so multiple edits to the same file chain correctly.
	local proposed_by_path = {}

	for _, tu in ipairs(tool_uses) do
		local input = tu.input
		local raw_path = input and (input.file_path or input.path)
		if not input or not raw_path then
			utils.log("Skipping tool_use with no path: " .. vim.inspect(tu))
		else
			-- Resolve to absolute path
			local path = raw_path
			if not vim.startswith(path, "/") then
				path = cwd .. "/" .. path
			end

			local original_full = utils.read_file_or_empty(path)
			local uv = vim.uv or vim.loop
			local is_new_file = uv.fs_stat(path) == nil

			local change = {
				path = path,
				tool_name = tu.name,
				original_full = original_full,
				is_new_file = is_new_file,
			}

			if tu.name == "Edit" then
				change.old_string = input.old_string
				change.new_string = input.new_string
				-- Chain: apply against the latest proposed content for this path
				local base = proposed_by_path[path] or original_full
				local result, err = utils.apply_edit_to_content(base, input.old_string or "", input.new_string or "")
				if err then
					change.error = err
					change.proposed_full = base
				else
					change.proposed_full = result
					proposed_by_path[path] = result
				end
			elseif tu.name == "Write" then
				change.content = input.content
				change.proposed_full = input.content or ""
				proposed_by_path[path] = change.proposed_full
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
		-- Show a relative path for readability
		local rel_path = change.path
		if vim.startswith(rel_path, cwd .. "/") then
			rel_path = rel_path:sub(#cwd + 2)
		end

		local text
		if change.error then
			text = "[ERROR] " .. rel_path .. ": " .. change.error
		elseif change.tool_name == "Edit" then
			local first_line = (change.new_string or ""):match("([^\n]*)")
			text = "[Edit] " .. rel_path .. ": " .. (first_line or "")
		else
			text = "[Write] " .. rel_path
		end

		table.insert(qf_items, {
			filename = change.path,
			lnum = 1,
			col = 1,
			text = text,
		})
	end

	vim.fn.setqflist({}, "r", { title = "AssistMulti Changes", items = qf_items })
	vim.cmd("copen")

	-- Find the quickfix buffer and install a buffer-local <CR> handler
	-- that opens the diff view instead of jumping to the file.
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
	-- Cursor line in the qf window is the 1-based index into the change list
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

	local job_id = vim.fn.jobstart(
		{ opts.claude_cmd, "--print", "--output-format", "stream-json", "--verbose", prompt },
		{
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

					local tool_uses, err = utils.parse_tool_uses_from_stream(raw)
					if err then
						vim.notify("[assist.nvim] " .. err, vim.log.levels.WARN)
						return
					end

					_session = build_session(tool_uses)
					populate_quickfix(_session)
				end)
			end,
		}
	)

	if job_id <= 0 then
		vim.notify("[assist.nvim] Failed to start claude (job_id=" .. job_id .. ")", vim.log.levels.ERROR)
		return
	end

	vim.fn.chanclose(job_id, "stdin")
end

function M.assist_multi()
	local width = 60
	local height = 8
	local buf = vim.api.nvim_create_buf(false, true)

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false

	local ui = vim.api.nvim_list_uis()[1]
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = math.floor((ui.width - width) / 2),
		row = math.floor((ui.height - height) / 2),
		style = "minimal",
		border = "rounded",
		title = " Assist Multi ",
		title_pos = "center",
	})

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
		vim.notify("[assist.nvim] Running claude...", vim.log.levels.INFO)
		run_multi(input)
	end

	local map_opts = { noremap = true, silent = true, buffer = buf }
	vim.keymap.set("n", "<CR>", submit, map_opts)
	vim.keymap.set("n", "q", close, map_opts)
	vim.keymap.set("n", "<Esc>", close, map_opts)
end

return M
