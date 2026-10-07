local sync = require("kustomize-sync.sync")

local M = {}

M.find_parent_kustomize = function(start_dir)
  local current = start_dir
  while current ~= "" do
    local target = sync.find_kustomization(current)
    if target then return target, current end
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then break end -- reached root; last check above covered it
    current = parent
  end
  return nil, nil
end

-- Map a changed path to the kustomization that governs it and the top-level entry
-- it lives under. Says nothing about whether anything should happen — that's
-- resolve_changes' job. Nil if no kustomization sits above the path.
M.locate = function(filepath)
  local clean_path = filepath:gsub("/$", "")
  local entry_name = vim.fn.fnamemodify(clean_path, ":t")
  local start_dir  = vim.fn.fnamemodify(clean_path, ":h")
  if entry_name == "" then return nil end

  -- A kustomization file is never a resource of the directory it sits in, so
  -- search from the parent: creating foo/kustomization.yaml is exactly the event
  -- that turns `foo` into a valid resource dir for the kustomization above it.
  local search_dir = start_dir
  if sync.is_kustomization(entry_name) then
    search_dir = vim.fn.fnamemodify(start_dir, ":h")
    if search_dir == start_dir then return nil end
  end

  local kustomize_file, kustomize_dir = M.find_parent_kustomize(search_dir)
  if not kustomize_file or not kustomize_dir then return nil end

  local rel  = clean_path:sub(#kustomize_dir + 2)
  local name = vim.split(rel, "/", { trimempty = true })[1]
  if not name then return nil end

  return {
    name           = name,
    rel            = rel,
    path           = kustomize_dir .. "/" .. name,
    kustomize_file = kustomize_file,
    kustomize_dir  = kustomize_dir,
  }
end

-- Every directory from the changed path up to the entry being added, deepest
-- first. Creating `apps/new/file.yaml` under a kustomization that has neither
-- directory yet makes `apps` the entry, but `apps/new` needs a kustomization
-- just as much: without one the new file is reachable from nowhere.
local function bootstrap_dirs(filepath, entry_path)
  local clean = filepath:gsub("/$", "")
  local dir = vim.fn.isdirectory(clean) == 1 and clean or vim.fn.fnamemodify(clean, ":h")

  local dirs = {}
  while #dir > #entry_path do
    table.insert(dirs, dir)
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  table.insert(dirs, entry_path)
  return dirs
end

local function basename(path) return vim.fn.fnamemodify(path, ":t") end
local function dirname(path) return vim.fn.fnamemodify(path, ":h") end

-- Does `path` equal `prefix` or sit below it?
local function within(path, prefix)
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

-- What one kustomization says, read lazily and at most once per batch: `cache`
-- is shared by every change being resolved together, so N changes under one
-- kustomization cost the same yq reads as one. Nothing writes between resolves,
-- so what the first one saw holds for the rest.
local function snapshot(kustomize_file, cache)
  if not cache[kustomize_file] then cache[kustomize_file] = { file = kustomize_file } end
  return cache[kustomize_file]
end

local function load_resources(known)
  if known.resources == nil then
    local resources, listed = sync.current_resources(known.file)
    known.resources, known.listed = resources or false, listed
    known.by_path = resources and sync.path_style_dirs(resources, dirname(known.file))
  end
  return known.resources ~= false
end

local function load_referenced(known)
  if known.referenced == nil then
    known.referenced = sync.referenced_paths(known.file) or false
  end
  return known.referenced ~= false
end

local function commented(known)
  known.commented = known.commented or sync.commented_set(known.file)
  return known.commented
end

-- Is `rel` already spoken for by a listed entry above or below it? `deploy`
-- covers `deploy/svc.yaml` and the other way round; listing both names the same
-- manifests twice.
local function overlaps(known, rel)
  for _, r in ipairs(known.resources) do
    if r ~= rel and (within(rel, r) or within(r, rel)) then return true end
  end
  return false
end

-- Every listed entry at or below a path that has gone away. A deleted file is
-- its own entry at most; a deleted directory takes with it both `deploy` and
-- any `deploy/svc.yaml` listed by path. `path` is kept on each item so the
-- batch can drop a removal whose target turns out to exist after all.
local function listed_under(loc, known)
  local items = {}
  for _, r in ipairs(known.resources) do
    if within(r, loc.rel) then
      table.insert(items, {
        op             = "remove",
        name           = r,
        path           = loc.kustomize_dir .. "/" .. r,
        kustomize_file = known.file,
      })
    end
  end
  return items
end

local function resolve_remove(loc, known)
  if not load_resources(known) then return {} end

  local items = listed_under(loc, known)
  if #items > 0 then return items end

  -- Nothing at that path was listed. The one removal that still follows is a
  -- directory losing its own kustomization: the directory is still there, but
  -- the entry naming it can no longer be built.
  local dir = dirname(loc.rel)
  if not (sync.is_kustomization(basename(loc.rel)) and known.listed[dir]) then return {} end

  local remove = { op = "remove", name = dir, kustomize_file = known.file }

  -- The manifests are still in there. Dropping the entry is one answer; the
  -- other is to keep building them, listed by path now that the directory can't
  -- be listed whole. Which yaml the deleted kustomization named is gone with
  -- it, so every candidate is offered and the menu lets the wrong ones go.
  local by_path = { vim.deepcopy(remove) }
  if load_referenced(known) then
    for _, found in ipairs(sync.paths_under(loc.kustomize_dir, dir)) do
      local is_dir = found.type == "directory"
      if not commented(known)[found.path]
        and not sync.is_referenced(known.referenced, found.path, is_dir)
        and sync.is_addable_entry(loc.kustomize_dir .. "/" .. dirname(found.path),
          basename(found.path), found.type) then
        table.insert(by_path, { op = "add", name = found.path, kustomize_file = known.file })
      end
    end
  end
  if #by_path > 1 then
    remove.alt_items  = by_path
    remove.prefer_alt = sync.preferred_style(known.file, known.resources) == "path"
  end
  return { remove }
end

-- A directory whose files are listed by path has gained a kustomization of its
-- own, so it can be listed whole instead. One item, not a removal per path and
-- an add: applying half of it either drops manifests or names them twice.
-- Nil when this isn't that case, so the caller carries on.
local function convert_to_directory(loc, known)
  local rel   = dirname(loc.rel)
  local child = sync.find_kustomization(loc.kustomize_dir .. "/" .. rel)
  if not child or sync.is_component(child) then return nil end

  local replaces = {}
  for _, r in ipairs(known.resources) do
    if r ~= rel and within(r, rel) then
      table.insert(replaces, r)
    elseif within(rel, r) then
      -- The directory, or one above it, is already listed whole.
      return nil
    end
  end
  if #replaces == 0 or commented(known)[rel] then return nil end
  if not load_referenced(known) or known.referenced[rel] then return nil end

  return { {
    op             = "convert",
    name           = rel,
    replaces       = replaces,
    child          = child,
    kustomize_file = known.file,
  } }
end

-- An entry named by its path inside a directory .resources already lists files
-- out of. Used for a new file there, and for whatever a move carries along.
local function add_by_path(kustomize_dir, rel, known)
  -- A kustomization file makes the directory holding it the entry.
  if sync.is_kustomization(basename(rel)) then rel = dirname(rel) end

  local abs = kustomize_dir .. "/" .. rel
  local is_dir = vim.fn.isdirectory(abs) == 1
  if is_dir then
    -- Only a directory that can be built on its own is an entry. A plain one
    -- contributes through the files in it, each of which gets its own event.
    local child = sync.find_kustomization(abs)
    if not child or sync.is_component(child) then return {} end
  elseif not sync.is_yaml(rel) then
    return {}
  end

  if known.listed[rel] or commented(known)[rel] or overlaps(known, rel) then return {} end
  if not load_referenced(known) or sync.is_referenced(known.referenced, rel, is_dir) then
    return {}
  end
  return { { op = "add", name = rel, kustomize_file = known.file } }
end

-- The top-level entry a new path belongs to, as an item: the file itself, or
-- the directory it was created in. Nil if that entry can't or needn't be added.
local function add_as_entry(filepath, loc, entry_type, known)
  local top_level_entry = loc.name
  local entry_path      = loc.path

  local is_dir = entry_type == "directory" or vim.fn.isdirectory(entry_path) == 1
  if not (is_dir or sync.is_yaml(top_level_entry)) then return nil end

  local child = is_dir and sync.find_kustomization(entry_path) or nil

  -- A component belongs under .components. Listing one as a resource makes
  -- `kustomize build` fail, so there's nothing to prompt about.
  if child and sync.is_component(child) then return nil end

  -- Already reached through .patches, a generator, .components or another key,
  -- so it isn't a resource and mustn't be offered as one. Asked after the gates
  -- above because it is the first one that costs a yq spawn.
  if not load_referenced(known)
    or sync.is_referenced(known.referenced, top_level_entry, is_dir) then
    return nil
  end

  if not load_resources(known) then return nil end
  if known.listed[top_level_entry] or overlaps(known, top_level_entry) then return nil end

  -- A directory with no kustomization file of its own can't be built. Adding it
  -- silently would break `kustomize build`, and staying silent loses the prompt
  -- entirely, so flag it and let the caller offer to create one first.
  local needs_bootstrap = is_dir and child == nil

  return {
    op              = "add",
    name            = top_level_entry,
    path            = entry_path,
    kustomize_file  = known.file,
    needs_bootstrap = needs_bootstrap,
    bootstrap_dirs  = needs_bootstrap and bootstrap_dirs(filepath, entry_path) or nil,
  }
end

local function resolve_add(filepath, loc, entry_type, known)
  local top_level_entry = loc.name
  local nested          = loc.rel ~= top_level_entry

  if commented(known)[top_level_entry] then return {} end

  -- .resources already lists files out of this directory by path, so a new one
  -- joins them the same way. Offering the directory instead would name every
  -- file in it twice.
  if nested then
    if not load_resources(known) then return {} end
    if known.by_path[top_level_entry] then
      local converted = sync.is_kustomization(basename(loc.rel))
        and convert_to_directory(loc, known)
      return converted or add_by_path(loc.kustomize_dir, loc.rel, known)
    end
  end

  -- A README or a script dropped into a directory is no reason to turn that
  -- directory into a resource.
  if nested and entry_type ~= "directory" and vim.fn.isdirectory(filepath) == 0
    and not sync.is_yaml(loc.rel) and not sync.is_kustomization(basename(loc.rel)) then
    return {}
  end

  local as_entry = add_as_entry(filepath, loc, entry_type, known)
  if as_entry and not as_entry.needs_bootstrap then return { as_entry } end

  -- What's left is a directory with no kustomization and nothing listed out of
  -- it, so nothing says which form it takes. Offer the preferred one and carry
  -- the other as `alt` for the prompt to switch to. A style that has nothing to
  -- offer here (a new empty directory can't be listed by path) stays quiet
  -- rather than falling back to the other.
  if not load_resources(known) then return {} end
  local by_path = nested and add_by_path(loc.kustomize_dir, loc.rel, known)[1] or nil

  local first, second = as_entry, by_path
  if sync.preferred_style(known.file, known.resources) == "path" then
    first, second = by_path, as_entry
  end
  if not first then return {} end
  first.alt = second
  return { first }
end

-- A rename or move. Whatever was listed at or below the old path is removed,
-- and the same entry is added back under the new one: `deploy/a.yaml` becomes
-- `deploy/b.yaml`, and renaming `deploy` carries `deploy/svc.yaml` along to
-- `deploy2/svc.yaml`. The two sides can belong to different kustomizations.
--
-- A moved entry keeps its form. It was a file or a buildable directory before
-- and still is, so nothing is bootstrapped on the way.
local function resolve_move(src, dest, cache)
  local src_loc, dest_loc = M.locate(src), M.locate(dest)
  local src_known  = src_loc and snapshot(src_loc.kustomize_file, cache)
  local dest_known = dest_loc and snapshot(dest_loc.kustomize_file, cache)

  local moved = {}
  if src_loc and load_resources(src_known) then moved = listed_under(src_loc, src_known) end

  if src_loc and #moved > 0 then
    local items = vim.deepcopy(moved)
    if dest_loc and load_resources(dest_known) then
      for _, item in ipairs(moved) do
        local rel = dest_loc.rel .. item.name:sub(#src_loc.rel + 1)
        vim.list_extend(items, add_by_path(dest_loc.kustomize_dir, rel, dest_known))
      end
    end
    return items
  end

  -- Nothing listed moved. Within one top-level entry that is the end of it:
  -- `foo/a.yaml` -> `foo/b.yaml` changes nothing the kustomization records.
  if src_loc and dest_loc
    and src_loc.name == dest_loc.name
    and src_loc.kustomize_file == dest_loc.kustomize_file then
    return {}
  end

  -- Renaming a patch file or a generator input doesn't turn it into a resource.
  -- The kustomization still names the old path, so the new one would otherwise
  -- look like an ordinary yaml. The dangling reference is the user's to fix;
  -- adding the file to .resources on top of it is not a help.
  if src_loc and load_referenced(src_known)
    and sync.is_referenced(src_known.referenced, src_loc.rel, false) then
    return {}
  end

  local items = src_loc and resolve_remove(src_loc, src_known) or {}
  if dest_loc then
    local entry_type = vim.fn.isdirectory(dest) == 1 and "directory" or "file"
    vim.list_extend(items, resolve_add(dest, dest_loc, entry_type, dest_known))
  end
  return items
end

-- One change to the items it amounts to, possibly none and possibly several.
-- A change is `{ op = "add" | "remove", filepath, entry_type }` or
-- `{ op = "move", src, dest }`.
local function resolve_change(change, cache)
  if change.op == "move" then return resolve_move(change.src, change.dest, cache) end

  local loc = M.locate(change.filepath)
  if not loc then return {} end

  local known = snapshot(loc.kustomize_file, cache)
  if change.op == "remove" then return resolve_remove(loc, known) end
  return resolve_add(change.filepath, loc, change.entry_type, known)
end

-- Resolve a list of changes into entries for a prompt: `{ items, alt }`, where
-- `items` is what apply_changes takes and `alt`, when present, is the other
-- form the same change could take. Swapping the two switches form.
--
-- Changes that land in one new directory share an entry. As a kustomization
-- that directory is a single item, however many files went into it, and each
-- change adds directories of its own to bootstrap; by path it is one item per
-- file. `apps/a/x.yaml` and `apps/b/y.yaml` are `+ apps` one way and two lines
-- the other.
--
-- Changes arrive after the fact, so the disk shows where the whole batch ended
-- up. A removal only stands if nothing is at that path any more: oil swaps two
-- names through a temporary third, which reads as both files leaving, and both
-- are in fact still there.
M.resolve_changes = function(changes)
  local function key(r) return r.op .. "\0" .. r.name .. "\0" .. r.kustomize_file end

  local cache, seen, entries = {}, {}, {}
  for _, change in ipairs(changes) do
    for _, r in ipairs(resolve_change(change, cache)) do
      local whole = r.needs_bootstrap and r or r.alt
      local part  = r.needs_bootstrap and r.alt or (r.alt and r or nil)
      r.alt = nil
      if whole then whole.alt = nil end

      if r.op == "remove" and r.path and vim.uv.fs_stat(r.path) then
        -- still there, so not a removal
      elseif whole then
        local entry = seen[key(whole)]
        if not entry then
          entry = { whole = whole, parts = {} }
          seen[key(whole)] = entry
          table.insert(entries, entry)
        else
          for _, dir in ipairs(whole.bootstrap_dirs) do
            if not vim.tbl_contains(entry.whole.bootstrap_dirs, dir) then
              table.insert(entry.whole.bootstrap_dirs, dir)
            end
          end
        end
        if part and not seen[key(part)] then
          seen[key(part)] = entry
          table.insert(entry.parts, part)
        end
        entry.prefer_parts = entry.prefer_parts or r ~= whole
      elseif not seen[key(r)] then
        local entry = { items = { r }, alt = r.alt_items }
        if r.prefer_alt then entry.items, entry.alt = entry.alt, entry.items end
        r.alt_items, r.prefer_alt = nil, nil
        seen[key(r)] = entry
        table.insert(entries, entry)
      end
    end
  end

  for _, entry in ipairs(entries) do
    if entry.whole then
      local whole, parts = { entry.whole }, entry.parts
      if #parts == 0 then
        entry.items = whole
      elseif entry.prefer_parts then
        entry.items, entry.alt = parts, whole
      else
        entry.items, entry.alt = whole, parts
      end
      entry.whole, entry.parts, entry.prefer_parts = nil, nil, nil
    end
  end
  return entries
end

return M
