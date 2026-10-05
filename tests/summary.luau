-- Bundle tail: totals + non-zero exit on failure (via error, no os.exit in Luau).
local __fails = __F1 + __F2
M.realPrint(string.format("== TOTAL: %d failed ==", __fails))
if __fails > 0 then
	error("hekz tests failed: " .. __fails)
end
M.realPrint("ALL HEKZ TESTS PASSED")
