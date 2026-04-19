local config = require("assist.config")
local utils = require("assist.utils")

local M = {}

local function build_insert_prompt(insert_info, user_prompt, file_path, lang, buf_content)
	local parts = {
		"<task>Generate a code snippet to insert after the cursor line based on the provided instructions. You MUST use the Edit tool.</task>",
		string.format(
			"<file path=%q language=%q cursor_line=%q/>",
			file_path,
			lang,
			tostring(insert_info.cursor_line + 1)
		),
	}
	if buf_content then
		table.insert(parts, string.format("<file_content>\n```%s\n%s\n```\n</file_content>", lang, buf_content))
	end
	table.insert(parts, string.format("<instructions>%s</instructions>", user_prompt))
	local prompt = table.concat(parts, "\n")
	utils.log(prompt)
	return prompt
end

local function run_assist_insert(insert_info, user_prompt)
	local buf = insert_info.buf
	local file_path = vim.api.nvim_buf_get_name(buf)
	local lang = vim.bo[buf].filetype
	local opts = config.options
	local cursor_line = insert_info.cursor_line

	local spinner = utils.start_spinner(buf, { { line = cursor_line } }, "Generating...")

	local buf_content = vim.bo[buf].modified and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		or nil
	local prompt = build_insert_prompt(insert_info, user_prompt, file_path, lang, buf_content)
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
	utils.log("=== AssistInsert command: " .. table.concat(cmd, " "))
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
				utils.log("=== AssistInsert exit code: " .. code)
				utils.log("=== stdout:\n" .. raw)
				local result, err = utils.parse_edit_write_tool_response(raw)
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

function M.assist_normal()
	local insert_info = utils.get_normal_insert_info()
	utils.prompt_and_run(" Assist Insert ", function(input)
		run_assist_insert(insert_info, input)
	end)
end

return M
