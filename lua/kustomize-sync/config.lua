local M = {}

M.defaults = {
  sort_resources = true,
  -- External formatter run over a kustomization after this plugin writes to it,
  -- e.g. { "yamlfmt" }. A string, a list for extra flags, or nil to leave yq's
  -- output alone. The tool resolves its own config, so a global one works
  -- without per-project setup.
  format_command = nil,
  build = {
    output = "split", -- "split" | "vsplit" | "float"
    -- Build-window keymaps. Each is a string, a list of strings to bind
    -- several keys, or false to leave the action unmapped.
    keymaps = {
      rebuild      = "R",
      next_change  = "]c",
      prev_change  = "[c",
      diff         = "d",
      set_baseline = "D",
      close        = "q",
    },
  },
  integrations = {
    neo_tree = {
      enabled = true,
      auto_prompt_on_change = true,
    },
    oil = {
      enabled = true,
      auto_prompt_on_change = true,
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

-- Per-call overrides on top of whatever setup() left behind.
function M.resolve(opts)
  return vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
