local sync = require("kustomize-sync.sync")

local M = {}

-- Reports on exactly the argv sync would run, rather than re-deriving it here.
local function check_format_command()
  local cmd = sync.formatter_cmd()
  if not cmd then
    vim.health.info(
      "format_command is not set; yq's formatting is kept as-is.\n"
      .. "If you did set it, setup() has not run with that value — check that your\n"
      .. "plugin manager passes it (lazy.nvim `opts`/`config`) and that it sits at the\n"
      .. "top level, not inside `build`."
    )
    return
  end

  local name = cmd[1]
  vim.health.info("format_command resolves to: " .. vim.inspect(cmd))

  if vim.fn.executable(name) ~= 1 then
    vim.health.warn(
      "'" .. name .. "' is not executable from Neovim, so files are left unformatted.\n"
      .. "It may be on your shell's PATH but not Neovim's. Compare `which " .. name .. "`\n"
      .. "in a terminal with `:echo exepath('" .. name .. "')` here."
    )
    return
  end

  vim.health.ok("format_command '" .. name .. "' is executable (" .. vim.fn.exepath(name) .. ").")
  vim.health.info(
    "It runs after each write. If the output looks unchanged, the formatter may\n"
    .. "simply agree with yq — both default to two-space indented list entries."
  )
end

M.check = function()
  vim.health.start("kustomize-sync.nvim")

  if vim.fn.executable("yq") == 1 then
    vim.health.ok("yq is installed.")
  else
    vim.health.error("yq is missing. Please install yq.")
  end

  if vim.fn.executable("kustomize") == 1 then
    vim.health.ok("kustomize is installed.")
  else
    vim.health.error("kustomize is missing. Please install kustomize.")
  end

  check_format_command()
end

return M
