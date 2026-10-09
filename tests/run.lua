-- Usage (from the repository root): lua tests/run.lua
local dir = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "tests"
local H = dofile(dir .. "/harness.lua")

for _, file in ipairs({ "test_store.lua", "test_upgrades.lua", "test_features.lua", "test_sim.lua", "test_ui_smoke.lua" }) do
	local chunk = assert(loadfile(dir .. "/" .. file))
	chunk(H)
end

print(("\n%d passed, %d failed"):format(H.results.passed, H.results.failed))
os.exit(H.results.failed == 0 and 0 or 1)
