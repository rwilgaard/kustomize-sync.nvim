local H = dofile("tests/helpers.lua")
local config = require("kustomize-sync.config")
local sync = require("kustomize-sync.sync")

local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = H.hooks })

local function run(dir)
  return sync.sync(H.ctx(dir))
end

T["sync"] = MiniTest.new_set()

T["sync"]["adds what is on disk and not listed"] = function()
  local root = H.project({
    "a.yaml", "b.yml", "notes.txt", "apps/x.yaml",
    ["kustomization.yaml"] = H.kustomization({ "a.yaml" }),
    ["apps/kustomization.yaml"] = H.kustomization({ "x.yaml" }),
  })
  run(root)
  eq(H.listed(root), { "a.yaml", "apps", "b.yml" })
end

T["sync"]["skips what can't be a resource"] = function()
  local root = H.project({
    "a.yaml", ".gitlab-ci.yml", ".github/workflow.yaml", "plain/x.yaml",
    ["kustomization.yaml"] = H.kustomization({ "a.yaml" }),
    ["shared/kustomization.yaml"] = H.component,
  })
  run(root)
  -- A dot-name, a directory with no kustomization, a component.
  eq(H.listed(root), { "a.yaml" })
  eq(vim.fn.filereadable(root .. "/plain/kustomization.yaml"), 0)
end

T["sync"]["leaves a commented-out entry off"] = function()
  local root = H.project({
    "a.yaml", "off.yaml",
    ["kustomization.yaml"] = H.kustomization({ "a.yaml" }) .. "  # - off.yaml\n",
  })
  run(root)
  eq(H.listed(root), { "a.yaml" })
end

T["sync"]["removes an entry with nothing behind it"] = function()
  local root = H.project({
    "a.yaml",
    ["kustomization.yaml"] = H.kustomization({ "a.yaml", "gone.yaml", "gone-dir" }),
  })
  run(root)
  eq(H.listed(root), { "a.yaml" })
end

-- The remove pass stats each entry where it points. Going by what the disk
-- scan recognises deleted every one of these.
T["sync"]["keeps entries the disk scan would not have found"] = function()
  local root = H.project({
    "overlay/data.json", "overlay/deploy/svc.yaml",
    ["base/kustomization.yaml"] = H.kustomization({}),
    ["elsewhere/kustomization.yaml"] = H.kustomization({}),
  })
  local overlay = root .. "/overlay"
  vim.uv.fs_symlink(root .. "/elsewhere", overlay .. "/linked")
  local kept = {
    "../base", "data.json", "deploy/svc.yaml", "linked",
    "https://example.com/x.yaml", "github.com/org/repo", "git@github.com:org/repo.git",
  }
  H.write(overlay, { ["kustomization.yaml"] = H.kustomization(kept) })

  run(overlay)
  eq(H.sorted(H.listed(overlay)), H.sorted(kept))
end

T["sync"]["does not list a file another key already uses"] = function()
  local root = H.project({
    "patch.yaml", "configs/deploy.yaml", "configs/extra.yaml", "configs/app.conf",
    "configs/patch.yaml",
    ["kustomization.yaml"] = H.kustomization({ "configs/deploy.yaml" }, table.concat({
      "patches:",
      "  - path: patch.yaml",
      "  - path: configs/patch.yaml",
      "configMapGenerator:",
      "  - name: app",
      "    files:",
      "      - app.conf=configs/app.conf",
      "",
    }, "\n")),
  })
  run(root)
  -- Patches stay out at any depth. The files beside them are still
  -- resources.
  eq(H.listed(root), { "configs/deploy.yaml", "configs/extra.yaml" })
end

T["sync"]["a remote ref does not make the project list files by path"] = function()
  local remotes = { "https://example.com/base.yaml", "github.com/org/repo" }
  local root = H.project({
    "a.yaml", "deploy/svc.yaml",
    ["kustomization.yaml"] = H.kustomization(remotes),
  })
  run(root)
  eq(H.sorted(H.listed(root)), H.sorted(vim.list_extend({ "a.yaml" }, remotes)))
end

T["sync"]["nor does a directory listed whole below the top level"] = function()
  local root = H.project({
    "other/x.yaml",
    ["kustomization.yaml"] = H.kustomization({ "apps/frontend" }),
    ["apps/frontend/kustomization.yaml"] = H.kustomization({}),
  })
  run(root)
  eq(H.listed(root), { "apps/frontend" })
end

T["sync"]["lists a new file by path where its neighbours are"] = function()
  local root = H.project({
    "deploy/svc.yaml", "deploy/ingress.yaml", "deploy/sub/x.yaml",
    ["kustomization.yaml"] = H.kustomization({ "deploy/svc.yaml" }),
    ["deploy/sub/kustomization.yaml"] = H.kustomization({ "x.yaml" }),
  })
  run(root)
  -- A subdirectory with its own kustomization is one entry, not walked.
  eq(H.listed(root), { "deploy/ingress.yaml", "deploy/sub", "deploy/svc.yaml" })
end

T["sync"]["looks into unlisted directories only in path style"] = function()
  local files = {
    "deploy/svc.yaml", "other/x.yaml", "apps/y.yaml",
    ["apps/kustomization.yaml"] = H.kustomization({ "y.yaml" }),
  }
  local by_path = H.project(vim.tbl_extend("error", files, {
    ["kustomization.yaml"] = H.kustomization({ "deploy/svc.yaml" }),
  }))
  run(by_path)
  eq(H.listed(by_path), { "apps", "deploy/svc.yaml", "other/x.yaml" })

  local whole = H.project(vim.tbl_extend("error", files, {
    ["kustomization.yaml"] = H.kustomization({ "apps" }),
  }))
  run(whole)
  eq(H.listed(whole), { "apps" })
end

T["sync"]["treats ./foo, foo/ and foo as one entry"] = function()
  local root = H.project({
    "a.yaml",
    ["kustomization.yaml"] = H.kustomization({ "./a.yaml", "apps/" }),
    ["apps/kustomization.yaml"] = H.kustomization({}),
  })
  run(root)
  eq(H.listed(root), { "a.yaml", "apps" })
end

T["sync"]["appends in name order when sort_resources is off"] = function()
  config.setup({ sort_resources = false })
  local root = H.project({
    "m.yaml", "z.yaml", "a.yaml",
    ["kustomization.yaml"] = H.kustomization({ "m.yaml" }),
  })
  run(root)
  eq(H.listed(root), { "m.yaml", "a.yaml", "z.yaml" })
end

T["sync"]["creates the kustomization when there is none"] = function()
  if vim.fn.executable("kustomize") ~= 1 then MiniTest.skip("kustomize is not installed") end
  local root = H.project({
    "a.yaml", "apps/x.yaml",
    ["apps/kustomization.yaml"] = H.kustomization({ "x.yaml" }),
  })
  -- The path comes back so the caller can tell the kustomization above.
  eq(run(root), root .. "/kustomization.yaml")
  -- `kustomize create --autodetect` sees only the yaml; the directory comes
  -- from the sync that follows.
  eq(H.listed(root), { "a.yaml", "apps" })
end

T["sync"]["gives an empty directory a kustomization that builds"] = function()
  if vim.fn.executable("kustomize") ~= 1 then MiniTest.skip("kustomize is not installed") end
  local root = H.project({})
  run(root)
  eq(H.listed(root), {})
  -- apiVersion and kind alone are rejected as "kustomization.yaml is empty".
  eq(vim.system({ "kustomize", "build", root }):wait().code, 0)
end

-- A remote ref has a first segment too. Taking `https:` or `github.com` for
-- a local directory made a plain project look like it listed files by path.
T["path_style_dirs"] = function()
  local root = H.project({ "deploy/svc.yaml" })
  local resources = { "deploy/svc.yaml", "https://example.com/x.yaml", "github.com/org/repo", "../base/x.yaml" }
  local found = {}
  for name, is_dir in pairs(sync.path_style_dirs(resources, root)) do
    if is_dir then table.insert(found, name) end
  end
  eq(found, { "deploy" })
end

T["is_remote"] = MiniTest.new_set({
  parametrize = {
    { "https://example.com/x.yaml", true },
    { "ssh://git@host/org/repo", true },
    { "git@github.com:org/repo.git", true },
    { "git::https://host/org/repo", true },
    { "github.com/org/repo", true },
    { "deploy/svc.yaml", false },
    { "../base", false },
    { "a.yaml", false },
  },
})

T["is_remote"]["tells a ref from a path"] = function(value, expected)
  eq(sync.is_remote(value), expected)
end

T["entry_path"] = MiniTest.new_set({
  parametrize = {
    { "a.yaml", false, "a.yaml" },
    { "./a.yaml", false, "a.yaml" },
    { "apps/", false, "apps" },
    { "../base/", false, "../base" },
    { "app.conf=configs/app.conf", true, "configs/app.conf" },
    { "app.conf=configs/app.conf", false, "app.conf=configs/app.conf" },
    { "configs/a=b.conf", true, "configs/a=b.conf" },
    { "kind: Deployment\nmetadata: {}", false, nil },
    { "", false, nil },
    { vim.NIL, false, nil },
  },
})

T["entry_path"]["reads a value as the path it names"] = function(value, keyed, expected)
  eq(sync.entry_path(value, keyed), expected)
end

T["local_path"] = function()
  local dir = "/project"
  eq(sync.local_path("deploy/svc.yaml", dir), "deploy/svc.yaml")
  eq(sync.local_path("/project/deploy/svc.yaml", dir), "deploy/svc.yaml")
  -- Outside the directory is not this kustomization's to judge.
  eq(sync.local_path("../base", dir), nil)
  eq(sync.local_path("/elsewhere/x.yaml", dir), nil)
end

T["preferred_style"] = MiniTest.new_set()

local function style(resources, files)
  local root = H.project(files)
  return sync.preferred_style(root .. "/kustomization.yaml", resources)
end

T["preferred_style"]["goes by what entries are, not by slashes"] = function()
  eq(style({ "deploy/svc.yaml" }, { "deploy/svc.yaml" }), "path")
  eq(style({ "apps/frontend" }, { "apps/frontend/" }), "kustomization")
  eq(style({ "deploy/svc.yaml", "apps" }, { "deploy/svc.yaml", "apps/" }), "kustomization")
end

T["preferred_style"]["ignores entries outside the directory"] = function()
  eq(style({ "../base", "../other/x.yaml" }, {}), "kustomization")
  eq(style({}, {}), "kustomization")
end

T["preferred_style"]["is whatever `nested` says when it says"] = function()
  config.setup({ nested = "path" })
  eq(style({ "apps" }, { "apps/" }), "path")
  config.setup({ nested = "kustomization" })
  eq(style({ "deploy/svc.yaml" }, { "deploy/svc.yaml" }), "kustomization")
end

T["is_component"] = function()
  local root = H.project({
    ["comp/kustomization.yaml"] = H.component,
    ["quoted/kustomization.yaml"] = 'kind: "Component"\n',
    ["plain/kustomization.yaml"] = H.kustomization({}),
  })
  eq(sync.is_component(root .. "/comp/kustomization.yaml"), true)
  eq(sync.is_component(root .. "/quoted/kustomization.yaml"), true)
  eq(sync.is_component(root .. "/plain/kustomization.yaml"), false)
end

return T
