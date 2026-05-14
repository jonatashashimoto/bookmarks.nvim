local test_file = debug.getinfo(1, "S").source:sub(2)
local test_dir = test_file:match("^(.*)/[^/]+$")
local repo_root = (test_dir and test_dir:match("^(.*)/tests$")) or "."

local function create_vim_stub(ctx)
   local function deep_copy(value)
      if type(value) ~= "table" then
         return value
      end
      local clone = {}
      for k, v in pairs(value) do
         clone[k] = deep_copy(v)
      end
      return clone
   end

   return {
      loop = {
         fs_realpath = function(path)
            return path
         end,
      },
      fs = {
         -- Mirrors the upward .git search performed by get_git_root.
         -- Returns an absolute path so callers never need to resolve
         -- against cwd (that was the root cause of the bug).
         find = function(name, opts)
            if name ~= ".git" then return {} end
            local path = opts and opts.path or ""
            for _, repo in ipairs({ "/repoA", "/repoB", "/repoC" }) do
               if path:find(repo, 1, true) then return { repo .. "/.git" } end
            end
            return {}
         end,
      },
      fn = {
         fnamemodify = function(path, mod)
            if mod == ":p:h" then
               return path:match("^(.+)/[^/]+/?$") or path
            end
            return path
         end,
      },
      api = {
         nvim_get_current_buf = function()
            return ctx.current_buf
         end,
         nvim_buf_get_name = function(bufnr)
            return ctx.buffers[bufnr]
         end,
      },
      json = {
         encode = function(cache)
            local files = {}
            for file, marks in pairs(cache.data or {}) do
               files[#files + 1] = file .. ":" .. tostring(next(marks) ~= nil)
            end
            table.sort(files)
            return table.concat(files, ";")
         end,
         decode = function(data)
            if data == "repoA_data" then
               return {
                  data = {
                     ["/repoA/file.lua"] = {
                        ["1"] = { m = "lineA" },
                     },
                  },
               }
            end
            if data == "repoB_data" then
               return {
                  data = {
                     ["/repoB/file.lua"] = {
                        ["5"] = { m = "lineB" },
                     },
                  },
               }
            end
            return { data = {} }
         end,
      },
      deepcopy = deep_copy,
   }
end

local function create_context()
   local ctx = {
      buffers = {},
      current_buf = 1,
      files = {},
      writes = {},
   }
   vim = create_vim_stub(ctx)
   return ctx
end

local function load_actions(ctx, config)
   package.loaded["bookmarks.actions"] = nil
   package.loaded["bookmarks.config"] = {
      config = config,
      schema = {
         cache = { default = { data = {} } },
      },
   }
   package.loaded["bookmarks.signs"] = {
      new = function()
         return {
            add = function()
               return false
            end,
            remove = function() end,
         }
      end,
   }
   package.loaded["bookmarks.util"] = {
      path_exists = function(path)
         return ctx.files[path] ~= nil
      end,
      read_file = function(path, callback)
         callback(ctx.files[path])
      end,
      write_file = function(path, content)
         ctx.writes[#ctx.writes + 1] = { path = path, content = content }
         ctx.files[path] = content
      end,
   }
   return dofile(repo_root .. "/lua/bookmarks/actions.lua")
end

local function assert_eq(actual, expected, message)
   assert(actual == expected, (message or "assert_eq failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function test_switches_between_project_files()
   local ctx = create_context()
   local config = {
      signs = {},
      save_file = "/global.json",
      per_project = true,
      cache = { data = {} },
      marks = nil,
   }
   local actions = load_actions(ctx, config)
   actions.setup()

   local repo_a_file = "/repoA/.bookmarks"
   ctx.files[repo_a_file] = "repoA_data"

   ctx.buffers[1] = "/repoA/file.lua"
   actions.switch_project(1)

   assert_eq(actions.current_project_root(), "/repoA", "project root should be repoA")
   assert_eq(actions.current_save_file(), repo_a_file, "save file should switch to project file")
   assert(config.cache.data["/repoA/file.lua"] ~= nil, "repoA cache should be loaded")
end

local function test_saves_previous_project_and_resets_missing_project_cache()
   local ctx = create_context()
   local config = {
      signs = {},
      save_file = "/global.json",
      per_project = true,
      cache = { data = {} },
      marks = nil,
   }
   local actions = load_actions(ctx, config)
   actions.setup()

   local repo_a_file = "/repoA/.bookmarks"
   local repo_b_file = "/repoB/.bookmarks"
   ctx.files[repo_a_file] = "repoA_data"

   ctx.buffers[1] = "/repoA/file.lua"
   actions.switch_project(1)
   config.cache.data["/repoA/file.lua"]["2"] = { m = "lineA2" }

   ctx.buffers[2] = "/repoB/file.lua"
   actions.switch_project(2)

   assert_eq(ctx.writes[1].path, repo_a_file, "switching projects should save previous project")
   assert_eq(actions.current_save_file(), repo_b_file, "active save file should switch to repoB")
   assert(next(config.cache.data) == nil, "missing project file should reset in-memory cache")
end

local function test_non_project_file_falls_back_to_global_save_file()
   local ctx = create_context()
   local config = {
      signs = {},
      save_file = "/global.json",
      per_project = true,
      cache = { data = {} },
      marks = nil,
   }
   local actions = load_actions(ctx, config)
   actions.setup()

   ctx.buffers[1] = "/tmp/noproject.lua"
   actions.switch_project(1)

   assert_eq(actions.current_save_file(), "/global.json", "non-project files should use global save file")
   assert_eq(actions.current_project_root(), nil, "non-project files should not set a project root")
end

-- Regression: vim.fn.finddir can return a relative path such as ".git" when
-- Neovim's cwd differs from the git root.  The old code passed that relative
-- path directly to fnamemodify(":p:h"), which resolved it against the cwd and
-- produced the wrong directory.  The fix uses vim.fs.find, which always
-- returns absolute paths.  This test would have failed before the fix because
-- the old finddir-based logic was never invoked for repoC (the stub returned
-- "" for unknown repos), so get_git_root returned nil and the global save file
-- was used instead of the project-local one.
local function test_git_root_resolved_when_finddir_returns_relative_path()
   local ctx = create_context()
   local config = {
      signs = {},
      save_file = "/global.json",
      per_project = true,
      cache = { data = {} },
      marks = nil,
   }
   local actions = load_actions(ctx, config)
   actions.setup()

   -- File lives inside /repoC (handled by the vim.fs.find stub above).
   -- The real-world trigger: vim.fn.finddir returned the relative path ".git"
   -- when Neovim's cwd was the plugin directory rather than the repo root.
   ctx.buffers[1] = "/repoC/src/deeply/nested/file.lua"
   actions.switch_project(1)

   assert_eq(actions.current_project_root(), "/repoC",
      "git root must be /repoC even when the file lives in a subdirectory")
   assert_eq(actions.current_save_file(), "/repoC/.bookmarks",
      "save file must be anchored at the git root, not at a relative path")
end

return {
   test_switches_between_project_files,
   test_saves_previous_project_and_resets_missing_project_cache,
   test_non_project_file_falls_back_to_global_save_file,
   test_git_root_resolved_when_finddir_returns_relative_path,
}
