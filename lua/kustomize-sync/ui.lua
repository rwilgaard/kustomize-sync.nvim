local Menu = require("nui.menu")
local NuiText = require("nui.text")
local sync = require("kustomize-sync.sync")
local context = require("kustomize-sync.context")

local M = {}

local BATCH_NS = vim.api.nvim_create_namespace("kustomize_batch")

M.interactive_sync = function(ctx, opts)
  local dir = ctx.is_dir and ctx.path or vim.fn.fnamemodify(ctx.path, ":h")
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
    local current_json = sync.yq({ '.resources // [] | map(sub("/$", ""))', target, "-o", "json" })
    local current_resources = current_json and vim.fn.json_decode(current_json) or {}
    local res_map = {}
    for _, r in ipairs(current_resources) do res_map[r] = true end

    local handle = vim.uv.fs_scandir(dir)
    local raw_items = {}
    local max_len = 0

    if handle then
      local commented = sync.commented_set(target)
      while true do
        local name, type = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if not sync.is_kustomization(name) and (type == "directory" or sync.is_yaml(name))
            and not commented[name] then
          local clean_name = name:gsub("/$", "")
          table.insert(raw_items, { name = clean_name, is_active = res_map[clean_name] == true })
          if #clean_name > max_len then max_len = #clean_name end
        end
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

  local function toggle()
    local curr_win = menu_instance.winid
    local curr_buf = menu_instance.bufnr
    local cursor = vim.api.nvim_win_get_cursor(curr_win)

    local item = active_items[cursor[1]]
    if not item then return end

    local action = item.is_active and "remove" or "add"
    sync.execute_yq(action, item.name, target, opts)

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
    if ctx.refresh then ctx.refresh() end
  end)
end

M.batch_handle_changes = function(changes, refresh, opts)
  if vim.fn.executable("yq") ~= 1 then
    vim.notify("yq not found", vim.log.levels.ERROR)
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
        table.insert(items, { op = change.op, name = r.name, kustomize_file = r.kustomize_file })
      end
    end
  end

  if #items == 0 then
    if refresh then refresh() end; return
  end

  local selected = {}
  for i = 1, #items do selected[i] = true end

  local title   = " Update kustomization.yaml "
  local hint    = " <Space> toggle  <CR> apply  q cancel "
  local max_len = math.max(#title, #hint)
  for _, item in ipairs(items) do
    local len = 4 + 2 + #item.name
    if len > max_len then max_len = len end
  end
  local width = max_len + 2

  local function item_label(item)
    return item.op == "add" and "+ " .. item.name or "- " .. item.name
  end

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
    for i, item in ipairs(items) do
      if selected[i] then sync.execute_yq(item.op, item.name, item.kustomize_file, opts) end
    end
    m:unmount()
  end

  m:map("n", "<Space>", toggle, { noremap = true, nowait = true })
  m:map("n", "<CR>", confirm, { noremap = true, nowait = true })

  m:on("BufLeave", function() if refresh then refresh() end end)
end

M.handle_change = function(action, filepath, refresh, entry_type, opts)
  if vim.fn.executable("yq") ~= 1 then return false end
  local r = context.resolve_change(filepath, action, entry_type)
  if not r then return false end
  local top_level_entry, kustomize_file = r.name, r.kustomize_file

  local prompt_title = action == "add" and
      string.format(" Add %s to kustomization? ", top_level_entry) or
      string.format(" Remove %s from kustomization? ", top_level_entry)

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
      if item.id == "yes" then sync.execute_yq(action, top_level_entry, kustomize_file, opts) end
    end,
  })

  menu:map("n", "y", function()
    menu:unmount()
    sync.execute_yq(action, top_level_entry, kustomize_file, opts)
  end, { nowait = true })

  menu:map("n", "n", function() menu:unmount() end, { nowait = true })

  menu:on("BufLeave", function()
    if refresh then refresh() end
  end)

  menu:mount()
  return true
end

return M
