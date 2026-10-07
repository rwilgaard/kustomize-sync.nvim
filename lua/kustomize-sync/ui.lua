local Menu = require("nui.menu")
local NuiText = require("nui.text")
local sync = require("kustomize-sync.sync")
local context = require("kustomize-sync.context")

local M = {}

local BATCH_NS = vim.api.nvim_create_namespace("kustomize_batch")

M.interactive_sync = function(ctx, opts)
  local dir = sync.ctx_dir(ctx)
  local target = sync.find_kustomization(dir)

  if not target then
    vim.notify("No kustomization.yaml found", vim.log.levels.WARN)
    return
  end

  local menu_instance
  local active_items = {}
  local calculated_width = 30
  local calculated_height = 10

  local function fetch_items()
    local _, res_map = sync.current_resources(target)
    res_map = res_map or {}

    local raw_items = {}
    local max_len = 0

    for name, addable in pairs(sync.scan_entries(dir, target) or {}) do
      local clean_name = name:gsub("/$", "")
      local is_active = res_map[clean_name] == true
      -- Entries that can't be added (a directory with no kustomization file)
      -- are hidden unless they're already listed, in which case the user still
      -- needs a way to toggle them off.
      if is_active or addable then
        table.insert(raw_items, { name = clean_name, is_active = is_active })
        if #clean_name > max_len then max_len = #clean_name end
      end
    end

    calculated_width = math.max(30, max_len + 8)
    calculated_height = math.min(20, math.max(1, #raw_items))
    table.sort(raw_items, function(a, b) return a.name < b.name end)

    local items = {}
    for _, it in ipairs(raw_items) do
      local label = string.format("%s %s", it.is_active and "[x]" or "[ ]", it.name)
      table.insert(items, Menu.item(label, { name = it.name, is_active = it.is_active }))
    end
    return items
  end

  active_items = fetch_items()

  menu_instance = Menu({
    relative = "cursor",
    position = { row = 1, col = 0 },
    size = { width = calculated_width, height = calculated_height },
    border = {
      style = "rounded",
      text = { top = NuiText(" Manage Resources ", "Normal"), top_align = "center" },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
  }, {
    lines = active_items,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = { "<Esc>", "q", "<C-c>" },
    },
  })

  menu_instance:mount()

  vim.bo[menu_instance.bufnr].modifiable = true
  vim.bo[menu_instance.bufnr].readonly = false
  vim.bo[menu_instance.bufnr].buftype = "nofile"

  -- The menu session is the batch: every keystroke writes, but the formatter
  -- runs once on close rather than spawning a process per checkbox.
  local wrote = false

  local function toggle()
    local curr_win = menu_instance.winid
    local curr_buf = menu_instance.bufnr
    local cursor = vim.api.nvim_win_get_cursor(curr_win)

    local item = active_items[cursor[1]]
    if not item then return end

    local action = item.is_active and "remove" or "add"
    sync.execute_yq(action, item.name, target, opts)
    wrote = true

    active_items = fetch_items()
    local new_lines = {}
    for _, it in ipairs(active_items) do
      table.insert(new_lines, string.format("%s %s", it.is_active and "[x]" or "[ ]", it.name))
    end

    vim.api.nvim_buf_set_lines(curr_buf, 0, -1, false, new_lines)
    pcall(vim.api.nvim_win_set_cursor, curr_win, cursor)
  end

  menu_instance:map("n", "<CR>", toggle, { noremap = true, nowait = true })
  menu_instance:map("n", "<Space>", toggle, { noremap = true, nowait = true })

  menu_instance:on("BufLeave", function()
    if wrote then sync.run_formatter(target, opts) end
    if ctx.refresh then ctx.refresh() end
  end)
end

M.batch_handle_changes = function(changes, refresh, opts)
  if not sync.require_cli("yq") then
    if refresh then refresh() end
    return
  end

  local seen  = {}
  local items = {}
  for _, change in ipairs(changes) do
    local r = context.resolve_change(change.filepath, change.op, change.entry_type)
    if r then
      local key = change.op .. "\0" .. r.name .. "\0" .. r.kustomize_file
      if not seen[key] then
        seen[key] = true
        table.insert(items, vim.tbl_extend("error", r, { op = change.op }))
      end
    end
  end

  if #items == 0 then
    if refresh then refresh() end; return
  end

  local selected = {}
  for i = 1, #items do selected[i] = true end

  local function item_label(item)
    local label = item.op == "add" and "+ " .. item.name or "- " .. item.name
    -- Say so up front: confirming this one writes a kustomization to disk.
    if item.needs_bootstrap then label = label .. " (create kustomization)" end
    return label
  end

  local title   = " Update kustomization.yaml "
  local hint    = " <Space> toggle  <CR> apply  q cancel "
  local max_len = math.max(#title, #hint)
  for _, item in ipairs(items) do
    local len = 4 + #item_label(item)
    if len > max_len then max_len = len end
  end
  local width = max_len + 2

  local function make_lines()
    local lines = {}
    for i, item in ipairs(items) do
      table.insert(lines, string.format("%s %s",
        selected[i] and "[x]" or "[ ]", item_label(item)))
    end
    return lines
  end

  local function apply_highlights(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, BATCH_NS, 0, -1)
    for i, item in ipairs(items) do
      local hl = item.op == "add" and "Added" or "Removed"
      vim.hl.range(bufnr, BATCH_NS, hl, { i - 1, 4 }, { i - 1, -1 })
    end
  end

  local menu_items = {}
  for _, item in ipairs(items) do
    table.insert(menu_items, Menu.item(
      string.format("[x] %s", item_label(item)), {}))
  end

  local m = Menu({
    relative    = "cursor",
    position    = { row = 1, col = 0 },
    size        = { width = width, height = #items },
    border      = {
      style = "rounded",
      text  = {
        top          = NuiText(title, "Normal"),
        top_align    = "center",
        bottom       = NuiText(hint, "Comment"),
        bottom_align = "center",
      },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
  }, {
    lines  = menu_items,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close      = { "<Esc>", "q", "<C-c>" },
    },
  })

  m:mount()
  vim.bo[m.bufnr].modifiable = true
  vim.bo[m.bufnr].readonly   = false
  vim.bo[m.bufnr].buftype    = "nofile"
  apply_highlights(m.bufnr)

  local function toggle()
    local cursor  = vim.api.nvim_win_get_cursor(m.winid)
    local idx     = cursor[1]
    selected[idx] = not selected[idx]
    vim.api.nvim_buf_set_lines(m.bufnr, 0, -1, false, make_lines())
    apply_highlights(m.bufnr)
    pcall(vim.api.nvim_win_set_cursor, m.winid, cursor)
  end

  local function confirm()
    local approved = {}
    for i, item in ipairs(items) do
      if selected[i] then table.insert(approved, item) end
    end
    sync.apply_changes(approved, opts)
    m:unmount()
  end

  m:map("n", "<Space>", toggle, { noremap = true, nowait = true })
  m:map("n", "<CR>", confirm, { noremap = true, nowait = true })

  m:on("BufLeave", function() if refresh then refresh() end end)
end

M.handle_change = function(action, filepath, refresh, entry_type, opts)
  -- Silent rather than `sync.require_cli`: this fires per file event, so a
  -- missing yq would be one notification per file the user touches.
  if vim.fn.executable("yq") ~= 1 then return false end
  local r = context.resolve_change(filepath, action, entry_type)
  if not r then return false end

  -- Bootstrapping is part of the same yes: the directory is useless as a
  -- resource without a kustomization, so say that rather than adding a broken
  -- entry or asking twice.
  local function apply()
    sync.apply_changes({ vim.tbl_extend("error", r, { op = action }) }, opts)
  end

  local prompt_title
  if r.needs_bootstrap then
    prompt_title = string.format(" Create kustomization in %s and add it? ", r.name)
  elseif action == "add" then
    prompt_title = string.format(" Add %s to kustomization? ", r.name)
  else
    prompt_title = string.format(" Remove %s from kustomization? ", r.name)
  end

  local menu = Menu({
    relative = "cursor",
    position = { row = 1, col = 0 },
    size = { width = #prompt_title + 2, height = 2 },
    border = {
      style = "rounded",
      text = { top = NuiText(prompt_title, "Normal"), top_align = "center" },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
  }, {
    lines = {
      Menu.item("(y) Yes", { id = "yes" }),
      Menu.item("(n) No", { id = "no" }),
    },
    keymap = {
      focus_next = { "j", "<Tab>" },
      focus_prev = { "k", "<S-Tab>" },
      close = { "<Esc>", "q", "<C-c>" },
      submit = { "<CR>", "<Space>" },
    },
    on_submit = function(item)
      if item.id == "yes" then apply() end
    end,
  })

  menu:map("n", "y", function()
    menu:unmount()
    apply()
  end, { nowait = true })

  menu:map("n", "n", function() menu:unmount() end, { nowait = true })

  menu:on("BufLeave", function()
    if refresh then refresh() end
  end)

  menu:mount()
  return true
end

return M
