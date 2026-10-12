local H = dofile("tests/helpers.lua")
local sync = require("kustomize-sync.sync")

local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = H.hooks })

local SEVERITY = { "ERROR", "WARN", "INFO", "HINT" }

-- Diagnostics arrive after a debounce and a yq spawn. Count the times they
-- were published so a test can wait for the next one instead of sleeping.
local published = 0
vim.api.nvim_create_autocmd("DiagnosticChanged", {
  callback = function() published = published + 1 end,
})

-- Do `action`, then wait for the publish it causes.
local function after(action)
  local before = published
  action()
  assert(vim.wait(5000, function() return published > before end, 10), "no diagnostics published")
end

-- For the cases where nothing should be published.
local function settle()
  vim.wait(600)
end

local function open(root, opts)
  H.setup(opts)
  after(function() vim.cmd("edit " .. vim.fn.fnameescape(root .. "/kustomization.yaml")) end)
  return vim.api.nvim_get_current_buf()
end

local function edited()
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
end

-- One line per diagnostic: `<line> <severity> <message>`, in file order.
local function report(buf)
  local found = vim.diagnostic.get(buf or 0)
  table.sort(found, function(a, b)
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return a.severity < b.severity
  end)
  return vim.tbl_map(function(d)
    return ("%d %s %s"):format(d.lnum + 1, SEVERITY[d.severity], d.message)
  end, found)
end

-- The text each diagnostic covers.
local function underlined()
  return vim.tbl_map(function(d)
    return vim.api.nvim_buf_get_lines(0, d.lnum, d.lnum + 1, false)[1]:sub(d.col + 1, d.end_col)
  end, vim.diagnostic.get(0))
end

T["flags"] = MiniTest.new_set()

T["flags"]["each kind of broken entry"] = function()
  local root = H.project({
    "ok.yaml", "dup.yaml", "patch.yaml", "apps/a.yaml", "nokust/x.yaml",
    ["apps/kustomization.yaml"] = H.kustomization({ "a.yaml" }),
    ["comp/kustomization.yaml"] = H.component,
    ["plain/kustomization.yaml"] = H.kustomization({}),
    ["kustomization.yaml"] = table.concat({
      "kind: Kustomization",
      "resources:",
      "  - ok.yaml",
      "  - missing.yaml",
      "  - nokust",
      "  - comp",
      "  - dup.yaml",
      "  - ./dup.yaml",
      "  - apps",
      "  - apps/a.yaml",
      "  - patch.yaml",
      "components:",
      "  - plain",
      "  - comp",
      "patches:",
      "  - path: patch.yaml",
      "  - path: gone-patch.yaml",
      "configMapGenerator:",
      "  - name: app",
      "    files:",
      "      - conf/nope.conf",
      "",
    }, "\n"),
  })
  eq(report(open(root)), {
    "4 ERROR missing.yaml: no such file or directory",
    "5 ERROR nokust has no kustomization file",
    "6 ERROR comp is a Component; list it under components",
    "8 ERROR dup.yaml is listed twice (first on line 7)",
    "10 WARN apps/a.yaml is inside apps, which line 9 lists whole",
    "11 WARN patch.yaml is also used under patches (line 16)",
    "13 ERROR plain is not a Component; list it under resources",
    "17 ERROR gone-patch.yaml: no such file or directory",
    "21 ERROR conf/nope.conf: no such file or directory",
  })
end

T["flags"]["nothing in a kustomization that is fine"] = function()
  local root = H.project({ ["base/kustomization.yaml"] = H.kustomization({}) }) .. "/overlay"
  H.write(root, {
    "a.yaml", "patch.yaml", "conf/app.conf", "off.yaml",
    ["shared/kustomization.yaml"] = H.component,
    ["kustomization.yaml"] = table.concat({
      "kind: Kustomization",
      "resources:",
      "  - a.yaml",
      "  - ../base",
      "  - https://example.com/x.yaml",
      "  - github.com/org/repo",
      "  # - off.yaml",
      "components:",
      "  - shared",
      "patches:",
      "  - path: patch.yaml",
      "  - path: https://example.com/patch.yaml",
      "  - patch: |-",
      "      kind: Deployment",
      "configMapGenerator:",
      "  - name: app",
      "    files:",
      "      - app.conf=conf/app.conf",
      "",
    }, "\n"),
  })
  eq(report(open(root)), {})
end

T["flags"]["the entry as it is written, quotes and all"] = function()
  local root = H.project({
    ["kustomization.yaml"] = "resources:\n  - \"a.yaml\" # one\n  - 'b.yaml'\n  - c.yaml\n",
  })
  open(root)
  eq(H.sorted(underlined()), { '"a.yaml"', "'b.yaml'", "c.yaml" })
end

T["flags"]["only the first document of several"] = function()
  local root = H.project({
    ["kustomization.yaml"] = "resources:\n  - gone.yaml\n---\nresources:\n  - other.yaml\n",
  })
  eq(report(open(root)), { "2 ERROR gone.yaml: no such file or directory" })
end

T["hint"] = MiniTest.new_set()

T["hint"]["names what sync would add"] = function()
  local root = H.project({
    "a.yaml", "b.yaml", "apps/x.yaml", "plain/y.yaml",
    ["apps/kustomization.yaml"] = H.kustomization({ "x.yaml" }),
    ["kustomization.yaml"] = H.kustomization({ "a.yaml" }),
  })
  local buf = open(root)
  eq(report(buf), { "3 HINT Not listed: apps, b.yaml" })

  -- The same names, by construction.
  sync.sync(H.ctx(root))
  eq(H.listed(root), { "a.yaml", "apps", "b.yaml" })
end

T["hint"]["counts past the first few"] = function()
  local files = { ["kustomization.yaml"] = H.kustomization({}) }
  for i = 1, 7 do table.insert(files, i .. ".yaml") end
  eq(report(open(H.project(files))),
    { "3 HINT Not listed: 1.yaml, 2.yaml, 3.yaml, 4.yaml, 5.yaml and 2 more" })
end

T["hint"]["can be turned off alone"] = function()
  local root = H.project({ "a.yaml", ["kustomization.yaml"] = H.kustomization({ "gone.yaml" }) })
  eq(report(open(root, { diagnostics = { unlisted = false } })),
    { "4 ERROR gone.yaml: no such file or directory" })
end

T["hint"]["drops a name once it is typed in, without a new scan"] = function()
  local root = H.project({ "a.yaml", "b.yaml", ["kustomization.yaml"] = H.kustomization({}) })
  local scans, unlisted_entries = 0, sync.unlisted_entries
  sync.unlisted_entries = function(...)
    scans = scans + 1
    return unlisted_entries(...)
  end
  local ok, err = pcall(function()
    open(root)
    eq(report(), { "3 HINT Not listed: a.yaml, b.yaml" })
    after(function()
      vim.api.nvim_buf_set_lines(0, 2, 3, false, { "resources:", "  - a.yaml" })
      edited()
    end)
    eq(report(), { "3 HINT Not listed: b.yaml" })
    eq(scans, 1)
  end)
  sync.unlisted_entries = unlisted_entries
  assert(ok, err)
end

-- Entering a buffer is a window switch away and the scan runs on the main
-- loop, so it is only repeated when the directory changed.
T["hint"]["is rescanned on enter only after the directory changed"] = function()
  local root = H.project({ "a.yaml", ["kustomization.yaml"] = H.kustomization({}) })
  local scans, unlisted_entries = 0, sync.unlisted_entries
  sync.unlisted_entries = function(...)
    scans = scans + 1
    return unlisted_entries(...)
  end
  local ok, err = pcall(function()
    local buf = open(root)
    local function leave_and_enter()
      after(function()
        vim.cmd("enew")
        vim.cmd("buffer " .. buf)
      end)
    end

    leave_and_enter()
    eq(scans, 1)

    H.write(root, { "new.yaml" })
    leave_and_enter()
    eq(scans, 2)
    eq(report(buf), { "3 HINT Not listed: a.yaml, new.yaml" })
  end)
  sync.unlisted_entries = unlisted_entries
  assert(ok, err)
end

T["refresh"] = MiniTest.new_set()

T["refresh"]["checks unsaved text"] = function()
  local root = H.project({ "a.yaml", ["kustomization.yaml"] = H.kustomization({ "a.yaml" }) })
  open(root)
  eq(report(), {})
  after(function()
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "  - typo.yaml" })
    edited()
  end)
  eq(report(), { "5 ERROR typo.yaml: no such file or directory" })
  eq(vim.bo.modified, true)
end

T["refresh"]["keeps the last results while the yaml does not parse"] = function()
  local root = H.project({ ["kustomization.yaml"] = H.kustomization({ "gone.yaml" }) })
  open(root)
  local before = report()
  eq(#before, 1)

  vim.api.nvim_buf_set_lines(0, 2, 3, false, { "resources: [" })
  edited()
  settle()
  eq(report(), before)
end

-- A scan that could not happen is still owed: the file opened broken, and
-- fixing it is an edit, which on its own asks for no scan.
T["refresh"]["scans once a file that opened broken parses"] = function()
  local root = H.project({ "a.yaml", ["kustomization.yaml"] = "resources: [\n" })
  H.setup()
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/kustomization.yaml"))
  settle()
  eq(report(), {})

  after(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "resources: []" })
    edited()
  end)
  eq(report(), { "1 HINT Not listed: a.yaml" })
end

T["refresh"]["spawns yq once for opening a file"] = function()
  local root = H.project({ ["kustomization.yaml"] = H.kustomization({ "gone.yaml" }) })
  local spawns, system = 0, vim.system
  vim.system = function(cmd, ...)
    if cmd[1] == "yq" then spawns = spawns + 1 end
    return system(cmd, ...)
  end
  local ok, err = pcall(function()
    open(root)
    settle()
  end)
  vim.system = system
  assert(ok, err)
  -- BufReadPost and BufEnter both fire.
  eq(spawns, 1)
end

T["refresh"]["follows a write the plugin made, in a buffer nothing reloaded"] = function()
  local root = H.project({ "a.yaml", "b.yaml", ["kustomization.yaml"] = H.kustomization({ "a.yaml" }) })
  local buf = open(root)
  eq(report(buf), { "3 HINT Not listed: b.yaml" })

  after(function()
    sync.apply_changes({ { op = "add", name = "b.yaml", kustomize_file = root .. "/kustomization.yaml" } })
  end)
  eq(vim.api.nvim_buf_get_lines(buf, 3, -1, false), { "  - a.yaml", "  - b.yaml" })
  eq(report(buf), {})
end

T["setup"] = MiniTest.new_set()

T["setup"]["takes `diagnostics = false` for all of it off"] = function()
  local root = H.project({ "a.yaml", ["kustomization.yaml"] = H.kustomization({ "gone.yaml" }) })
  H.setup({ diagnostics = false })
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/kustomization.yaml"))
  settle()
  eq(report(), {})
end

T["setup"]["clears what is showing when turned off"] = function()
  local root = H.project({ ["kustomization.yaml"] = H.kustomization({ "gone.yaml" }) })
  open(root)
  eq(#report(), 1)
  H.setup({ diagnostics = { enabled = false } })
  eq(report(), {})
end

T["setup"]["picks up a kustomization that was open already"] = function()
  local root = H.project({ ["kustomization.yaml"] = H.kustomization({ "gone.yaml" }) })
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/kustomization.yaml"))
  after(H.setup)
  eq(#report(), 1)
end

return T
