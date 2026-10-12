local H = dofile("tests/helpers.lua")
local config = require("kustomize-sync.config")
local context = require("kustomize-sync.context")

local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = H.hooks })

-- An item as one line: what it does, to which entry, and in which
-- kustomization when that isn't the project's own.
local function line(item, root)
  local text = item.op .. " " .. item.name
  if item.op == "convert" then text = text .. " <- " .. table.concat(item.replaces, ",") end
  if item.needs_bootstrap then text = text .. " (bootstrap)" end
  local dir = vim.fn.fnamemodify(item.kustomize_file, ":h")
  if dir ~= root then text = text .. " in " .. dir:sub(#root + 2) end
  return text
end

local function lines(items, root)
  if not items then return nil end
  return vim.tbl_map(function(item) return line(item, root) end, items)
end

-- Entries as resolve_changes returns them, readable: `{ items, alt }` each.
local function resolve(root, changes)
  for _, change in ipairs(changes) do
    for _, field in ipairs({ "filepath", "src", "dest" }) do
      if change[field] then change[field] = root .. "/" .. change[field] end
    end
  end
  local entries = context.resolve_changes(changes)
  return vim.tbl_map(function(entry)
    return { items = lines(entry.items, root), alt = lines(entry.alt, root) }
  end, entries), entries
end

local function added(path, entry_type)
  return { op = "add", filepath = path, entry_type = entry_type or "file" }
end

local function removed(path, entry_type)
  return { op = "remove", filepath = path, entry_type = entry_type or "file" }
end

local function moved(src, dest)
  return { op = "move", src = src, dest = dest }
end

T["locate"] = MiniTest.new_set()

T["locate"]["finds the kustomization above a path"] = function()
  local root = H.project({
    "deploy/sub/svc.yaml",
    ["kustomization.yaml"] = H.kustomization({}),
  })
  local loc = context.locate(root .. "/deploy/sub/svc.yaml")
  eq(loc.name, "deploy")
  eq(loc.rel, "deploy/sub/svc.yaml")
  eq(loc.kustomize_file, root .. "/kustomization.yaml")
end

T["locate"]["searches from the parent for a kustomization file"] = function()
  local root = H.project({
    ["kustomization.yaml"] = H.kustomization({}),
    ["foo/kustomization.yaml"] = H.kustomization({}),
  })
  local loc = context.locate(root .. "/foo/kustomization.yaml")
  eq(loc.name, "foo")
  eq(loc.kustomize_file, root .. "/kustomization.yaml")
end

T["locate"]["is nil with no kustomization above"] = function()
  local root = H.project({ "a.yaml" })
  eq(context.locate(root .. "/a.yaml"), nil)
end

T["add"] = MiniTest.new_set()

T["add"]["a new yaml is one add"] = function()
  local root = H.project({ "new.yaml", ["kustomization.yaml"] = H.kustomization({}) })
  eq(resolve(root, { added("new.yaml") }), { { items = { "add new.yaml" } } })
end

T["add"]["nothing for what is not a manifest, or is accounted for"] = function()
  local root = H.project({
    "notes.txt", "listed.yaml", "off.yaml", "patch.yaml",
    ["kustomization.yaml"] = H.kustomization({ "listed.yaml" },
      "  # - off.yaml\npatches:\n  - path: patch.yaml\n"),
  })
  for _, name in ipairs({ "notes.txt", "listed.yaml", "off.yaml", "patch.yaml" }) do
    eq(resolve(root, { added(name) }), {})
  end
end

T["add"]["a file in a listed directory belongs to that directory's kustomization"] = function()
  local root = H.project({
    "apps/new.yaml",
    ["kustomization.yaml"] = H.kustomization({ "apps" }),
    ["apps/kustomization.yaml"] = H.kustomization({}),
  })
  eq(resolve(root, { added("apps/new.yaml") }), { { items = { "add new.yaml in apps" } } })
end

T["add"]["a new kustomization file offers its directory"] = function()
  local root = H.project({
    ["kustomization.yaml"] = H.kustomization({}),
    ["foo/kustomization.yaml"] = H.kustomization({}),
  })
  eq(resolve(root, { added("foo/kustomization.yaml") }), { { items = { "add foo" } } })
end

T["add"]["a component is never offered as a resource"] = function()
  local root = H.project({
    ["kustomization.yaml"] = H.kustomization({}),
    ["shared/kustomization.yaml"] = H.component,
  })
  eq(resolve(root, { added("shared/kustomization.yaml") }), {})
  eq(resolve(root, { added("shared", "directory") }), {})
end

T["add"]["a readme in a new directory is no reason to list it"] = function()
  local root = H.project({ "docs/README.md", ["kustomization.yaml"] = H.kustomization({}) })
  eq(resolve(root, { added("docs/README.md") }), {})
end

T["add"]["a file joins the ones already listed by path"] = function()
  local root = H.project({
    "deploy/svc.yaml", "deploy/new.yaml",
    ["kustomization.yaml"] = H.kustomization({ "deploy/svc.yaml" }),
  })
  eq(resolve(root, { added("deploy/new.yaml") }), { { items = { "add deploy/new.yaml" } } })
end

T["new directory"] = MiniTest.new_set()

T["new directory"]["is offered whole first, with the path form as the other"] = function()
  local root = H.project({ "a.yaml", "apps/x.yaml", ["kustomization.yaml"] = H.kustomization({ "a.yaml" }) })
  local readable, entries = resolve(root, { added("apps/x.yaml") })
  eq(readable, { { items = { "add apps (bootstrap)" }, alt = { "add apps/x.yaml" } } })
  eq(entries[1].items[1].bootstrap_dirs, { root .. "/apps" })
end

T["new directory"]["leads with the path form when the kustomization lists by path"] = function()
  local root = H.project({
    "deploy/svc.yaml", "apps/x.yaml",
    ["kustomization.yaml"] = H.kustomization({ "deploy/svc.yaml" }),
  })
  eq(resolve(root, { added("apps/x.yaml") }),
    { { items = { "add apps/x.yaml" }, alt = { "add apps (bootstrap)" } } })
end

T["new directory"]["follows `nested` over what the kustomization does"] = function()
  config.setup({ nested = "path" })
  local root = H.project({ "a.yaml", "apps/x.yaml", ["kustomization.yaml"] = H.kustomization({ "a.yaml" }) })
  eq(resolve(root, { added("apps/x.yaml") }),
    { { items = { "add apps/x.yaml" }, alt = { "add apps (bootstrap)" } } })
end

-- Without every level getting a kustomization, `apps` ends up with an empty
-- .resources and the file is reachable from nowhere.
T["new directory"]["bootstraps every level down to the file"] = function()
  local root = H.project({ "apps/new/file.yaml", ["kustomization.yaml"] = H.kustomization({}) })
  local _, entries = resolve(root, { added("apps/new/file.yaml") })
  eq(H.sorted(entries[1].items[1].bootstrap_dirs), { root .. "/apps", root .. "/apps/new" })
end

T["new directory"]["is one entry however many files went into it"] = function()
  local root = H.project({ "apps/a/x.yaml", "apps/b/y.yaml", ["kustomization.yaml"] = H.kustomization({}) })
  local readable, entries = resolve(root, { added("apps/a/x.yaml"), added("apps/b/y.yaml") })
  eq(readable, { {
    items = { "add apps (bootstrap)" },
    alt = { "add apps/a/x.yaml", "add apps/b/y.yaml" },
  } })
  -- Each change brings directories of its own; dropping the merge leaves
  -- apps/b without a kustomization.
  eq(H.sorted(entries[1].items[1].bootstrap_dirs),
    { root .. "/apps", root .. "/apps/a", root .. "/apps/b" })
end

T["new directory"]["empty, is offered whole or not at all"] = function()
  local whole = H.project({ "apps/", ["kustomization.yaml"] = H.kustomization({}) })
  eq(resolve(whole, { added("apps", "directory") }), { { items = { "add apps (bootstrap)" } } })

  -- Path style has no file to list, and must not fall back to bootstrapping.
  local by_path = H.project({
    "deploy/svc.yaml", "apps/",
    ["kustomization.yaml"] = H.kustomization({ "deploy/svc.yaml" }),
  })
  eq(resolve(by_path, { added("apps", "directory") }), {})
end

T["convert"] = MiniTest.new_set()

T["convert"]["a kustomization created among files listed by path is one item"] = function()
  local root = H.project({
    "deploy/a.yaml", "deploy/b.yaml",
    ["kustomization.yaml"] = H.kustomization({ "deploy/a.yaml", "deploy/b.yaml" }),
    ["deploy/kustomization.yaml"] = "",
  })
  eq(resolve(root, { added("deploy/kustomization.yaml") }),
    { { items = { "convert deploy <- deploy/a.yaml,deploy/b.yaml" } } })
end

T["convert"]["not for a component"] = function()
  local root = H.project({
    "deploy/a.yaml",
    ["kustomization.yaml"] = H.kustomization({ "deploy/a.yaml" }),
    ["deploy/kustomization.yaml"] = H.component,
  })
  eq(resolve(root, { added("deploy/kustomization.yaml") }), {})
end

T["remove"] = MiniTest.new_set()

T["remove"]["a deleted file is its own entry at most"] = function()
  local root = H.project({
    "apps/y.yaml",
    ["kustomization.yaml"] = H.kustomization({ "a.yaml", "apps" }),
    ["apps/kustomization.yaml"] = H.kustomization({ "x.yaml", "y.yaml" }),
  })
  eq(resolve(root, { removed("a.yaml") }), { { items = { "remove a.yaml" } } })
  -- Inside a listed directory it is that kustomization's entry, and no
  -- removal of the directory.
  eq(resolve(root, { removed("apps/x.yaml") }), { { items = { "remove x.yaml in apps" } } })
  eq(resolve(root, { removed("unlisted.yaml") }), {})
end

T["remove"]["a deleted directory takes every entry below it"] = function()
  local root = H.project({
    "keep.yaml",
    ["kustomization.yaml"] = H.kustomization({ "deploy/a.yaml", "deploy/sub/b.yaml", "keep.yaml" }),
  })
  eq(resolve(root, { removed("deploy", "directory") }),
    { { items = { "remove deploy/a.yaml" } }, { items = { "remove deploy/sub/b.yaml" } } })
end

T["remove"]["does not stand if the path is there afterwards"] = function()
  local root = H.project({ "a.yaml", ["kustomization.yaml"] = H.kustomization({ "a.yaml" }) })
  eq(resolve(root, { removed("a.yaml") }), {})
end

T["remove"]["a listed directory losing its kustomization can go, or be listed by path"] = function()
  local files = { "apps/x.yaml", "apps/y.yaml" }
  local whole = H.project(vim.tbl_extend("error", files, {
    ["kustomization.yaml"] = H.kustomization({ "apps" }),
  }))
  eq(resolve(whole, { removed("apps/kustomization.yaml") }), { {
    items = { "remove apps" },
    alt = { "remove apps", "add apps/x.yaml", "add apps/y.yaml" },
  } })

  config.setup({ nested = "path" })
  local by_path = H.project(vim.tbl_extend("error", files, {
    ["kustomization.yaml"] = H.kustomization({ "apps" }),
  }))
  eq(resolve(by_path, { removed("apps/kustomization.yaml") }), {
    { items = { "remove apps", "add apps/x.yaml", "add apps/y.yaml" }, alt = { "remove apps" } },
  })
end

T["move"] = MiniTest.new_set()

T["move"]["a renamed entry is removed and added back"] = function()
  local root = H.project({ "b.yaml", ["kustomization.yaml"] = H.kustomization({ "a.yaml" }) })
  eq(resolve(root, { moved("a.yaml", "b.yaml") }),
    { { items = { "remove a.yaml" } }, { items = { "add b.yaml" } } })
end

T["move"]["a renamed directory carries its path entries along"] = function()
  local root = H.project({
    "deploy2/svc.yaml", "deploy2/sub/b.yaml",
    ["kustomization.yaml"] = H.kustomization({ "deploy/svc.yaml", "deploy/sub/b.yaml" }),
  })
  eq(resolve(root, { moved("deploy", "deploy2") }), {
    { items = { "remove deploy/svc.yaml" } },
    { items = { "remove deploy/sub/b.yaml" } },
    { items = { "add deploy2/svc.yaml" } },
    { items = { "add deploy2/sub/b.yaml" } },
  })
end

T["move"]["between kustomizations touches both"] = function()
  local root = H.project({
    "y/a.yaml",
    ["x/kustomization.yaml"] = H.kustomization({ "a.yaml" }),
    ["y/kustomization.yaml"] = H.kustomization({}),
  })
  eq(resolve(root, { moved("x/a.yaml", "y/a.yaml") }),
    { { items = { "remove a.yaml in x" } }, { items = { "add a.yaml in y" } } })
end

T["move"]["never bootstraps"] = function()
  local root = H.project({
    "apps2/x.yaml",
    ["kustomization.yaml"] = H.kustomization({ "apps" }),
  })
  -- The destination has no kustomization. A create there would offer to
  -- write one; a move only carries over what can be listed as it is.
  eq(resolve(root, { moved("apps", "apps2") }), { { items = { "remove apps" } } })
end

T["move"]["within one unlisted entry changes nothing"] = function()
  local root = H.project({ "foo/b.yaml", ["kustomization.yaml"] = H.kustomization({}) })
  eq(resolve(root, { moved("foo/a.yaml", "foo/b.yaml") }), {})
end

T["move"]["a renamed patch is not offered as a resource"] = function()
  local root = H.project({
    "renamed.yaml",
    ["kustomization.yaml"] = H.kustomization({}, "patches:\n  - path: patch.yaml\n"),
  })
  eq(resolve(root, { moved("patch.yaml", "renamed.yaml") }), {})
end

-- Oil swaps two names through a temporary third. Read one move at a time
-- both files leave; on disk both are still there.
T["move"]["a rename cycle comes out as no change"] = function()
  local root = H.project({
    "a.yaml", "b.yaml",
    ["kustomization.yaml"] = H.kustomization({ "a.yaml", "b.yaml" }),
  })
  eq(resolve(root, {
    moved("a.yaml", "__oil_tmp_12345"),
    moved("b.yaml", "a.yaml"),
    moved("__oil_tmp_12345", "b.yaml"),
  }), {})
end

T["a batch reads each kustomization once"] = function()
  local sync = require("kustomize-sync.sync")
  local root = H.project({
    "a.yaml", "b.yaml", "c.yaml",
    ["kustomization.yaml"] = H.kustomization({}),
  })
  local spawns, yq = 0, sync.yq
  sync.yq = function(...)
    spawns = spawns + 1
    return yq(...)
  end
  local ok, err = pcall(resolve, root, { added("a.yaml"), added("b.yaml"), added("c.yaml") })
  sync.yq = yq
  assert(ok, err)
  -- .resources and the referenced paths, whatever the number of changes.
  eq(spawns, 2)
end

return T
