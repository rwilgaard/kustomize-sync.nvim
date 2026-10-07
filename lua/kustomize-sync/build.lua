local sync = require("kustomize-sync.sync")
local context = require("kustomize-sync.context")
local config = require("kustomize-sync.config")
local Split = require("nui.split")
local Popup = require("nui.popup")
local NuiText = require("nui.text")

local M = {}

local MARK_NS = vim.api.nvim_create_namespace("kustomize_build_diff")

-- `vim.diff` was renamed to `vim.text.diff` in Nvim 0.12 and is deprecated
-- until 1.0. The old name is all 0.11 has, so prefer the new one and fall back.
---@diagnostic disable-next-line: deprecated
local diff_fn = vim.text and vim.text.diff or vim.diff

-- Order the hint line lists actions in. Actions grouped together share one
-- label, so `<Tab>`/`<S-Tab>` read as a single "change" entry.
local HINT_SPEC = {
  { actions = { "rebuild" },                    text = "rebuild" },
  { actions = { "next_change", "prev_change" }, text = "change" },
  { actions = { "diff" },                       text = "diff" },
  { actions = { "set_baseline" },               text = "set baseline" },
  { actions = { "close" },                      text = "close" },
}

-- Configured keys for an action, normalized to a list. `false` (or a missing
-- entry) means the action stays unmapped.
local function lhs_list(action)
  local value = (config.options.build.keymaps or {})[action]
  if not value then return {} end
  return type(value) == "table" and value or { value }
end

local function map_action(win, action, fn)
  for _, lhs in ipairs(lhs_list(action)) do
    win:map("n", lhs, fn, { nowait = true })
  end
end

-- Built fresh on each use so it always reflects the configured keys, and skips
-- anything the user unmapped.
local function hint()
  local parts = {}
  for _, spec in ipairs(HINT_SPEC) do
    local keys = {}
    for _, action in ipairs(spec.actions) do
      local first = lhs_list(action)[1]
      if first then table.insert(keys, first) end
    end
    if #keys > 0 then
      table.insert(parts, table.concat(keys, "/") .. " " .. spec.text)
    end
  end
  return table.concat(parts, "  ")
end

-- Winbar and statusline treat `%` as the start of an item, so a path
-- containing one has to be doubled before it goes on screen.
local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

-- Render lines into the output buffer (toggles modifiable around write).
local function set_buffer_lines(bufnr, stdout)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(stdout, "\n", { plain = true }))
  vim.bo[bufnr].modifiable = false
end

-- Highlight, inside the rendered buffer, every line that differs from the
-- baseline, so drift is visible without opening the diff tab. Returns the rows
-- (0-indexed) each hunk starts on, for the next/previous change keys.
local function mark_changes(bufnr, baseline, current)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  vim.api.nvim_buf_clear_namespace(bufnr, MARK_NS, 0, -1)
  if baseline == current then return {} end

  -- `result_type = "indices"` yields a list of hunks, but the signature also
  -- allows a string, so check before iterating.
  local ok, hunks = pcall(diff_fn, baseline, current, { result_type = "indices" })
  if not ok or type(hunks) ~= "table" then return {} end

  local last_row = vim.api.nvim_buf_line_count(bufnr) - 1
  local rows = {}
  for _, hunk in ipairs(hunks) do
    local count_a, start_b, count_b = hunk[2], hunk[3], hunk[4]
    if count_b == 0 then
      -- Pure deletion: no line left to colour, so hang a marker off the line
      -- the removed block used to follow.
      local row = math.min(math.max(start_b - 1, 0), math.max(last_row, 0))
      vim.api.nvim_buf_set_extmark(bufnr, MARK_NS, row, 0, {
        virt_text = { {
          string.format("  ← %d line%s removed", count_a, count_a == 1 and "" or "s"),
          "DiffDelete",
        } },
        virt_text_pos = "eol",
      })
      table.insert(rows, row)
    else
      local hl = count_a == 0 and "DiffAdd" or "DiffChange"
      local first = start_b - 1
      local last = math.min(start_b + count_b - 2, last_row)
      table.insert(rows, first)
      -- One extmark spanning the hunk, not one per line: a change that touches
      -- every manifest (an image tag, a common label) is otherwise an API call
      -- per line of a build that runs to thousands.
      if first <= last then
        vim.api.nvim_buf_set_extmark(bufnr, MARK_NS, first, 0, {
          end_row = last + 1,
          end_col = 0,
          hl_group = hl,
          hl_eol = true,
        })
      end
    end
  end
  return rows
end

-- Pin a window to its buffer. The rendered output is throwaway, so anything
-- that opens a file into this window (`:edit`, `:bnext`, a picker) would drop
-- the render and leave a stray window behind instead.
local function pin_buffer(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  if vim.fn.exists("&winfixbuf") == 1 then
    vim.wo[winid].winfixbuf = true
  end
end

-- Persistent drift indicator: float gets it in the bottom border, split in the
-- winbar. Either way it stays on screen, unlike the rebuild notification.
local function set_status(win, label, status)
  if win.border and win.border.set_text then
    pcall(function()
      win.border:set_text("bottom", NuiText(" " .. status .. "  │  " .. hint() .. " ", "Comment"), "center")
    end)
  elseif win.winid and vim.api.nvim_win_is_valid(win.winid) then
    vim.wo[win.winid].winbar = table.concat({
      "kustomize build: " .. esc(label),
      esc(status),
      hint(),
    }, "   ")
  end
end

local function status_text(hunk_count, baseline_at)
  if hunk_count == 0 then
    return "= baseline " .. baseline_at
  end
  return string.format("± %d hunk%s since baseline %s",
    hunk_count, hunk_count == 1 and "" or "s", baseline_at)
end

-- Run `kustomize build <target_dir>` asynchronously. on_ok receives stdout.
local function run_build(target_dir, on_ok)
  if not sync.require_cli("kustomize") then return end

  vim.system(
    { "kustomize", "build", target_dir },
    { text = true },
    function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          vim.notify("kustomize build failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
          return
        end
        on_ok(res.stdout or "")
      end)
    end
  )
end

local OUTPUT_BUF_OPTIONS = { buftype = "nofile", swapfile = false, filetype = "yaml" }

-- Create the output window for the configured mode. `label` names the build in
-- the float's border title; the drift indicator and hint line are left to
-- `set_status`, which runs before the window is ever drawn. Returns an unmounted
-- nui component (NuiSplit or NuiPopup) exposing `.bufnr`, `:map`, `:unmount`.
local function make_output_window(label)
  local mode = config.options.build.output

  if mode == "float" then
    return Popup({
      enter = true,
      relative = "editor",
      position = "50%",
      size = { width = "80%", height = "80%" },
      border = {
        style = "rounded",
        text = {
          top = NuiText(" kustomize build: " .. label .. " ", "Normal"),
          top_align = "center",
        },
      },
      win_options = { winhighlight = "Normal:Normal,FloatBorder:Normal" },
      buf_options = OUTPUT_BUF_OPTIONS,
    })
  end

  local position = "bottom"
  if mode == "vsplit" then
    position = "right"
  elseif mode ~= "split" then
    vim.notify("Unknown build.output '" .. tostring(mode) .. "', using split", vim.log.levels.WARN)
  end

  return Split({
    relative = "editor",
    position = position,
    size = "40%",
    buf_options = OUTPUT_BUF_OPTIONS,
  })
end

local diff_seq = 0

-- Baselines outlive the window that produced them, keyed by build dir. In
-- `float` output the window covers the screen, so editing manifests means
-- closing it first — a baseline scoped to the window would never survive long
-- enough to diff against. Reopening the build reuses the stored baseline;
-- `:KustomizeBuild!` or `D` starts a new one.
local baselines = {}

-- One side of a diff. Buffer names are unique so repeated diffs don't collide.
local function make_diff_buf(side, content)
  diff_seq = diff_seq + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, string.format("kustomize-diff://%s/%d", side, diff_seq))
  for option, value in pairs(OUTPUT_BUF_OPTIONS) do
    vim.bo[buf][option] = value
  end
  -- Each diff makes a fresh pair holding a full render; without this they
  -- stay loaded after the tab closes.
  vim.bo[buf].bufhidden = "wipe"
  set_buffer_lines(buf, content)
  return buf
end

-- Side-by-side diff of two rendered outputs. Opens in its own tabpage: the
-- invoking window may be a float or a split, and neither can host a diff pair
-- without wrecking the layout (see the anchoring note in M.build).
local function open_diff(old, old_label, new, new_label)
  vim.cmd("tabnew")
  local placeholder = vim.api.nvim_get_current_buf()

  local function show(side, content, label)
    local buf = make_diff_buf(side, content)
    vim.api.nvim_win_set_buf(0, buf)
    vim.wo.winbar = esc(label)
    vim.cmd("diffthis")
    pin_buffer(vim.api.nvim_get_current_win())
    return buf
  end

  local left = show("baseline", old, old_label)
  vim.cmd("rightbelow vsplit")
  local right = show("current", new, new_label)

  pcall(vim.api.nvim_buf_delete, placeholder, { force = true })

  -- The diff tab reuses the build window's keys, so the same ones close it and
  -- walk its changes. These windows are in real diff mode, where `]c` / `[c`
  -- already do the walking; the configured keys are pointed at those. Leaving
  -- them unmapped is not neutral: a key the user has bound globally to switch
  -- buffers falls through here and fails on the pinned window with E1513.
  local motions = { next_change = "]c", prev_change = "[c" }
  for _, buf in ipairs({ left, right }) do
    for _, lhs in ipairs(lhs_list("close")) do
      vim.keymap.set("n", lhs, "<Cmd>tabclose<CR>", { buffer = buf, nowait = true })
    end
    for action, motion in pairs(motions) do
      for _, lhs in ipairs(lhs_list(action)) do
        if lhs ~= motion then
          vim.keymap.set("n", lhs, motion, { buffer = buf, nowait = true })
        end
      end
    end
  end
end

-- A relative=editor split created while a floating window is current (e.g. a
-- floating neo-tree/oil) collapses the layout to a single full-screen window,
-- so split/vsplit output moves to a normal window first. Float output (Popup)
-- is editor-relative regardless, and switching away would move focus off the
-- invoking float, so it stays put.
local function anchor_to_normal_window()
  if config.options.build.output == "float" then return end
  if vim.api.nvim_win_get_config(0).relative == "" then return end

  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      vim.api.nvim_set_current_win(w)
      return
    end
  end
end

M.build = function(ctx, opts)
  -- Build the nearest kustomization at or above the ctx path.
  local kfile, target_dir = context.find_parent_kustomize(sync.ctx_dir(ctx))
  if not kfile or not target_dir then
    vim.notify("No kustomization.yaml found", vim.log.levels.WARN)
    return
  end

  local label = vim.fn.fnamemodify(kfile, ":~:.")

  run_build(target_dir, function(stdout)
    anchor_to_normal_window()

    local win = make_output_window(label)
    win:mount()
    pin_buffer(win.winid)

    set_buffer_lines(win.bufnr, stdout)

    -- Snapshot the render so later builds can be diffed against it: edit the
    -- manifests, build again, and see what actually moved in the output.
    --
    -- Read from the module table each time rather than held in a local: two
    -- windows on one directory share the baseline, and a copy captured when
    -- this one opened would go on diffing against it after the other moved it.
    local function base() return baselines[target_dir] end
    local function set_baseline(output)
      baselines[target_dir] = { output = output, at = os.date("%H:%M:%S") }
    end
    if opts and opts.reset_baseline then baselines[target_dir] = nil end
    if not base() then set_baseline(stdout) end
    local current = stdout
    local hunk_rows = {}
    local painted

    -- Paint drift into the buffer and the status indicator. Called on open, on
    -- every rebuild, and after re-baselining, so what's on screen always says
    -- how far it has moved from the baseline.
    local function refresh_drift()
      painted = base()
      hunk_rows = mark_changes(win.bufnr, painted.output, current)
      set_status(win, label, status_text(#hunk_rows, painted.at))
    end
    refresh_drift()

    -- Repaint first if the baseline moved under this window, so a jump or a
    -- diff never works from marks drawn against the old one.
    local function catch_up()
      if painted ~= base() then refresh_drift() end
    end

    map_action(win, "close", function() win:unmount() end)

    map_action(win, "rebuild", function()
      vim.notify("Rebuilding " .. label .. "…", vim.log.levels.INFO)
      run_build(target_dir, function(new_stdout)
        -- Closed while the build ran: nui has dropped the buffer, and there is
        -- nothing left to repaint.
        if not win.bufnr then return end
        current = new_stdout
        set_buffer_lines(win.bufnr, current)
        refresh_drift()
        vim.notify("Rebuilt " .. label .. " — " .. status_text(#hunk_rows, base().at), vim.log.levels.INFO)
      end)
    end)

    local function notify_unchanged()
      vim.notify("No change since baseline (" .. base().at .. ")", vim.log.levels.INFO)
    end

    -- Jump between changed regions, wrapping at either end.
    local function jump(forward)
      catch_up()
      if #hunk_rows == 0 then return notify_unchanged() end
      local row = vim.api.nvim_win_get_cursor(win.winid)[1] - 1
      local target
      if forward then
        for _, r in ipairs(hunk_rows) do
          if r > row then target = r break end
        end
        target = target or hunk_rows[1]
      else
        for i = #hunk_rows, 1, -1 do
          if hunk_rows[i] < row then target = hunk_rows[i] break end
        end
        target = target or hunk_rows[#hunk_rows]
      end
      pcall(vim.api.nvim_win_set_cursor, win.winid, { target + 1, 0 })
    end

    map_action(win, "next_change", function() jump(true) end)
    map_action(win, "prev_change", function() jump(false) end)

    map_action(win, "diff", function()
      catch_up()
      if current == base().output then return notify_unchanged() end
      open_diff(
        base().output, "baseline " .. base().at .. ": " .. label,
        current, "current: " .. label
      )
    end)

    map_action(win, "set_baseline", function()
      set_baseline(current)
      refresh_drift()
      vim.notify("Baseline set to current build (" .. base().at .. ")", vim.log.levels.INFO)
    end)
  end)
end

return M
