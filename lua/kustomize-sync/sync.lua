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

M.execute_yq = function(action, entry_name, kustomize_file, opts)
  opts = vim.tbl_deep_extend("force", config.options, opts or {})

  if action == "add" then
    local yq_filter = opts.sort_resources
        and '.resources += [strenv(ENTRY)] | .resources |= (unique_by(sub("/$", "")) | sort)'
        or '.resources += [strenv(ENTRY)] | .resources |= unique_by(sub("/$", ""))'

    if not M.yq({ "-i", yq_filter, kustomize_file }, entry_name) then return end

    -- Cleanup empty lines left by yq
    local lines = vim.fn.readfile(kustomize_file)
    vim.fn.writefile(vim.tbl_filter(function(l) return l:match("%S") ~= nil end, lines), kustomize_file)
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
M.bootstrap = function(dir)
  if vim.fn.executable("kustomize") ~= 1 then
    vim.notify("kustomize CLI not found", vim.log.levels.ERROR)
    return false
  end
  local res = vim.system({ "kustomize", "create", "--autodetect" }, { cwd = dir, text = true }):wait()
  if res.code ~= 0 then
    vim.notify("kustomize create failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    return false
  end

  -- In an empty directory `kustomize create` writes only apiVersion and kind,
  -- which `kustomize build` then rejects as "kustomization.yaml is empty". An
  -- explicit (even empty) .resources builds, so the directory is usable as a
  -- resource the moment it's created.
  local created = M.find_kustomization(dir)
  if created then M.yq({ "-i", ".resources = (.resources // [])", created }) end
  return true
end

M.sync = function(ctx, opts)
  local dir = ctx.is_dir and ctx.path or vim.fn.fnamemodify(ctx.path, ":h")
  local target = M.find_kustomization(dir)

  if not target then
    if not M.bootstrap(dir) then return end
    vim.notify("Kustomize base created", vim.log.levels.INFO)
  else
    if vim.fn.executable("yq") ~= 1 then
      vim.notify("yq not found", vim.log.levels.ERROR)
      return
    end

    local current_json = M.yq({ '.resources // [] | map(sub("/$", ""))', target, "-o", "json" })
    if not current_json then return end
    local current_resources = vim.fn.json_decode(current_json) or {}
    local res_map = {}
    for _, r in ipairs(current_resources) do res_map[r] = true end

    local handle = vim.uv.fs_scandir(dir)
    if not handle then return end

    local commented = M.commented_set(target)
    -- name -> addable. Entries that exist but aren't addable (a directory with
    -- no kustomization file yet) stay out of the add pass while still counting
    -- as present, so the remove pass leaves them alone.
    local disk_map = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if M.is_resource_entry(name, ftype) and not commented[name] then
        disk_map[name] = M.is_addable_entry(dir, name, ftype)
      end
    end

    for name, addable in pairs(disk_map) do
      if addable and not res_map[name] then M.execute_yq("add", name, target, opts) end
    end

    for _, r in ipairs(current_resources) do
      if disk_map[r] == nil and not M.is_remote(r) then
        M.execute_yq("remove", r, target, opts)
      end
    end

    vim.notify("Kustomization synced", vim.log.levels.INFO)
  end
  if ctx.refresh then ctx.refresh() end
end

return M
