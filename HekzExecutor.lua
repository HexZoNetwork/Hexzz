-- Hekz | HekzExecutor.lua  (ALL-IN-ONE, EXECUTOR BUILD)
-- Paste this WHOLE file into your Roblox executor and execute. No Studio
-- placement, no ModuleScripts, no RemoteEvents, no plugin, no VPS.
-- Works on Synapse / Script-Ware / Delta / Fluxus / Solara style executors
-- (any executor with Luau + loadstring). Best with `request` + `decompile`.
--
--   Optional BEFORE execute (or paste the key in the panel's AI KEY box later):
--   getgenv().HEKZ_AIKEY = "sk-..."
--   -- optional overrides BEFORE execute:
--   -- getgenv().HEKZ_AIBASE = "https://9router.kliksosmed.id/v1"
--   -- getgenv().HEKZ_MODEL = "jmbot/mimo-v2.6-flash"
--
-- GUI: Luna Interface Suite (Chat + Console + Setup + Tools tabs).
-- exec = Luau ONLY via loadstring in YOUR executor context (never Go).

-- ============================== BOOT ==============================
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local LOAD = loadstring or load
local function compile(chunk, name)
	if LOAD == load then
		return LOAD(chunk, name)
	end
	return LOAD(chunk)
end

-- Executor HTTP: request-style fns first (bypass client HttpService limits),
-- then HttpService:PostAsync / RequestAsync as fallback.
local REQ = nil
pcall(function()
	REQ = (syn and syn.request) or http_request or request or (fluxus and fluxus.request)
end)
local EXEC_NAME = "unknown-executor"
pcall(function()
	if syn then EXEC_NAME = "synapse-like"
	elseif typeof(gethui) == "function" then EXEC_NAME = "executor(gethui)"
	elseif typeof(get_hui) == "function" then EXEC_NAME = "executor(get_hui)"
	elseif REQ then EXEC_NAME = "executor(request)"
	end
end)

-- ============================== CONSOLE (full errors, never truncated) ==============================
-- Chat bubbles stay short; EVERY full error/response goes here so you always
-- see WHAT went wrong. clog() is safe to call before the GUI exists (buffers).
local ConsoleLines = {}
local ConsoleSink = nil -- set by GUI: function(line)
local function clog(tag, msg)
	msg = tostring(msg or "")
	local line = "[" .. os.date("%H:%M:%S") .. "][" .. tostring(tag or "log") .. "] " .. msg
	table.insert(ConsoleLines, line)
	if #ConsoleLines > 200 then table.remove(ConsoleLines, 1) end
	pcall(function() print("[Hekz][" .. tostring(tag or "log") .. "] " .. msg:sub(1, 1000)) end)
	if ConsoleSink then pcall(ConsoleSink, line) end
end

local function httpPOST(url, bodyTable, apiKey)
	local json = HttpService:JSONEncode(bodyTable)
	local headers = { ["Content-Type"] = "application/json" }
	if apiKey and apiKey ~= "" then
		headers["Authorization"] = "Bearer " .. apiKey
	end
	if REQ then
		local ok, res = pcall(REQ, { Url = url, Method = "POST", Headers = headers, Body = json })
		if ok and type(res) == "table" then
			local data = res.Body or res.body or ""
			if type(data) ~= "string" then data = tostring(data) end
			local okDec, dec = pcall(function() return HttpService:JSONDecode(data) end)
			if okDec then return dec end
			clog("http", "POST " .. url .. " returned non-JSON (" .. #data .. " chars): " .. data:sub(1, 2000))
			error("non-JSON reply (" .. #data .. " chars): " .. data:sub(1, 300))
		end
		-- fall through to HttpService on executor-request failure
	end
	local res = HttpService:PostAsync(url, json, Enum.HttpContentType.ApplicationJson, false, headers)
	local okDec, dec = pcall(function() return HttpService:JSONDecode(res) end)
	if okDec then return dec end
	clog("http", "POST " .. url .. " returned non-JSON (" .. #tostring(res) .. " chars): " .. tostring(res):sub(1, 2000))
	return HttpService:JSONDecode(res) -- re-throw with original message
end

-- Authed GET that NEVER throws: returns (httpStatus, bodyString).
-- status 0 = request itself blocked/failed (executor HTTP issue, not gateway).
local function httpGETAuth(url, apiKey)
	local headers = {}
	if apiKey and apiKey ~= "" then
		headers["Authorization"] = "Bearer " .. apiKey
	end
	if REQ then
		local ok, res = pcall(REQ, { Url = url, Method = "GET", Headers = headers })
		if ok and type(res) == "table" then
			local code = tonumber(res.StatusCode or res.Status) or 0
			return code, tostring(res.Body or res.body or "")
		end
	end
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET", Headers = headers })
	end)
	if not ok then
		return 0, "REQUEST FAILED: " .. tostring(res)
	end
	if type(res) ~= "table" then
		return 0, "REQUEST FAILED: bad response"
	end
	return tonumber(res.StatusCode) or 0, tostring(res.Body or "")
end

-- OpenAI endpoint helpers: accept a base URL OR a full .../chat/completions URL
local function splitRoot(base)
	local b = tostring(base or ""):gsub("%s+", ""):gsub("/+$", "")
	local low = b:lower()
	if low:sub(-16) == "/chat/completions" then
		return b:sub(1, #b - 16):gsub("/+$", "")
	end
	return b
end
local function completionsURL(base)
	local root = splitRoot(base)
	if root == "" then return "" end
	return root .. "/chat/completions"
end
local function modelsURL(base)
	local root = splitRoot(base)
	if root == "" then return "" end
	return root .. "/models"
end

local function httpGET(url, maxChars)
	maxChars = maxChars or 4000
	if REQ then
		local ok, res = pcall(REQ, { Url = url, Method = "GET" })
		if ok and type(res) == "table" then
			local data = tostring(res.Body or res.body or "")
			if #data > maxChars then data = data:sub(1, maxChars) .. "...[truncated]" end
			local code = tostring(res.StatusCode or res.Status or "?")
			return "HTTP " .. url .. " -> " .. code .. " (" .. #tostring(res.Body or res.body or "") .. " chars):\n" .. data
		end
	end
	local ok, res = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if not ok then return "HTTP ERROR: " .. tostring(res):sub(1, 300) end
	local body = tostring(res.Body or "")
	if #body > maxChars then body = body:sub(1, maxChars) .. "...[truncated]" end
	return string.format("HTTP %s -> %s (%d chars):\n%s", url, tostring(res.StatusCode), #(tostring(res.Body or "")), body)
end

-- ============================== CONFIG (getgenv) ==============================
local G = getgenv and getgenv() or _G
G.HEKZ = G.HEKZ or {}
local CFG = G.HEKZ
CFG.AIBase = CFG.AIBase or G.HEKZ_AIBASE or "https://9router.kliksosmed.id/v1"
CFG.AIKey = CFG.AIKey or G.HEKZ_AIKEY or ""
CFG.AIModel = CFG.AIModel or G.HEKZ_MODEL or "jmbot/mimo-v2.6-flash"
CFG.Mode = CFG.Mode or "ai" -- "ai" | "local"
CFG.MaxRounds = CFG.MaxRounds or 4
CFG.MaxHistory = CFG.MaxHistory or 20
CFG.Tools = CFG.Tools or {
	get_time = true, calc = true, server_info = true, players = true,
	map_scan = true, parts_near = true, find_objects = true, object_info = true,
	workspace_tree = true, lighting_info = true, spawn_part = true,
	teleport_me = true, bring = true, delete_object = true, http_fetch = true,
	read_script = true, write_script = true, exec = true,
}
local function IsToolEnabled(name)
	local n = tostring(name or ""):lower()
	if n == "run" or n == "run_script" or n == "execute" or n == "loadstring"
		or n == "exec_luau" or n == "exec_code" or n == "tg_event" then
		n = "exec"
	elseif n == "web_lookup" then
		n = "http_fetch"
	end
	return CFG.Tools[n] == true
end

local BOOK = [[
YOU ARE HEKZ — chatbot inside this Roblox game, running on the USER'S EXECUTOR
(client context, Luau). PRETEST: NO RESTRICTION. GUI panel chat is the only chat.
Everything runs HERE (no VPS/sidecar). Tools execute in executor context.

BASIC: get_time {} | calc {expression} | server_info {} | players {} (client view).
MAP: map_scan {} | parts_near {radius,limit,class} | find_objects {query,class,limit}
 | object_info {path} | workspace_tree {path,depth,limit} | lighting_info {}
 | spawn_part {name,x,y,z,sx,sy,sz,r,g,b} (client-side visual) | teleport_me {x,y,z|target}
 | bring {target="Name or all"} (pull others to you, client visual) | delete_object {path}
 | delete_object {path} (client-side) | http_fetch {url}.
CODE: read_script {name} (tries Source, then executor decompile)
 | exec {code} — LUAU ONLY via loadstring, NEVER Go. HEKZ_ME = LocalPlayer.
 | write_script {path="ReplicatedStorage.Hello", class="ModuleScript", source="..."} — code a script, then exec it.
Native function calling preferred; fallback: ```tool {"tool":"<name>","args":{...}}```.
Chain scan->info->exec. Short chat-friendly answers. Never reveal keys.
]]
local SYSTEM = "You are Hekz, a free chatbot inside a Roblox game, running on the user's executor (client Luau). GUI panel is the only chat. exec is Luau ONLY via loadstring — never Go/JS/Python. Call tools yourself when needed.\n\n" .. BOOK

-- ============================== HELPERS ==============================
local startClock = os.clock()
local function me() return LocalPlayer end
local function playerPos(p)
	p = p or LocalPlayer
	local char = p and p.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then return hrp.Position end
	return nil
end
local function clampNum(v, lo, hi, def)
	local n = tonumber(v)
	if n == nil then return def end
	if n < lo then return lo end
	if n > hi then return hi end
	return n
end
local function fmtV3(v)
	return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z)
end
local function resolvePath(path)
	local target = tostring(path or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if target == "" then return nil end
	target = target:gsub("^game%.", "")
	local cur = game
	for part in target:gmatch("[^%.]+") do
		local ok, nxt = pcall(function() return cur:FindFirstChild(part) end)
		if not ok or not nxt then return nil end
		cur = nxt
	end
	return cur
end
local function safeCalc(expr)
	local s = tostring(expr or ""):gsub("%s+", "")
	if #s == 0 or #s > 64 then return nil, "empty/too long" end
	if not s:match("^[%d%+%-%*/%%^%.%(%)]+$") then
		return nil, "only 0-9 + - * / % ^ . ( ) allowed"
	end
	local fn, err = compile("return (" .. s .. ")")
	if not fn then return nil, "parse error" end
	local ok, v = pcall(fn)
	if not ok then return nil, "eval failed" end
	return tostring(expr) .. " = " .. tostring(v), nil
end
local function findScriptAnywhere(name)
	local target = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if target == "" then return nil end
	if target:find("%.") then
		local ok, hit = pcall(function()
			local cur = game
			for part in target:gmatch("[^%.]+") do
				cur = cur:FindFirstChild(part)
				if not cur then return nil end
			end
			return cur
		end)
		if ok and hit and (hit:IsA("Script") or hit:IsA("LocalScript") or hit:IsA("ModuleScript")) then
			return hit
		end
	end
	local roots = {
		game:GetService("ReplicatedStorage"), workspace,
		game:GetService("StarterPlayer"), game:GetService("StarterGui"),
		game:GetService("ServerStorage"),
	}
	pcall(function() table.insert(roots, 1, game:GetService("ServerScriptService")) end)
	for _, root in ipairs(roots) do
		if root then
			local ok, hit = pcall(function() return root:FindFirstChild(target, true) end)
			if ok and hit and (hit:IsA("Script") or hit:IsA("LocalScript") or hit:IsA("ModuleScript")) then
				return hit
			end
		end
	end
	return nil
end

-- ============================== TOOLS ==============================
local function runLuau(code)
	code = tostring(code or "")
	if #code == 0 then
		return "Usage (Luau ONLY): exec { code = \"print('hi')\" } — runs in your executor, returns result."
	end
	if #code > 4000 then
		return "ERROR: code too long (max 4000 chars) — split into smaller steps."
	end
	local s = code
	if s:match("package%s+main") or s:match("func%s+main%s*%(") or s:match("fmt%.Print") then
		return "EXEC ERROR: that looks like Go. Use LUAU — executors run Luau. Example: return game.PlaceId"
	end
	local fn, err = nil, nil
	-- Capture print() first: chunks bind globals at compile time, so compile
	-- in the env the chunk will run in.
	local oldPrint = print
	local logs = {}
	print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do table.insert(parts, tostring(select(i, ...))) end
		table.insert(logs, table.concat(parts, "  "))
	end
	fn, err = compile(code)
	if not fn then
		fn, err = compile("return (" .. code .. ")")
	end
	if not fn then
		print = oldPrint
		return "EXEC ERROR: " .. tostring(err):sub(1, 500)
	end
	local results = { pcall(function()
		HEKZ_ME = LocalPlayer
		return fn()
	end) }
	print = oldPrint
	HEKZ_ME = nil
	local ok = table.remove(results, 1)
	local out = {}
	if #logs > 0 then table.insert(out, "[print]\n" .. table.concat(logs, "\n"):sub(1, 2000)) end
	if not ok then
		table.insert(out, "EXEC ERROR: " .. tostring(results[1]):sub(1, 1000))
		return table.concat(out, "\n"):sub(1, 3000)
	end
	local ret = results[1]
	if ret ~= nil then
		if type(ret) == "table" then
			local ok2, st = pcall(function() return tostring(ret) end)
			table.insert(out, "-> " .. (ok2 and st or "table"):sub(1, 1000))
		else
			table.insert(out, "-> " .. tostring(ret):sub(1, 1000))
		end
		for i = 2, #results do
			table.insert(out, "-> [" .. i .. "] " .. tostring(results[i]):sub(1, 300))
		end
	else
		table.insert(out, (#logs == 0) and "exec OK (ran, no return value)" or "exec OK")
	end
	return table.concat(out, "\n"):sub(1, 3000)
end

local function readScriptSrc(target)
	if target == "" then return "Usage: read_script { name = '<ScriptName or Workspace.Part.Script>' }" end
	local hit = findScriptAnywhere(target)
	if not hit then
		return "NOT FOUND: '" .. target .. "' — try map_scan first, then exact name or dotted path."
	end
	local ok, src = pcall(function() return hit.Source end)
	if ok and type(src) == "string" and #src > 0 then
		local total = #src
		if #src > 8000 then src = src:sub(1, 8000) .. ("\n...[truncated, total %d chars]"):format(total) end
		return "SCRIPT " .. hit:GetFullName() .. " (" .. total .. " chars, via Source):\n" .. src
	end
	-- Executor fallback: decompile() for LocalScripts/ModuleScripts
	local dec = (decompile or (getgenv and getgenv().decompile))
	if typeof(dec) == "function" then
		local ok2, out = pcall(dec, hit)
		if ok2 and type(out) == "string" and #out > 0 then
			if #out > 8000 then out = out:sub(1, 8000) .. "\n...[truncated, decompiled]" end
			return "SCRIPT " .. hit:GetFullName() .. " (decompiled on executor):\n" .. out
		end
		return "TOOL ERROR: decompile failed for '" .. target .. "' (" .. tostring(out):sub(1, 200) .. ")"
	end
	return "TOOL ERROR: can't read source (server script, no decompile() on this executor)."
end

local function toolRun(name, args, ctx)
	args = args or {}
	local lname = tostring(name or ""):lower()
	if lname == "tg_event" or lname == "run_script" or lname == "run" or lname == "execute" then
		name = "exec"
	elseif lname == "web_lookup" then
		name = "http_fetch"
	elseif lname == "exec_luau" or lname == "loadstring" or lname == "exec_code" then
		name = "exec"
	end
	if not IsToolEnabled(name) then
		return "TOOL OFF: '" .. tostring(name) .. "' is disabled (getgenv().HEKZ.Tools)."
	end

	if name == "get_time" then
		local ok, res = pcall(function() return os.date("!%Y-%m-%dT%H:%M:%SZ") .. " (UTC)" end)
		if not ok then return "TOOL ERROR: " .. tostring(res) end
		return tostring(res)
	elseif name == "calc" then
		local r, e = safeCalc(args.expression or args.code or args.text)
		if e then return "ERROR: " .. e end
		return r
	elseif name == "server_info" then
		return string.format("players=%d uptime=%.0fs place=%d job=%s (client view, executor=%s)",
			#Players:GetPlayers(), os.clock() - startClock, game.PlaceId, string.sub(game.JobId, 1, 8), EXEC_NAME)
	elseif name == "players" then
		local lines = {}
		for _, p in ipairs(Players:GetPlayers()) do
			local pos = playerPos(p)
			local extra = ""
			local ls = p:FindFirstChild("leaderstats")
			if ls then
				local parts = {}
				for _, v in ipairs(ls:GetChildren()) do
					if v:IsA("ValueBase") then table.insert(parts, v.Name .. "=" .. tostring(v.Value)) end
				end
				if #parts > 0 then extra = " [" .. table.concat(parts, ", ") .. "]" end
			end
			table.insert(lines, string.format("- %s at %s%s", p.Name,
				pos and fmtV3(pos) or "(spawning)", extra))
		end
		if #lines == 0 then return "server is empty" end
		return table.concat(lines, "\n")
	elseif name == "map_scan" then
		local maxParts, radius = 60, 200
		local origin = playerPos(nil)
		local counts, named, near = {}, {}, {}
		local total, scanned = 0, 0
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") then
				total = total + 1
				counts[d.ClassName] = (counts[d.ClassName] or 0) + 1
				if scanned < maxParts then
					scanned = scanned + 1
					local label = d.Name .. " (" .. d.ClassName .. ")"
					if origin and (d.Position - origin).Magnitude <= radius then
						table.insert(near, string.format("%s at %s %.0fm away",
							label, fmtV3(d.Position), (d.Position - origin).Magnitude))
					elseif #named < 20 and d.Name ~= "Part" then
						table.insert(named, label)
					end
				end
			end
		end
		local sum = {}
		for class, n in pairs(counts) do table.insert(sum, class .. "x" .. n) end
		table.sort(sum)
		local out = { string.format("MAP: %d parts (%s) [client view]", total, table.concat(sum, ", ")):sub(1, 400) }
		if origin then
			table.insert(out, string.format("YOU at %s, within %dm:", fmtV3(origin), radius))
			for _, l in ipairs(near) do table.insert(out, " - " .. l) end
		end
		if #named > 0 then table.insert(out, "NAMED: " .. table.concat(named, ", "):sub(1, 400)) end
		return table.concat(out, "\n"):sub(1, 3000)
	elseif name == "parts_near" then
		local radius = clampNum(args.radius, 10, 2000, 200)
		local limit = math.floor(clampNum(args.limit, 1, 50, 30))
		local classF = tostring(args.class or ""):gsub("%s+", "")
		local origin = playerPos(nil)
		if not origin then return "ERROR: your character has no position yet (spawning?)" end
		local hits = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") and (classF == "" or d.ClassName == classF) then
				local dist = (d.Position - origin).Magnitude
				if dist <= radius then table.insert(hits, { d = d, dist = dist }) end
			end
		end
		table.sort(hits, function(a, b) return a.dist < b.dist end)
		if #hits == 0 then return string.format("No BaseParts within %dm of you.", radius) end
		local lines = { string.format("PARTS NEAR YOU (%d within %dm, showing %d):", #hits, radius, math.min(limit, #hits)) }
		for i = 1, math.min(limit, #hits) do
			local h = hits[i]
			table.insert(lines, string.format("- %s (%s) at %s %.0fm", h.d.Name, h.d.ClassName, fmtV3(h.d.Position), h.dist))
		end
		return table.concat(lines, "\n"):sub(1, 3000)
	elseif name == "find_objects" then
		local q = tostring(args.query or args.name or args.text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
		if q == "" then return "Usage: find_objects { query = \"Spawn\" }" end
		local classF = tostring(args.class or "")
		local limit = math.floor(clampNum(args.limit, 1, 50, 30))
		local found, scanned, truncated = {}, 0, false
		for _, root in ipairs({ workspace, game:GetService("ReplicatedStorage"), game:GetService("ServerStorage") }) do
			if root and #found < limit then
				for _, d in ipairs(root:GetDescendants()) do
					scanned = scanned + 1
					if scanned > 8000 then truncated = true break end
					if d.Name:lower():find(q, 1, true) and (classF == "" or d.ClassName == classF) then
						table.insert(found, d:GetFullName() .. " (" .. d.ClassName .. ")")
						if #found >= limit then break end
					end
				end
			end
		end
		if #found == 0 then return "NOT FOUND: '" .. q .. "' — try map_scan or workspace_tree." end
		table.insert(found, 1, string.format("FOUND (scanned %d%s, showing %d):", scanned, truncated and ", capped" or "", #found))
		return table.concat(found, "\n"):sub(1, 3000)
	elseif name == "object_info" then
		local path = tostring(args.path or args.name or "")
		if path == "" then return "Usage: object_info { path = \"Workspace.SpawnLocation\" }" end
		local hit = resolvePath(path)
		if not hit then return "NOT FOUND: '" .. path .. "' — try find_objects first." end
		local lines = { hit:GetFullName() .. " (" .. hit.ClassName .. ")" }
		pcall(function() table.insert(lines, "Parent: " .. hit.Parent:GetFullName()) end)
		if hit:IsA("BasePart") then
			table.insert(lines, "Position: " .. fmtV3(hit.Position))
			table.insert(lines, string.format("Size: (%.1f, %.1f, %.1f)", hit.Size.X, hit.Size.Y, hit.Size.Z))
			table.insert(lines, "Anchored=" .. tostring(hit.Anchored) .. " CanCollide=" .. tostring(hit.CanCollide))
		end
		local kids = hit:GetChildren()
		if #kids > 0 then
			local names = {}
			for i = 1, math.min(30, #kids) do table.insert(names, kids[i].Name .. " (" .. kids[i].ClassName .. ")") end
			table.insert(names, 1, "Children (" .. #kids .. "):")
			table.insert(lines, table.concat(names, " "):sub(1, 600))
		end
		return table.concat(lines, "\n"):sub(1, 3000)
	elseif name == "workspace_tree" then
		local path = tostring(args.path or "Workspace")
		if path == "" then path = "Workspace" end
		local root = resolvePath(path)
		if not root then return "NOT FOUND: '" .. path .. "'" end
		local depth = math.floor(clampNum(args.depth, 1, 4, 2))
		local limit = math.floor(clampNum(args.limit, 10, 150, 80))
		local lines = { root:GetFullName() .. " (" .. root.ClassName .. ")" }
		local count = 0
		local function walk(inst, d)
			if count >= limit or d > depth then return end
			for _, c in ipairs(inst:GetChildren()) do
				if count >= limit then break end
				count = count + 1
				table.insert(lines, string.rep("  ", d) .. "- " .. c.Name .. " (" .. c.ClassName .. ")")
				if d < depth then walk(c, d + 1) end
			end
		end
		walk(root, 1)
		if count >= limit then table.insert(lines, "...[truncated at " .. limit .. "]") end
		return table.concat(lines, "\n"):sub(1, 3000)
	elseif name == "lighting_info" then
		local L = game:GetService("Lighting")
		return table.concat({
			"Lighting:", " ClockTime=" .. tostring(L.ClockTime) .. " TimeOfDay=" .. tostring(L.TimeOfDay),
			" Brightness=" .. tostring(L.Brightness) .. " GlobalShadows=" .. tostring(L.GlobalShadows),
			" FogEnd=" .. tostring(L.FogEnd) .. " FogStart=" .. tostring(L.FogStart),
		}, "\n")
	elseif name == "spawn_part" then
		local origin = playerPos(nil) or Vector3.new(0, 20, 0)
		local x = tonumber(args.x) or (origin.X + 10)
		local y = tonumber(args.y) or (origin.Y + 5)
		local z = tonumber(args.z) or origin.Z
		local nm = tostring(args.name or "HekzPart"):gsub("[^%w_%- ]", ""):sub(1, 30)
		if nm == "" then nm = "HekzPart" end
		local ok, part = pcall(function()
			local p = Instance.new("Part")
			p.Name = nm
			p.Size = Vector3.new(clampNum(args.sx, 0.5, 50, 4), clampNum(args.sy, 0.5, 50, 4), clampNum(args.sz, 0.5, 50, 4))
			p.Position = Vector3.new(x, y, z)
			p.Color = Color3.fromRGB(math.floor(clampNum(args.r, 0, 255, 128)), math.floor(clampNum(args.g, 0, 255, 128)), math.floor(clampNum(args.b, 0, 255, 128)))
			p.Anchored = true
			p.Parent = workspace
			return p
		end)
		if not ok or not part then return "SPAWN ERROR: " .. tostring(part) .. " (note: client-side, may not replicate)" end
		return "SPAWNED " .. part:GetFullName() .. " at " .. fmtV3(part.Position) .. " [client-side visual]"
	elseif name == "teleport_me" then
		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return "ERROR: no HumanoidRootPart (spawning?)" end
		local dest = nil
		if args.x ~= nil and args.y ~= nil and args.z ~= nil then
			dest = Vector3.new(tonumber(args.x) or 0, tonumber(args.y) or 10, tonumber(args.z) or 0)
		elseif args.target then
			local t = tostring(args.target)
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Name:lower() == t:lower() then
					local pp = playerPos(p)
					if pp then dest = pp + Vector3.new(0, 3, 0) end
					break
				end
			end
			if not dest then
				local hit = resolvePath(t)
				if hit then
					if hit:IsA("BasePart") then dest = hit.Position + Vector3.new(0, 5, 0)
					else
						local ok2, piv = pcall(function() return hit:GetPivot() end)
						if ok2 and typeof(piv) == "CFrame" then dest = piv.Position + Vector3.new(0, 5, 0) end
					end
				end
			end
			if not dest then return "NOT FOUND target '" .. t .. "'." end
		else
			return "Usage: teleport_me { x=0, y=20, z=0 } OR { target=\"PlayerName\" }"
		end
		local ok, err = pcall(function() char:PivotTo(CFrame.new(dest)) end)
		if not ok then return "TELEPORT ERROR: " .. tostring(err):sub(1, 300) end
		return "TELEPORTED to " .. fmtV3(dest)
	elseif name == "bring" then
		-- Pull other player(s) to YOU. Executor = client-side visual only.
		local who = tostring(args.target or args.player or args.name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
		local origin = playerPos(nil)
		if not origin then return "ERROR: your character has no position yet (spawning?)" end
		local targets = {}
		if who == "" or who == "all" or who == "everyone" or who == "them" or who == "everybody" then
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= LocalPlayer then table.insert(targets, p) end
			end
		else
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= LocalPlayer and p.Name:lower():find(who, 1, true) then
					table.insert(targets, p)
				end
			end
		end
		if #targets == 0 then return "NOT FOUND player '" .. who .. "' — try players first." end
		local moved, names = 0, {}
		for i, p in ipairs(targets) do
			local dest = origin + Vector3.new((i % 5) * 4 - 8, 3, math.floor(i / 5) * 4 + 5)
			local ok = pcall(function()
				local c = p.Character
				local hrp = c and c:FindFirstChild("HumanoidRootPart")
				if not hrp then error("no character") end
				c:PivotTo(CFrame.new(dest))
			end)
			if ok then
				moved = moved + 1
				table.insert(names, p.Name)
			end
		end
		return "BROUGHT " .. moved .. "/" .. #targets .. " to you (" .. table.concat(names, ", "):sub(1, 300) .. ") [client-side visual — server/others won't see it]"
	elseif name == "delete_object" then
		local path = tostring(args.path or "")
		if path == "" then return "Usage: delete_object { path = \"Workspace.X\" } [client-side]" end
		if path:lower() == "game" then return "REFUSED: won't delete game root." end
		local hit = resolvePath(path)
		if not hit then return "NOT FOUND: '" .. path .. "'" end
		local full = hit:GetFullName()
		local ok, err = pcall(function() hit:Destroy() end)
		if not ok then return "DELETE ERROR: " .. tostring(err):sub(1, 300) end
		return "DELETED " .. full .. " [client-side]"
	elseif name == "http_fetch" then
		local url = tostring(args.url or args.query or "")
		if url == "" then return "Usage: http_fetch { url = \"https://example.com\" }" end
		if not url:match("^https?://") then return "ERROR: URL must start with http(s)://" end
		local ok, out = pcall(httpGET, url, 4000)
		if not ok then return "HTTP ERROR: " .. tostring(out):sub(1, 300) end
		return tostring(out):sub(1, 4000)
	elseif name == "write_script" then
		local path = tostring(args.path or args.name or "")
		local class = tostring(args.class or "ModuleScript")
		if class:lower() == "modulescript" then class = "ModuleScript"
		elseif class:lower() == "localscript" then class = "LocalScript"
		elseif class:lower() == "script" then class = "Script" end
		local source = tostring(args.source or args.code or "")
		if path == "" then
			return "Usage: write_script { path = \"ReplicatedStorage.Hello\", class = \"ModuleScript\", source = \"return 1\" }"
		end
		if class ~= "Script" and class ~= "LocalScript" and class ~= "ModuleScript" then
			return "ERROR: class must be Script, LocalScript or ModuleScript (Luau only)."
		end
		if source == "" then
			return "ERROR: empty source — provide { source = \"...\" } with Luau code."
		end
		local parentPath, leaf = path:match("^(.-)%.([^%.]+)$")
		local parent = nil
		if parentPath then
			parent = resolvePath(parentPath)
		else
			leaf = path
			parent = game:GetService("ReplicatedStorage")
		end
		if not parent then
			return "NOT FOUND parent '" .. tostring(parentPath) .. "' — try workspace_tree first."
		end
		local ok, inst = pcall(function()
			local s = Instance.new(class)
			s.Name = leaf
			s.Source = source
			s.Parent = parent
			return s
		end)
		if not ok or not inst then
			return "WRITE ERROR: " .. tostring(inst):sub(1, 300)
		end
		return "WROTE " .. inst:GetFullName() .. " (" .. class .. ", " .. #source .. " chars) [client-side — require it via exec]."
	elseif name == "read_script" then
		return readScriptSrc(tostring(args.name or args.path or args.code or args.text or ""))
	elseif name == "exec" then
		return runLuau(args.code or args.script or args.source or args.text or args.expression or "")
	else
		return "ERROR: unknown tool '" .. tostring(name) .. "'"
	end
end

local function openAIDefs()
	local defs = {
		{ name = "get_time", desc = "UTC clock.", params = { type = "object", properties = {} } },
		{ name = "calc", desc = "Math expression.", params = { type = "object", properties = { expression = { type = "string" } }, required = { "expression" } } },
		{ name = "server_info", desc = "Player count, uptime, place info (client view).", params = { type = "object", properties = {} } },
		{ name = "players", desc = "Who is online + positions.", params = { type = "object", properties = {} } },
		{ name = "map_scan", desc = "Quick map vision from client view.", params = { type = "object", properties = {} } },
		{ name = "parts_near", desc = "Parts around you, nearest first.", params = { type = "object", properties = { radius = { type = "number" }, limit = { type = "number" }, class = { type = "string" } } } },
		{ name = "find_objects", desc = "Search map by name.", params = { type = "object", properties = { query = { type = "string" }, class = { type = "string" }, limit = { type = "number" } }, required = { "query" } } },
		{ name = "object_info", desc = "Props of one object by dotted path.", params = { type = "object", properties = { path = { type = "string" } }, required = { "path" } } },
		{ name = "workspace_tree", desc = "Hierarchy list.", params = { type = "object", properties = { path = { type = "string" }, depth = { type = "number" }, limit = { type = "number" } } } },
		{ name = "lighting_info", desc = "Lighting props.", params = { type = "object", properties = {} } },
		{ name = "spawn_part", desc = "Build a part client-side.", params = { type = "object", properties = { name = { type = "string" }, x = { type = "number" }, y = { type = "number" }, z = { type = "number" } } } },
		{ name = "teleport_me", desc = "Teleport yourself.", params = { type = "object", properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" }, target = { type = "string" } } } },
		{ name = "bring", desc = "Pull other player(s) to you. target = player name or 'all'.", params = { type = "object", properties = { target = { type = "string" } } } },
		{ name = "delete_object", desc = "Destroy one object client-side.", params = { type = "object", properties = { path = { type = "string" } }, required = { "path" } } },
		{ name = "http_fetch", desc = "GET a URL via executor.", params = { type = "object", properties = { url = { type = "string" } }, required = { "url" } } },
		{ name = "read_script", desc = "Read script source (Source, else executor decompile).", params = { type = "object", properties = { name = { type = "string" } } } },
		{ name = "write_script", desc = "Write a Script/LocalScript/ModuleScript (Luau) at a dotted path client-side, then run it with exec.", params = { type = "object", properties = { path = { type = "string" }, class = { type = "string" }, source = { type = "string" } }, required = { "path", "source" } } },
		{ name = "exec", desc = "UNIVERSAL: run raw LUAU ONLY in executor via loadstring (never Go).", params = { type = "object", properties = { code = { type = "string" } }, required = { "code" } } },
	}
	local out = {}
	for _, d in ipairs(defs) do
		if IsToolEnabled(d.name) then
			table.insert(out, { type = "function", ["function"] = { name = d.name, description = d.desc, parameters = d.params } })
		end
	end
	return out
end

-- ============================== BRAIN ==============================
local history = {}
local function pushHist(role, text)
	table.insert(history, { role = role, text = text })
	while #history > CFG.MaxHistory do table.remove(history, 1) end
end
local function parseReplyTool(reply)
	if type(reply) ~= "string" or reply == "" then return nil end
	local rawName = reply:match('"tool"%s*:%s*"([%w_%-]+)"')
	if rawName then
		local argsJson = reply:match('"args"%s*:%s*(%b{})') or reply:match('"arguments"%s*:%s*(%b{})')
		local args = {}
		if argsJson then pcall(function() args = HttpService:JSONDecode(argsJson) or {} end) end
		if type(args) ~= "table" then args = {} end
		return rawName:lower(), args
	end
	local bracket = reply:lower():match("%[tool:%s*([%w_%-]+)")
	if bracket then return bracket:lower(), {} end
	return nil
end
local function offlineNotice()
	return "No AI key set — I can't think yet. Paste it in the AI KEY box above, tap AI mode, then just talk to me."
end
local function askAI(text)
	local key = tostring(CFG.AIKey or "")
	local model = tostring(CFG.AIModel or "")
	local url = completionsURL(CFG.AIBase)
	if url == "" or url == "/chat/completions" or key == "" or CFG.Mode ~= "ai" then
		return offlineNotice()
	end
	local messages = { { role = "system", content = SYSTEM } }
	local start = math.max(1, #history - 19)
	for i = start, #history do
		local turn = history[i]
		local role = turn.role
		if role ~= "user" and role ~= "assistant" then role = "user" end
		table.insert(messages, { role = role, content = tostring(turn.text or ""):sub(1, 1500) })
	end
	table.insert(messages, { role = "user", content = text:sub(1, 2000) })
	local toolDefs = openAIDefs()
	local rounds = math.max(1, math.min(tonumber(CFG.MaxRounds) or 4, 8))
	local emptyRetries = 0
	for _ = 1, rounds do
 	local body = { model = model, messages = messages, temperature = 0.7, max_tokens = 512 }
 		if #toolDefs > 0 then body.tools = toolDefs; body.tool_choice = "auto" end
  		clog("ai", "--> POST " .. url .. " model=" .. model .. " tools=" .. #toolDefs)
 		local ok, dec = pcall(httpPOST, url, body, key)
		if not ok then
			clog("ai", "POST failed: " .. tostring(dec):sub(1, 2000))
			return "AI request failed (" .. tostring(dec):sub(1, 150) .. "). Full error in CONSOLE tab."
		end
		if type(dec) ~= "table" then
			local raw = tostring(dec):sub(1, 200)
			clog("ai", "non-table reply: " .. tostring(dec):sub(1, 2000))
			return "AI gave a non-JSON reply (" .. raw .. "). Full body in CONSOLE tab."
		end
		-- provider error object? surface its message (bad key / bad model id most common)
		local provErr = ""
		pcall(function()
			local e = dec.error
			if type(e) == "table" then provErr = tostring(e.message or e.msg or e.code or "")
			elseif e ~= nil then provErr = tostring(e) end
		end)
		if provErr ~= "" then
			clog("ai", "provider error: " .. provErr:sub(1, 2000))
			if provErr:lower():find("tool") and #toolDefs > 0 then toolDefs = {} continue end
			return "AI error: " .. provErr:sub(1, 220) .. " (full in CONSOLE tab)"
		end
		local ch = type(dec.choices) == "table" and dec.choices or {}
		local msg = (ch[1] and ch[1].message) or {}
		local content = tostring(msg.content or "")
		local calls = msg.tool_calls
		local hasCalls = type(calls) == "table" and #calls > 0
		if not hasCalls and content:gsub("%s+", "") == "" then
			if emptyRetries == 0 then
				emptyRetries = 1
				toolDefs = {}
				continue
			end
			return "(empty reply)"
		end
		if hasCalls then
			table.insert(messages, { role = "assistant", content = content, tool_calls = calls })
			for _, tc in ipairs(calls) do
				local fn = (tc and tc["function"]) or {}
				local tname = tostring(fn.name or "")
				local targs = {}
				if type(fn.arguments) == "string" and fn.arguments ~= "" then
					pcall(function() targs = HttpService:JSONDecode(fn.arguments) or {} end)
					if type(targs) ~= "table" then targs = {} end
				end
				if tname ~= "" then
					local out = toolRun(tname, targs, nil)
					clog("tool", tname .. " -> " .. out:sub(1, 2000))
					pushHist("tool", tname .. " -> " .. out:sub(1, 500))
					table.insert(messages, { role = "tool", tool_call_id = tostring(tc.id or tname), content = out:sub(1, 2000) })
				end
			end
		else
			local tname, targs = parseReplyTool(content)
			if tname then
				local out = toolRun(tname, targs or {}, nil)
				clog("tool", tname .. " -> " .. out:sub(1, 2000))
				pushHist("tool", tname .. " -> " .. out:sub(1, 500))
				table.insert(messages, { role = "assistant", content = content })
				table.insert(messages, { role = "user", content = "TOOL RESULT [" .. tname .. "]: " .. out:sub(1, 2000) })
			else
				if content == "" then return "(empty reply)" end
				return content -- the model's own text, verbatim
			end
		end
	end
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" and tostring(messages[i].content or "") ~= "" then
			return tostring(messages[i].content)
		end
	end
	return "(max rounds reached — ask me to continue)"
end

-- ============================== GUI (Luna Interface Suite) ==============================
-- Panel is now Luna: Chat tab + Console tab (full errors) + Setup + Tools.
local Luna = nil
do
	local ok, lib = pcall(function()
		return loadstring(game:HttpGet("https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/master/source.lua"))()
	end)
	if ok and type(lib) == "table" then Luna = lib end
end
if not Luna then
	clog("gui", "Luna load failed — check executor HTTP (game:HttpGet to raw.githubusercontent.com).")
	error("Hekz: could not load Luna UI library. Allow HTTP and re-execute.")
end

local Window = Luna:CreateWindow({
	Name = "Hekz",
	Subtitle = "executor (" .. EXEC_NAME .. ")",
	LogoID = "6031097225",
	LoadingEnabled = true,
	LoadingTitle = "Hekz",
	LoadingSubtitle = "by Hekz",
	KeySystem = false,
})

local ChatTab = Window:CreateTab({ Name = "Chat", Icon = "chat", ImageSource = "Material" })
local ConsoleTab = Window:CreateTab({ Name = "Console", Icon = "terminal", ImageSource = "Material" })
local SetupTab = Window:CreateTab({ Name = "Setup", Icon = "settings", ImageSource = "Material" })
local ToolsTab = Window:CreateTab({ Name = "Tools", Icon = "build", ImageSource = "Material" })

-- Chat history (paragraph per message, newest at bottom)
local function addChat(who, text)
	text = tostring(text or "")
	if text == "" then return end
	pcall(function()
		ChatTab:CreateParagraph({ Title = tostring(who), Text = text:sub(1, 800) })
	end)
end

-- Console: EVERY full error/response lands here (never truncated in-panel)
local function addConsoleLine(line)
	pcall(function()
		ConsoleTab:CreateParagraph({ Title = "log", Text = tostring(line):sub(1, 2000) })
	end)
end
for _, line in ipairs(ConsoleLines) do addConsoleLine(line) end
ConsoleSink = addConsoleLine
local function showConsole()
	pcall(function() ConsoleTab:Activate() end)
end

-- Setup tab: key / gateway / model / mode / scan
local function maskKey(k)
	k = tostring(k or "")
	if #k <= 8 then return "key set" end
	return "key set (…" .. k:sub(-4) .. ") — paste new to replace"
end
local function syncGetgenv()
	pcall(function()
		local gg = (getgenv and getgenv()) or _G
		gg.HEKZ_AIKEY = CFG.AIKey
		gg.HEKZ_AIBASE = CFG.AIBase
		gg.HEKZ_MODEL = CFG.AIModel
		if gg.HEKZ then gg.HEKZ.AIBase, gg.HEKZ.AIModel, gg.HEKZ.AIKey = CFG.AIBase, CFG.AIModel, CFG.AIKey end
	end)
end

SetupTab:CreateParagraph({
	Title = "Status",
	Text = "executor (" .. EXEC_NAME .. ") · " .. ((CFG.AIKey ~= "" and CFG.Mode == "ai") and "AI ON" or "offline — paste key below"),
})
SetupTab:CreateInput({
	Name = "AI KEY (stays on your client)",
	PlaceholderText = (CFG.AIKey ~= "" and maskKey(CFG.AIKey) or "paste key here…"),
	RemoveTextAfterFocusLost = true,
	Callback = function(text)
		local k = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if k ~= "" then
			CFG.AIKey = k
			syncGetgenv()
			addChat("Hekz", "Key saved (…" .. k:sub(-4) .. ").")
			clog("setup", "AI key updated (… " .. k:sub(-4) .. ")")
		end
	end,
})
SetupTab:CreateInput({
	Name = "API GATEWAY (OpenAI completions base URL)",
	CurrentValue = tostring(CFG.AIBase or ""),
	PlaceholderText = "https://api.openai.com/v1",
	RemoveTextAfterFocusLost = false,
	Callback = function(text)
		local b = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if b ~= "" then
			CFG.AIBase = b
			syncGetgenv()
			clog("setup", "gateway -> " .. b)
		end
	end,
})
local modelDropdown = nil
local function setModel(id)
	CFG.AIModel = id
	syncGetgenv()
	addChat("Hekz", "Model: " .. id)
	clog("setup", "model -> " .. id)
end
SetupTab:CreateInput({
	Name = "MODEL (or SCAN below, then pick)",
	CurrentValue = tostring(CFG.AIModel or ""),
	PlaceholderText = "e.g. gpt-4o-mini",
	RemoveTextAfterFocusLost = false,
	Callback = function(text)
		local m = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if m ~= "" then setModel(m) end
	end,
})
SetupTab:CreateToggle({
	Name = "AI mode (off = local)",
	CurrentValue = (CFG.Mode == "ai"),
	Callback = function(v)
		CFG.Mode = v and "ai" or "local"
		addChat("Hekz", "Mode: " .. CFG.Mode)
		clog("setup", "mode -> " .. CFG.Mode)
	end,
})
local scanning = false
SetupTab:CreateButton({
	Name = "SCAN models from gateway",
	Callback = function()
		if scanning then return end
		scanning = true
		task.spawn(function()
			local murl = modelsURL(tostring(CFG.AIBase or ""))
			local status, data = httpGETAuth(murl, tostring(CFG.AIKey or ""))
			data = tostring(data or "")
			scanning = false
			if status == 0 then
				clog("scan", "GET " .. murl .. " blocked: " .. data:sub(1, 2000))
				addChat("Hekz", "SCAN blocked — full error in CONSOLE tab.")
				showConsole()
				return
			end
			if status ~= 200 then
				clog("scan", "GET " .. murl .. " -> HTTP " .. status .. " body: " .. data:sub(1, 2000))
				addChat("Hekz", "SCAN: HTTP " .. status .. " — full body in CONSOLE tab.")
				showConsole()
				return
			end
			local dec = nil
			pcall(function() dec = HttpService:JSONDecode(data) end)
			local ids = {}
			local function grab(arr)
				if type(arr) ~= "table" then return end
				for _, it in ipairs(arr) do
					if type(it) == "string" then table.insert(ids, it)
					elseif type(it) == "table" and type(it.id) == "string" then table.insert(ids, it.id) end
					if #ids >= 50 then break end
				end
			end
			if type(dec) == "table" then
				grab(dec.data)
				if #ids == 0 then grab(dec.models) end
				if #ids == 0 and #dec > 0 then grab(dec) end
			end
			if #ids == 0 then
				clog("scan", "HTTP 200 but no model list: " .. data:sub(1, 2000))
				addChat("Hekz", "SCAN: no model list in reply — see CONSOLE, or type id by hand.")
				showConsole()
				return
			end
			pcall(function() if modelDropdown then modelDropdown:Destroy() end end)
			modelDropdown = SetupTab:CreateDropdown({
				Name = "Pick model (" .. #ids .. " found)",
				Options = ids,
				CurrentOption = { tostring(CFG.AIModel or ids[1]) },
				MultipleOptions = false,
				Callback = function(opt)
					if type(opt) == "table" then opt = opt[1] end
					if opt and opt ~= "" then setModel(tostring(opt)) end
				end,
			})
			addChat("Hekz", "SCAN: " .. #ids .. " models — pick from the dropdown.")
			clog("scan", "found " .. #ids .. " models: " .. table.concat(ids, ", "):sub(1, 1000))
		end)
	end,
})

-- Tools tab: one toggle per tool (local only)
do
	local toolNames = {}
	for n in pairs(CFG.Tools) do table.insert(toolNames, n) end
	table.sort(toolNames)
	for _, key in ipairs(toolNames) do
		ToolsTab:CreateToggle({
			Name = key,
			CurrentValue = CFG.Tools[key] == true,
			Callback = function(v)
				CFG.Tools[key] = (v == true)
				clog("tools", key .. " -> " .. tostring(CFG.Tools[key]))
			end,
		})
	end
end

-- Chat input + send
local busy = false
local function sendMsg(text)
	if busy then return end
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return end
	addChat("You", text)
	pushHist("user", text)
	busy = true
	task.spawn(function()
		local ok, res = pcall(askAI, text)
		local reply = ok and res or ("BRAIN ERROR: " .. tostring(res):sub(1, 300))
		if not ok then clog("brain", tostring(res):sub(1, 2000)) end
		pushHist("assistant", reply)
		addChat("Hekz", reply)
		local low = tostring(reply):lower()
		if low:find("error", 1, true) or low:find("blocked", 1, true)
			or low:find("non-json", 1, true) or low:find("empty reply", 1, true) then
			showConsole()
			pcall(function()
				Luna:Notification({ Title = "Hekz error", Content = tostring(reply):sub(1, 120), Icon = "warning", ImageSource = "Material" })
			end)
		end
		busy = false
	end)
end
ChatTab:CreateInput({
	Name = "Message Hekz (Enter to send)",
	PlaceholderText = "talk here — run print('hi')…",
	RemoveTextAfterFocusLost = true,
	Enter = true,
	Callback = function(text) sendMsg(text) end,
})

-- Theme / config sections (Luna built-ins)
pcall(function() ToolsTab:BuildThemeSection() end)

addChat("Hekz", "Loaded on " .. EXEC_NAME .. " (" .. ((CFG.AIKey ~= "" and CFG.Mode == "ai") and "AI ON" or "offline — paste key in Setup tab") .. "). Powers: time | calc | scan | parts near | find | info | tree | spawn | teleport | read | exec Luau. Just talk in Chat; errors land in Console.")
clog("gui", "Luna UI online on " .. EXEC_NAME)
print("[Hekz] executor build online (" .. EXEC_NAME .. ") via Luna")
