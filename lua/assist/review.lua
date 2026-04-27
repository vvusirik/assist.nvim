local utils = require("assist.utils")
local M = {}

local _last_state = nil
local _state = {
	-- session table from multi.lua
	session = nil,
	-- which change is displayed
	current_idx = nil,
	-- "pending" | "accepted" | "rejected" keyed by change index
	statuses = nil,
	tab_page = nil,
	panel_win = nil,
	panel_buf = nil,
	orig_win = nil,
	orig_buf = nil,
	prop_win = nil,
	prop_buf = nil,
}

function M.reset_state()
	for key in pairs(_state) do
		_state[key] = nil
	end
end

function M.persist_last_state()
	_last_state = _state
end

function M.open_review(session)
	M.reset_state()
	_state.session = session
	_state.current_idx = 1

	-- open dedicated tab
	vim.cmd("tabnew")
	_state.tab_page = vim.api.nvim_get_current_tabpage()

	--create 3 pane layout
	vim.cmd("leftabove vsplit")
	vim.cmd("leftabove vsplit")
	local wins = vim.api.nvim_tabpage_list_wins(0)
	_state.panel_win = wins[1]
	_state.orig_win = wins[2]
	_state.prop_win = wins[3]

	-- panel gets 15% of total width; orig and prop split the rest evenly
	local total_width = vim.o.columns
	local panel_width = math.floor(total_width * 0.15)
	local half_remaining = math.floor((total_width - panel_width) / 2)
	vim.api.nvim_win_set_width(_state.panel_win, panel_width)
	vim.api.nvim_win_set_width(_state.orig_win, half_remaining)
	vim.api.nvim_win_set_width(_state.prop_win, half_remaining)

	-- Create scratch buffers for panel, original, and proposed panes
	local panel_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[panel_buf].bufhidden = "wipe"
	vim.bo[panel_buf].modifiable = false
	vim.bo[panel_buf].buftype = "nofile"
	local orig_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[orig_buf].bufhidden = "wipe"
	local prop_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[prop_buf].bufhidden = "wipe"

	_state.panel_buf = panel_buf
	_state.orig_buf = orig_buf
	_state.prop_buf = prop_buf

	-- Attach to windows
	vim.api.nvim_win_set_buf(_state.panel_win, panel_buf)
	vim.api.nvim_win_set_buf(_state.orig_win, orig_buf)
	vim.api.nvim_win_set_buf(_state.prop_win, prop_buf)

	-- initialize statuses
	_state.statuses = {}
	for idx, _ in ipairs(session.changes) do
		_state.statuses[idx] = "pending"
	end

	-- Keymaps on panel buffer
	local km_opts = { noremap = true, silent = true }
	local function keymap(km, func, buf, desc)
		vim.keymap.set("n", km, func, vim.tbl_extend("force", km_opts, { buffer = buf, desc = desc }))
	end

	local open_key_maps = { "<CR>", "<2-LeftMouse>", "o", "l" }
	for _, km in ipairs(open_key_maps) do
		keymap(km, function()
			local idx = vim.api.nvim_win_get_cursor(_state.panel_win)[1]
			M.show_change(idx)
		end, panel_buf, "Open diff for entry under cursor")
	end

	-- Keymaps on all buffers
	for _, buf in ipairs({ panel_buf, orig_buf, prop_buf }) do
		keymap("q", M.close, buf, "Close review tab")
		keymap("<leader>da", function()
			M.accept()
		end, buf, "Accept diff change")
		keymap("<leader>dr", function()
			M.reject()
		end, buf, "Reject diff change")
		keymap("<tab>", function()
			M.advance_change(false, false)
		end, buf, "Go to next diff")
		keymap("<s-tab>", function()
			M.advance_change(true, false)
		end, buf, "Go to next diff")
		keymap("<leader>e", function()
			vim.api.nvim_set_current_win(_state.panel_win)
		end, buf, "Focus review panel")
	end

	M.render_panel()
	M.show_change(_state.current_idx)
end

function M.reopen_last_review()
	if _last_state ~= nil then
		vim.notify("No prior review to reopen", vim.log.levels.ERROR)
	end
	-- TODO: implement reopen
end

function M.render_panel()
	local session = _state.session
	if not session then
		return
	end
	local lines = {}
	for i, change in ipairs(session.changes) do
		local status = _state.statuses[i] or "pending"

		local box
		if status == "accepted" then
			box = "[✓]"
		elseif status == "rejected" then
			box = "[✗]"
		elseif change.error then
			box = "[!]"
		else
			box = "[ ]"
		end
		lines[#lines + 1] = box .. " " .. (change.path or "")
	end
	vim.bo[_state.panel_buf].modifiable = true
	vim.api.nvim_buf_set_lines(_state.panel_buf, 0, -1, false, lines)
	vim.bo[_state.panel_buf].modifiable = false
end

function M.advance_change(prev, only_pending)
	local session = _state.session
	if not session then
		return
	end
	local current_idx = _state.current_idx
	local n = #session.changes
	local dir = prev and -1 or 1
	for offset = 1, n do
		local i = (current_idx - 1 + dir * offset) % n + 1
		if i < 1 then
			i = i + n
		end
		if not only_pending or _state.statuses[i] == "pending" then
			M.show_change(i)
			return
		end
	end
	vim.notify("No pending changes remaining.", vim.log.levels.INFO)
end

function M.show_change(idx)
	local session = _state.session
	if idx > #session.changes or idx < 1 then
		vim.notify("Invalid change idx: " .. tostring(idx), vim.log.levels.ERROR)
	end
	_state.current_idx = idx

	vim.api.nvim_win_set_cursor(_state.panel_win, { idx, 0 })

	vim.api.nvim_win_call(_state.orig_win, function()
		vim.cmd("diffoff")
	end)
	vim.api.nvim_win_call(_state.prop_win, function()
		vim.cmd("diffoff")
	end)

	local change = session.changes[idx]

	vim.bo[_state.orig_buf].modifiable = true
	vim.api.nvim_buf_set_lines(
		_state.orig_buf,
		0,
		-1,
		false,
		vim.split(change.original_full or "", "\n", { plain = true })
	)
	vim.bo[_state.orig_buf].modifiable = false

	vim.api.nvim_buf_set_lines(
		_state.prop_buf,
		0,
		-1,
		false,
		vim.split(change.proposed_full or "", "\n", { plain = true })
	)

	vim.api.nvim_buf_set_name(_state.orig_buf, "[Original] " .. change.path)
	vim.api.nvim_buf_set_name(_state.prop_buf, "[Proposed] " .. change.path)

	local ft = vim.filetype.match({ filename = change.path }) or ""
	vim.bo[_state.orig_buf].filetype = ft
	vim.bo[_state.prop_buf].filetype = ft

	vim.api.nvim_win_call(_state.orig_win, function()
		vim.cmd("diffthis")
	end)
	vim.api.nvim_win_call(_state.prop_win, function()
		vim.cmd("diffthis")
	end)

	vim.api.nvim_win_set_cursor(_state.prop_win, { 1, 1 })
	vim.api.nvim_set_current_win(_state.prop_win)

	if change.error then
		vim.notify("[assist.nvim] Edit error: " .. change.error, vim.log.levels.WARN)
	end
end

function M.accept()
	local idx = _state.current_idx
	local session = _state.session
	if not session then
		return
	end
	local change = session.changes[idx]
	if not change then
		return
	end

	if change.error then
		vim.notify("[assist.nvim] Cannot accept: " .. change.error, vim.log.levels.ERROR)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(_state.prop_buf, 0, -1, false)
	vim.fn.mkdir(vim.fn.fnamemodify(change.path, ":h"), "p")
	vim.fn.writefile(lines, change.path)

	_state.statuses[idx] = "accepted"
	M.render_panel()
	M.advance_change(false, true)
end

function M.reject()
	local idx = _state.current_idx
	local session = _state.session
	if not session then
		return
	end
	local change = session.changes[idx]
	if not change then
		return
	end

	_state.statuses[idx] = "rejected"
	M.render_panel()
	M.advance_change(false, true)
end

function M.close()
	M.persist_last_state()

	utils.log(_state.orig_win)
	vim.api.nvim_win_call(_state.orig_win, function()
		vim.cmd("diffoff")
	end)
	vim.api.nvim_win_call(_state.prop_win, function()
		vim.cmd("diffoff")
	end)

	vim.cmd("tabclose")
	M.reset_state()
end

function M.test_review()
	local session = {
		changes = {
			{
				path = "/tmp/test_a.lua",
				original_full = "local x = 1\nlocal y = 2\nreturn x + y\n",
				proposed_full = "local x = 10\nlocal y = 20\nreturn x + y\n",
			},
			{
				path = "/tmp/test_b.lua",
				original_full = "print('hello')\n",
				proposed_full = "print('hello, world')\n",
			},
			{
				path = "/tmp/test_c.lua",
				original_full = "local function add(a, b)\n\treturn a + b\nend\n",
				proposed_full = "local function add(a, b)\n\treturn a + b\nend\n\nlocal function sub(a, b)\n\treturn a - b\nend\n",
			},
		},
	}
	M.open_review(session)
end

return M
