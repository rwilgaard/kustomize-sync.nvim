local config = require("kustomize-sync.config")

local M = {}

-- Accepted kustomization filenames, in probe order.
M.KUSTOMIZATION_NAMES = { "kustomization.yaml", "kustomization.yml", "Kustomization" }

M.is_kustomization = function(name)
  for _, n in ipairs(M.KUSTOMIZATION_NAMES) do
    if name == n then return true end
  end
  return false
end

M.find_kustomization = function(dir)
  for _, name in ipairs(M.KUSTOMIZATION_NAMES) do
    local p = dir .. "/" .. name
    if vim.fn.filereadable(p) == 1 then return p end
  end
  return nil
end

-- Matches .yaml and .yml.
M.is_yaml = function(name)
  return name:match("%.ya?ml$") ~= nil
end

-- Could `name` (a scandir entry) ever be a resource entry?
--
-- Dot-names never are: `.github`, `.gitlab-ci.yml` and `.yamllint.yaml` are
-- yaml, and none of them is a manifest.
M.is_resource_entry = function(name, ftype)
  if M.is_kustomization(name) or name:sub(1, 1) == "." then return false end
  return ftype == "directory" or M.is_yaml(name)
end

-- A kustomize component is a kustomization carrying `kind: Component`, and it
-- belongs under .components rather than .resources.
--
-- Read in Lua rather than through yq: scan_entries asks this once per
-- subdirectory, so a thirty-directory overlay would mean thirty process spawns
-- per sync. The rule binding this plugin to yq is about mutation, not reading —
-- commented_set reads the same way.
M.is_component = function(kustomize_file)
  for _, line in ipairs(vim.fn.readfile(kustomize_file)) do
    local kind = line:match("^kind:%s*[\"']?(%a+)")
    if kind then return kind == "Component" end
  end
  return false
end

-- Whether an entry is safe to *add* to .resources. A directory is only a valid
-- resource if it carries its own kustomization file — listing one without it
-- makes `kustomize build` fail — and that kustomization has to be a
-- Kustomization, not a Component. Existing entries are not judged by this: a
-- half-built directory should not be ripped out from under the user.
M.is_addable_entry = function(dir, name, ftype)
  if ftype ~= "directory" then return true end
  local child = M.find_kustomization(dir .. "/" .. name)
  if not child then return false end
  return not M.is_component(child)
end

-- Remote resource refs (scheme://, git@host, git::url, and the scheme-less
-- github.com/org/repo form) are left untouched on sync. The last pattern also
-- matches a local `my.dir/file.yaml`, so check the disk before asking.
M.is_remote = function(r)
  return r:match("^%w[%w+.-]*://") ~= nil
      or r:match("^git@") ~= nil
      or r:match("^git::") ~= nil
      or r:match("^[%w-]+%.[%w.-]+/") ~= nil
end

-- How a .resources entry is compared by name: `foo/`, `./foo` and `foo` are the
-- same entry. Every yq filter that matches one goes through this, so they can't
-- disagree about what is already listed.
M.ENTRY_NORM = 'sub("/$", "") | sub("^[.]/", "")'

-- The directory a ctx points at: the path itself for a directory, its parent
-- for a file.
M.ctx_dir = function(ctx)
  return ctx.is_dir and ctx.path or vim.fn.fnamemodify(ctx.path, ":h")
end

-- Guard for the external CLIs this plugin shells out to. Notifies on failure so
-- callers can just bail.
M.require_cli = function(name)
  if vim.fn.executable(name) == 1 then return true end
  vim.notify(name .. " not found on PATH", vim.log.levels.ERROR)
  return false
end

M.yq = function(args, entry_name)
  local env = entry_name and { ENTRY = entry_name } or nil
  local res = vim.system(
    vim.list_extend({ "yq" }, args),
    { text = true, env = env }
  ):wait()

  if res.code ~= 0 then
    vim.notify("yq failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    return nil
  end
  return res.stdout
end

-- Set of resource names that are present but commented out in the kustomization.
M.commented_set = function(kustomize_file)
  local set = {}
  for _, line in ipairs(vim.fn.readfile(kustomize_file)) do
    local trimmed = vim.trim(line)
    if trimmed:sub(1, 1) == "#" then
      local rest = vim.trim(trimmed:sub(2))
      if rest:sub(1, 1) == "-" then
        set[vim.trim(rest:sub(2)):gsub("/$", "")] = true
      end
    end
  end
  return set
end

-- Every key besides .resources that names a path on disk. A file reached through
-- one of these is already accounted for and must never be offered as a resource:
-- a patch listed under .patches is a yaml file sitting in the directory, and
-- adding it to .resources makes `kustomize build` fail on a duplicate resource id
-- or apply the patch as a resource of its own.
--
-- Written as a sum of arrays so a missing key contributes an empty list rather
-- than an error.
local REFERENCED_FILTER = [[
  (.components // [])
+ (.bases // [])
+ (.crds // [])
+ (.configurations // [])
+ (.transformers // [])
+ (.generators // [])
+ (.patchesStrategicMerge // [])
+ ((.patches // []) | map(select(tag == "!!str")))
+ ((.patches // []) | map(select(tag == "!!map") | .path))
+ ((.patchesJson6902 // []) | map(.path))
+ ((.configMapGenerator // []) | map((.files // []) + (.envs // []) + [.env]) | flatten)
+ ((.secretGenerator // []) | map((.files // []) + (.envs // []) + [.env]) | flatten)
+ ((.replacements // []) | map(.path))
+ ((.helmCharts // []) | map(.valuesFile))
+ [.openapi.path]
| map(select(. != null))
]]

-- Normalize a path written in a kustomization to one relative to its own
-- directory. Returns nil for anything that isn't a path inside that directory.
local function local_path(value, dir)
  if type(value) ~= "string" then return nil end
  -- patchesStrategicMerge accepts an inline patch in the same field a path would
  -- use, and an inline patch is a multi-line string.
  if value:find("\n") then return nil end

  -- Generator file and env entries may carry a key: `app.conf=configs/app.conf`.
  local path = value:match("^[^=/]+=(.+)$") or value
  path = path:gsub("/+$", ""):gsub("^%./", "")
  if path == "" then return nil end

  -- An absolute path can still land inside the directory. Anything else there,
  -- and anything reached through `../`, is outside it and not ours to judge.
  if path:sub(1, 1) == "/" then
    if path:sub(1, #dir + 1) ~= dir .. "/" then return nil end
    path = path:sub(#dir + 2)
  end

  local first = path:match("^([^/]+)")
  if not first or first == "." or first == ".." then return nil end
  return path
end

-- Set of paths, relative to the kustomization, that it already reaches through
-- some key other than .resources. Nil if yq failed, so callers can bail the way
-- they do for current_resources.
M.referenced_paths = function(kustomize_file)
  local out = M.yq({ REFERENCED_FILTER, kustomize_file, "-o", "json" })
  if not out then return nil end

  local dir = vim.fn.fnamemodify(kustomize_file, ":h")
  local set = {}
  for _, value in ipairs(vim.fn.json_decode(out) or {}) do
    local path = local_path(value, dir)
    if path then set[path] = true end
  end
  return set
end

-- Whether `rel` is one of those paths, sits inside a directory that is, or (for
-- a directory) holds one. The last case is what keeps a directory out of
-- .resources when the kustomization pulls a generator input or a patch from it,
-- without holding that against the other files next to it.
M.is_referenced = function(referenced, rel, is_dir)
  if referenced[rel] then return true end
  for path in pairs(referenced) do
    if rel:sub(1, #path + 1) == path .. "/" then return true end
    if is_dir and path:sub(1, #rel + 1) == rel .. "/" then return true end
  end
  return false
end

-- What .resources lists right now, normalized with ENTRY_NORM. Returns the list
-- in file order plus a lookup set, or nil if yq failed.
M.current_resources = function(kustomize_file)
  local out = M.yq({ ".resources // [] | map(" .. M.ENTRY_NORM .. ")", kustomize_file, "-o", "json" })
  if not out then return nil end

  local list = vim.fn.json_decode(out) or {}
  local set = {}
  for _, r in ipairs(list) do set[r] = true end
  return list, set
end

-- Top-level directories that .resources reaches into file by file
-- (`deploy/svc.yaml`) instead of listing whole. Such a directory must not be
-- offered as an entry of its own: with both in place every file under it is
-- named twice and `kustomize build` fails on the duplicate ids.
--
-- Only directories that exist in `dir` count. A remote ref has a first segment
-- too (`https:`, `github.com`), and taking that for a local directory would
-- make a kustomization with one remote base look like it lists files by path.
M.path_style_dirs = function(resources, dir)
  local set = {}
  for _, r in ipairs(resources) do
    local first = r:match("^([^/]+)/")
    if first and first ~= ".." and set[first] == nil then
      set[first] = vim.fn.isdirectory(dir .. "/" .. first) == 1
    end
  end
  return set
end

-- Which form a file in a new directory takes when nothing about that directory
-- says: "kustomization" (the directory gets its own and is listed whole) or
-- "path" (the file is listed as `dir/file.yaml`). Configured, or read off what
-- the kustomization already does: files listed by path and no directory listed
-- whole means path.
--
-- It goes by what each entry is, not by whether it has a slash in it.
-- `apps/frontend` is a directory listed whole; reading it as a path-listed file
-- once made `:KustomizeSync` list every yaml under every other directory.
-- Entries reaching outside (`../base`) say nothing about this directory.
M.preferred_style = function(kustomize_file, resources)
  local nested = config.options.nested
  if nested == "kustomization" or nested == "path" then return nested end

  local dir = vim.fn.fnamemodify(kustomize_file, ":h")
  local files_by_path = false
  for _, r in ipairs(resources) do
    if r:sub(1, 3) ~= "../" and r:sub(1, 1) ~= "/" then
      if vim.fn.isdirectory(dir .. "/" .. r) == 1 then return "kustomization" end
      if r:find("/", 1, true) and vim.fn.filereadable(dir .. "/" .. r) == 1 then
        files_by_path = true
      end
    end
  end
  return files_by_path and "path" or "kustomization"
end

-- scandir reports a symlink as "link"; kustomize follows it, so ask what it
-- points at.
local function entry_type(path, ftype)
  if ftype ~= "link" then return ftype end
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type or ftype
end

-- Everything below `root/rel` that could be listed by path, handed to `visit`
-- as a path relative to `root` and its type. A directory with its own
-- kustomization is one entry (`deploy/sub`), not somewhere to look inside.
-- Dot-directories and symlinked directories are passed over: the first are
-- never manifests, the second can loop.
local function walk(root, rel, visit)
  local handle = vim.uv.fs_scandir(root .. "/" .. rel)
  if not handle then return end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end
    local path = rel .. "/" .. name
    local linked = ftype == "link"
    ftype = entry_type(root .. "/" .. path, ftype)

    if ftype == "directory" then
      if M.find_kustomization(root .. "/" .. path) then
        visit(path, ftype)
      elseif not linked and name:sub(1, 1) ~= "." then
        walk(root, path, visit)
      end
    elseif M.is_resource_entry(name, ftype) then
      visit(path, ftype)
    end
  end
end

-- The same walk as a list of `{ path, type }`, sorted by path.
M.paths_under = function(root, rel)
  local found = {}
  walk(root, rel, function(path, ftype) table.insert(found, { path = path, type = ftype }) end)
  table.sort(found, function(a, b) return a.path < b.path end)
  return found
end

-- What's on disk that could be a resource, as path -> addable. Commented-out
-- entries are left out entirely so disabling one doesn't re-add it. `addable`
-- is false for a directory with no kustomization of its own, for a component,
-- for anything the kustomization already reaches through another key, and for
-- anything a listed entry above or below it already covers. None of those can
-- be added, but the interactive menu still shows the ones that are listed.
--
-- Top-level names are always scanned. Below that it depends on the directory:
-- one .resources lists files out of is walked, since new files there belong
-- next to the ones already listed. One with no kustomization and nothing
-- listed is only walked when `opts.loose` asks for it, and is then named in
-- the second return value, so a caller can tell "these would start a new
-- style" from "these continue an existing one".
--
-- `resources` is the list current_resources returns; pass it when it is already
-- in hand to save the yq call.
M.scan_entries = function(dir, kustomize_file, resources, opts)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return nil end

  resources = resources or M.current_resources(kustomize_file)
  if not resources then return nil end
  local by_path = M.path_style_dirs(resources, dir)
  local listed = {}
  for _, r in ipairs(resources) do listed[r] = true end

  local commented = M.commented_set(kustomize_file)
  local referenced = opts and opts.referenced or M.referenced_paths(kustomize_file)
  if not referenced then return nil end

  -- Is `path` already spoken for by a listed entry above or below it? A
  -- directory listed whole covers everything in it, and a directory with files
  -- listed out of it can't be listed whole as well.
  local function covered(path)
    local parent = path:match("^(.*)/[^/]+$")
    while parent do
      if listed[parent] then return true end
      parent = parent:match("^(.*)/[^/]+$")
    end
    for _, r in ipairs(resources) do
      if r:sub(1, #path + 1) == path .. "/" then return true end
    end
    return false
  end

  local entries, loose = {}, {}
  local function visit(path, ftype)
    if commented[path] then return end
    local parent, name = path:match("^(.*)/([^/]+)$")
    entries[path] = not M.is_referenced(referenced, path, ftype == "directory")
      and not covered(path)
      and M.is_addable_entry(dir .. "/" .. parent, name, ftype)
  end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end
    local linked = ftype == "link"
    ftype = entry_type(dir .. "/" .. name, ftype)

    if M.is_resource_entry(name, ftype) and not commented[name] then
      entries[name] = not M.is_referenced(referenced, name, ftype == "directory")
        and not by_path[name]
        and M.is_addable_entry(dir, name, ftype)

      -- A symlinked directory can be an entry but is never walked: it can loop.
      if ftype == "directory" and not linked
        and not M.find_kustomization(dir .. "/" .. name) then
        if by_path[name] then
          walk(dir, name, visit)
        elseif opts and opts.loose and not listed[name] then
          loose[name] = true
          walk(dir, name, visit)
        end
      end
    end
  end
  return entries, loose
end

-- yq can leave blank lines behind; a kustomization this plugin has touched
-- never has them.
M.strip_blank_lines = function(kustomize_file)
  local lines = vim.fn.readfile(kustomize_file)
  vim.fn.writefile(vim.tbl_filter(function(l) return l:match("%S") ~= nil end, lines), kustomize_file)
end

-- The configured formatter as an argv list, or nil if there isn't one. Health
-- reports on this too, so what :checkhealth shows is what actually runs.
M.formatter_cmd = function(opts)
  local configured = config.resolve(opts).format_command
  if not configured then return nil end

  local cmd = type(configured) == "table" and vim.deepcopy(configured) or { configured }
  if #cmd == 0 then return nil end
  return cmd
end

-- Hand a kustomization to the user's formatter, if they configured one. Runs
-- after this plugin's own writes so their settings have the final say.
--
-- cwd is the kustomization's directory on purpose: yamlfmt and friends look for
-- a project config relative to the working directory, and running from anywhere
-- else silently falls back to the global config instead. A formatter failure is
-- reported but never fatal — the file is already correct, just unformatted.
M.run_formatter = function(kustomize_file, opts)
  local cmd = M.formatter_cmd(opts)
  if not cmd then return end

  if vim.fn.executable(cmd[1]) ~= 1 then
    vim.notify("format_command not executable: " .. cmd[1], vim.log.levels.WARN)
    return
  end

  table.insert(cmd, kustomize_file)
  local res = vim.system(cmd, {
    cwd = vim.fn.fnamemodify(kustomize_file, ":h"),
    text = true,
  }):wait()

  if res.code ~= 0 then
    vim.notify("format_command failed: " .. (res.stderr or ""), vim.log.levels.WARN)
  end
end

-- The one way .resources is rewritten: `filter` produces the list, which is
-- then sorted if configured and cleared of the blank lines yq leaves behind.
-- A single yq spawn, so execute_yq can afford it once per resource.
local function write_resources(filter, kustomize_file, opts, entry_name)
  if config.resolve(opts).sort_resources then
    filter = filter .. " | .resources |= sort"
  end
  if not M.yq({ "-i", filter, kustomize_file }, entry_name) then return false end

  M.strip_blank_lines(kustomize_file)
  return true
end

-- Bring a kustomization to the shape sync leaves behind: an explicit
-- `.resources`, yq's indented block sequences, optionally sorted, no blank
-- lines. `kustomize create` writes flush-left list items and omits `.resources`
-- entirely in an empty directory, so bootstrapped files are run through this to
-- keep both paths producing the same file.
M.format_kustomization = function(kustomize_file, opts)
  return write_resources(".resources = (.resources // [])", kustomize_file, opts)
end

-- Returns whether the write happened, so a caller doing several in a row can
-- stop before the next one makes things worse.
M.execute_yq = function(action, entry_name, kustomize_file, opts)
  if action == "add" then
    return write_resources(
      ".resources += [strenv(ENTRY)] | .resources |= unique_by(" .. M.ENTRY_NORM .. ")",
      kustomize_file, opts, entry_name)
  end
  -- Scoped delete: only remove from .resources, never other list keys.
  return M.yq({
    "-i",
    "del(.resources[] | select((" .. M.ENTRY_NORM .. ") == strenv(ENTRY)))",
    kustomize_file,
  }, entry_name) ~= nil
end

local function add_entries(names, kustomize_file, opts)
  for _, name in ipairs(names) do
    if not M.execute_yq("add", name, kustomize_file, opts) then return false end
  end
  return true
end

-- Create a kustomization in `dir` with `kustomize create --autodetect`.
-- `children` are subdirectory names to list in it as well, since autodetect
-- only looks at yaml files. Returns true on success; notifies and returns false
-- otherwise.
M.bootstrap = function(dir, opts, children)
  if not (M.require_cli("kustomize") and M.require_cli("yq")) then return false end

  local res = vim.system({ "kustomize", "create", "--autodetect" }, { cwd = dir, text = true }):wait()
  if res.code ~= 0 then
    vim.notify("kustomize create failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    return false
  end

  -- Beyond matching sync's formatting, this is what gives the file an explicit
  -- `.resources`: in an empty directory `kustomize create` writes only
  -- apiVersion and kind, which `kustomize build` rejects as
  -- "kustomization.yaml is empty". Adding an entry goes through the same
  -- writer, so the format pass is only needed when there is nothing to add.
  local created = M.find_kustomization(dir)
  if created then
    local ok
    if children and #children > 0 then
      ok = add_entries(children, created, opts)
    else
      ok = M.format_kustomization(created, opts)
    end
    if not ok then return false end
    -- The file just written is a new kustomization in its own right, and the
    -- caller only knows about the *parent* it is about to be added to. Format
    -- it here or nothing ever will.
    M.run_formatter(created, opts)
  end
  return true
end

-- The directories a bootstrapping item needs a kustomization in. Defaults to
-- the entry itself for callers that build items by hand.
M.missing_kustomizations = function(item)
  local missing = {}
  for _, dir in ipairs(item.bootstrap_dirs or { item.path }) do
    if not M.find_kustomization(dir) then table.insert(missing, dir) end
  end
  return missing
end

-- Bootstrap an item's directories from the deepest up, so each kustomization
-- can list the ones created beneath it. False if any of them failed.
local function bootstrap_item(item, opts)
  local dirs = vim.deepcopy(item.bootstrap_dirs or { item.path })
  local function depth(p) return select(2, p:gsub("/", "")) end
  table.sort(dirs, function(a, b) return depth(a) > depth(b) end)

  for _, dir in ipairs(dirs) do
    local children = {}
    for _, other in ipairs(dirs) do
      if vim.fn.fnamemodify(other, ":h") == dir then
        table.insert(children, vim.fn.fnamemodify(other, ":t"))
      end
    end

    local existing = M.find_kustomization(dir)
    if not existing then
      if not M.bootstrap(dir, opts, children) then return false end
    elseif #children > 0 then
      if not add_entries(children, existing, opts) then return false end
      M.run_formatter(existing, opts)
    end
  end
  return true
end

-- Replace the entries listed by path under a directory with the directory
-- itself, now that it has a kustomization of its own. That kustomization has to
-- list what the parent listed, or the manifests drop out of the build, so it is
-- given those entries first, relative to itself.
--
-- A kustomization the user has just created from an explorer is an empty file,
-- which `kustomize build` rejects, so it is given its header first. That goes
-- through yq like every other write; an old yq that leaves an empty file empty
-- is caught by reading it back.
--
-- The order is what keeps a failure harmless: the child is written first and
-- the parent is not touched unless that worked, and in the parent the directory
-- is added before the paths are removed. Stopping anywhere leaves every
-- manifest still reachable.
local function convert_item(item, opts)
  local child = item.child

  local function blank()
    for _, line in ipairs(vim.fn.readfile(child)) do
      if line:match("%S") then return false end
    end
    return true
  end
  if blank() then
    M.yq({
      "-i",
      '.apiVersion = "kustomize.config.k8s.io/v1beta1" | .kind = "Kustomization"',
      child,
    })
    if blank() then
      vim.notify("could not write " .. child, vim.log.levels.ERROR)
      return false
    end
  end

  local entries = {}
  for _, r in ipairs(item.replaces) do
    table.insert(entries, r:sub(#item.name + 2))
  end
  if not add_entries(entries, child, opts) then return false end
  M.run_formatter(child, opts)

  if not M.execute_yq("add", item.name, item.kustomize_file, opts) then return false end
  for _, r in ipairs(item.replaces) do
    if not M.execute_yq("remove", r, item.kustomize_file, opts) then return false end
  end
  return true
end

-- The one write protocol: bootstrap where the entry needs it, write every
-- change, then format each kustomization once at the end. Items carry the shape
-- `context.resolve_changes` returns.
--
-- The formatter runs per file rather than per entry on purpose: execute_yq runs
-- once per resource, and a formatter alongside it would be a process spawn each
-- time.
--
-- Returns false if any write failed. Each failure has already been notified;
-- the return is for callers that would otherwise report success.
M.apply_changes = function(items, opts)
  local touched, ok = {}, true
  for _, item in ipairs(items) do
    local written
    if item.op == "convert" then
      written = convert_item(item, opts)
    else
      written = (not item.needs_bootstrap or bootstrap_item(item, opts))
        and M.execute_yq(item.op, item.name, item.kustomize_file, opts)
    end
    ok = ok and written
    -- Touched even on failure: a convert that stopped halfway has still written
    -- to the file, and formatting an untouched one is harmless.
    touched[item.kustomize_file] = true
  end

  for kustomize_file in pairs(touched) do
    M.run_formatter(kustomize_file, opts)
  end
  return ok
end

-- Whether a listed resource has nothing behind it any more. Decided by a stat
-- of where the entry points, never by the disk scan: the scan only knows what
-- could be *added*, and .resources legitimately holds more than that — a
-- `../base`, a `deploy/svc.yaml`, a json manifest, a symlinked directory.
-- Removing whatever the scan didn't recognise strips those out.
local function is_stale(dir, r)
  local path = r:sub(1, 1) == "/" and r or dir .. "/" .. r
  return vim.uv.fs_stat(path) == nil and not M.is_remote(r)
end

M.sync = function(ctx, opts)
  local dir = M.ctx_dir(ctx)
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.notify("Not a directory: " .. dir, vim.log.levels.WARN)
    return
  end
  if not M.require_cli("yq") then return end
  local target = M.find_kustomization(dir)

  -- Bootstrapping is the start of a sync, not a substitute for one:
  -- `kustomize create --autodetect` only picks up yaml files, so any
  -- subdirectory that is itself a kustomization is still missing afterwards.
  local created = false
  if not target then
    if not M.bootstrap(dir, opts) then return end
    target = M.find_kustomization(dir)
    if not target then
      vim.notify("kustomize create wrote no kustomization", vim.log.levels.ERROR)
      return
    end
    created = true
  end

  local current_resources, res_map = M.current_resources(target)
  if not current_resources or not res_map then return end

  -- A directory nothing is listed out of is only looked into when files there
  -- would be listed by path anyway. Otherwise it needs a kustomization first,
  -- and creating one is the explorer prompt's to offer, not this command's.
  local disk_map = M.scan_entries(dir, target, current_resources, {
    loose = M.preferred_style(target, current_resources) == "path",
  })
  if not disk_map then return end

  -- Sorted so the order entries land in doesn't depend on table iteration,
  -- which shows when sort_resources is off.
  local names = vim.tbl_keys(disk_map)
  table.sort(names)

  local changes = {}
  for _, name in ipairs(names) do
    if disk_map[name] and not res_map[name] then
      table.insert(changes, { op = "add", name = name, kustomize_file = target })
    end
  end

  for _, r in ipairs(current_resources) do
    if is_stale(dir, r) then
      table.insert(changes, { op = "remove", name = r, kustomize_file = target })
    end
  end

  if M.apply_changes(changes, opts) then
    vim.notify(
      created and "Kustomize base created and synced" or "Kustomization synced",
      vim.log.levels.INFO
    )
  else
    vim.notify("Kustomization sync did not complete; see the errors above", vim.log.levels.WARN)
  end
  if ctx.refresh then ctx.refresh() end

  -- The path of a kustomization this run created, for the caller to follow up
  -- on: the kustomization above it knows nothing about it yet.
  return created and target or nil
end

return M
