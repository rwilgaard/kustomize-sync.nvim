local config = require("kustomize-sync.config")

local M = {}

M.setup = function(opts)
  config.setup(opts)

  if config.options.integrations.neo_tree.enabled then
    pcall(require, "kustomize-sync.integrations.neo-tree")
  end
  if config.options.integrations.oil.enabled then
    pcall(require, "kustomize-sync.integrations.oil")
  end
end

M.sync = function(...) return require("kustomize-sync.sync").sync(...) end
M.interactive_sync = function(...) return require("kustomize-sync.ui").interactive_sync(...) end
M.batch_handle_changes = function(...) return require("kustomize-sync.ui").batch_handle_changes(...) end
M.handle_change = function(...) return require("kustomize-sync.ui").handle_change(...) end

return M
