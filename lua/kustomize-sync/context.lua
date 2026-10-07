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

M.resolve_change = function(filepath, op, entry_type)
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

  local top_level_entry = vim.split(clean_path:sub(#kustomize_dir + 2), "/", { trimempty = true })[1]
  if not top_level_entry then return nil end

  if sync.is_commented_out(top_level_entry, kustomize_file) then return nil end

  local is_yaml = sync.is_yaml(top_level_entry)
  local is_dir
  if entry_type == "directory" then
    is_dir = true
  elseif op == "add" then
    is_dir = vim.fn.isdirectory(kustomize_dir .. "/" .. top_level_entry) == 1
  else
    -- On remove the path is already gone; guess dir by absence of an extension.
    -- Fallible for extension-less files or dot-named dirs, but the yq presence
    -- check below still gates the actual prompt.
    is_dir = not top_level_entry:match("%.")
  end
  if not (is_yaml or is_dir) then return nil end

  -- A directory with no kustomization file of its own can't be built. Adding it
  -- silently would break `kustomize build`, and staying silent loses the prompt
  -- entirely, so flag it and let the caller offer to create one first.
  local entry_path = kustomize_dir .. "/" .. top_level_entry
  local needs_bootstrap = op == "add" and is_dir and not sync.find_kustomization(entry_path)

  local present_out = sync.yq({
    '.resources // [] | map(sub("/$", "")) | map(select(. == strenv(ENTRY))) | length > 0',
    kustomize_file,
  }, top_level_entry)
  if not present_out then return nil end
  local is_present = present_out:gsub("%s+", "") == "true"

  local should_prompt = (op == "add" and not is_present) or (op == "remove" and is_present)
  if not should_prompt then return nil end

  return {
    name            = top_level_entry,
    path            = entry_path,
    kustomize_file  = kustomize_file,
    needs_bootstrap = needs_bootstrap,
  }
end

return M

