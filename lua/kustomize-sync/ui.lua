local Menu = require("nui.menu")
local NuiText = require("nui.text")
local sync = require("kustomize-sync.sync")
local context = require("kustomize-sync.context")

local M = {}

local BATCH_NS = vim.api.nvim_create_namespace("kustomize_batch")

-- Cursor movement for a menu whose lines are rewritten after it is mounted.
-- nui's own j/k step through the items the menu was created with, so rows that
-- appear later (an opened directory, an entry switched to one line per file)
-- would be out of reach. These go by the buffer instead, wrapping at the ends.
-- Mapped after mount so they replace nui's bindings for the same keys.
local function map_navigation(menu, next_keys, prev_keys)
  local function move(delta)
    return function()
      local count = vim.api.nvim_buf_line_count(menu.bufnr)
      local row = vim.api.nvim_win_get_cursor(menu.winid)[1]
      vim.api.nvim_win_set_cursor(menu.winid, { (row - 1 + delta) % count + 1, 0 })
    end
  end
  for _, key in ipairs(next_keys) do
    menu:map("n", key, move(1), { noremap = true, nowait = true })
  end
  for _, key in ipairs(prev_keys) do
    menu:map("n", key, move(-1), { noremap = true, nowait = true })
  end
end

M.interactive_sync = function(ctx, opts)
  if not sync.require_cli("yq") then return end
  local dir = sync.ctx_dir(ctx)
  local target = sync.find_kustomization(dir)

  if not target then
    vim.notify("No kustomization.yaml found", vim.log.levels.WARN)
    return
  end

  local title = " Manage Resources "
  local hint  = " <Space> toggle  q close "

  -- Directories the user opened by hand. One that nothing is listed out of
  -- starts as a single folded line: its files could be listed by path, but
  -- showing every yaml under every such directory would bury the entries that
  -- are actually in play.
  local expanded = {}

  -- Read once: toggling an entry rewrites .resources and nothing else, so what
  -- the other keys reference can't change while the menu is open.
  local referenced = sync.referenced_paths(target)

  local rows, width, height
  local function fetch()
    local resources, listed = sync.current_resources(target)
    resources, listed = resources or {}, listed or {}
    local entries, loose = sync.scan_entries(dir, target, resources,
      { loose = true, referenced = referenced })
    entries, loose = entries or {}, loose or {}
    local by_path = sync.preferred_style(target, resources) == "path"

    local paths = vim.tbl_keys(entries)
    table.sort(paths)

    rows = {}
    local folds = {}
    for _, path in ipairs(paths) do
      -- Entries that can't be added (a directory with no kustomization file)
      -- are hidden unless they're already listed, in which case the user still
      -- needs a way to toggle them off.
      if listed[path] or entries[path] then
        local top = path:match("^([^/]+)/")
        if top and loose[top] and not by_path and not expanded[top] then
          if not folds[top] then
            folds[top] = { fold = top, count = 0 }
            table.insert(rows, folds[top])
          end
          folds[top].count = folds[top].count + 1
        else
          table.insert(rows, { name = path, top = top, is_active = listed[path] == true })
        end
      end
    end

    width = math.max(30, #title, #hint)
    for _, row in ipairs(rows) do
      if row.fold then
        row.text = string.format(" ▸  %s/ (%d yaml)", row.fold, row.count)
      else
        row.text = (row.is_active and "[x] " or "[ ] ") .. row.name
      end
      width = math.max(width, vim.fn.strdisplaywidth(row.text) + 4)
    end
    height = math.min(20, math.max(1, #rows))
  end
  fetch()

  local function lines()
    return vim.tbl_map(function(row) return row.text end, rows)
  end

  local menu = Menu({
    relative = "cursor",
    position = { row = 1, col = 0 },
    size = { width = width, height = height },
    border = {
      style = "rounded",
      text = {
        top          = NuiText(title, "Normal"),
        top_align    = "center",
        bottom       = NuiText(hint, "Comment"),
        bottom_align = "center",
      },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
  }, {
    lines = vim.tbl_map(function(line) return Menu.item(line, {}) end, lines()),
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = { "<Esc>", "q", "<C-c>" },
    },
  })

  menu:mount()

  vim.bo[menu.bufnr].modifiable = true
  vim.bo[menu.bufnr].readonly = false
  vim.bo[menu.bufnr].buftype = "nofile"

  local function draw()
    vim.api.nvim_buf_set_lines(menu.bufnr, 0, -1, false, lines())
    vim.api.nvim_buf_clear_namespace(menu.bufnr, BATCH_NS, 0, -1)
    for i, row in ipairs(rows) do
      if row.fold then
        vim.hl.range(menu.bufnr, BATCH_NS, "Comment", { i - 1, 0 }, { i - 1, -1 })
      end
    end
    -- Size only: see confirm_entries.
    menu:update_layout({ size = { width = width, height = height } })
  end
  draw()

  -- The menu session is the batch: every keystroke writes, but the formatter
  -- runs once on close rather than spawning a process per checkbox.
  local wrote = false

  local function toggle()
    local cursor = vim.api.nvim_win_get_cursor(menu.winid)
    local row = rows[cursor[1]]
    if not row then return end

    if row.fold then
      expanded[row.fold] = true
    else
      sync.execute_yq(row.is_active and "remove" or "add", row.name, target, opts)
      wrote = true
      -- Unticking the last file listed out of a directory makes it one that
      -- nothing is listed out of. Keep it open rather than folding it away
      -- under the cursor.
      if row.top then expanded[row.top] = true end
    end

    fetch()
    draw()
    pcall(vim.api.nvim_win_set_cursor, menu.winid, cursor)
  end

  menu:map("n", "<CR>", toggle, { noremap = true, nowait = true })
  menu:map("n", "<Space>", toggle, { noremap = true, nowait = true })
  map_navigation(menu, { "j", "<Down>", "<Tab>" }, { "k", "<Up>", "<S-Tab>" })

  menu:on("BufLeave", function()
    if wrote then sync.run_formatter(target, opts) end
    if ctx.refresh then ctx.refresh() end
  end)
end

-- What confirming an item will do, as the menu line and the prompt title say it.
local function item_label(item)
  if item.op == "convert" then
    return string.format("~ %s (replaces %d listed by path)", item.name, #item.replaces)
  end
  local label = (item.op == "add" and "+ " or "- ") .. item.name
  -- Say so up front: confirming this one writes a kustomization to disk.
  if item.needs_bootstrap then
    local n = #sync.missing_kustomizations(item)
    label = label .. (n > 1 and string.format(" (create %d kustomizations)", n)
      or " (create kustomization)")
  end
  return label
end

-- The checkbox menu over resolved entries: everything ticked to start with,
-- <Space> to leave a line out, <CR> to write the rest. An entry that could take
-- another form (a new directory as its own kustomization, or its files by path)
-- is marked, and <Tab> on it switches.
local function confirm_entries(entries, refresh, opts)
  local switchable = false
  for _, entry in ipairs(entries) do
    if entry.alt then switchable = true end
  end

  local title = " Update kustomization.yaml "
  local hint  = " <Space> toggle  " .. (switchable and "<Tab> switch style  " or "")
    .. "<CR> apply  q cancel "

  -- Keyed by item rather than row, so a tick survives the rows shifting when
  -- an entry above it switches form.
  local unselected = {}

  -- Everything a redraw needs, rebuilt whenever an entry switches form. Labels
  -- are worked out here rather than per repaint: the bootstrap count stats the
  -- disk.
  local rows, width
  local function layout()
    rows = {}
    for _, entry in ipairs(entries) do
      for _, item in ipairs(entry.items) do
        table.insert(rows, { entry = entry, item = item, label = item_label(item) })
      end
    end

    -- A move across directories removes and adds the same name in two
    -- different kustomizations, which reads as a no-op unless each line names
    -- the file it edits.
    local multiple, label_width = false, 0
    for _, row in ipairs(rows) do
      if row.item.kustomize_file ~= rows[1].item.kustomize_file then multiple = true end
      if row.entry.alt then row.label = row.label .. " ⇄" end
      label_width = math.max(label_width, vim.fn.strdisplaywidth(row.label))
    end

    width = math.max(#title, #hint)
    for _, row in ipairs(rows) do
      row.text = row.label
      if multiple then
        row.text = row.label
          .. string.rep(" ", label_width - vim.fn.strdisplaywidth(row.label) + 2)
          .. vim.fn.fnamemodify(row.item.kustomize_file, ":~:.")
      end
      row.tail = multiple
      width = math.max(width, 4 + vim.fn.strdisplaywidth(row.text))
    end
    width = width + 2
  end
  layout()

  local function make_lines()
    local lines = {}
    for _, row in ipairs(rows) do
      table.insert(lines, (unselected[row.item] and "[ ] " or "[x] ") .. row.text)
    end
    return lines
  end

  local function draw(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, make_lines())
    vim.api.nvim_buf_clear_namespace(bufnr, BATCH_NS, 0, -1)
    for i, row in ipairs(rows) do
      local hl = ({ add = "Added", remove = "Removed" })[row.item.op] or "Changed"
      local label_end = 4 + #row.label
      vim.hl.range(bufnr, BATCH_NS, hl, { i - 1, 4 }, { i - 1, label_end })
      if row.tail then
        vim.hl.range(bufnr, BATCH_NS, "Comment", { i - 1, label_end }, { i - 1, -1 })
      end
    end
  end

  local m = Menu({
    relative    = "cursor",
    position    = { row = 1, col = 0 },
    size        = { width = width, height = #rows },
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
    lines  = vim.tbl_map(function(line) return Menu.item(line, {}) end, make_lines()),
    keymap = {
      focus_next = { "j", "<Down>" },
      focus_prev = { "k", "<Up>" },
      close      = { "<Esc>", "q", "<C-c>" },
    },
  })

  m:mount()
  vim.bo[m.bufnr].modifiable = true
  vim.bo[m.bufnr].readonly   = false
  vim.bo[m.bufnr].buftype    = "nofile"
  draw(m.bufnr)

  local function toggle()
    local cursor = vim.api.nvim_win_get_cursor(m.winid)
    local row    = rows[cursor[1]]
    if not row then return end
    unselected[row.item] = not unselected[row.item] or nil
    draw(m.bufnr)
    pcall(vim.api.nvim_win_set_cursor, m.winid, cursor)
  end

  local function switch()
    local row = rows[vim.api.nvim_win_get_cursor(m.winid)[1]]
    if not row or not row.entry.alt then return end
    local entry = row.entry
    entry.items, entry.alt = entry.alt, entry.items

    layout()
    -- Size only: the menu is anchored to where the cursor was when it opened,
    -- and passing a position would re-anchor it to the cursor inside itself.
    m:update_layout({ size = { width = width, height = #rows } })
    draw(m.bufnr)
    for i, r in ipairs(rows) do
      if r.entry == entry then
        pcall(vim.api.nvim_win_set_cursor, m.winid, { i, 0 })
        break
      end
    end
  end

  local function confirm()
    local approved = {}
    for _, row in ipairs(rows) do
      if not unselected[row.item] then table.insert(approved, row.item) end
    end
    sync.apply_changes(approved, opts)
    m:unmount()
  end

  m:map("n", "<Space>", toggle, { noremap = true, nowait = true })
  m:map("n", "<Tab>", switch, { noremap = true, nowait = true })
  m:map("n", "<CR>", confirm, { noremap = true, nowait = true })
  map_navigation(m, { "j", "<Down>" }, { "k", "<Up>" })

  m:on("BufLeave", function() if refresh then refresh() end end)
end

M.batch_handle_changes = function(changes, refresh, opts)
  if not sync.require_cli("yq") then
    if refresh then refresh() end
    return
  end

  local entries = context.resolve_changes(changes)
  if #entries == 0 then
    if refresh then refresh() end; return
  end
  confirm_entries(entries, refresh, opts)
end

M.handle_change = function(action, filepath, refresh, entry_type, opts)
  -- Silent rather than `sync.require_cli`: this fires per file event, so a
  -- missing yq would be one notification per file the user touches.
  if vim.fn.executable("yq") ~= 1 then return false end
  local entries = context.resolve_changes({
    { op = action, filepath = filepath, entry_type = entry_type },
  })
  if #entries == 0 then return false end

  -- One event can touch several entries: deleting a directory whose files are
  -- listed by path removes each of them. A yes/no can't leave one out, so that
  -- case gets the same menu a batch does.
  local entry = entries[1]
  if #entries > 1 or #entry.items > 1 or (entry.alt and #entry.alt > 1) then
    confirm_entries(entries, refresh, opts)
    return true
  end
  local r   = entry.items[1]
  local alt = entry.alt and entry.alt[1]

  -- Bootstrapping is part of the same yes: the directory is useless as a
  -- resource without a kustomization, so say that rather than adding a broken
  -- entry or asking twice.
  --
  -- Refresh again once the write is done. The menu closes before this runs, and
  -- the BufLeave refresh that fires on close would otherwise be the last one:
  -- a tree repainted before the new kustomization exists.
  local function apply(item)
    sync.apply_changes({ item }, opts)
    if refresh then refresh() end
  end

  -- The question for one item, as a prompt title or as the line offering it
  -- instead of the first.
  local function question(item)
    local missing = item.needs_bootstrap and #sync.missing_kustomizations(item) or 0
    if missing > 1 then
      return string.format("Create %d kustomizations under %s and add it", missing, item.name)
    elseif item.needs_bootstrap then
      return string.format("Create kustomization in %s and add it", item.name)
    elseif item.op == "add" then
      return string.format("Add %s to kustomization", item.name)
    elseif item.op == "convert" then
      return string.format("List %s whole instead of %d %s by path",
        item.name, #item.replaces, #item.replaces == 1 and "file" or "files")
    end
    return string.format("Remove %s from kustomization", item.name)
  end

  local prompt_title = " " .. question(r) .. "? "

  -- The other form gets a line of its own between yes and no. `s` for switch:
  -- `k` and `p` would name the two forms, but `k` already moves the cursor.
  local alt_key = "s"
  local lines = { Menu.item("(y) Yes", { id = "yes" }) }
  local width = #prompt_title
  if alt then
    local text = string.format("(%s) %s instead", alt_key, question(alt))
    table.insert(lines, Menu.item(text, { id = "alt" }))
    width = math.max(width, #text)
  end
  table.insert(lines, Menu.item("(n) No", { id = "no" }))

  local menu = Menu({
    relative = "cursor",
    position = { row = 1, col = 0 },
    size = { width = width + 2, height = #lines },
    border = {
      style = "rounded",
      text = { top = NuiText(prompt_title, "Normal"), top_align = "center" },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
  }, {
    lines = lines,
    keymap = {
      focus_next = { "j", "<Tab>" },
      focus_prev = { "k", "<S-Tab>" },
      close = { "<Esc>", "q", "<C-c>" },
      submit = { "<CR>", "<Space>" },
    },
    on_submit = function(item)
      if item.id == "yes" then apply(r) elseif item.id == "alt" then apply(alt) end
    end,
  })

  menu:map("n", "y", function()
    menu:unmount()
    apply(r)
  end, { nowait = true })

  if alt then
    menu:map("n", alt_key, function()
      menu:unmount()
      apply(alt)
    end, { nowait = true })
  end

  menu:map("n", "n", function() menu:unmount() end, { nowait = true })

  menu:on("BufLeave", function()
    if refresh then refresh() end
  end)

  menu:mount()
  return true
end

return M
