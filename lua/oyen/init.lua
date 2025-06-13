-- i will refactor this and modularize it later
-- i need to work so i dont have time right now
-- but everything works
-- maybe i will add a config option to enable/disable the popup
-- and enhance the get_method_declarations

local M = {}

-- plugin state
M.is_cycling = false
M.cycle_mode = "buffer"

-- buffer cycle
M.histories = {}
M.last_entered = {}
M.current_positions = {}

-- for debugging
M.debug_win = nil
M.debug_buf = nil
M.debug_enabled = false
M.debug = false

-- popup
M.popup_timer_id = nil
M.cycle_popup_win = nil -- buffer cycle
M.cycle_popup_buf = nil -- buffer cycle
M.method_popup_buf = nil -- method cycle
M.method_popup_win = nil -- method cycle

-- method cycle
M.method_cache = {}
M.method_cache_timestamp = {}
M.method_cache_ttl = 2000
M.method_debounce_timer = nil
M.method_debounce_delay = 100

M.config = {
	max_history_size = 30,
	popup_timeout = 1000,
	popup_max_display = 8,
	path_display = {
		enabled = true,
		mode = "default",
		project_roots = {
			"pom.xml",
			"build.gradle",
			".git",
			"package.json",
			"Cargo.toml",
			"Makefile",
			".project",
			".luacheckrc",
		},
	},
	separator = " 󰇘 ",
	keymaps = {
		next = "<C-n>",
		prev = "<C-p>",
		change_mode = "<leader><leader>",
	},
	popup = {
		title = "Oyen",
		title_pos = "center",
		border = "rounded",
	},
}

local function debounced_popup_update(methods, current_index)
	if M.method_debounce_timer then
		vim.fn.timer_stop(M.method_debounce_timer)
	end

	M.method_debounce_timer = vim.fn.timer_start(M.method_debounce_delay, function()
		M.show_method_popup(methods, current_index)
		M.method_debounce_timer = nil
	end)
end

local function get_method_declarations()
	local bufnr = vim.api.nvim_get_current_buf()

	local filetype = vim.bo[bufnr].filetype
	if not filetype or filetype == "" then
		return {}
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if line_count == 1 then
		local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
		if not first_line or first_line == "" then
			return {}
		end
	end

	local success, parser = pcall(vim.treesitter.get_parser, bufnr)
	if not success or not parser then
		return {}
	end

	local tree_ok, trees = pcall(parser.parse, parser)
	if not tree_ok or not trees or #trees == 0 then
		return {}
	end

	local tree = trees[1]
	local root = tree:root()
	local methods = {}
	local lang = parser:lang()

	local queries = {
		java = [[
			(method_declaration
				name: (identifier) @method_name
			) @method_decl
		]],
		javascript = [[
			(method_definition
				name: (property_identifier) @method_name
			) @method_decl
			
			(function_declaration
				name: (identifier) @method_name
			) @method_decl
			
			(variable_declarator
				name: (identifier) @method_name
				value: (function_expression)
			) @method_decl
			
			(variable_declarator
				name: (identifier) @method_name
				value: (arrow_function)
			) @method_decl
			
			(pair
				key: (property_identifier) @method_name
				value: (function_expression)
			) @method_decl
			
			(pair
				key: (property_identifier) @method_name
				value: (arrow_function)
			) @method_decl
		]],
		typescript = [[
			(method_definition
				name: (property_identifier) @method_name
			) @method_decl
			
			(function_declaration
				name: (identifier) @method_name
			) @method_decl
			
			(variable_declarator
				name: (identifier) @method_name
				value: (function_expression)
			) @method_decl
			
			(variable_declarator
				name: (identifier) @method_name
				value: (arrow_function)
			) @method_decl
			
			(pair
				key: (property_identifier) @method_name
				value: (function_expression)
			) @method_decl
			
			(pair
				key: (property_identifier) @method_name
				value: (arrow_function)
			) @method_decl
		]],
		python = [[
			(function_definition
				name: (identifier) @method_name
			) @method_decl
		]],
		c = [[
			(function_definition
				declarator: (function_declarator
					declarator: (identifier) @method_name
				)
			) @method_decl
		]],
		lua = [[
			(function_declaration
				name: (identifier) @method_name
			) @method_decl
			
			(assignment_statement
				(variable_list
					name: (identifier) @method_name
				)
				(expression_list
					value: (function_definition)
				)
			) @method_decl
		]],
		rust = [[
			(function_item
				name: (identifier) @method_name
			) @method_decl
			
			(impl_item
				body: (declaration_list
					(function_item
						name: (identifier) @method_name
					) @method_decl
				)
			)
		]],
		go = [[
			(function_declaration
				name: (identifier) @method_name
			) @method_decl
			
			(method_declaration
				name: (field_identifier) @method_name
			) @method_decl
		]],
	}

	local lang_map = {
		tsx = "typescript",
		javascriptreact = "javascript",
		typescriptreact = "typescript",
	}

	local query_lang = lang_map[lang] or lang
	local query_string = queries[query_lang]

	if not query_string then
		query_string = [[
			(method_declaration
				name: (identifier) @method_name
			) @method_decl
			
			(function_declaration
				name: (identifier) @method_name
			) @method_decl
			
			(function_definition
				name: (identifier) @method_name
			) @method_decl
		]]
	end

	local ok, query = pcall(vim.treesitter.query.parse, lang, query_string)
	if not ok then
		local simple_query = [[
			(function_declaration
				name: (identifier) @method_name
			) @method_decl
			
			(method_definition
				name: (property_identifier) @method_name
			) @method_decl
		]]
		ok, query = pcall(vim.treesitter.query.parse, lang, simple_query)
		if not ok then
			-- Silently return empty table instead of showing warning for empty buffers
			return {}
		end
	end

	local captures = {}
	local capture_ok, _ = pcall(function()
		for id, node in query:iter_captures(root, bufnr, 0, -1) do
			local capture_name = query.captures[id]
			table.insert(captures, {
				name = capture_name,
				node = node,
				id = id,
			})
		end
	end)

	if not capture_ok then
		return {}
	end

	local i = 1
	while i <= #captures do
		local capture = captures[i]
		if capture.name == "method_decl" then
			local start_row, start_col, end_row, end_col = capture.node:range()
			local method_name = ""

			for j = 1, #captures do
				if captures[j].name == "method_name" then
					local name_start_row = captures[j].node:range()
					if name_start_row >= start_row and name_start_row <= end_row then
						method_name = vim.treesitter.get_node_text(captures[j].node, bufnr)
						break
					end
				end
			end

			if method_name == "" then
				local function find_identifier_in_node(node)
					local node_type = node:type()
					if node_type == "identifier" or node_type == "property_identifier" then
						return vim.treesitter.get_node_text(node, bufnr)
					end
					for child in node:iter_children() do
						local result = find_identifier_in_node(child)
						if result then
							return result
						end
					end
					return nil
				end
				method_name = find_identifier_in_node(capture.node) or "unknown"
			end

			table.insert(methods, {
				name = method_name,
				start_row = start_row,
				start_col = start_col,
				end_row = end_row,
				end_col = end_col,
				node = capture.node,
			})
		end
		i = i + 1
	end

	table.sort(methods, function(a, b)
		return a.start_row < b.start_row
	end)

	return methods
end

function M.show_method_popup(methods, current_index)
	if #methods == 0 then
		return
	end
	M.stop_popup_timer()
	if M.method_popup_win and vim.api.nvim_win_is_valid(M.method_popup_win) then
		pcall(vim.api.nvim_win_close, M.method_popup_win, true)
		M.method_popup_win = nil
	end
	if not M.method_popup_buf or not vim.api.nvim_buf_is_valid(M.method_popup_buf) then
		M.method_popup_buf = vim.api.nvim_create_buf(false, true)
		if not M.method_popup_buf then
			return
		end
		vim.bo[M.method_popup_buf].bufhidden = "wipe"
		vim.bo[M.method_popup_buf].buftype = "nofile"
		vim.bo[M.method_popup_buf].swapfile = false
	end

	local max_display = M.config.popup_max_display or 5
	local total_methods = #methods

	-- Fixed window positioning logic
	local start_idx, end_idx
	if total_methods <= max_display then
		-- If we have fewer methods than max_display, show all
		start_idx = 1
		end_idx = total_methods
	else
		-- Calculate the ideal start position (centered around current_index)
		local half_display = math.floor(max_display / 2)
		start_idx = math.max(1, current_index - half_display)

		-- Ensure we don't go past the end
		if start_idx + max_display - 1 > total_methods then
			start_idx = total_methods - max_display + 1
		end

		end_idx = start_idx + max_display - 1
	end

	local lines = {}
	local max_width = 20
	for i = start_idx, end_idx do
		local method = methods[i]
		local display = i .. M.config.separator .. method.name
		table.insert(lines, display)
		max_width = math.max(max_width, vim.fn.strdisplaywidth(display))
	end

	vim.bo[M.method_popup_buf].modifiable = true
	vim.api.nvim_buf_set_lines(M.method_popup_buf, 0, -1, false, lines)

	local ns_id = vim.api.nvim_create_namespace("bufstack_method_highlight")
	vim.api.nvim_buf_clear_namespace(M.method_popup_buf, ns_id, 0, -1)

	-- Calculate which line in the popup should be highlighted
	local highlight_line = current_index - start_idx
	if highlight_line >= 0 and highlight_line < #lines then
		local line_length = #lines[highlight_line + 1]
		local success = pcall(vim.api.nvim_buf_set_extmark, M.method_popup_buf, ns_id, highlight_line, 0, {
			end_line = highlight_line,
			end_col = line_length,
			hl_group = "Statement",
		})
		if not success then
			pcall(
				vim.highlight.range,
				M.method_popup_buf,
				ns_id,
				"Statement",
				{ highlight_line, 0 },
				{ highlight_line, -1 },
				{}
			)
		end
	end

	vim.bo[M.method_popup_buf].modifiable = false

	local width = math.min(max_width + 4, math.floor(vim.o.columns * 0.6))
	local height = math.min(max_display, #lines)
	local col = math.floor((vim.o.columns - width) / 2)
	local row = math.floor((vim.o.lines - height) / 2) - 2

	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = M.config.popup.border,
		title = "Oyen",
		title_pos = M.config.popup.title_pos,
		noautocmd = true,
	}

	local ok, win_id = pcall(vim.api.nvim_open_win, M.method_popup_buf, false, win_opts)
	if not ok then
		return
	end

	M.method_popup_win = win_id
	vim.wo[M.method_popup_win].wrap = false
	vim.wo[M.method_popup_win].number = false

	M.popup_timer_id = vim.fn.timer_start(math.max(500, M.config.popup_timeout), function()
		if M.method_popup_win and vim.api.nvim_win_is_valid(M.method_popup_win) then
			pcall(vim.api.nvim_win_close, M.method_popup_win, true)
			M.method_popup_win = nil
		end
		M.popup_timer_id = nil
	end)
end

local function setup_method_cache_invalidation()
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
		callback = function()
			local bufnr = vim.api.nvim_get_current_buf()
			local buf_key = tostring(bufnr)
			M.method_cache[buf_key] = nil
			M.method_cache_timestamp[buf_key] = nil
		end,
	})
end

local function get_cached_methods()
	local bufnr = vim.api.nvim_get_current_buf()
	local buf_key = tostring(bufnr)
	local current_time = vim.fn.reltime()

	if M.method_cache[buf_key] and M.method_cache_timestamp[buf_key] then
		local elapsed = vim.fn.reltimestr(vim.fn.reltime(M.method_cache_timestamp[buf_key]))
		if tonumber(elapsed) * 1000 < M.method_cache_ttl then
			return M.method_cache[buf_key]
		end
	end

	local methods = get_method_declarations()

	M.method_cache[buf_key] = methods
	M.method_cache_timestamp[buf_key] = current_time

	return methods
end

function M.cycle_methods(offset)
	local methods = get_cached_methods()

	if #methods == 0 then
		vim.notify("No methods found", vim.log.levels.WARN)
		return
	end

	local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local target_method

	if offset > 0 then
		for _, method in ipairs(methods) do
			if method.start_row > cursor_row then
				target_method = method
				break
			end
		end
		if not target_method then
			target_method = methods[1]
		end
	else
		for i = #methods, 1, -1 do
			local method = methods[i]
			if method.start_row < cursor_row then
				target_method = method
				break
			end
		end
		if not target_method then
			target_method = methods[#methods]
		end
	end

	if target_method then
		pcall(vim.api.nvim_win_set_cursor, 0, { target_method.start_row + 1, target_method.start_col })
		vim.cmd.normal({ "zz", bang = true })

		local method_number = 1
		for i, method in ipairs(methods) do
			if method.start_row == target_method.start_row then
				method_number = i
				break
			end
		end

		debounced_popup_update(methods, method_number)
	end
end

local function smart_truncate_path(path, max_length)
	local dirpath = vim.fn.fnamemodify(path, ":~:.:h")

	if dirpath == "." then
		return ""
	end

	if #dirpath <= max_length then
		return dirpath
	end

	local parts = vim.split(dirpath, "/")
	if #parts > 2 then
		return parts[1] .. "/.../" .. parts[#parts]
	end

	return "..." .. string.sub(dirpath, -(max_length - 3))
end

local function project_relative_path(path)
	local dirpath = vim.fn.fnamemodify(path, ":~:.:h")

	if dirpath == "." then
		return ""
	end

	local current_dir = vim.fn.fnamemodify(path, ":p:h")
	local check_dir = current_dir
	while check_dir ~= "/" and check_dir ~= "" do
		for _, root in ipairs(M.config.path_display.project_roots) do
			local root_path = check_dir .. "/" .. root
			if vim.fn.filereadable(root_path) == 1 or vim.fn.isdirectory(root_path) == 1 then
				return vim.fn.fnamemodify(check_dir, ":t")
			end
		end
		check_dir = vim.fn.fnamemodify(check_dir, ":h")
	end

	return dirpath
end

local function get_pathname(path)
	if M.config.path_display.mode == "default" then
		return vim.fn.fnamemodify(path, ":~:.:h")
	elseif M.config.path_display.mode == "smart" then
		return smart_truncate_path(path, 30)
	elseif M.config.path_display.mode == "project" then
		return project_relative_path(path)
	else
		return vim.fn.fnamemodify(path, ":~:.:h")
	end
end

local function is_trackable_buffer(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	return path ~= ""
		and vim.api.nvim_buf_is_valid(bufnr)
		and vim.bo[bufnr].buftype == ""
		and vim.fn.buflisted(bufnr) == 1
end

local function get_current_window()
	return vim.api.nvim_get_current_win()
end

local function ensure_window_history(winid)
	winid = winid or get_current_window()
	if not M.histories[winid] then
		M.histories[winid] = {}
		M.current_positions[winid] = 1
	end
end

local function add_to_history(bufnr, winid)
	winid = winid or get_current_window()

	if not is_trackable_buffer(bufnr) then
		return
	end

	ensure_window_history(winid)

	local path = vim.api.nvim_buf_get_name(bufnr)
	M.last_entered[winid] = bufnr

	table.insert(M.histories[winid], 1, { bufnr = bufnr, path = path })
	M.current_positions[winid] = 1

	if #M.histories[winid] > M.config.max_history_size then
		table.remove(M.histories[winid])
	end
end

function M.stop_popup_timer()
	if M.popup_timer_id then
		vim.fn.timer_stop(M.popup_timer_id)
		M.popup_timer_id = nil
	end
end

function M.show_cycle_popup(winid)
	winid = winid or get_current_window()

	M.stop_popup_timer()

	local history = M.histories[winid] or {}
	local current_pos = M.current_positions[winid] or 1

	local start_idx = math.max(1, current_pos - math.floor(M.config.popup_max_display / 2))
	local end_idx = math.min(start_idx + M.config.popup_max_display - 1, #history)

	local lines = {}
	for i = start_idx, end_idx do
		local entry = history[i]
		if entry then
			local filename = vim.fn.fnamemodify(entry.path, ":t")
			local reversed_index = #history - i + 1

			local display = reversed_index .. M.config.separator .. filename

			if M.config.path_display.enabled then
				local dirpath = get_pathname(entry.path)
				if dirpath ~= "." and dirpath ~= "" then
					display = display .. " (" .. dirpath .. ")"
				end
			end

			table.insert(lines, display)
		end
	end

	if #lines == 0 then
		return
	end

	if not M.cycle_popup_buf or not vim.api.nvim_buf_is_valid(M.cycle_popup_buf) then
		if M.cycle_popup_buf then
			M.cycle_popup_buf = nil
		end
		M.cycle_popup_buf = vim.api.nvim_create_buf(false, true)
		if not M.cycle_popup_buf or not vim.api.nvim_buf_is_valid(M.cycle_popup_buf) then
			vim.notify("Failed to create popup buffer", vim.log.levels.ERROR)
			return
		end
		vim.bo[M.cycle_popup_buf].bufhidden = "wipe"
		vim.bo[M.cycle_popup_buf].filetype = "bufstack-popup"
		vim.bo[M.cycle_popup_buf].buftype = "nofile"
		vim.bo[M.cycle_popup_buf].swapfile = false
	end

	if M.cycle_popup_win and vim.api.nvim_win_is_valid(M.cycle_popup_win) then
		vim.api.nvim_win_close(M.cycle_popup_win, true)
		M.cycle_popup_win = nil
	end

	if not vim.api.nvim_buf_is_valid(M.cycle_popup_buf) then
		vim.notify("Invalid popup buffer", vim.log.levels.ERROR)
		M.cycle_popup_buf = nil
		return
	end

	vim.bo[M.cycle_popup_buf].modifiable = true
	vim.api.nvim_buf_set_lines(M.cycle_popup_buf, 0, -1, false, lines)
	vim.bo[M.cycle_popup_buf].modifiable = false

	local width = 30
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
	end
	width = math.min(width, math.floor(vim.o.columns * 0.8))
	local height = math.min(5, #lines)
	local col = math.floor((vim.o.columns - width) / 2)
	local row = math.floor((vim.o.lines - height) / 2)

	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = M.config.popup.border,
		title = M.config.popup.title,
		title_pos = M.config.popup.title_pos,
	}

	local status, win_id = pcall(vim.api.nvim_open_win, M.cycle_popup_buf, false, win_opts)

	if not status or not win_id then
		vim.notify("Failed to create popup window", vim.log.levels.ERROR)
		return
	end

	M.cycle_popup_win = win_id

	vim.wo[M.cycle_popup_win].wrap = false
	vim.wo[M.cycle_popup_win].number = false

	local ns_id = vim.api.nvim_create_namespace("bufstack_highlight")
	vim.api.nvim_buf_clear_namespace(M.cycle_popup_buf, ns_id, 0, -1)

	local highlight_idx = current_pos - start_idx + 1
	if highlight_idx >= 1 and highlight_idx <= #lines then
		vim.highlight.range(
			M.cycle_popup_buf,
			ns_id,
			"Statement",
			{ highlight_idx - 1, 0 },
			{ highlight_idx - 1, -1 },
			{}
		)

		for i, line in ipairs(lines) do
			local filename_end = string.find(line, " %(")
			if filename_end then
				vim.highlight.range(M.cycle_popup_buf, ns_id, "Comment", { i - 1, filename_end - 1 }, { i - 1, -1 }, {})
			end
		end
	end

	M.popup_timer_id = vim.fn.timer_start(M.config.popup_timeout, function()
		if M.cycle_popup_win and vim.api.nvim_win_is_valid(M.cycle_popup_win) then
			vim.api.nvim_win_close(M.cycle_popup_win, true)
			M.cycle_popup_win = nil
		end
		M.popup_timer_id = nil
	end)
end

function M.update_cycle_popup(winid)
	winid = winid or get_current_window()

	M.stop_popup_timer()

	local history = M.histories[winid] or {}
	local current_pos = M.current_positions[winid] or 1

	local start_idx = math.max(1, current_pos - math.floor(M.config.popup_max_display / 2))
	local end_idx = math.min(start_idx + M.config.popup_max_display - 1, #history)

	local lines = {}
	for i = start_idx, end_idx do
		local entry = history[i]
		if entry then
			local filename = vim.fn.fnamemodify(entry.path, ":t")
			local reversed_index = #history - i + 1

			local display = reversed_index .. M.config.separator .. filename

			if M.config.path_display.enabled then
				local dirpath = get_pathname(entry.path)
				if dirpath ~= "." and dirpath ~= "" then
					display = display .. " (" .. dirpath .. ")"
				end
			end

			table.insert(lines, display)
		end
	end

	if #lines == 0 then
		return
	end

	if
		M.cycle_popup_win
		and vim.api.nvim_win_is_valid(M.cycle_popup_win)
		and M.cycle_popup_buf
		and vim.api.nvim_buf_is_valid(M.cycle_popup_buf)
	then
		vim.bo[M.cycle_popup_buf].modifiable = true
		vim.api.nvim_buf_set_lines(M.cycle_popup_buf, 0, -1, false, lines)
		vim.bo[M.cycle_popup_buf].modifiable = false

		local ns_id = vim.api.nvim_create_namespace("bufstack_highlight")
		vim.api.nvim_buf_clear_namespace(M.cycle_popup_buf, ns_id, 0, -1)

		local highlight_idx = current_pos - start_idx + 1
		if highlight_idx >= 1 and highlight_idx <= #lines then
			vim.highlight.range(
				M.cycle_popup_buf,
				ns_id,
				"Statement",
				{ highlight_idx - 1, 0 },
				{ highlight_idx - 1, -1 },
				{}
			)

			for i, line in ipairs(lines) do
				local filename_end = string.find(line, " %(")
				if filename_end then
					vim.highlight.range(
						M.cycle_popup_buf,
						ns_id,
						"Comment",
						{ i - 1, filename_end - 1 },
						{ i - 1, -1 },
						{}
					)
				end
			end
		end
	else
		M.show_cycle_popup(winid)
		return
	end

	M.popup_timer_id = vim.fn.timer_start(M.config.popup_timeout, function()
		if M.cycle_popup_win and vim.api.nvim_win_is_valid(M.cycle_popup_win) then
			vim.api.nvim_win_close(M.cycle_popup_win, true)
			M.cycle_popup_win = nil
		end
		M.popup_timer_id = nil
	end)
end

function M.close_cycle_popup()
	M.stop_popup_timer()

	if M.cycle_popup_win and vim.api.nvim_win_is_valid(M.cycle_popup_win) then
		vim.api.nvim_win_close(M.cycle_popup_win, true)
		M.cycle_popup_win = nil
	end
end

function M.cycle(offset)
	local winid = get_current_window()
	ensure_window_history(winid)

	local history = M.histories[winid]

	if #history <= 1 then
		return
	end

	local new_position = M.current_positions[winid] + offset
	if new_position < 1 or new_position > #history then
		vim.notify("Reached " .. (new_position < 1 and "top" or "bottom") .. " of buffer stack", vim.log.levels.WARN)
		return
	end

	local entry = history[new_position]
	if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) and vim.api.nvim_buf_is_loaded(entry.bufnr) then
		M.is_cycling = true
		vim.api.nvim_win_set_buf(winid, entry.bufnr)
		M.current_positions[winid] = new_position

		M.update_cycle_popup(winid)

		if M.debug then
			M.update_debug_window()
		end

		vim.defer_fn(function()
			M.is_cycling = false
		end, 50)
	else
		table.remove(history, new_position)
		M.cycle(offset)
	end
end

function M.clean_up_window(winid)
	if M.histories[winid] then
		M.histories[winid] = nil
		M.current_positions[winid] = nil
		M.last_entered[winid] = nil
	end

	M.close_cycle_popup()
end

local function setup_autocmds()
	vim.api.nvim_create_autocmd("BufEnter", {
		callback = function(args)
			local winid = get_current_window()

			if M.is_cycling or (M.last_entered[winid] and M.last_entered[winid] == args.buf) then
				return
			end

			add_to_history(args.buf, winid)

			if M.debug then
				M.update_debug_window()
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		callback = function(args)
			local winid = tonumber(args.match)
			if winid then
				M.clean_up_window(winid)
				if M.debug then
					M.update_debug_window()
				end
			end
		end,
	})
end

if M.debug then
	function M.toggle_debug_window()
		if M.debug_enabled and M.debug_win and vim.api.nvim_win_is_valid(M.debug_win) then
			vim.api.nvim_win_close(M.debug_win, true)
			M.debug_win = nil
			M.debug_buf = nil
			M.debug_enabled = false
			return
		end

		M.debug_buf = vim.api.nvim_create_buf(false, true)

		vim.bo[M.debug_buf].bufhidden = "wipe"
		vim.bo[M.debug_buf].filetype = "bufstack-debug"
		vim.bo[M.debug_buf].buftype = "nofile"
		vim.bo[M.debug_buf].swapfile = false
		vim.bo[M.debug_buf].modifiable = false
		vim.api.nvim_buf_set_name(M.debug_buf, "Buffer Stack Debug")

		local width = math.floor(vim.o.columns * 0.3)
		local height = math.floor(vim.o.lines * 0.5)
		local col = math.floor((vim.o.columns - width) / 2)
		local row = math.floor((vim.o.lines - height) / 2)

		local win_opts = {
			relative = "editor",
			width = width,
			height = height,
			col = col,
			row = row,
			style = "minimal",
			border = "rounded",
		}

		M.debug_win = vim.api.nvim_open_win(M.debug_buf, false, win_opts)

		vim.wo[M.debug_win].winhighlight = "Normal:BufferStackDebug"
		vim.wo[M.debug_win].wrap = false
		vim.wo[M.debug_win].number = false

		vim.cmd([[highlight BufferStackDebug guibg=#303540]])

		vim.cmd([[
		syntax match BufferStackHeader /^Buffer Stack Debug View$/
		syntax match BufferStackHeader /^====================$/
		syntax match BufferStackWindow /^Window \d\+.*:$/
		syntax match BufferStackDivider /^--------------------$/
		highlight link BufferStackHeader Title
		highlight link BufferStackWindow Identifier
		highlight link BufferStackDivider Comment
	]])

		M.debug_enabled = true
		M.update_debug_window()

		vim.api.nvim_buf_set_keymap(
			M.debug_buf,
			"n",
			"q",
			'<cmd>lua require("buffer_stack").toggle_debug_window()<CR>',
			{ noremap = true, silent = true }
		)
	end

	function M.update_debug_window()
		if not M.debug_enabled or not M.debug_win or not M.debug_buf then
			return
		end

		if not vim.api.nvim_win_is_valid(M.debug_win) then
			M.debug_win = nil
			M.debug_buf = nil
			return
		end

		local current_win = get_current_window()

		local lines = { "Buffer Stack Debug View", "====================" }

		for winid, history in pairs(M.histories) do
			local win_str = "Window " .. winid

			if winid == current_win then
				win_str = win_str .. " (CURRENT)"
			end

			table.insert(lines, "")
			table.insert(lines, win_str .. ":")
			table.insert(lines, "--------------------")

			if #history == 0 then
				table.insert(lines, "  [Empty history]")
			else
				for i, entry in ipairs(history) do
					local filename = vim.fn.fnamemodify(entry.path, ":t")
					local buf_info = string.format("%d: %s (buf %d)", i, filename, entry.bufnr)

					local total_width = 40
					local padding = math.floor((total_width - #buf_info) / 2)
					padding = math.max(padding, 0)
					local line = string.rep(" ", padding) .. buf_info

					table.insert(lines, line)
				end
			end
		end

		vim.bo[M.debug_buf].modifiable = true
		vim.api.nvim_buf_set_lines(M.debug_buf, 0, -1, false, lines)
		vim.bo[M.debug_buf].modifiable = false

		local ns_id = vim.api.nvim_create_namespace("bufstack_debug_highlight")
		vim.api.nvim_buf_clear_namespace(M.debug_buf, ns_id, 0, -1)

		for winid, history in pairs(M.histories) do
			if #history > 0 then
				local target_pos = M.current_positions[winid]
				local offset = 0

				for w_id, _ in pairs(M.histories) do
					if w_id == winid then
						break
					end
					offset = offset + 4 + #M.histories[w_id]
				end

				local highlight_line = 5 + offset + target_pos - 1

				vim.highlight.range(M.debug_buf, ns_id, "Statement", { highlight_line, 0 }, { highlight_line, -1 }, {})
			end
		end
	end

	vim.keymap.set("n", "<Leader>bs", function()
		M.toggle_debug_window()
	end, { desc = "Toggle Buffer Stack Debug Window" })
end

local function init_current()
	local current_win = get_current_window()
	local current_buf = vim.api.nvim_get_current_buf()

	if is_trackable_buffer(current_buf) then
		add_to_history(current_buf, current_win)
	end
end

function M.cycle_mode_keybind(offset)
	if M.cycle_mode == "buffer" then
		return M.cycle(offset)
	elseif M.cycle_mode == "method" then
		return M.cycle_methods(offset)
	end
end

function M.toggle_cycle_mode()
	if M.cycle_mode == "buffer" then
		M.cycle_mode = "method"
		vim.notify("Switched to method cycle mode", vim.log.levels.INFO)
	else
		M.cycle_mode = "buffer"
		vim.notify("Switched to buffer cycle mode", vim.log.levels.INFO)
	end
end

function M.setup(config)
	M.config = vim.tbl_deep_extend("force", M.config, config or {})
	if M.config.keymaps.next then
		vim.keymap.set("n", M.config.keymaps.next, function()
			M.cycle_mode_keybind(1)
		end, { desc = "Cycle to next buffer" })
	end
	if M.config.keymaps.prev then
		vim.keymap.set("n", M.config.keymaps.prev, function()
			M.cycle_mode_keybind(-1)
		end, { desc = "Cycle to previous buffer" })
	end
	if M.config.keymaps.change_mode then
		vim.keymap.set("n", M.config.keymaps.change_mode, function()
			M.toggle_cycle_mode()
		end, { desc = "Cycle to next method" })
	end

	setup_method_cache_invalidation()

	setup_autocmds()

	init_current()
end

function M.cleanup()
	M.stop_popup_timer()
	if M.method_debounce_timer then
		vim.fn.timer_stop(M.method_debounce_timer)
		M.method_debounce_timer = nil
	end

	if M.method_popup_win and vim.api.nvim_win_is_valid(M.method_popup_win) then
		pcall(vim.api.nvim_win_close, M.method_popup_win, true)
		M.method_popup_win = nil
	end

	M.method_cache = {}
	M.method_cache_timestamp = {}
end

return M
