local config = require("kustomize-sync.config")
local sync = require("kustomize-sync.sync")

local M = {}

local NS = vim.api.nvim_create_namespace("kustomize-sync-diagnostics")
local GROUP = "KustomizeSyncDiagnostics"
-- How long to wait after an edit, and after an event that leaves the text
-- alone.
local TYPING_MS, SETTLED_MS = 300, 20
-- How many unlisted names the hint spells out before it starts counting.
local HINT_NAMES = 5

-- Every key that names a path, by name. `patches` has two rows; they agree on
-- everything read here.
local KEYS = { resources = sync.RESOURCES_KEY }
for _, row in ipairs(sync.REFERENCED_KEYS) do KEYS[row.key] = row end

-- Every path the kustomization names, each with the key it sits under and its
-- position. One yq spawn for the lot.
local FILTER = table.concat(vim.tbl_map(function(row)
  return "[" .. row.expr .. '[] | select(. != null) | {"key": "' .. row.key
    .. '", "value": ., "line": line, "col": column}]'
end, vim.list_extend({ sync.RESOURCES_KEY }, sync.REFERENCED_KEYS)), " + ")

-- Per buffer: `gen` and `scan` for the pending refresh, `unlisted` for the
-- last disk scan and `stamp` for the directory as that scan found it.
local state = {}
local enabled = false

-- `diagnostics = false` is what turning a feature off usually looks like, so
-- a boolean stands for the whole table.
local function options()
  local opts = config.options.diagnostics
  if type(opts) == "table" then return opts end
  return { enabled = opts == true, unlisted = opts == true }
end

-- Strictly below: the same path twice is the "listed twice" case.
local function within(path, dir)
  return path:sub(1, #dir + 1) == dir .. "/"
end

-- Fills in what an entry points at: `rel` as written (normalized), `path` on
-- disk, `stat`, and `remote`. An entry that isn't a path at all, like an
-- inline patch, gets no `rel` and is skipped from then on.
local function resolve(entry, dir)
  local row = KEYS[entry.key]
  local rel = sync.entry_path(entry.value, row.keyed)
  if not rel then return end
  entry.rel = rel
  entry.path, entry.stat = sync.entry_target(dir, rel)
  -- Stat first: is_remote also matches a local `my.dir/file.yaml`. A url is
  -- fetched by kustomize under any key, a patch as much as a base; the looser
  -- forms (`github.com/org/repo`) only mean a remote where one can be listed.
  entry.remote = not entry.stat
    and (entry.value:match("^%w[%w+.-]*://") ~= nil or row.remote and sync.is_remote(entry.value))
end

-- How many bytes the entry takes up where it is written. yq hands back the
-- value, which is shorter than a quoted scalar and unrelated to an alias.
local function written_length(entry, lines)
  local rest = (lines[entry.line] or ""):sub(entry.col)
  if rest:sub(1, #entry.value) == entry.value then return #entry.value end
  local quote = rest:match("^[\"']")
  return #(quote and rest:match("^" .. quote .. ".-" .. quote) or rest:match("^%S*"))
end

local function diagnostic(entry, lines, severity, message)
  return {
    lnum = entry.line - 1,
    col = entry.col - 1,
    end_col = entry.col - 1 + written_length(entry, lines),
    severity = severity,
    message = message,
    source = "kustomize-sync",
  }
end

-- What is wrong with the entries as written, and what .resources lists.
-- Everything here is judged by a stat of where the entry points, the way the
-- remove pass of sync does it.
local function judge(entries, dir, lines)
  local ERROR, WARN = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN
  local found, resources, listed, elsewhere = {}, {}, {}, {}

  for _, entry in ipairs(entries) do
    resolve(entry, dir)
    if entry.rel and entry.key == "resources" then
      table.insert(resources, entry)
      table.insert(listed, entry.rel)
    elseif entry.rel then
      elsewhere[entry.rel] = elsewhere[entry.rel] or entry
    end
  end

  local function add(entry, severity, message)
    table.insert(found, diagnostic(entry, lines, severity, message))
  end

  local first = {}
  for _, entry in ipairs(entries) do
    local rel = entry.rel
    local misplaced = false
    if rel and not entry.remote then
      if not entry.stat then
        add(entry, ERROR, rel .. ": no such file or directory")
      elseif entry.stat.type == "directory" and KEYS[entry.key].dir then
        local child = sync.find_kustomization(entry.path)
        local wants_component = entry.key == "components"
        if not child then
          add(entry, ERROR, rel .. " has no kustomization file")
        elseif sync.is_component(child) ~= wants_component then
          misplaced = not wants_component
          add(entry, ERROR, wants_component
            and rel .. " is not a Component; list it under resources"
            or rel .. " is a Component; list it under components")
        end
      end
    end

    if rel and entry.key == "resources" then
      if first[rel] then
        add(entry, ERROR, ("%s is listed twice (first on line %d)"):format(rel, first[rel].line))
      else
        first[rel] = entry
      end

      -- A warning, not an error: the build only fails when the directory's
      -- own kustomization lists the file as well.
      for _, other in ipairs(resources) do
        if other.stat and within(rel, other.rel) then
          add(entry, WARN, ("%s is inside %s, which line %d lists whole")
            :format(rel, other.rel, other.line))
          break
        end
      end

      -- A component under resources has been told where it belongs already.
      local use = elsewhere[rel]
      if use and not misplaced then
        add(entry, WARN, ("%s is also used under %s (line %d)"):format(rel, use.key, use.line))
      end
    end
  end
  return found, listed
end

-- Names on disk that sync would add. Costs a directory scan, so it runs on the
-- events that ask for one and is remembered in between.
local function scan_unlisted(file, dir, entries, listed)
  -- commented_set reads the file, and a buffer that was never written has none.
  if vim.fn.filereadable(file) ~= 1 then return {} end

  local elsewhere = {}
  for _, entry in ipairs(entries) do
    if entry.key ~= "resources" then table.insert(elsewhere, entry.value) end
  end
  return sync.unlisted_entries(dir, file, listed, sync.local_paths(elsewhere, dir)) or {}
end

-- The hint for unlisted names, on the `resources:` line when there is one.
local function hint(names, listed, lines)
  -- The scan may be older than the text: drop what has been typed in since.
  names = vim.tbl_filter(function(name) return not vim.list_contains(listed, name) end, names)
  if #names == 0 then return nil end

  local row = 0
  for i, line in ipairs(lines) do
    if line:match("^resources:") then
      row = i - 1
      break
    end
  end

  local shown = vim.list_slice(names, 1, HINT_NAMES)
  local message = "Not listed: " .. table.concat(shown, ", ")
  if #names > #shown then message = message .. (" and %d more"):format(#names - #shown) end
  return {
    lnum = row,
    col = 0,
    end_col = #(lines[row + 1]:match("^resources") or ""),
    severity = vim.diagnostic.severity.HINT,
    message = message,
    source = "kustomize-sync",
  }
end

-- The directory's mtime, which moves when something is added to or removed
-- from it.
local function dir_stamp(dir)
  local stat = vim.uv.fs_stat(dir)
  return stat and stat.mtime.sec .. "." .. stat.mtime.nsec
end

-- An open kustomization in an ordinary buffer.
local function checked(buf)
  return vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ""
    and sync.is_kustomization(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"))
end

-- Check one buffer. The text goes to yq on stdin, so what is flagged is what
-- is on screen, saved or not. `scan` also looks for unlisted files on disk.
--
-- yq failing means the yaml doesn't parse right now, which is the normal state
-- of a file being typed in. The last diagnostics stay up until it does.
local function refresh(buf, scan)
  -- Silent without yq: checkhealth is where that gets reported.
  if not enabled or not checked(buf) or vim.fn.executable("yq") ~= 1 then return end

  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
  local dir = vim.fn.fnamemodify(file, ":h")
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  vim.system(
    { "yq", "-o", "json", "-I0", FILTER, "-" },
    { stdin = table.concat(lines, "\n") .. "\n", text = true },
    vim.schedule_wrap(function(res)
      if not enabled or not vim.api.nvim_buf_is_loaded(buf) then return end
      local known = state[buf]

      -- -I0 puts each yaml document on a line of its own. A kustomization is
      -- the first one; anything after a `---` is not ours to judge.
      local ok, entries = false, nil
      if res.code == 0 and vim.api.nvim_buf_get_changedtick(buf) == tick then
        ok, entries = pcall(vim.json.decode, res.stdout:match("[^\n]*"))
      end
      if not ok or type(entries) ~= "table" then
        -- Nothing was published, so a scan asked for is still owed.
        if known then known.scan = known.scan or scan end
        return
      end

      local found, listed = judge(entries, dir, lines)
      if known and options().unlisted then
        if scan then
          known.stamp = dir_stamp(dir)
          known.unlisted = scan_unlisted(file, dir, entries, listed)
        end
        local unlisted = hint(known.unlisted or {}, listed, lines)
        if unlisted then table.insert(found, unlisted) end
      end

      vim.diagnostic.set(NS, buf, found)
    end)
  )
end

-- Ask for a refresh `delay` ms from now. Only the last request in a burst
-- runs, and it scans if any of them wanted to. Bursts are the normal case:
-- opening a file fires BufReadPost and BufEnter back to back, and a sync
-- announces its write just before the buffer is reloaded.
local function request(buf, scan, delay)
  if not enabled or not checked(buf) then return end
  local known = state[buf] or { gen = 0 }
  state[buf] = known
  known.gen = known.gen + 1
  known.scan = known.scan or scan

  local gen = known.gen
  vim.defer_fn(function()
    if state[buf] ~= known or known.gen ~= gen then return end
    local wants_scan = known.scan
    known.scan = false
    refresh(buf, wants_scan)
  end, delay)
end

M.setup = function()
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  enabled = options().enabled
  state = {}
  if not enabled then
    vim.diagnostic.reset(NS)
    return
  end

  local function every_buffer()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      request(buf, true, SETTLED_MS)
    end
  end

  -- A write this plugin made: the disk changed and maybe no buffer did. The
  -- kustomization itself may be open in a window the explorer's refresh
  -- doesn't reach, still showing the text from before, and the hint would
  -- then name what was just added. checktime reloads it the way 'autoread'
  -- would on the next focus.
  local function written()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if checked(buf) then pcall(vim.cmd.checktime, buf) end
    end
    every_buffer()
  end

  local pattern = sync.KUSTOMIZATION_NAMES
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    pattern = pattern,
    callback = function(args) request(args.buf, true, SETTLED_MS) end,
  })
  -- Entering is the common event, a window switch away, and the scan runs on
  -- the main loop: in path style it walks every directory below. So it is
  -- only repeated when the directory itself changed, at the cost of missing
  -- a file added deeper down until the next read or write.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = pattern,
    callback = function(args)
      local known = state[args.buf]
      local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(args.buf), ":p:h")
      request(args.buf, not known or known.stamp ~= dir_stamp(dir), SETTLED_MS)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    pattern = pattern,
    callback = function(args) request(args.buf, false, TYPING_MS) end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = pattern,
    callback = function(args) state[args.buf] = nil end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "KustomizeSyncWritten",
    callback = written,
  })

  -- setup() often runs after the first kustomization is already open.
  every_buffer()
end

return M
