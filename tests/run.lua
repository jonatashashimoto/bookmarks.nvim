local test_file = debug.getinfo(1, "S").source:sub(2)
local test_dir = test_file:match("^(.*)/[^/]+$") or "."
local tests = dofile(test_dir .. "/project_persistence_spec.lua")

for i, test_fn in ipairs(tests) do
   local ok, err = pcall(test_fn)
   if not ok then
      io.stderr:write(string.format("test %d failed: %s\n", i, err))
      os.exit(1)
   end
end

print(string.format("%d tests passed", #tests))
