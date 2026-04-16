local M = {}

-- State for the currently open diff session.
-- Only one diff can be open at a time.
local _diff_state = nil

function M.close_diff()
	if not _diff_state then
		return
	end
	local state = _diff_state
	_diff_state = nil

	-- diffoff on both windows before closing
	for _, win in ipairs({ state.original_win, state.proposed_win }) do
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_call(win, function()
				vim.cmd("diffoff")
			end)
		end
	end

	-- Close the whole tab; bufhidden=wipe on the scratch buffer cleans it up automatically
	local tab = state.tab_page
	if tab and vim.api.nvim_tabpage_is_valid(tab) then
		-- Switch away first so we don't accidentally close a tab the user is editing in
		local current_tab = vim.api.nvim_get_current_tabpage()
		if current_tab == tab then
			-- Try to go to a previous tab before closing
			pcall(vim.cmd, "tabprevious")
		end
		pcall(vim.api.nvim_set_current_tabpage, tab)
		pcall(vim.cmd, "tabclose")
	end
end

function M.accept()
	if not _diff_state then
		vim.notify("[assist.nvim] No diff session active.", vim.log.levels.WARN)
		return
	end
	local state = _diff_state

	-- Read from the live proposed buffer — the user may have edited it
	local lines = vim.api.nvim_buf_get_lines(state.proposed_buf, 0, -1, false)
	local content = table.concat(lines, "\n")

	-- Write to disk
	local f = io.open(state.change.path, "w")
	if not f then
		vim.notify("[assist.nvim] Could not write to " .. state.change.path, vim.log.levels.ERROR)
		return
	end
	f:write(content)
	f:close()

	-- Reload the file in any open buffer
	vim.cmd("checktime")

	local path = state.change.path
	M.close_diff()
	vim.notify("[assist.nvim] Applied change to " .. path, vim.log.levels.INFO)
end

function M.reject()
	if not _diff_state then
		vim.notify("[assist.nvim] No diff session active.", vim.log.levels.WARN)
		return
	end
	M.close_diff()
	vim.notify("[assist.nvim] Change rejected.", vim.log.levels.INFO)
end

function M.open_diff(change)
	-- Close any existing diff first
	M.close_diff()

	-- Open a new tab for the diff so we don't disturb the user's window layout
	vim.cmd("tabnew")
	local tab_page = vim.api.nvim_get_current_tabpage()

	-- Left side: the original file (or an empty buffer for new files)
	if change.is_new_file then
		vim.cmd("enew")
		pcall(vim.api.nvim_buf_set_name, 0, change.path)
	else
		vim.cmd("edit " .. vim.fn.fnameescape(change.path))
	end

	local original_win = vim.api.nvim_get_current_win()
	local original_buf = vim.api.nvim_get_current_buf()
	vim.cmd("diffthis")

	-- Right side: a scratch buffer containing the proposed content
	vim.cmd("vsplit")
	local proposed_win = vim.api.nvim_get_current_win()

	local scratch_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[scratch_buf].buftype = "nofile"
	vim.bo[scratch_buf].bufhidden = "wipe"
	vim.bo[scratch_buf].swapfile = false
	-- Match filetype for syntax highlighting in the diff
	local ft = vim.bo[original_buf].filetype
	if ft and ft ~= "" then
		vim.bo[scratch_buf].filetype = ft
	end

	-- Populate with proposed content
	local proposed_lines = vim.split(change.proposed_full or "", "\n", { plain = true })
	vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, proposed_lines)

	vim.api.nvim_win_set_buf(proposed_win, scratch_buf)

	-- Name the scratch buffer for clarity
	local short_name = vim.fn.fnamemodify(change.path, ":t")
	pcall(vim.api.nvim_buf_set_name, scratch_buf, "[proposed] " .. short_name)

	vim.cmd("diffthis")

	-- Store state before setting keymaps (keymaps reference M.accept/reject which read _diff_state)
	_diff_state = {
		tab_page = tab_page,
		original_win = original_win,
		original_buf = original_buf,
		proposed_win = proposed_win,
		proposed_buf = scratch_buf,
		change = change,
	}

	-- Install keymaps on both buffers so the user can act from either pane
	local km_opts = { noremap = true, silent = true }
	for _, buf in ipairs({ original_buf, scratch_buf }) do
		vim.keymap.set("n", "<leader>da", function()
			M.accept()
		end, vim.tbl_extend("force", km_opts, { buffer = buf, desc = "Accept diff change" }))
		vim.keymap.set("n", "<leader>dr", function()
			M.reject()
		end, vim.tbl_extend("force", km_opts, { buffer = buf, desc = "Reject diff change" }))
	end
end

return M
