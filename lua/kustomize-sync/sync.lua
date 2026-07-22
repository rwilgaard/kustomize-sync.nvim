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

M.sync = function(ctx, opts)
  local dir = ctx.is_dir and ctx.path or vim.fn.fnamemodify(ctx.path, ":h")
  local target = M.find_kustomization(dir)

  if not target then
    if vim.fn.executable("kustomize") ~= 1 then
      vim.notify("kustomize CLI not found", vim.log.levels.ERROR)
      return
    end
    local res = vim.system({ "kustomize", "create", "--autodetect" }, { cwd = dir, text = true }):wait()
    if res.code ~= 0 then
      vim.notify("kustomize create failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
      return
    end
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
    local disk_map = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if not M.is_kustomization(name) and (ftype == "directory" or M.is_yaml(name))
          and not commented[name] then
        disk_map[name] = true
      end
    end

    for name in pairs(disk_map) do
      if not res_map[name] then M.execute_yq("add", name, target, opts) end
    end

    for _, r in ipairs(current_resources) do
      if not disk_map[r] and not M.is_remote(r) then
        M.execute_yq("remove", r, target, opts)
      end
    end

    vim.notify("Kustomization synced", vim.log.levels.INFO)
  end
  if ctx.refresh then ctx.refresh() end
end

return M
