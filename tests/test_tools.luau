-- ToolRegistry unit tests (mocked Roblox, real Luau). Returns fail count.
local T = HekzTest
local check = T.check
local Tools = T.Tools
local failsA = 0
local function markA(ok, label, extra)
	if not ok then failsA += 1 end
	check(ok, label, extra)
end

-- calc
markA(Tools:run("calc", { expression = "(2+3)*4" }) == "(2+3)*4 = 20", "calc basic")
markA(Tools:run("calc", { expression = "abc" }):find("ERROR") ~= nil, "calc rejects letters")
markA(Tools:run("calc", { expression = "" }):find("ERROR") ~= nil, "calc rejects empty")

-- time
local tm = Tools:run("get_time", {})
markA(tm:find("^%d%d%d%d%-%d%d%-%d%dT") ~= nil and tm:find("UTC") ~= nil, "get_time format", tm)

-- exec direct + print capture + aliases + Go guard
local r1 = Tools:run("exec", { code = "return 1+1" })
markA(r1:find("-> 2") ~= nil, "exec bare expression", r1)
local r2 = Tools:run("exec", { code = "print('hi')" })
markA(r2:find("%[print%]") ~= nil and r2:find("hi") ~= nil, "exec print capture", r2)
local r3 = Tools:run("run", { code = "return 6*7" })
markA(r3:find("-> 42") ~= nil, "exec alias run", r3)
local r4 = Tools:run("exec", { code = "package main\nfunc main() {}" })
markA(r4:find("LUAU") ~= nil, "exec rejects Go", r4)
markA(Tools:run("nope_tool", {}):find("TOOL OFF") ~= nil, "unknown tool rejected")

-- enabled toggle
T.Config.Tools.calc.Value = false
markA(Tools:run("calc", { expression = "1+1" }):find("TOOL OFF") ~= nil, "disabled tool blocked")
T.Config.Tools.calc.Value = true
markA(T.Config.IsToolEnabled("run") == true, "alias run enabled")
markA(T.Config.IsToolEnabled("web_lookup") == true, "alias web_lookup->http_fetch enabled")

-- write_script then read/exec round-trip
local w = Tools:run("write_script", { path = "ReplicatedStorage.Hello", class = "ModuleScript", source = "return 42" })
markA(w:find("WROTE") ~= nil and w:find("ReplicatedStorage.Hello") ~= nil, "write_script creates", w)
markA(Tools:run("write_script", { path = "ReplicatedStorage.X", source = "" }):find("empty source") ~= nil, "write rejects empty source")
markA(Tools:run("write_script", { path = "Nope.Nothing", source = "x" }):find("NOT FOUND parent") ~= nil, "write bad parent")
markA(Tools:run("read_script", { name = "NoSuchScriptXYZ" }):find("NOT FOUND") ~= nil, "read missing script")

-- teleport + bring with mock players
local me = T.makePlayer("Me", 1)
local alice = T.makePlayer("Alice", 2)
local bob = T.makePlayer("Bob", 3)
T.playersList[1], T.playersList[2], T.playersList[3] = me, alice, bob
local tp = Tools:run("teleport_me", { x = 0, y = 20, z = 0 }, { player = me })
markA(tp:find("TELEPORTED") ~= nil, "teleport_me xyz", tp)
local br = Tools:run("bring", { target = "all" }, { player = me })
markA(br:find("BROUGHT 2/2") ~= nil and br:find("Alice") ~= nil, "bring all", br)
local br1 = Tools:run("bring", { target = "bob" }, { player = me })
markA(br1:find("BROUGHT 1/1") ~= nil, "bring one by name", br1)
markA(Tools:run("bring", { target = "NobodyHere" }, { player = me }):find("NOT FOUND") ~= nil, "bring unknown name")

-- server info + defs build
markA(Tools:run("server_info", {}):find("players=3") ~= nil, "server_info count")
local defs = Tools:openAIDefs()
local hasExec, hasWrite = false, false
for _, d in ipairs(defs) do
	if d["function"].name == "exec" then hasExec = true end
	if d["function"].name == "write_script" then hasWrite = true end
end
markA(hasExec and hasWrite and #defs >= 10, "openAIDefs complete (" .. #defs .. " tools)")

__F1 = failsA
