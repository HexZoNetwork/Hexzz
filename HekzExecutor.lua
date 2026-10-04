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
-- GUI: same dark H panel (toggles + chat log + input). Chat in the panel.
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
			return HttpService:JSONDecode(data)
		end
		-- fall through to HttpService on executor-request failure
	end
	local res = HttpService:PostAsync(url, json, Enum.HttpContentType.ApplicationJson, false, headers)
	return HttpService:JSONDecode(res)
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
	teleport_me = true, delete_object = true, http_fetch = true,
	read_script = true, exec = true,
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
 | delete_object {path} (client-side) | http_fetch {url}.
CODE: read_script {name} (tries Source, then executor decompile)
 | exec {code} — LUAU ONLY via loadstring, NEVER Go. _G.HEKZ_ME = LocalPlayer.
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
	local fn, err = compile(code)
	if not fn then
		fn, err = compile("return (" .. code .. ")")
	end
	if not fn then
		return "EXEC ERROR: " .. tostring(err):sub(1, 500)
	end
	local oldPrint = print
	local logs = {}
	print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do table.insert(parts, tostring(select(i, ...))) end
		table.insert(logs, table.concat(parts, "  "))
	end
	local results = { pcall(function()
		_G.HEKZ_ME = LocalPlayer
		return fn()
	end) }
	print = oldPrint
	_G.HEKZ_ME = nil
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
		{ name = "delete_object", desc = "Destroy one object client-side.", params = { type = "object", properties = { path = { type = "string" } }, required = { "path" } } },
		{ name = "http_fetch", desc = "GET a URL via executor.", params = { type = "object", properties = { url = { type = "string" } }, required = { "url" } } },
		{ name = "read_script", desc = "Read script source (Source, else executor decompile).", params = { type = "object", properties = { name = { type = "string" } } } },
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
local function routeLocal(text)
	local t = text:lower()
	if t:find("time") or t:find("clock") or t:find("date") then
		return toolRun("get_time", {}, nil)
	elseif t:find("calc") or t:match("[%d][%+%-%*/%^][%d]") then
		local expr = text:match("[%d%+%-%*/%%^%s%.%(%)]+")
		return toolRun("calc", { expression = expr or text }, nil)
	elseif t:find("teleport") or t:find("bring me") or t:find("take me") or t:find("tp me") then
		local x, y, z = text:match("(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)")
		if x then return toolRun("teleport_me", { x = tonumber(x), y = tonumber(y), z = tonumber(z) }, nil) end
		return toolRun("teleport_me", { target = text:match("to%s+([%w%.%_%-]+)") or "" }, nil)
	elseif t:find("spawn") or t:find("create part") or t:find("build") then
		return toolRun("spawn_part", { name = text:match("spawn%s+([%w_%-]+)") or "HekzPart" }, nil)
	elseif t:find("delete") or t:find("destroy") or t:find("remove") then
		return toolRun("delete_object", { path = text:match("delete%s+([%w%.%_%-]+)") or text:match("destroy%s+([%w%.%_%-]+)") or "" }, nil)
	elseif t:find("parts near") or t:find("nearby") or t:find("near me") or t:find("around me") then
		return toolRun("parts_near", {}, nil)
	elseif t:find("find") or (t:find("search") and not t:find("web")) then
		return toolRun("find_objects", { query = text:match("find%s+([%w_%-]+)") or text }, nil)
	elseif t:find("info on") or t:find("inspect") or t:find("object info") then
		return toolRun("object_info", { path = text:match("Workspace%.[%w%.%_%-]+") or "" }, nil)
	elseif t:find("tree") or t:find("hierarchy") or t:find("list workspace") then
		return toolRun("workspace_tree", { path = text:match("Workspace%.[%w%.%_%-]+") or "Workspace" }, nil)
	elseif t:find("light") or t:find("time of day") or t:find("fog") then
		return toolRun("lighting_info", {}, nil)
	elseif t:find("fetch") or t:find("http") or text:match("https?://") then
		return toolRun("http_fetch", { url = text:match("(https?://%S+)") or "" }, nil)
	elseif t:find("scan") or t:find("map") or t:find("see") or t:find("look") or t:find("around") or t:find("vision") then
		return toolRun("map_scan", {}, nil)
	elseif t:find("who") or t:find("player") or t:find("here") or t:find("online") then
		return toolRun("players", {}, nil)
	elseif t:find("read") or t:find("script") or t:find("source") then
		local block = text:match("```[Ll][Uu][Aa][Uu]?%s*(.-)%s*```") or text:match("```%s*(.-)%s*```")
		if block and #block > 0 then return toolRun("exec", { code = block }, nil) end
		return toolRun("read_script", { name = text:match("read%s+([%w%.%_%-]+)") or "" }, nil)
	elseif t:find("run") or t:find("exec") or t:find("execute") or t:find("loadstring") or text:match("```") then
		local block = text:match("```[Ll][Uu][Aa][Uu]?%s*(.-)%s*```") or text:match("```%s*(.-)%s*```")
		return toolRun("exec", { code = block or text:match("[Rr][Uu][Nn]%s+(.+)") or text }, nil)
	elseif t:find("server") or t:find("uptime") then
		return toolRun("server_info", {}, nil)
	elseif t:find("help") or t:find("command") or t:find("tool") or t:find("what can you") or t:find("book") or t:find("power") then
		local lines = { "Hekz (executor) — NO RESTRICTION, Luau ONLY. Tools:" }
		for n, on in pairs(CFG.Tools) do table.insert(lines, string.format(" - %s [%s]", n, on and "ON" or "OFF")) end
		table.insert(lines, "Try: scan the map | parts near me | find Spawn | spawn a part | teleport me | read MyScript | run print('hi')")
		return table.concat(lines, "\n")
	else
		return "Hekz here (executor, " .. EXEC_NAME .. "). You said: " .. text .. "\nI can: time | calc | scan | parts near | find | info | tree | spawn | teleport | read | exec Luau. Just ask."
	end
end
local function askAI(text)
	local base = tostring(CFG.AIBase or ""):gsub("/+$", "")
	local key = tostring(CFG.AIKey or "")
	local model = tostring(CFG.AIModel or "")
	if base == "" or key == "" or CFG.Mode ~= "ai" then
		return routeLocal(text) .. ((CFG.Mode == "ai" and key == "") and "\n\n(tip: set getgenv().HEKZ_AIKEY then re-execute for full AI)" or "")
	end
	local url = base .. "/chat/completions"
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
	for _ = 1, rounds do
		local body = { model = model, messages = messages, temperature = 0.7, max_tokens = 512 }
		if #toolDefs > 0 then body.tools = toolDefs; body.tool_choice = "auto" end
		local ok, dec = pcall(httpPOST, url, body, key)
		if not ok then
			return "AI unreachable (" .. tostring(dec):sub(1, 150) .. "). Using local brain.\n" .. routeLocal(text)
		end
		if type(dec) ~= "table" or type(dec.choices) ~= "table" or #dec.choices == 0 then
			local errM = ""
			pcall(function() errM = tostring(dec.error and dec.error.message or "") end)
			if errM:lower():find("tool") and #toolDefs > 0 then toolDefs = {} continue end
			return routeLocal(text)
		end
		local msg = dec.choices[1].message or {}
		local content = tostring(msg.content or "")
		local calls = msg.tool_calls
		if type(calls) == "table" and #calls > 0 then
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
					pushHist("tool", tname .. " -> " .. out:sub(1, 500))
					table.insert(messages, { role = "tool", tool_call_id = tostring(tc.id or tname), content = out:sub(1, 2000) })
				end
			end
		else
			local tname, targs = parseReplyTool(content)
			if tname then
				local out = toolRun(tname, targs or {}, nil)
				pushHist("tool", tname .. " -> " .. out:sub(1, 500))
				table.insert(messages, { role = "assistant", content = content })
				table.insert(messages, { role = "user", content = "TOOL RESULT [" .. tname .. "]: " .. out:sub(1, 2000) })
			else
				if content == "" then return routeLocal(text) end
				return content
			end
		end
	end
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" and tostring(messages[i].content or "") ~= "" then
			return tostring(messages[i].content)
		end
	end
	return routeLocal(text)
end

-- ============================== GUI (same dark H panel) ==============================
local parentGui = nil
pcall(function()
	if typeof(gethui) == "function" then parentGui = gethui()
	elseif typeof(get_hui) == "function" then parentGui = get_hui() end
end)
if not parentGui then
	pcall(function() parentGui = game:GetService("CoreGui") end)
end
if not parentGui then
	parentGui = LocalPlayer:WaitForChild("PlayerGui")
end
pcall(function()
	local old = parentGui:FindFirstChild("Hekz")
	if old then old:Destroy() end
end)

local BG = Color3.fromRGB(18, 18, 20)
local SURF = Color3.fromRGB(30, 30, 34)
local BORDER = Color3.fromRGB(70, 70, 76)
local TXT = Color3.fromRGB(240, 240, 242)
local DIM = Color3.fromRGB(150, 150, 156)
local ONC = Color3.fromRGB(46, 204, 113)
local OFFC = Color3.fromRGB(231, 76, 60)
local ACCENT = Color3.fromRGB(79, 109, 245) -- modern indigo (your bubbles)
local BUBBLE = Color3.fromRGB(35, 35, 41) -- hekz bubbles

local gui = Instance.new("ScreenGui")
gui.Name = "Hekz"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
pcall(function() gui.DisplayOrder = 999 end)
pcall(function()
	if typeof(protectgui) == "function" then protectgui(gui) end
end)
gui.Parent = parentGui

local function tween(obj, props, time, style)
	pcall(function()
		TweenService:Create(obj, TweenInfo.new(time or 0.28, style or Enum.EasingStyle.Quart, Enum.EasingDirection.Out), props):Play()
	end)
end

local fab = Instance.new("TextButton")
fab.Name = "Fab"
fab.Size = UDim2.new(0, 52, 0, 52)
fab.Position = UDim2.new(1, -68, 1, -140)
fab.BackgroundColor3 = Color3.fromRGB(10, 10, 12) -- black H button
fab.Text = "H"
fab.Font = Enum.Font.GothamBold
fab.TextSize = 22
fab.TextColor3 = Color3.fromRGB(255, 255, 255)
fab.AutoButtonColor = false
fab.ZIndex = 50
fab.LayoutOrder = 999
fab.Parent = gui
local fabCorner = Instance.new("UICorner") fabCorner.CornerRadius = UDim.new(1, 0) fabCorner.Parent = fab
local fabStroke = Instance.new("UIStroke") fabStroke.Color = BORDER fabStroke.Thickness = 2 fabStroke.Parent = fab
local function fabPop()
	tween(fab, { Size = UDim2.new(0, 44, 0, 44) }, 0.08)
	task.delay(0.08, function()
		tween(fab, { Size = UDim2.new(0, 52, 0, 52) }, 0.22, Enum.EasingStyle.Back)
	end)
end

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.new(0, 340, 0, 620)
panel.Position = UDim2.new(1, -364, 1, -780)
panel.BackgroundColor3 = BG
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
local pCorner = Instance.new("UICorner") pCorner.CornerRadius = UDim.new(0, 18) pCorner.Parent = panel
local pStroke = Instance.new("UIStroke") pStroke.Color = BORDER pStroke.Thickness = 1 pStroke.Parent = panel

-- Modern header: avatar + title + live status dot + close (drag by header)
local avatar = Instance.new("TextLabel")
avatar.Size = UDim2.new(0, 30, 0, 30)
avatar.Position = UDim2.new(0, 12, 0, 11)
avatar.BackgroundColor3 = ACCENT
avatar.Text = "H"
avatar.Font = Enum.Font.GothamBold
avatar.TextSize = 15
avatar.TextColor3 = Color3.fromRGB(255, 255, 255)
avatar.Parent = panel
local avCorner = Instance.new("UICorner") avCorner.CornerRadius = UDim.new(1, 0) avCorner.Parent = avatar

local header = Instance.new("TextLabel")
header.Size = UDim2.new(1, -116, 0, 40)
header.Position = UDim2.new(0, 48, 0, 8)
header.BackgroundTransparency = 1
header.Text = "HEKZ"
header.Font = Enum.Font.GothamBold
header.TextSize = 16
header.TextXAlignment = Enum.TextXAlignment.Left
header.TextColor3 = TXT
header.Parent = panel

local statusDot = Instance.new("Frame")
statusDot.Name = "Status"
statusDot.Size = UDim2.new(0, 10, 0, 10)
statusDot.Position = UDim2.new(1, -56, 0, 19)
statusDot.BackgroundColor3 = (CFG.AIKey ~= "" and CFG.Mode == "ai") and ONC or DIM
statusDot.BorderSizePixel = 0
statusDot.Parent = panel
local dotCorner = Instance.new("UICorner") dotCorner.CornerRadius = UDim.new(1, 0) dotCorner.Parent = statusDot

-- Close (X) button: hides panel, H button reopens it
local closeBtn = Instance.new("TextButton")
closeBtn.Name = "Close"
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -38, 0, 12)
closeBtn.BackgroundColor3 = SURF
closeBtn.Text = "X"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.TextColor3 = OFFC
closeBtn.AutoButtonColor = false
closeBtn.Parent = panel
local xCorner = Instance.new("UICorner") xCorner.CornerRadius = UDim.new(1, 0) xCorner.Parent = closeBtn
local xStroke = Instance.new("UIStroke") xStroke.Color = BORDER xStroke.Thickness = 1 xStroke.Parent = closeBtn

-- Draggable panel: drag by the header (mouse + touch, executor-safe)
local anchor = panel.Position -- remembered spot; open/close animates around it
do
	local dragging, dragStart, startPos = false, nil, nil
	header.Active = true
	header.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = inp.Position
			startPos = panel.Position
			inp.Changed:Connect(function()
				if inp.UserInputState == Enum.UserInputState.End then
					dragging = false
					anchor = panel.Position
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
			local d = inp.Position - dragStart
			panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

local sub = Instance.new("TextLabel")
sub.Size = UDim2.new(1, -24, 0, 18)
sub.Position = UDim2.new(0, 12, 0, 42)
sub.BackgroundTransparency = 1
sub.Text = "executor (" .. EXEC_NAME .. ") · " .. (CFG.AIKey ~= "" and "AI ON" or "offline (paste key below)")
sub.Font = Enum.Font.Gotham
sub.TextSize = 12
sub.TextXAlignment = Enum.TextXAlignment.Left
sub.TextColor3 = DIM
sub.Parent = panel

-- AI KEY box (set key in-GUI, stays on your client, also syncs getgenv)
local keyLabel = Instance.new("TextLabel")
keyLabel.Size = UDim2.new(1, -24, 0, 16)
keyLabel.Position = UDim2.new(0, 12, 0, 62)
keyLabel.BackgroundTransparency = 1
keyLabel.Text = "AI KEY (stays on your client)"
keyLabel.Font = Enum.Font.GothamBold
keyLabel.TextSize = 11
keyLabel.TextXAlignment = Enum.TextXAlignment.Left
keyLabel.TextColor3 = DIM
keyLabel.Parent = panel

local keyBox = Instance.new("TextBox")
keyBox.Size = UDim2.new(1, -136, 0, 32)
keyBox.Position = UDim2.new(0, 12, 0, 80)
keyBox.BackgroundColor3 = SURF
keyBox.PlaceholderText = "paste key here…"
keyBox.PlaceholderColor3 = DIM
keyBox.Text = ""
keyBox.Font = Enum.Font.Gotham
keyBox.TextSize = 12
keyBox.TextColor3 = TXT
keyBox.ClearTextOnFocus = false
keyBox.Parent = panel
local kCorner = Instance.new("UICorner") kCorner.CornerRadius = UDim.new(0, 10) kCorner.Parent = keyBox
local kStroke = Instance.new("UIStroke") kStroke.Color = BORDER kStroke.Parent = keyBox

local saveBtn = Instance.new("TextButton")
saveBtn.Size = UDim2.new(0, 56, 0, 32)
saveBtn.Position = UDim2.new(1, -124, 0, 80)
saveBtn.BackgroundColor3 = SURF
saveBtn.Text = "SAVE"
saveBtn.Font = Enum.Font.GothamBold
saveBtn.TextSize = 12
saveBtn.TextColor3 = TXT
saveBtn.AutoButtonColor = false
saveBtn.Parent = panel
local sCorner = Instance.new("UICorner") sCorner.CornerRadius = UDim.new(0, 10) sCorner.Parent = saveBtn
local sStroke = Instance.new("UIStroke") sStroke.Color = BORDER sStroke.Parent = saveBtn

local modeBtn = Instance.new("TextButton")
modeBtn.Size = UDim2.new(0, 56, 0, 32)
modeBtn.Position = UDim2.new(1, -64, 0, 80)
modeBtn.Text = (CFG.Mode == "ai") and "AI" or "LOCAL"
modeBtn.Font = Enum.Font.GothamBold
modeBtn.TextSize = 12
modeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
modeBtn.BackgroundColor3 = (CFG.Mode == "ai") and ONC or OFFC
modeBtn.AutoButtonColor = false
modeBtn.Parent = panel
local mCorner = Instance.new("UICorner") mCorner.CornerRadius = UDim.new(0, 10) mCorner.Parent = modeBtn

local togLabel = Instance.new("TextLabel")
togLabel.Size = UDim2.new(1, -24, 0, 16)
togLabel.Position = UDim2.new(0, 12, 0, 118)
togLabel.BackgroundTransparency = 1
togLabel.Text = "TOGGLES"
togLabel.Font = Enum.Font.GothamBold
togLabel.TextSize = 11
togLabel.TextXAlignment = Enum.TextXAlignment.Left
togLabel.TextColor3 = DIM
togLabel.Parent = panel

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -24, 0, 120)
list.Position = UDim2.new(0, 12, 0, 136)
list.BackgroundTransparency = 1
list.ScrollBarThickness = 4
list.ScrollBarImageColor3 = BORDER
list.CanvasSize = UDim2.new(0, 0, 0, 0)
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = panel
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.Parent = list

local chatLabel = Instance.new("TextLabel")
chatLabel.Size = UDim2.new(1, -24, 0, 16)
chatLabel.Position = UDim2.new(0, 12, 0, 264)
chatLabel.BackgroundTransparency = 1
chatLabel.Text = "CHAT"
chatLabel.Font = Enum.Font.GothamBold
chatLabel.TextSize = 11
chatLabel.TextXAlignment = Enum.TextXAlignment.Left
chatLabel.TextColor3 = DIM
chatLabel.Parent = panel

local chatLog = Instance.new("ScrollingFrame")
chatLog.Size = UDim2.new(1, -24, 0, 180)
chatLog.Position = UDim2.new(0, 12, 0, 282)
chatLog.BackgroundColor3 = SURF
chatLog.BorderSizePixel = 0
chatLog.ScrollBarThickness = 4
chatLog.ScrollBarImageColor3 = BORDER
chatLog.CanvasSize = UDim2.new(0, 0, 0, 0)
chatLog.AutomaticCanvasSize = Enum.AutomaticSize.Y
chatLog.Parent = panel
local chatCorner = Instance.new("UICorner") chatCorner.CornerRadius = UDim.new(0, 10) chatCorner.Parent = chatLog
local chatLayout = Instance.new("UIListLayout")
chatLayout.Padding = UDim.new(0, 6)
chatLayout.SortOrder = Enum.SortOrder.LayoutOrder
chatLayout.Parent = chatLog

local input = Instance.new("TextBox")
input.Size = UDim2.new(1, -68, 0, 38)
input.Position = UDim2.new(0, 12, 1, -48)
input.BackgroundColor3 = SURF
input.PlaceholderText = "talk here — run print('hi')…"
input.PlaceholderColor3 = DIM
input.Text = ""
input.Font = Enum.Font.Gotham
input.TextSize = 13
input.TextColor3 = TXT
input.ClearTextOnFocus = false
input.Parent = panel
local iCorner = Instance.new("UICorner") iCorner.CornerRadius = UDim.new(1, 0) iCorner.Parent = input
local iStroke = Instance.new("UIStroke") iStroke.Color = BORDER iStroke.Parent = input

local sendBtn = Instance.new("TextButton")
sendBtn.Name = "Send"
sendBtn.Size = UDim2.new(0, 38, 0, 38)
sendBtn.Position = UDim2.new(1, -50, 1, -48)
sendBtn.BackgroundColor3 = ACCENT
sendBtn.Text = "»"
sendBtn.Font = Enum.Font.GothamBold
sendBtn.TextSize = 20
sendBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
sendBtn.AutoButtonColor = false
sendBtn.Parent = panel
local sendCorner = Instance.new("UICorner") sendCorner.CornerRadius = UDim.new(1, 0) sendCorner.Parent = sendBtn

local chatOrder = 0
local function scrollDown()
	task.delay(0.05, function()
		pcall(function()
			chatLog.CanvasPosition = Vector2.new(0, math.max(0, chatLog.AbsoluteCanvasSize.Y - chatLog.AbsoluteWindowSize.Y))
		end)
	end)
end
local function maxBubbleW()
	local w = 230
	pcall(function()
		local aw = chatLog.AbsoluteWindowSize.X
		if aw and aw > 100 then w = aw - 70 end
	end)
	return math.max(120, w)
end
-- Modern chat bubble. Returns holder + body label (for the typing dots).
local function makeBubble(mine, nameText, bodyText, animate)
	chatOrder = chatOrder + 1
	local holder = Instance.new("Frame")
	holder.Name = "M"
	holder.LayoutOrder = chatOrder
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.BackgroundTransparency = 1
	holder.Parent = chatLog
	local bubble = Instance.new("Frame")
	bubble.AnchorPoint = mine and Vector2.new(1, 0) or Vector2.new(0, 0)
	bubble.Position = mine and UDim2.new(1, -6, 0, 8) or UDim2.new(0, 6, 0, 8)
	bubble.Size = UDim2.new(0, 0, 0, 0)
	bubble.AutomaticSize = Enum.AutomaticSize.XY
	bubble.BackgroundColor3 = mine and ACCENT or BUBBLE
	bubble.BackgroundTransparency = animate and 1 or 0
	bubble.BorderSizePixel = 0
	bubble.Parent = holder
	local bc = Instance.new("UICorner") bc.CornerRadius = UDim.new(0, 14) bc.Parent = bubble
	local cap = Instance.new("UISizeConstraint") cap.MaxSize = Vector2.new(maxBubbleW(), 100000) cap.Parent = bubble
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10) pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 8) pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = bubble
	local bl = Instance.new("UIListLayout")
	bl.Padding = UDim.new(0, 2)
	bl.SortOrder = Enum.SortOrder.LayoutOrder
	bl.Parent = bubble
	local nameLbl = nil
	if nameText and nameText ~= "" then
		nameLbl = Instance.new("TextLabel")
		nameLbl.LayoutOrder = 1
		nameLbl.Size = UDim2.new(1, 0, 0, 12)
		nameLbl.AutomaticSize = Enum.AutomaticSize.Y
		nameLbl.BackgroundTransparency = 1
		nameLbl.Font = Enum.Font.GothamBold
		nameLbl.TextSize = 10
		nameLbl.TextColor3 = DIM
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.Text = nameText
		nameLbl.TextTransparency = animate and 1 or 0
		nameLbl.Parent = bubble
	end
	local msg = Instance.new("TextLabel")
	msg.LayoutOrder = 2
	msg.Size = UDim2.new(1, 0, 0, 0)
	msg.AutomaticSize = Enum.AutomaticSize.Y
	msg.BackgroundTransparency = 1
	msg.Font = Enum.Font.Gotham
	msg.TextSize = 13
	msg.TextColor3 = mine and Color3.fromRGB(255, 255, 255) or TXT
	msg.TextXAlignment = Enum.TextXAlignment.Left
	msg.TextYAlignment = Enum.TextYAlignment.Top
	msg.TextWrapped = true
	msg.Text = tostring(bodyText or ""):sub(1, 800)
	msg.TextTransparency = animate and 1 or 0
	msg.Parent = bubble
	if animate then
		local target = mine and UDim2.new(1, -6, 0, 0) or UDim2.new(0, 6, 0, 0)
		tween(bubble, { BackgroundTransparency = 0, Position = target }, 0.22)
		tween(msg, { TextTransparency = 0 }, 0.22)
		if nameLbl then tween(nameLbl, { TextTransparency = 0 }, 0.22) end
	end
	scrollDown()
	return holder, msg
end
local function addChat(who, text)
	text = tostring(text or "")
	if text == "" then return end
	if who == "You" then
		makeBubble(true, "", text, true)
	else
		makeBubble(false, "HEKZ", text, true)
	end
end
-- Typing indicator bubble ("..." pulsing) while the brain works
local typingHolder, typingDots, typingStop = nil, nil, false
local function hideTyping()
	typingStop = true
	if typingHolder then pcall(function() typingHolder:Destroy() end) end
	typingHolder, typingDots = nil, nil
end
local function showTyping()
	hideTyping()
	typingStop = false
	typingHolder, typingDots = makeBubble(false, "HEKZ", ".  ", false)
	task.spawn(function()
		local frames = { ".  ", ".. ", "..." }
		local i = 0
		while not typingStop and typingHolder and typingHolder.Parent do
			i = i % 3 + 1
			pcall(function() typingDots.Text = frames[i] end)
			task.wait(0.35)
		end
	end)
end

-- Key box + mode switch wiring (key stays on your client only)
local function maskKey(k)
	k = tostring(k or "")
	if #k <= 8 then return "key set" end
	return "key set (…" .. k:sub(-4) .. ") — paste new to replace"
end
local function refreshSub()
	sub.Text = "executor (" .. EXEC_NAME .. ") · " .. ((CFG.AIKey ~= "" and CFG.Mode == "ai") and "AI ON" or "offline")
	statusDot.BackgroundColor3 = ((CFG.AIKey ~= "" and CFG.Mode == "ai") and ONC or DIM)
end
if CFG.AIKey ~= "" then
	keyBox.PlaceholderText = maskKey(CFG.AIKey)
	refreshSub()
end
saveBtn.MouseButton1Click:Connect(function()
	local k = keyBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
	if k == "" then return end
	CFG.AIKey = k
	pcall(function()
		local gg = getgenv and getgenv() or _G
		gg.HEKZ_AIKEY = k
		if gg.HEKZ then gg.HEKZ.AIKey = k end
	end)
	keyBox.Text = ""
	keyBox.PlaceholderText = maskKey(k)
	refreshSub()
	addChat("Hekz", "Key saved (…" .. k:sub(-4) .. "). Set mode to AI and talk.")
end)
modeBtn.MouseButton1Click:Connect(function()
	CFG.Mode = (CFG.Mode == "ai") and "local" or "ai"
	modeBtn.Text = (CFG.Mode == "ai") and "AI" or "LOCAL"
	tween(modeBtn, { BackgroundColor3 = (CFG.Mode == "ai") and ONC or OFFC }, 0.18)
	refreshSub()
	addChat("Hekz", "Mode: " .. CFG.Mode .. ((CFG.Mode == "ai" and CFG.AIKey == "") and " (no key yet — paste it above)" or ""))
end)

-- Toggles (local only, no server to sync to)
local toolNames = {}
for n in pairs(CFG.Tools) do table.insert(toolNames, n) end
table.sort(toolNames)
for _, key in ipairs(toolNames) do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 32)
	row.BackgroundColor3 = SURF
	row.BorderSizePixel = 0
	row.Parent = list
	local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 12) c.Parent = row
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -84, 1, 0)
	lbl.Position = UDim2.new(0, 10, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.TextColor3 = TXT
	lbl.Text = key .. " [" .. tostring(CFG.Tools[key]) .. "]"
	lbl.Parent = row
	local pill = Instance.new("TextButton")
	pill.Size = UDim2.new(0, 58, 0, 26)
	pill.Position = UDim2.new(1, -68, 0.5, -13)
	pill.Text = CFG.Tools[key] and "ON" or "OFF"
	pill.Font = Enum.Font.GothamBold
	pill.TextSize = 12
	pill.TextColor3 = Color3.fromRGB(255, 255, 255)
	pill.BackgroundColor3 = CFG.Tools[key] and ONC or OFFC
	pill.AutoButtonColor = false
	pill.Parent = row
	local pc = Instance.new("UICorner") pc.CornerRadius = UDim.new(1, 0) pc.Parent = pill
	pill.MouseButton1Click:Connect(function()
		CFG.Tools[key] = not CFG.Tools[key]
		pill.Text = CFG.Tools[key] and "ON" or "OFF"
		tween(pill, { BackgroundColor3 = CFG.Tools[key] and ONC or OFFC }, 0.18)
		lbl.Text = key .. " [" .. tostring(CFG.Tools[key]) .. "]"
	end)
end

local open = false
local function setOpen(v)
	open = v
	if v then
		panel.Visible = true
		panel.BackgroundTransparency = 1
		panel.Position = UDim2.new(anchor.X.Scale, anchor.X.Offset, anchor.Y.Scale, anchor.Y.Offset + 24)
		tween(panel, { BackgroundTransparency = 0 }, 0.22)
		tween(panel, { Position = anchor }, 0.34, Enum.EasingStyle.Back)
		tween(fab, { Rotation = 45 }, 0.28)
	else
		tween(panel, {
			BackgroundTransparency = 1,
			Position = UDim2.new(anchor.X.Scale, anchor.X.Offset, anchor.Y.Scale, anchor.Y.Offset + 20),
		}, 0.2)
		tween(fab, { Rotation = 0 }, 0.28)
		task.delay(0.22, function() if not open then panel.Visible = false end end)
	end
end
fab.MouseButton1Click:Connect(function() fabPop() setOpen(not open) end)
closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)

local busy = false
local function sendMsg()
	if busy or #input.Text == 0 then return end
	local msg = input.Text
	input.Text = ""
	input.PlaceholderText = "thinking…"
	addChat("You", msg)
	pushHist("user", msg)
	busy = true
	showTyping()
	task.spawn(function()
		local reply
		if CFG.Mode == "ai" and CFG.AIKey ~= "" then
			local ok, res = pcall(askAI, msg)
			reply = ok and res or ("BRAIN ERROR: " .. tostring(res):sub(1, 300))
		else
			reply = routeLocal(msg)
		end
		hideTyping()
		pushHist("assistant", reply)
		addChat("Hekz", reply)
		input.PlaceholderText = tostring(reply):sub(1, 60)
		busy = false
	end)
end
input.FocusLost:Connect(function(enter)
	if enter then sendMsg() end
end)
sendBtn.MouseButton1Click:Connect(function()
	tween(sendBtn, { Size = UDim2.new(0, 32, 0, 32) }, 0.07)
	task.delay(0.07, function()
		tween(sendBtn, { Size = UDim2.new(0, 38, 0, 38) }, 0.14, Enum.EasingStyle.Back)
	end)
	sendMsg()
end)

addChat("Hekz", "Loaded on " .. EXEC_NAME .. " (" .. ((CFG.AIKey ~= "" and CFG.Mode == "ai") and "AI ON" or "offline — paste key in AI KEY box") .. "). Powers: time | calc | scan | parts near | find | info | tree | spawn | teleport | read | exec Luau. Just talk here.")
setOpen(true)
print("[Hekz] executor build online (" .. EXEC_NAME .. ")")
