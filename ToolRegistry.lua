-- Hekz | ToolRegistry.lua
-- Put as ModuleScript "ToolRegistry" next to HekzServer.
-- Hosted 100% in the Roblox game server. NO VPS, NO Go sidecar.
-- Free chatbot tools: info + MAP tool bunch + OPEN read + UNIVERSAL Luau exec.
--
-- exec runs raw Luau on the game server via loadstring (Luau ONLY, never Go).
-- No allowlist here by request (pretest only).
-- TODO (owner): gate exec/read_script/spawn/delete yourself before public release.
-- Anyone chatting can currently run anything the server can do.

local HttpService = game:GetService("HttpService")

local ToolRegistry = {}
ToolRegistry.__index = ToolRegistry

local function safeCalc(expr)
	local s = tostring(expr or ""):gsub("%s+", "")
	if #s == 0 or #s > 64 then return nil, "empty/too long" end
	if not s:match("^[%d%+%-%*/%%^%.%(%)]+$") then
		return nil, "only 0-9 + - * / % ^ . ( ) allowed"
	end
	local fn, err = loadstring("return (" .. s .. ")")
	if not fn then return nil, "parse error" end
	local ok, v = pcall(fn)
	if not ok then return nil, "eval failed" end
	return tostring(expr) .. " = " .. tostring(v), nil
end

local function playerPos(player)
	local char = player and player.Character
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

local function resolvePath(path)
	-- Dotted path from game: "Workspace.Part", "game.Workspace.Part",
	-- "ServerScriptService.HekzServer", "ReplicatedStorage.Foo".
	local target = tostring(path or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if target == "" then return nil end
	target = target:gsub("^game%.", "")
	local cur = game
	for part in target:gmatch("[^%.]+") do
		local ok, nxt = pcall(function()
			return cur:FindFirstChild(part)
		end)
		if not ok or not nxt then return nil end
		cur = nxt
	end
	return cur
end

local function fmtV3(v)
	return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z)
end

local function findScriptAnywhere(name)
	-- Open lookup: exact path (Workspace.Part.Script) or plain name search.
	-- Searches common containers, no folder restriction (pretest).
	local target = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if target == "" then return nil end

	-- 1) dotted path from game: e.g. "Workspace.MyPart.MyScript"
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

	-- 2) plain name: recursive search in likely roots (cap scan for perf)
	local roots = {
		game.ServerScriptService,
		game.ReplicatedStorage,
		game.Workspace,
		game.StarterPlayer,
		game.StarterGui,
		game.ServerStorage,
	}
	for _, root in ipairs(roots) do
		if root then
			local ok, hit = pcall(function()
				return root:FindFirstChild(target, true)
			end)
			if ok and hit and (hit:IsA("Script") or hit:IsA("LocalScript") or hit:IsA("ModuleScript")) then
				return hit
			end
		end
	end
	return nil
end

local function runLuau(code, ctx)
	-- Universal exec, tg_event-style. code = raw LUAU chunk ONLY.
	-- NEVER Go, NEVER JS, NEVER Python — Roblox scripts run Luau via loadstring.
	-- Helpers: _G.HEKZ_ME = chatting player, game/workspace as usual.
	local maxChars = 4000
	if ctx and ctx.config and ctx.config.Vision and ctx.config.Vision.MaxExecChars then
		maxChars = ctx.config.Vision.MaxExecChars.Value or maxChars
	end
	code = tostring(code or "")
	if #code == 0 then
		return "Usage (Luau ONLY, never Go): exec { code = \"print('hi')\" } — runs Luau on the server via loadstring, returns result."
	end
	if #code > maxChars then
		return "ERROR: code too long (max " .. maxChars .. " chars) — split into smaller steps."
	end

	local player = ctx and ctx.player or nil

	-- Wrap so bare expressions also return: `1+1` -> 2, statements run normally.
	local fn, err = loadstring(code)
	if not fn then
		fn, err = loadstring("return (" .. code .. ")")
	end
	if not fn then
		return "EXEC ERROR: " .. tostring(err):sub(1, 500)
	end

	-- Capture print() output during exec
	local oldPrint = print
	local logs = {}
	print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			table.insert(parts, tostring(select(i, ...)))
		end
		table.insert(logs, table.concat(parts, "  "))
	end

	local results = { pcall(function()
		-- expose caller to chunk via globals the chunk can read
		_G.HEKZ_ME = player
		return fn()
	end) }

	print = oldPrint
	_G.HEKZ_ME = nil

	local ok = table.remove(results, 1)
	local out = {}
	if #logs > 0 then
		table.insert(out, "[print]\n" .. table.concat(logs, "\n"):sub(1, 2000))
	end
	if not ok then
		table.insert(out, "EXEC ERROR: " .. tostring(results[1]):sub(1, 1000))
		return table.concat(out, "\n"):sub(1, 3000)
	end
	local ret = results[1]
	if ret ~= nil then
		if type(ret) == "table" then
			local ok2, s = pcall(function() return tostring(ret) end)
			table.insert(out, "-> " .. (ok2 and s or "table"):sub(1, 1000))
		else
			table.insert(out, "-> " .. tostring(ret):sub(1, 1000))
		end
		-- extra return values
		for i = 2, #results do
			table.insert(out, "-> [" .. i .. "] " .. tostring(results[i]):sub(1, 300))
		end
	else
		if #logs == 0 then
			table.insert(out, "exec OK (ran, no return value)")
		else
			table.insert(out, "exec OK")
		end
	end
	-- convenience handles for vision work inside returned text
	if player then
		-- nothing extra needed: chunk already had full `game`/`workspace` access
	end
	_ = player
	return table.concat(out, "\n"):sub(1, 3000)
end

function ToolRegistry.new(config)
	return setmetatable({ config = config, startTime = os.clock() }, ToolRegistry)
end

function ToolRegistry:list()
	local out = {}
	for name, t in pairs(self.config.Tools) do
		if type(t) == "table" then
			table.insert(out, { name = name, enabled = (t.Value == true) })
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

function ToolRegistry:describe()
	-- Short AI-facing cheat sheet (full powers live in HekzBook).
	-- Luau ONLY for exec — everything hosted in this game server, no VPS.
	return table.concat({
		"get_time {} — UTC clock.",
		"calc { expression = \"(2+3)*4\" } — math.",
		"server_info {} — players/uptime/place.",
		"players {} — who + positions.",
		"map_scan {} — quick vision: census + near you + named.",
		"parts_near { radius=200, limit=30, class=\"Part\" } — parts around you, nearest first.",
		"find_objects { query=\"Spawn\", class=\"\", limit=30 } — search map by name.",
		"object_info { path=\"Workspace.SpawnLocation\" } — props of one object.",
		"workspace_tree { path=\"Workspace\", depth=2, limit=80 } — hierarchy list.",
		"lighting_info {} — Lighting/clock/weather props.",
		"spawn_part { name, x,y,z, sx,sy,sz, r,g,b } — build a part (no coords = near you).",
		"teleport_me { x,y,z OR target=\"PlayerName or Workspace.Part\" } — move yourself.",
		"delete_object { path=\"Workspace.X\" } — destroy one object.",
		"http_fetch { url=\"https://...\" } — GET a URL (HTTP Requests must be ON).",
		"read_script { name = \"<Name or Workspace.A.B>\" } — read ANY script, no restriction.",
		"exec { code = \"<Luau ONLY>\" } — run ANY Luau via loadstring, full game access.",
	}, "\n")
end

function ToolRegistry:openAIDefs()
	-- OpenAI-compatible function definitions for DIRECT in-game AI calls.
	-- Only enabled tools are offered (IsToolEnabled). Luau ONLY for exec.
	local defs = {
		{ name = "get_time", desc = "UTC clock.", params = { type = "object", properties = {} } },
		{ name = "calc", desc = "Math expression.", params = { type = "object", properties = { expression = { type = "string" } }, required = { "expression" } } },
		{ name = "server_info", desc = "Player count, uptime, place info.", params = { type = "object", properties = {} } },
		{ name = "players", desc = "Who is online + positions + leaderstats.", params = { type = "object", properties = {} } },
		{ name = "map_scan", desc = "Quick map vision: part census + what's near you + named objects.", params = { type = "object", properties = {} } },
		{ name = "parts_near", desc = "Parts around the chatting player, nearest first.", params = { type = "object", properties = { radius = { type = "number" }, limit = { type = "number" }, class = { type = "string" } } } },
		{ name = "find_objects", desc = "Search the map by name substring.", params = { type = "object", properties = { query = { type = "string" }, class = { type = "string" }, limit = { type = "number" } }, required = { "query" } } },
		{ name = "object_info", desc = "Properties of one object by dotted path.", params = { type = "object", properties = { path = { type = "string" } }, required = { "path" } } },
		{ name = "workspace_tree", desc = "Hierarchy list under a path.", params = { type = "object", properties = { path = { type = "string" }, depth = { type = "number" }, limit = { type = "number" } } } },
		{ name = "lighting_info", desc = "Lighting / time-of-day / fog props.", params = { type = "object", properties = {} } },
		{ name = "spawn_part", desc = "Build an anchored part (defaults near the player).", params = { type = "object", properties = { name = { type = "string" }, x = { type = "number" }, y = { type = "number" }, z = { type = "number" }, sx = { type = "number" }, sy = { type = "number" }, sz = { type = "number" }, r = { type = "number" }, g = { type = "number" }, b = { type = "number" } } } },
		{ name = "teleport_me", desc = "Teleport the chatting player to x,y,z or to a target object/player.", params = { type = "object", properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" }, target = { type = "string" } } } },
		{ name = "delete_object", desc = "Destroy one object by dotted path.", params = { type = "object", properties = { path = { type = "string" } }, required = { "path" } } },
		{ name = "http_fetch", desc = "GET a URL, return truncated text. HTTP Requests must be ON.", params = { type = "object", properties = { url = { type = "string" } }, required = { "url" } } },
		{ name = "read_script", desc = "Read ANY Script/LocalScript/ModuleScript source by name or dotted path.", params = { type = "object", properties = { name = { type = "string" } } } },
		{ name = "exec", desc = "UNIVERSAL: run raw LUAU ONLY on the game server via loadstring (never Go). Full game access.", params = { type = "object", properties = { code = { type = "string", description = "Luau chunk, e.g. return game.PlaceId" } }, required = { "code" } } },
	}
	local out = {}
	for _, d in ipairs(defs) do
		if self.config.IsToolEnabled(d.name) then
			table.insert(out, {
				type = "function",
				["function"] = { name = d.name, description = d.desc, parameters = d.params },
			})
		end
	end
	return out
end

function ToolRegistry:run(name, args, ctx)
	args = args or {}
	ctx = ctx or {}
	ctx.config = self.config
	-- alias first (so AI can call run/execute/tg_event/web_lookup freely)
	local lname = tostring(name or ""):lower()
	if lname == "tg_event" or lname == "run_script" or lname == "run" or lname == "execute" then
		name = "exec"
	elseif lname == "web_lookup" then
		name = "http_fetch"
	elseif lname == "exec_luau" or lname == "loadstring" or lname == "exec_code" then
		name = "exec"
	end
	if not self.config.IsToolEnabled(name) then
		return "TOOL OFF: '" .. tostring(name) .. "' is disabled in Config.Tools (toggle it in the GUI)"
	end

	if name == "get_time" then
		local ok, res = pcall(function()
			return os.date("!%Y-%m-%dT%H:%M:%SZ") .. " (UTC)"
		end)
		if not ok then return "TOOL ERROR: " .. tostring(res) end
		return tostring(res)

	elseif name == "calc" then
		local r, e = safeCalc(args.expression or args.code or args.text)
		if e then return "ERROR: " .. e end
		return r

	elseif name == "server_info" then
		return string.format("players=%d uptime=%.0fs place=%d job=%s",
			#game.Players:GetPlayers(), os.clock() - self.startTime, game.PlaceId, string.sub(game.JobId, 1, 8))

	elseif name == "players" then
		local lines = {}
		for _, p in ipairs(game.Players:GetPlayers()) do
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
				pos and string.format("(%.0f, %.0f, %.0f)", pos.X, pos.Y, pos.Z) or "(spawning)",
				extra))
		end
		if #lines == 0 then return "server is empty" end
		return table.concat(lines, "\n")

	elseif name == "map_scan" then
		-- Vision: describe the map around the caller (parts census + nearby).
		local maxParts = self.config.Vision.MaxParts.Value or 60
		local radius = self.config.Vision.ScanRadius.Value or 200
		local origin = playerPos(ctx.player)
		local counts = {}
		local named, near = {}, {}
		local total, scanned = 0, 0
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") then
				total += 1
				counts[d.ClassName] = (counts[d.ClassName] or 0) + 1
				if scanned < maxParts then
					scanned += 1
					local label = d.Name .. " (" .. d.ClassName .. ")"
					if origin and (d.Position - origin).Magnitude <= radius then
						table.insert(near, string.format("%s at (%.0f, %.0f, %.0f) %.0fm away",
							label, d.Position.X, d.Position.Y, d.Position.Z, (d.Position - origin).Magnitude))
					elseif #named < 20 and d.Name ~= "Part" then
						table.insert(named, label)
					end
				end
			end
		end
		local sum = {}
		for class, n in pairs(counts) do table.insert(sum, class .. "x" .. n) end
		table.sort(sum)
		local out = { string.format("MAP: %d parts (%s)", total, table.concat(sum, ", ")):sub(1, 400) }
		if origin then
			table.insert(out, string.format("YOU at (%.0f, %.0f, %.0f), within %dm:", origin.X, origin.Y, origin.Z, radius))
			for _, l in ipairs(near) do table.insert(out, " - " .. l) end
		end
		if #named > 0 then
			table.insert(out, "NAMED: " .. table.concat(named, ", "):sub(1, 400))
		end
		table.insert(out, "Need more detail? Ask me to exec custom vision code.")
		return table.concat(out, "\n"):sub(1, 3000)

	elseif name == "read_script" then
		local target = tostring(args.name or args.path or args.code or args.text or "")
		if target == "" then
			return "Usage: read_script { name = '<ScriptName or Workspace.Part.Script>' }"
		end
		local hit = findScriptAnywhere(target)
		if not hit then
			return "NOT FOUND: '" .. target .. "' — try map_scan first, then the exact script name or dotted path."
		end
		local ok, src = pcall(function() return hit.Source end)
		if not ok then return "TOOL ERROR: can't read source (plugin-only?)" end
		local max = self.config.Vision.MaxReadChars.Value or 8000
		src = tostring(src or "")
		local total = #src
		if #src > max then src = src:sub(1, max) .. ("\n...[truncated, total %d chars]"):format(total) end
		return "SCRIPT " .. hit:GetFullName() .. " (" .. total .. " chars):\n" .. src

	elseif name == "exec" or name == "exec_luau" or name == "loadstring" or name == "exec_code" then
		local code = args.code or args.script or args.source or args.text or args.expression or ""
		-- Guard: AI sometimes pastes Go by mistake ("you cannot run Go inside Roblox").
		-- Reject obvious Go and tell it to use Luau instead.
		local s = tostring(code or "")
		if s:match("package%s+main") or s:match("func%s+main%s*%(") or s:match("fmt%.Print") then
			return "EXEC ERROR: that looks like Go. Use LUAU instead — Roblox cannot run Go. Example: exec { code = \"return game.PlaceId\" }"
		end
		return runLuau(code, ctx)

	elseif name == "parts_near" then
		local radius = clampNum(args.radius or (self.config.Vision.ScanRadius.Value or 200), 10, 2000, 200)
		local limit = math.floor(clampNum(args.limit, 1, 50, 30))
		local classF = tostring(args.class or ""):gsub("%s+", "")
		local origin = playerPos(ctx.player)
		if not origin then return "ERROR: your character has no position yet (spawning?)" end
		local hits = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") and (classF == "" or d.ClassName == classF) then
				local dist = (d.Position - origin).Magnitude
				if dist <= radius then
					table.insert(hits, { d = d, dist = dist })
				end
			end
		end
		table.sort(hits, function(a, b) return a.dist < b.dist end)
		if #hits == 0 then return string.format("No BaseParts within %dm of you.", radius) end
		local lines = { string.format("PARTS NEAR YOU (%d found within %dm, showing %d):", #hits, radius, math.min(limit, #hits)) }
		for i = 1, math.min(limit, #hits) do
			local h = hits[i]
			local d = h.d
			table.insert(lines, string.format("- %s (%s) at %s %.0fm size(%.0f,%.0f,%.0f)", d.Name, d.ClassName, fmtV3(d.Position), h.dist, d.Size.X, d.Size.Y, d.Size.Z))
		end
		return table.concat(lines, "\n"):sub(1, 3000)

	elseif name == "find_objects" then
		local q = tostring(args.query or args.name or args.text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
		if q == "" then return "Usage: find_objects { query = \"Spawn\" }" end
		local classF = tostring(args.class or "")
		local limit = math.floor(clampNum(args.limit, 1, 50, 30))
		local found, scanned, truncated = {}, 0, false
		local roots = { workspace, game.ServerStorage, game.ReplicatedStorage }
		for _, root in ipairs(roots) do
			if root and #found < limit then
				for _, d in ipairs(root:GetDescendants()) do
					scanned += 1
					if scanned > 8000 then truncated = true break end
					if d.Name:lower():find(q, 1, true) and (classF == "" or d.ClassName == classF) then
						table.insert(found, d:GetFullName() .. " (" .. d.ClassName .. ")")
						if #found >= limit then break end
					end
				end
			end
		end
		if #found == 0 then return "NOT FOUND: '" .. q .. "' — try map_scan or workspace_tree first." end
		local head = string.format("FOUND %d (showing %d)%s:", scanned, #found, truncated and " [scan capped]" or "")
		table.insert(found, 1, head)
		return table.concat(found, "\n"):sub(1, 3000)

	elseif name == "object_info" then
		local path = tostring(args.path or args.name or "")
		if path == "" then return "Usage: object_info { path = \"Workspace.SpawnLocation\" }" end
		local hit = resolvePath(path)
		if not hit then return "NOT FOUND: '" .. path .. "' — try find_objects first." end
		local lines = { hit:GetFullName() .. " (" .. hit.ClassName .. ")" }
		pcall(function()
			table.insert(lines, "Parent: " .. hit.Parent:GetFullName())
		end)
		if hit:IsA("BasePart") then
			table.insert(lines, "Position: " .. fmtV3(hit.Position))
			table.insert(lines, string.format("Size: (%.1f, %.1f, %.1f)", hit.Size.X, hit.Size.Y, hit.Size.Z))
			table.insert(lines, "Anchored=" .. tostring(hit.Anchored) .. " CanCollide=" .. tostring(hit.CanCollide) .. " Transparency=" .. tostring(hit.Transparency))
			pcall(function()
				table.insert(lines, "Color: " .. tostring(hit.Color) .. " Material: " .. tostring(hit.Material))
			end)
		elseif hit:IsA("Model") then
			local n = #hit:GetChildren()
			table.insert(lines, "Children: " .. n)
			pcall(function()
				table.insert(lines, "Pivot: " .. tostring(hit:GetPivot()))
			end)
		end
		local kids = hit:GetChildren()
		if #kids > 0 then
			local names = {}
			for i = 1, math.min(30, #kids) do
				table.insert(names, kids[i].Name .. " (" .. kids[i].ClassName .. ")")
			end
			table.insert(lines, "Children (" .. #kids .. "): " .. table.concat(names, ", "):sub(1, 500))
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
				count += 1
				table.insert(lines, string.rep("  ", d) .. "- " .. c.Name .. " (" .. c.ClassName .. ")")
				if d < depth then walk(c, d + 1) end
			end
		end
		walk(root, 1)
		if count >= limit then table.insert(lines, "...[truncated at " .. limit .. "]") end
		return table.concat(lines, "\n"):sub(1, 3000)

	elseif name == "lighting_info" then
		local L = game:GetService("Lighting")
		local lines = {
			"Lighting:",
			" ClockTime=" .. tostring(L.ClockTime) .. " TimeOfDay=" .. tostring(L.TimeOfDay),
			" Brightness=" .. tostring(L.Brightness) .. " GlobalShadows=" .. tostring(L.GlobalShadows),
			" Ambient=" .. tostring(L.Ambient) .. " OutdoorAmbient=" .. tostring(L.OutdoorAmbient),
			" FogEnd=" .. tostring(L.FogEnd) .. " FogStart=" .. tostring(L.FogStart),
		}
		return table.concat(lines, "\n")

	elseif name == "spawn_part" then
		local origin = playerPos(ctx.player) or Vector3.new(0, 20, 0)
		local x = tonumber(args.x) or (origin.X + 10)
		local y = tonumber(args.y) or (origin.Y + 5)
		local z = tonumber(args.z) or (origin.Z)
		local sx = clampNum(args.sx or args.size, 0.5, 50, 4)
		if args.sy or args.sz then
			-- per-axis given
		end
		local sy = clampNum(args.sy, 0.5, 50, 4)
		local sz = clampNum(args.sz, 0.5, 50, 4)
		local r = math.floor(clampNum(args.r or 128, 0, 255, 128))
		local g = math.floor(clampNum(args.g or 128, 0, 255, 128))
		local b = math.floor(clampNum(args.b or 128, 0, 255, 128))
		local nm = tostring(args.name or "HekzPart"):gsub("[^%w_%- ]", ""):sub(1, 30)
		if nm == "" then nm = "HekzPart" end
		local ok, part = pcall(function()
			local p = Instance.new("Part")
			p.Name = nm
			p.Size = Vector3.new(sx, sy, sz)
			p.Position = Vector3.new(x, y, z)
			p.Color = Color3.fromRGB(r, g, b)
			p.Anchored = true
			p.Parent = workspace
			return p
		end)
		if not ok or not part then return "SPAWN ERROR: " .. tostring(part) end
		return "SPAWNED " .. part:GetFullName() .. " at " .. fmtV3(part.Position)

	elseif name == "teleport_me" then
		local player = ctx and ctx.player or nil
		if not player then return "ERROR: no player in context" end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return "ERROR: your character has no HumanoidRootPart (spawning?)" end
		local dest = nil
		if args.x ~= nil and args.y ~= nil and args.z ~= nil then
			dest = Vector3.new(tonumber(args.x) or 0, tonumber(args.y) or 10, tonumber(args.z) or 0)
		elseif args.target then
			local t = tostring(args.target)
			-- player name first
			for _, p in ipairs(game.Players:GetPlayers()) do
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
			if not dest then return "NOT FOUND target '" .. t .. "' — use player name or Workspace path, or x/y/z." end
		else
			return "Usage: teleport_me { x=0, y=20, z=0 } OR { target=\"PlayerName\" } OR { target=\"Workspace.SpawnLocation\" }"
		end
		local ok, err = pcall(function()
			char:PivotTo(CFrame.new(dest))
		end)
		if not ok then return "TELEPORT ERROR: " .. tostring(err):sub(1, 300) end
		return "TELEPORTED " .. player.Name .. " to " .. fmtV3(dest)

	elseif name == "delete_object" then
		local path = tostring(args.path or "")
		if path == "" then return "Usage: delete_object { path = \"Workspace.X\" }" end
		if path:lower() == "game" or path == "" then return "REFUSED: won't delete game root." end
		local hit = resolvePath(path)
		if not hit then return "NOT FOUND: '" .. path .. "'" end
		local full = hit:GetFullName()
		local ok, err = pcall(function() hit:Destroy() end)
		if not ok then return "DELETE ERROR: " .. tostring(err):sub(1, 300) end
		return "DELETED " .. full

	elseif name == "http_fetch" or name == "web_lookup" then
		local url = tostring(args.url or args.query or "")
		if url == "" then return "Usage: http_fetch { url = \"https://example.com\" } — HTTP Requests must be ON." end
		if not url:match("^https?://") then return "ERROR: URL must start with http:// or https://" end
		local max = math.floor(clampNum(args.max_chars or args.maxChars, 500, 8000, 4000))
		local ok, res = pcall(function()
			return HttpService:RequestAsync({ Url = url, Method = "GET" })
		end)
		if not ok then return "HTTP ERROR: " .. tostring(res):sub(1, 300) end
		if type(res) ~= "table" then return "HTTP ERROR: bad response" end
		local body = tostring(res.Body or "")
		if #body > max then body = body:sub(1, max) .. "...[truncated]" end
		return string.format("HTTP %s -> %s (%d chars):\n%s", url, tostring(res.StatusCode), #tostring(res.Body or ""), body):sub(1, 4000)

	else
		return "ERROR: unknown tool '" .. tostring(name) .. "'"
	end
end

return ToolRegistry
