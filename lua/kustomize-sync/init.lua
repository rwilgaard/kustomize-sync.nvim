local config = require("kustomize-sync.config")

local M = {}

M.setup = function(opts)
  config.setup(opts)

  if config.options.integrations.neo_tree.enabled then
    local ok, mod = pcall(require, "kustomize-sync.integrations.neo-tree")
    if ok then mod.setup() end
  end
  if config.options.integrations.oil.enabled then
    local ok, mod = pcall(require, "kustomize-sync.integrations.oil")
    if ok then mod.setup() end
  end
end

-- A sync that had to create the kustomization has made a new file, the same as
-- creating one from an explorer, so the kustomization above gets the same
-- prompt: add the directory, or list it whole in place of files it had by path.
-- Without this the two ways of creating one leave the parent in different
-- states.
M.sync = function(ctx, opts)
  local created = require("kustomize-sync.sync").sync(ctx, opts)
  if created then
    require("kustomize-sync.ui").handle_change("add", created, ctx.refresh, "file", opts)
  end
end
M.interactive_sync = function(...) return require("kustomize-sync.ui").interactive_sync(...) end
M.batch_handle_changes = function(...) return require("kustomize-sync.ui").batch_handle_changes(...) end
M.handle_change = function(...) return require("kustomize-sync.ui").handle_change(...) end

-- A rename or move, as one prompt over the remove/add pair it amounts to. Goes
-- through batch_handle_changes because the two sides can belong to different
-- kustomizations.
M.handle_move = function(src, dest, refresh, opts)
  return require("kustomize-sync.ui").batch_handle_changes(
    { { op = "move", src = src, dest = dest } }, refresh, opts)
end
M.build = function(...) return require("kustomize-sync.build").build(...) end

return M
