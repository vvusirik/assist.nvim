local config = require("assist.config")
local utils = require("assist.utils")

local M = {}

function M.setup(opts)
	config.setup(opts)
end

local function build_edit_prompt(selection, user_prompt, file_path, lang, buf_content)
	local parts = {
		"<task>Edit the following code region according to the instructions. You MUST apply your changes using the Edit tool — do not print the code as text.</task>",
		string.format(
			"<file path=%q language=%q start_line=%q end_line=%q/>",
			file_path,
			lang,
			tostring(selection.start_line + 1),
			tostring(selection.end_line + 1)
		),
	}
	if buf_content then
		table.insert(parts, string.format("<file_content>\n```%s\n%s\n```\n</file_content>", lang, buf_content))
	end
	table.insert(parts, string.format("<selection>\n```%s\n%s\n```\n</selection>", lang, selection.text))
	table.insert(parts, string.format("<instructions>%s</instructions>", user_prompt))

	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

local function run_assist_selection(selection, user_prompt)
	local buf = selection.buf
	local file_path = vim.api.nvim_buf_get_name(buf)
	local lang = vim.bo[buf].filetype
	local opts = config.options

	local spinner = utils.start_spinner(buf, {
		{ line = selection.start_line, above = true },
		{ line = selection.end_line },
	}, "Implementing...")

	local buf_content = vim.bo[buf].modified and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") or nil
	local prompt = build_edit_prompt(selection, user_prompt, file_path, lang, buf_content)
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
		prompt,
	}
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
				spinner.stop()

				if code ~= 0 then
					local stderr_out = table.concat(stderr_lines, "\n")
					vim.notify(
						"[assist.nvim] claude exited with code "
							.. code
							.. (stderr_out ~= "" and (": " .. stderr_out) or ""),
						vim.log.levels.ERROR
					)
					return
				end

				local raw = table.concat(stdout_lines, "\n")
				local result, err = utils.parse_tool_use_content(raw)
				if err then
					vim.notify("[assist.nvim] " .. err, vim.log.levels.ERROR)
					return
				end

				local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local buf_content = table.concat(buf_lines, "\n")
				local new_content, n = buf_content:gsub(vim.pesc(result.old_string), result.content, 1)
				if n == 0 then
					vim.notify("[assist.nvim] Could not find anchor text in buffer", vim.log.levels.ERROR)
					return
				end
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new_content, "\n", { plain = true }))
				vim.notify("[assist.nvim] Done.", vim.log.levels.INFO)
			end)
		end,
	})

	if job_id <= 0 then
		spinner.stop()
		vim.notify("[assist.nvim] Failed to start claude (job_id=" .. job_id .. ")", vim.log.levels.ERROR)
		return
	end

	vim.fn.chanclose(job_id, "stdin")
end

function M.assist_visual_selection(line1, line2)
	local selection = utils.get_visual_selection(line1, line2)
	if selection.text == "" then
		vim.notify("[assist.nvim] No text selected.", vim.log.levels.WARN)
		return
	end
	utils.prompt_and_run(" Assist Select ", function(input)
		run_assist_selection(selection, input)
	end)
end

return M
