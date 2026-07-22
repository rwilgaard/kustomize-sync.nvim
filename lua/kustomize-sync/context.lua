local sync = require("kustomize-sync.sync")

local M = {}

M.find_parent_kustomize = function(start_dir)
  local current = start_dir
  while current ~= "/" and current ~= "." and current ~= "" do
    local target = current .. "/kustomization.yaml"
    if vim.fn.filereadable(target) == 1 then
      return target, current
    end
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then break end
    current = parent
  end
  return nil, nil
end

M.resolve_change = function(filepath, op, entry_type)
  local clean_path = filepath:gsub("/$", "")
  local entry_name = vim.fn.fnamemodify(clean_path, ":t")
  local start_dir  = vim.fn.fnamemodify(clean_path, ":h")
  if entry_name == "kustomization.yaml" or entry_name == "" then return nil end

  local kustomize_file, kustomize_dir = M.find_parent_kustomize(start_dir)
  if not kustomize_file or not kustomize_dir then return nil end

  local top_level_entry = vim.split(clean_path:sub(#kustomize_dir + 2), "/", { trimempty = true })[1]
  if not top_level_entry then return nil end
  if sync.is_commented_out(top_level_entry, kustomize_file) then return nil end

  local is_yaml = top_level_entry:match("%.yaml$") ~= nil
  local is_dir
  if entry_type == "directory" then
    is_dir = true
  elseif op == "add" then
    is_dir = vim.fn.isdirectory(kustomize_dir .. "/" .. top_level_entry) == 1
  else
    is_dir = not top_level_entry:match("%.")
  end
  if not (is_yaml or is_dir) then return nil end

  local present_out = sync.yq({
    '.resources // [] | map(sub("/$", "")) | map(select(. == strenv(ENTRY))) | length > 0',
    kustomize_file,
  }, top_level_entry)
  if not present_out then return nil end
  local is_present = present_out:gsub("%s+", "") == "true"

  local should_prompt = (op == "add" and not is_present) or (op == "remove" and is_present)
  if not should_prompt then return nil end

  return { name = top_level_entry, kustomize_file = kustomize_file }
end

return M

