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
M.is_resource_entry = function(name, ftype)
  if M.is_kustomization(name) then return false end
  return ftype == "directory" or M.is_yaml(name)
end

-- Whether an entry is safe to *add* to .resources. A directory is only a valid
-- resource if it carries its own kustomization file — listing one without it
-- makes `kustomize build` fail. Existing entries are not judged by this: a
-- half-built directory should not be ripped out from under the user.
M.is_addable_entry = function(dir, name, ftype)
  if ftype ~= "directory" then return true end
  return M.find_kustomization(dir .. "/" .. name) ~= nil
end

-- Remote resource refs (scheme://, git@host, git::url) are left untouched on sync.
M.is_remote = function(r)
  return r:match("^%w[%w+.-]*://") ~= nil
      or r:match("^git@") ~= nil
      or r:match("^git::") ~= nil
end

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

M.is_commented_out = function(entry_name, kustomize_file)
  return M.commented_set(kustomize_file)[entry_name] == true
end

-- What .resources lists right now, trailing slashes stripped. Returns the list
-- in file order plus a lookup set, or nil if yq failed.
M.current_resources = function(kustomize_file)
  local out = M.yq({ '.resources // [] | map(sub("/$", ""))', kustomize_file, "-o", "json" })
  if not out then return nil end

  local list = vim.fn.json_decode(out) or {}
  local set = {}
  for _, r in ipairs(list) do set[r] = true end
  return list, set
end

-- What's on disk that could be a resource, as name -> addable. Commented-out
-- entries are left out entirely so disabling one doesn't re-add it. `addable`
-- is false for a directory with no kustomization of its own: it can't be added,
-- but it still counts as present, so an entry the user is midway through
-- creating doesn't get removed.
M.scan_entries = function(dir, kustomize_file)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return nil end

  local commented = M.commented_set(kustomize_file)
  local entries = {}
  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if M.is_resource_entry(name, ftype) and not commented[name] then
      entries[name] = M.is_addable_entry(dir, name, ftype)
    end
  end
  return entries
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

-- Bring a kustomization to the shape sync leaves behind: an explicit
-- `.resources`, yq's indented block sequences, optionally sorted, no blank
-- lines. `kustomize create` writes flush-left list items and omits `.resources`
-- entirely in an empty directory, so bootstrapped files are run through this to
-- keep both paths producing the same file.
M.format_kustomization = function(kustomize_file, opts)
  opts = config.resolve(opts)

  local filter = ".resources = (.resources // [])"
  if opts.sort_resources then
    filter = filter .. " | .resources |= sort"
  end
  if not M.yq({ "-i", filter, kustomize_file }) then return false end

  M.strip_blank_lines(kustomize_file)
  return true
end

M.execute_yq = function(action, entry_name, kustomize_file, opts)
  opts = config.resolve(opts)

  if action == "add" then
    local yq_filter = '.resources += [strenv(ENTRY)] | .resources |= unique_by(sub("/$", ""))'
    if opts.sort_resources then
      yq_filter = yq_filter .. " | .resources |= sort"
    end

    if not M.yq({ "-i", yq_filter, kustomize_file }, entry_name) then return end
    M.strip_blank_lines(kustomize_file)
  else
    -- Scoped delete: only remove from .resources, never other list keys.
    M.yq({
      "-i",
      'del(.resources[] | select(sub("/$", "") == strenv(ENTRY)))',
      kustomize_file,
    }, entry_name)
  end
end

-- Create a kustomization in `dir` with `kustomize create --autodetect`.
-- Returns true on success; notifies and returns false otherwise.
M.bootstrap = function(dir, opts)
  if not M.require_cli("kustomize") then return false end

  local res = vim.system({ "kustomize", "create", "--autodetect" }, { cwd = dir, text = true }):wait()
  if res.code ~= 0 then
    vim.notify("kustomize create failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    return false
  end

  -- Beyond matching sync's formatting, this is what gives the file an explicit
  -- `.resources`: in an empty directory `kustomize create` writes only
  -- apiVersion and kind, which `kustomize build` rejects as
  -- "kustomization.yaml is empty".
  local created = M.find_kustomization(dir)
  if created then
    M.format_kustomization(created, opts)
    -- The file just written is a new kustomization in its own right, and the
    -- caller only knows about the *parent* it is about to be added to. Format
    -- it here or nothing ever will.
    M.run_formatter(created, opts)
  end
  return true
end

-- The one write protocol: bootstrap where the entry needs it, write every
-- change, then format each kustomization once at the end. Items carry the shape
-- `context.resolve_change` returns, plus `op`.
--
-- The formatter runs per file rather than per entry on purpose: execute_yq runs
-- once per resource, and a formatter alongside it would be a process spawn each
-- time.
M.apply_changes = function(items, opts)
  local touched = {}
  for _, item in ipairs(items) do
    if not item.needs_bootstrap or M.bootstrap(item.path, opts) then
      M.execute_yq(item.op, item.name, item.kustomize_file, opts)
      touched[item.kustomize_file] = true
    end
  end

  for kustomize_file in pairs(touched) do
    M.run_formatter(kustomize_file, opts)
  end
end

M.sync = function(ctx, opts)
  local dir = M.ctx_dir(ctx)
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

  if not M.require_cli("yq") then return end

  local current_resources, res_map = M.current_resources(target)
  if not current_resources or not res_map then return end

  local disk_map = M.scan_entries(dir, target)
  if not disk_map then return end

  local changes = {}
  for name, addable in pairs(disk_map) do
    if addable and not res_map[name] then
      table.insert(changes, { op = "add", name = name, kustomize_file = target })
    end
  end

  for _, r in ipairs(current_resources) do
    if disk_map[r] == nil and not M.is_remote(r) then
      table.insert(changes, { op = "remove", name = r, kustomize_file = target })
    end
  end

  M.apply_changes(changes, opts)

  vim.notify(
    created and "Kustomize base created and synced" or "Kustomization synced",
    vim.log.levels.INFO
  )
  if ctx.refresh then ctx.refresh() end
end

return M
