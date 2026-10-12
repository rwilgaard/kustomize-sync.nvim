-- Shared by every test file: `local H = dofile("tests/helpers.lua")`.
--
-- Tests run in the Neovim that runs the suite, against real directories and a
-- real yq. Each one builds the project it needs with H.project and gets a
-- clean slate from the pre_case/post_case hooks.
local H = {}

local config = require("kustomize-sync.config")
local sync = require("kustomize-sync.sync")

local HEADER = "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n"
local NO_EXPLORERS = { neo_tree = { enabled = false }, oil = { enabled = false } }

local roots = {}
local real_notify = vim.notify

-- Everything vim.notify was called with since the test began.
H.messages = {}

-- A kustomization's text. `rest` is appended as written, for the other keys.
H.kustomization = function(resources, rest)
  local lines = { HEADER .. "resources:" .. (#resources == 0 and " []" or "") }
  for _, r in ipairs(resources) do table.insert(lines, "  - " .. r) end
  return table.concat(lines, "\n") .. "\n" .. (rest or "")
end

H.component = "apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\n"

-- Write `files` below `root`. A list item is an empty file, or an empty
-- directory when it ends in a slash; a keyed item is a file with that content.
H.write = function(root, files)
  for key, value in pairs(files) do
    local path, content = key, value
    if type(key) == "number" then path, content = value, "" end
    local full = root .. "/" .. path
    if path:sub(-1) == "/" then
      vim.fn.mkdir(full, "p")
    else
      vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
      vim.fn.writefile(vim.split(content, "\n", { plain = true }), full, "b")
    end
  end
end

-- A fresh directory holding `files`, removed after the test.
H.project = function(files)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  -- The plugin compares paths by prefix, and on macOS the temp directory is
  -- reached through a symlink.
  root = vim.uv.fs_realpath(root)
  table.insert(roots, root)
  H.write(root, files or {})
  return root
end

H.ctx = function(path)
  return { path = path, is_dir = vim.fn.isdirectory(path) == 1, refresh = function() end }
end

-- What .resources of the kustomization in `dir` lists, in file order.
H.listed = function(dir)
  return (sync.current_resources(dir .. "/kustomization.yaml"))
end

H.sorted = function(list)
  local copy = vim.deepcopy(list)
  table.sort(copy)
  return copy
end

-- Run the plugin's setup with the explorers off.
H.setup = function(opts)
  require("kustomize-sync").setup(vim.tbl_extend("force", { integrations = NO_EXPLORERS }, opts or {}))
end

H.reset = function()
  config.setup({})
  H.messages = {}
  vim.notify = function(msg) table.insert(H.messages, msg) end
end

H.cleanup = function()
  vim.notify = real_notify
  -- Turns the diagnostics autocmds off again, for the tests that turned them on.
  H.setup({ diagnostics = false })
  vim.cmd("silent! %bwipeout!")
  for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
  roots = {}
end

H.hooks = { pre_case = H.reset, post_case = H.cleanup }

return H
