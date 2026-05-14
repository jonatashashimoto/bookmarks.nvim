local config = require("bookmarks.config").config
local schema = require("bookmarks.config").schema
local uv = vim.loop
local Signs = require "bookmarks.signs"
local utils = require "bookmarks.util"
local api = vim.api
local current_buf = api.nvim_get_current_buf
local M = {}
local signs
local active_save_file
local active_project_root

local function reset_cache()
   config.cache = vim.deepcopy(schema.cache.default)
   config.marks = nil
end

local function get_git_root(filepath)
   local dir = vim.fn.fnamemodify(filepath, ":p:h")
   local gitdir = vim.fn.finddir(".git", dir .. ";")
   if gitdir == "" then
      return nil
   end
   return vim.fn.fnamemodify(gitdir, ":p:h")
end

local function get_project_save_file(project_root)
   if not project_root then
      return config.save_file
   end
   return project_root .. "/.bookmarks"
end

local function resolve_save_file(bufnr)
   if not config.per_project then
      return config.save_file, nil
   end
   local filepath = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   if filepath == nil then
      return config.save_file, nil
   end
   local project_root = get_git_root(filepath)
   if not project_root then
      return config.save_file, nil
   end
   return get_project_save_file(project_root), project_root
end

local function current_save_file()
   return active_save_file or config.save_file
end

local function switch_project(bufnr)
   bufnr = bufnr or current_buf()
   local next_save_file, next_project_root = resolve_save_file(bufnr)
   if active_save_file == next_save_file then
      return
   end
   if active_save_file ~= nil then
      M.saveBookmarks()
   end
   active_save_file = next_save_file
   active_project_root = next_project_root
   reset_cache()
   M.loadBookmarks()
end

M.setup = function()
   signs = Signs.new(config.signs)
   active_save_file = nil
   active_project_root = nil
   reset_cache()
end

M.detach = function(bufnr, keep_signs)
   if not keep_signs then
      signs:remove(bufnr)
   end
end

local function updateBookmarks(bufnr, lnum, mark, ann)
   switch_project(bufnr)
   local filepath = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   if filepath == nil then
      return
   end
   local data = config.cache["data"]
   local marks = data[filepath]
   local isIns = false
   if lnum == -1 then
      marks = nil
      isIns = true
      -- check buffer auto_save to file
   end
   local line_count = api.nvim_buf_line_count(bufnr)
   for k, _ in pairs(marks or {}) do
      if k == tostring(lnum) then
         isIns = true
         if mark == "" then
            marks[k] = nil
         end
         break
      elseif tonumber(k) > line_count then
         marks[k] = nil
      end
   end
   if isIns == false or ann then
      marks = marks or {}
      marks[tostring(lnum)] = ann and { m = mark, a = ann } or { m = mark }
      -- check buffer auto_save to file
      -- M.saveBookmarks()
   end
   data[filepath] = marks
end

M.toggle_signs = function(value)
   if value ~= nil then
      config.signcolumn = value
   else
      config.signcolumn = not config.signcolumn
   end
   M.refresh()
   return config.signcolumn
end

M.bookmark_toggle = function()
   local lnum = api.nvim_win_get_cursor(0)[1]
   local bufnr = current_buf()
   local signlines = { {
      type = "add",
      lnum = lnum,
   } }
   local isExt = signs:add(bufnr, signlines)
   if isExt then
      signs:remove(bufnr, lnum)
      updateBookmarks(bufnr, lnum, "")
   else
      local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
      updateBookmarks(bufnr, lnum, line)
   end
end

M.bookmark_clean = function()
   local bufnr = current_buf()
   signs:remove(bufnr)
   updateBookmarks(bufnr, -1, "")
end

M.bookmark_line = function(lnum, bufnr)
   bufnr = bufnr or current_buf()
   switch_project(bufnr)
   local file = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   local marks = config.cache["data"][file] or {}
   return lnum and marks[tostring(lnum)] or marks
end

M.bookmark_ann = function()
   local lnum = api.nvim_win_get_cursor(0)[1]
   local bufnr = current_buf()
   local signlines = { {
      type = "ann",
      lnum = lnum,
   } }
   local mark = M.bookmark_line(lnum, bufnr)
   vim.ui.input({ prompt = "Edit:", default = mark.a }, function(answer)
      if answer == nil then return end
      local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
      signs:remove(bufnr, lnum)
      local text = config.keywords[string.sub(answer or "", 1, 2)]
      if text then
         signlines[1]["text"] = text
      end
      signs:add(bufnr, signlines)
      updateBookmarks(bufnr, lnum, line, answer)
   end)
end

local jump_line = function(prev)
   local lnum = api.nvim_win_get_cursor(0)[1]
   local marks = M.bookmark_line()
   local small, big = {}, {}
   for k, _ in pairs(marks) do
      k = tonumber(k)
      if k < lnum then
         table.insert(small, k)
      elseif k > lnum then
         table.insert(big, k)
      end
   end
   if prev then
      local tmp = #small > 0 and small or big
      table.sort(tmp, function(a, b)
         return a > b
      end)
      lnum = tmp[1]
   else
      local tmp = #big > 0 and big or small
      table.sort(tmp)
      lnum = tmp[1]
   end
   if lnum then
      api.nvim_win_set_cursor(0, { lnum, 0 })
      local mark = marks[tostring(lnum)]
      if mark.a then
         api.nvim_echo({ { "ann: " .. mark.a, "WarningMsg" } }, false, {})
      else
      end
   end
end

M.bookmark_prev = function()
   jump_line(true)
end

M.bookmark_next = function()
   jump_line(false)
end

M.bookmark_list = function()
   local allmarks = config.cache.data
   local marklist = {}
   for k, ma in pairs(allmarks) do
      if utils.path_exists(k) == false then
         allmarks[k] = nil
      end
      for l, v in pairs(ma) do
         table.insert(marklist, { filename = k, lnum = l, text = v.m .. "|" .. (v.a or "") })
      end
   end
   utils.setqflist(marklist)
end

M.refresh = function(bufnr)
   bufnr = bufnr or current_buf()
   switch_project(bufnr)
   local file = uv.fs_realpath(api.nvim_buf_get_name(bufnr))
   if file == nil then
      return
   end
   local marks = config.cache.data[file]
   local signlines = {}
   if marks then
      for k, v in pairs(marks) do
         local ma = {
            type = v.a and "ann" or "add",
            lnum = tonumber(k),
         }
         local pref = string.sub(v.a or "", 1, 2)
         local text = config.keywords[pref]
         if text then
            ma["text"] = text
         end
         signs:remove(bufnr, ma.lnum)
         table.insert(signlines, ma)
      end
      signs:add(bufnr, signlines)
   end
end

function M.loadBookmarks()
   local save_file = current_save_file()
   if utils.path_exists(save_file) then
      utils.read_file(save_file, function(data)
         config.cache = vim.json.decode(data)
         config.marks = data
      end)
   else
      reset_cache()
   end
end

function M.saveBookmarks()
   local data = vim.json.encode(config.cache)
   if config.marks ~= data then
      utils.write_file(current_save_file(), data)
      config.marks = data
   end
end

function M.bookmark_clear_all()
   reset_cache()
   M.saveBookmarks()
end

function M.switch_project(bufnr)
   switch_project(bufnr)
end

function M.current_project_root()
   return active_project_root
end

function M.current_save_file()
   return current_save_file()
end

return M
