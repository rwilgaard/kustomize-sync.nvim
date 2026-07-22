local config = require("kustomize-sync.config")

local M = {}

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
    local escaped = vim.fn.escape(entry_name, '\\.^$*[]~')
    local pattern = '^\\s*-\\s*' .. escaped .. '/\\?\\s*$'
    local lines = vim.fn.readfile(kustomize_file)
    local new_lines = {}
    for _, line in ipairs(lines) do
      if vim.fn.match(line, pattern) < 0 then
        table.insert(new_lines, line)
      end
    end
    vim.fn.writefile(new_lines, kustomize_file)
  end
end

M.is_commented_out = function(entry_name, kustomize_file)
  for _, line in ipairs(vim.fn.readfile(kustomize_file)) do
    local trimmed = vim.trim(line)
    if trimmed:sub(1, 1) == "#" then
      local rest = vim.trim(trimmed:sub(2))
      if rest:sub(1, 1) == "-" then
        local name = vim.trim(rest:sub(2)):gsub("/$", "")
        if name == entry_name then return true end
      end
    end
  end
  return false
end

M.sync = function(ctx, opts)
  local dir = ctx.is_dir and ctx.path or vim.fn.fnamemodify(ctx.path, ":h")
  local target = dir .. "/kustomization.yaml"

  if vim.fn.filereadable(target) ~= 1 then
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

    local disk_map = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if name ~= "kustomization.yaml" and (ftype == "directory" or name:match("%.yaml$"))
          and not M.is_commented_out(name, target) then
        disk_map[name] = true
      end
    end

    for name in pairs(disk_map) do
      if not res_map[name] then M.execute_yq("add", name, target, opts) end
    end

    for _, r in ipairs(current_resources) do
      if not disk_map[r] and not r:match("^https?://") and not r:match("^git") then
        M.execute_yq("remove", r, target, opts)
      end
    end

    vim.notify("Kustomization synced", vim.log.levels.INFO)
  end
  if ctx.refresh then ctx.refresh() end
end

return M
