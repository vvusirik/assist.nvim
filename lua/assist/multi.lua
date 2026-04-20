local config = require("assist.config")
local utils = require("assist.utils")
local review = require("assist.review")

local M = {}

local function build_multi_prompt(user_prompt)
	local cwd = vim.fn.getcwd()
	local parts = {
		"<task>Make all changes required by the instructions to the project. "
			.. "Use your tools to read and explore files you need for more context. "
			.. "Apply every change using the Edit tool — one call per contiguous changed region. "
			.. "Your Edit calls will not be executed; do not verify or retry them. "
			.. "Do not respond with any text summary or explanation of your changes.</task>",
		string.format("<cwd>%s</cwd>", cwd),
		string.format("<instructions>%s</instructions>", user_prompt),
	}
	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

-- Build session state from a list of Edit tool_use objects.
local function build_session(tool_uses)
	local cwd = vim.fn.getcwd()
	local changes = {}
	local snapshots = {} -- original_full per absolute path, taken once before any edit
	local by_path = {} -- ordered list of unique paths
	local edits_by_path = {} -- path -> list of {old_string, new_string}

	for _, tu in ipairs(tool_uses) do
		local path = tu.file_path
		if not vim.startswith(path, "/") then
			path = cwd .. "/" .. path
		end

		if not snapshots[path] then
			snapshots[path] = utils.read_file_or_empty(path)
			table.insert(by_path, path)
			edits_by_path[path] = {}
		end

		table.insert(edits_by_path[path], { old_string = tu.old_string, new_string = tu.new_string })
	end

	for _, path in ipairs(by_path) do
		local original_full = snapshots[path]
		local current = original_full
		local first_lnum = nil
		local errors = {}

		for _, edit in ipairs(edits_by_path[path]) do
			local escaped = vim.pesc(edit.old_string)
			local new_full, n = current:gsub(escaped, edit.new_string, 1)
			if n == 0 then
				table.insert(errors, "old_string not found: " .. edit.old_string:sub(1, 60))
			else
				if first_lnum == nil then
					local before = current:sub(1, current:find(escaped) - 1)
					local _, newline_count = before:gsub("\n", "")
					first_lnum = newline_count + 1
				end
				current = new_full
			end
		end

		local change = {
			path = path,
			original_full = original_full,
			proposed_full = current,
			lnum = first_lnum or 1,
		}
		if #errors > 0 then
			change.error = table.concat(errors, "; ")
		end

		table.insert(changes, change)
	end

	return { changes = changes }
end

local function run_multi(user_prompt)
	local opts = config.options
	local prompt = build_multi_prompt(user_prompt)
	local stdout_lines = {}
	local stderr_lines = {}

	local cmd = {
		opts.claude_cmd,
		"--disallowedTools",
		"Write",
		"--print",
		"--verbose",
		"--output-format",
		"stream-json",
		"--model",
		opts.model,
		prompt,
	}
	utils.log("=== AssistMulti command: " .. table.concat(cmd, " "))
	local job_id = vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, lines)
			for _, line in ipairs(lines) do
				if line ~= "" then
					table.insert(stdout_lines, line)
					utils.log("=== AssistMulti stdout: " .. line)
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

				local tool_uses, err = utils.parse_all_file_tool_uses(raw)
				if err then
					vim.notify("[assist.nvim] " .. err, vim.log.levels.WARN)
					return
				end

				local session = build_session(tool_uses)
				review.open_review(session)
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
