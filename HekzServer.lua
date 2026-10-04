-- Hekz | HekzServer.lua
-- Put as Script in ServerScriptService. Requires HekzConfig + ToolRegistry.
-- STUDIO BUILD. For executors use HekzExecutor.lua instead (all-in-one).
-- FREE CHATBOT: every chat message is a prompt. Just talk, no prefix.
-- No allowlist (pretest). Cooldown is the only gate.
-- Executor users: run HekzExecutor.lua (same tools + GUI, client-side).
-- Pretest warning: exec runs loadstring with full `game` access for anyone
-- chatting. Add your own allowlist before public release.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("HekzConfig"))
local ToolRegistry = require(script.Parent:WaitForChild("ToolRegistry"))
local HekzBook = nil
pcall(function()
	HekzBook = require(ReplicatedStorage:WaitForChild("HekzBook"))
end)

local Tools = ToolRegistry.new(Config)

local ToggleEvent = Instance.new("RemoteEvent")
ToggleEvent.Name = "HekzToggle"
ToggleEvent.Parent = ReplicatedStorage

-- GUI chat is PRIMARY (Roblox chat bubble often misses / filters).
-- Client: HekzChat:FireServer(text). Server replies via HekzReply + attribute.
local ChatEvent = ReplicatedStorage:FindFirstChild("HekzChat")
if not ChatEvent then
	ChatEvent = Instance.new("RemoteEvent")
	ChatEvent.Name = "HekzChat"
	ChatEvent.Parent = ReplicatedStorage
end
local ReplyEvent = ReplicatedStorage:FindFirstChild("HekzReply")
if not ReplyEvent then
	ReplyEvent = Instance.new("RemoteEvent")
	ReplyEvent.Name = "HekzReply"
	ReplyEvent.Parent = ReplicatedStorage
end

local function fullSystem()
	-- Book gives the AI its powers. Luau ONLY for exec, never Go.
	local base = Config.Brain.SystemPrompt.Value or ""
	local book = ""
	if HekzBook then
		local ok, txt = pcall(function()
			if type(HekzBook.get) == "function" then return HekzBook.get() end
			return HekzBook.TEXT or ""
		end)
		if ok and type(txt) == "string" and txt ~= "" then
			book = "\n\n" .. txt
		end
	end
	return base .. book
end

-- No owner gate: anyone can flip toggles in pretest.
ToggleEvent.OnServerEvent:Connect(function(_, section, key)
	local s = Config[section]
	if type(s) ~= "table" then return end
	local e = s[key]
	if type(e) ~= "table" or e.Enabled == false then return end
	if type(e.Value) == "boolean" then
		e.Value = not e.Value
	end
end)

local histories = {} -- [userId] = { {role=, text=} }
local lastUse = {}

local function pushHistory(uid, role, text)
	local h = histories[uid]
	if not h then h = {} histories[uid] = h end
	table.insert(h, { role = role, text = text })
	local max = Config.Chat.MaxHistory.Value or 20
	while #h > max do table.remove(h, 1) end
end

local function parseReplyTool(reply)
	-- Let the AI itself call tools via its own reply text (for models without
	-- native function-calling). Accepts ```tool {"tool":"exec","args":{...}}```,
	-- raw {"tool":...}, or [TOOL: name {...}]. Returns toolName, args or nil.
	if type(reply) ~= "string" or reply == "" then return nil end
	local lower = reply:lower()
	-- 1) fenced ```tool ...``` / ```json ...``` blocks
	for fence in reply:gmatch("```%s*[Tt][Oo][Oo][Ll]%s*\n?(.-)%s*```") do
		local name = fence:match('"tool"%s*:%s*"([%w_%-]+)"') or fence:match('"name"%s*:%s*"([%w_%-]+)"')
		if name then
			local argsJson = fence:match('"args"%s*:%s*(%b{})') or fence:match('"arguments"%s*:%s*(%b{})')
			local args = {}
			if argsJson then
				pcall(function()
					args = HttpService:JSONDecode(argsJson) or {}
				end)
			else
				-- flat keys: {"tool":"calc","expression":"2+2"}
				local expr = fence:match('"expression"%s*:%s*"([^"]+)"')
				local code = fence:match('"code"%s*:%s*"([^"]+)"') or fence:match('"code"%s*:%s*(%b{})')
				local nm = fence:match('"name"%s*:%s*"([^"]+)"')
				if expr then args.expression = expr end
				if code then args.code = code end
				if nm and name:lower() == "read_script" then args.name = nm end
			end
			return name:lower(), args
		end
	end
	for fence in reply:gmatch("```%s*[Jj][Ss][Oo][Nn]%s*\n?(.-)%s*```") do
		local name = fence:match('"tool"%s*:%s*"([%w_%-]+)"') or fence:match('"name"%s*:%s*"([%w_%-]+)"')
		if name then
			local argsJson = fence:match('"args"%s*:%s*(%b{})') or fence:match('"arguments"%s*:%s*(%b{})')
			local args = {}
			if argsJson then
				pcall(function() args = HttpService:JSONDecode(argsJson) or {} end)
			end
			return name:lower(), args
		end
	end
	-- 2) raw {"tool":"name","args":{...}} anywhere in text
	local rawName = reply:match('"tool"%s*:%s*"([%w_%-]+)"')
	if rawName then
		local argsJson = reply:match('"args"%s*:%s*(%b{})') or reply:match('"arguments"%s*:%s*(%b{})')
		local args = {}
		if argsJson then
			pcall(function() args = HttpService:JSONDecode(argsJson) or {} end)
		end
		if type(args) ~= "table" then args = {} end
		-- flat fallback
		if not args.expression and not args.code and not args.name then
			local expr = reply:match('"expression"%s*:%s*"([^"]+)"')
			if expr then args.expression = expr end
			local code = reply:match('"code"%s*:%s*"([^"]-)"')
			if code then args.code = code end
		end
		return rawName:lower(), args
	end
	-- 3) [TOOL: name {...}] style
	local bracket = lower:match("%[tool:%s*([%w_%-]+)")
	if bracket then
		local rest = reply:match("%[TOOL:%s*[%w_%-]+%s*(.-)%]")
			or reply:match("%[tool:%s*[%w_%-]+%s*(.-)%]")
		local args = {}
		if rest and rest:match("^%s*{") then
			pcall(function() args = HttpService:JSONDecode(rest:match("(%b{})") or "{}") or {} end)
		elseif rest and #rest:gsub("%s+", "") > 0 then
			args.code = rest
		end
		return bracket:lower(), args
	end
	return nil
end

local function routeLocal(text, ctx)
	-- Offline keyword routing (no key, no HTTP). All tools run IN-GAME (Luau).
	local t = text:lower()
	if t:find("time") or t:find("clock") or t:find("date") then
		return Tools:run("get_time", {}, ctx)
	elseif t:find("calc") or t:match("[%d][%+%-%*/%^][%d]") then
		local expr = text:match("[%d%+%-%*/%%^%s%.%(%)]+")
		return Tools:run("calc", { expression = expr or text }, ctx)
	elseif t:find("teleport") or t:find("bring me") or t:find("take me") or t:find("tp me") then
		local x, y, z = text:match("(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)")
		if x then
			return Tools:run("teleport_me", { x = tonumber(x), y = tonumber(y), z = tonumber(z) }, ctx)
		end
		local tgt = text:match("to%s+([%w%.%_%-]+)")
		return Tools:run("teleport_me", { target = tgt or "" }, ctx)
	elseif t:find("spawn") or t:find("create part") or t:find("build") or t:find("make a part") then
		local nm = text:match("spawn%s+([%w_%-]+)") or text:match("called%s+([%w_%-]+)")
		return Tools:run("spawn_part", { name = nm or "HekzPart" }, ctx)
	elseif t:find("delete") or t:find("destroy") or t:find("remove") then
		local tgt = text:match("delete%s+([%w%.%_%-]+)") or text:match("destroy%s+([%w%.%_%-]+)") or text:match("remove%s+([%w%.%_%-]+)")
		return Tools:run("delete_object", { path = tgt or "" }, ctx)
	elseif t:find("parts near") or t:find("nearby") or t:find("near me") or t:find("around me") then
		return Tools:run("parts_near", {}, ctx)
	elseif t:find("find") or (t:find("search") and not t:find("web")) then
		local q = text:match("find%s+([%w_%-]+)") or text:match("search%s+([%w_%-]+)") or text:match("look for%s+([%w_%-]+)")
		return Tools:run("find_objects", { query = q or text }, ctx)
	elseif t:find("object info") or t:find("info on") or t:find("inspect") or t:find("properties of") then
		local p = text:match("Workspace%.[%w%.%_%-]+") or text:match("info%s+([%w%.%_%-]+)") or text:match("inspect%s+([%w%.%_%-]+)")
		return Tools:run("object_info", { path = p or "" }, ctx)
	elseif t:find("tree") or t:find("hierarchy") or t:find("children of") or t:find("list workspace") then
		local p = text:match("Workspace%.[%w%.%_%-]+")
		return Tools:run("workspace_tree", { path = p or "Workspace" }, ctx)
	elseif t:find("light") or t:find("time of day") or t:find("fog") or t:find("brightness") then
		return Tools:run("lighting_info", {}, ctx)
	elseif t:find("fetch") or t:find("http") or text:match("https?://") then
		local url = text:match("(https?://[%w%.%-%_%~%:%/%?%#%[%]%@%!%$%&%'%(%)%*%+%,%;%=%S]+)")
		return Tools:run("http_fetch", { url = url or "" }, ctx)
	elseif t:find("scan") or t:find("map") or t:find("see") or t:find("look") or t:find("around") or t:find("vision") then
		return Tools:run("map_scan", {}, ctx)
	elseif t:find("who") or t:find("player") or t:find("here") or t:find("online") then
		return Tools:run("players", {}, ctx)
	elseif t:find("read") or t:find("script") or t:find("source") or t:find("code") then
		-- "read X" -> read_script, anything with a code block -> exec
		local block = text:match("```[Ll][Uu][Aa][Uu]?%s*(.-)%s*```") or text:match("```%s*(.-)%s*```")
		if block and #block > 0 then
			return Tools:run("exec", { code = block }, ctx)
		end
		local name = text:match("read%s+([%w%.%_%-]+)")
			or text:match("script%s+([%w%.%_%-]+)")
			or text:match("source%s+([%w%.%_%-]+)")
		return Tools:run("read_script", { name = name or "" }, ctx)
	elseif t:find("run") or t:find("exec") or t:find("execute") or t:find("do ") or t:find("loadstring") or text:match("```") then
		local block = text:match("```[Ll][Uu][Aa][Uu]?%s*(.-)%s*```") or text:match("```%s*(.-)%s*```")
		local code = block
		if not code then
			code = text:match("[Rr][Uu][Nn]%s+(.+)")
				or text:match("[Ee][Xx][Ee][Cc]%s+(.+)")
				or text:match("[Ee][Xx][Ee][Cc][Uu][Tt][Ee]%s+(.+)")
				or text
		end
		return Tools:run("exec", { code = code }, ctx)
	elseif t:find("server") or t:find("uptime") then
		return Tools:run("server_info", {}, ctx)
	elseif t:find("help") or t:find("command") or t:find("tool") or t:find("what can you") or t:find("book") or t:find("power") then
		local lines = { "Hekz — just talk. NO RESTRICTION (pretest). Luau ONLY for exec. Hosted 100% in-game." }
		for _, td in ipairs(Tools:list()) do
			table.insert(lines, string.format(" - %s [%s]", td.name, td.enabled and "ON" or "OFF"))
		end
		table.insert(lines, "Examples: 'what time is it', 'calc (2+3)*4', 'scan the map', 'parts near me', 'find Spawn', 'spawn a part', 'teleport me to SpawnLocation', 'read MyScript', 'run print(\"hi\")'")
		table.insert(lines, "exec runs Luau via loadstring with full game access. read_script reads ANY script. GUI panel is primary chat.")
		return table.concat(lines, "\n")
	else
		return fullSystem() .. "\nYou said: " .. text ..
			"\nI can: time | calc | map scan | parts near | find | info | tree | spawn | teleport | read script | exec Luau | server info. Just ask."
	end
end

local function routeLocalMulti(text, ctx)
	-- Local brain multi-tool: let it chain tools itself when one message holds
	-- several intents ("time and scan", "who is here then server info", ...).
	-- Single-intent messages behave exactly like routeLocal.
	local norm = text:gsub("\n", " and "):gsub(";", " and "):gsub(" & ", " and ")
	local parts = {}
	-- split on " and " / " then " (case-insensitive)
	local buf, i = "", 1
	local low = norm:lower()
	local function flush()
		local p = buf:gsub("^%s+", ""):gsub("%s+$", "")
		if p ~= "" then table.insert(parts, p) end
		buf = ""
	end
	while i <= #norm do
		if low:sub(i, i + 4) == " and " then
			flush()
			i = i + 5
		elseif low:sub(i, i + 5) == " then " then
			flush()
			i = i + 6
		else
			buf = buf .. norm:sub(i, i)
			i = i + 1
		end
	end
	flush()
	if #parts <= 1 then
		return routeLocal(text, ctx)
	end
	local outs = {}
	for _, p in ipairs(parts) do
		local r = routeLocal(p, ctx)
		-- skip fallback echo ("You said: ...") so only real tool outputs chain
		if not r:find("You said:") then
			table.insert(outs, "[" .. p:sub(1, 50) .. "]\n" .. r)
		end
	end
	if #outs == 0 then
		return routeLocal(text, ctx)
	elseif #outs == 1 then
		return outs[1]
	end
	return table.concat(outs, "\n\n"):sub(1, 3000)
end

local function aiPost(url, body, key)
	-- Direct completions call from the GAME SERVER. No VPS, no sidecar.
	local json = HttpService:JSONEncode(body)
	local headers = { ["Content-Type"] = "application/json" }
	if key and key ~= "" then
		headers["Authorization"] = "Bearer " .. key
	end
	local res = HttpService:PostAsync(url, json, Enum.HttpContentType.ApplicationJson, false, headers)
	return HttpService:JSONDecode(res)
end

local function buildAIMessages(text, ctx)
	local msgs = { { role = "system", content = fullSystem() } }
	local h = histories[ctx.player.UserId] or {}
	-- last 20 turns, truncated, mapped to OpenAI roles
	local start = math.max(1, #h - 19)
	for i = start, #h do
		local turn = h[i]
		local role = turn.role
		if role == "tool" then
			role = "user" -- "TOOL RESULT ..." stays readable for any model
		elseif role ~= "user" and role ~= "assistant" then
			role = "user"
		end
		table.insert(msgs, { role = role, content = tostring(turn.text or ""):sub(1, 1500) })
	end
	table.insert(msgs, { role = "user", content = text:sub(1, 2000) })
	return msgs
end

local function askAI(text, ctx)
	-- 100% in-game: game server -> AI completions API -> tools run HERE (Luau).
	local base = tostring((Config.Brain.AIBase and Config.Brain.AIBase.Value) or ""):gsub("/+$", "")
	local key = tostring((Config.Brain.AIKey and Config.Brain.AIKey.Value) or "")
	local model = tostring((Config.Brain.AIModel and Config.Brain.AIModel.Value) or "jmbot/mimo-v2.6-flash")
	local maxRounds = (Config.Brain.MaxRounds and Config.Brain.MaxRounds.Value) or 4
	if maxRounds < 1 then maxRounds = 1 end
	if maxRounds > 8 then maxRounds = 8 end
	if base == "" or key == "" then
		return routeLocalMulti(text, ctx) .. "\n\n(tip: set Brain.AIKey + Brain.Mode=\"ai\" for full AI)"
	end
	local url = base .. "/chat/completions"
	local messages = buildAIMessages(text, ctx)
	local toolDefs = Tools:openAIDefs()
	for _ = 1, maxRounds do
		local body = {
			model = model,
			messages = messages,
			temperature = 0.7,
			max_tokens = 512,
		}
		if #toolDefs > 0 then
			body.tools = toolDefs
			body.tool_choice = "auto"
		end
		local ok, dec = pcall(function() return aiPost(url, body, key) end)
		if not ok then
			-- network/API down: fall back to offline brain, keep the error visible
			return "AI unreachable (" .. tostring(dec):sub(1, 150) .. "). Using local brain.\n" .. routeLocalMulti(text, ctx)
		end
		if type(dec) ~= "table" or type(dec.choices) ~= "table" or #dec.choices == 0 then
			-- provider without tools support may still return plain text in error shape;
			-- try text fallback, else offline.
			local errMsg = ""
			pcall(function() errMsg = tostring(dec.error and dec.error.message or "") end)
			if errMsg ~= "" and errMsg:lower():find("tool") and #toolDefs > 0 then
				toolDefs = {} -- retry once without tools, rely on ```tool text calls
				continue
			end
			return routeLocalMulti(text, ctx)
		end
		local msg = dec.choices[1].message or {}
		local content = tostring(msg.content or "")
		local calls = msg.tool_calls
		if type(calls) == "table" and #calls > 0 then
			-- AI itself asked for tools: run them HERE and feed results back.
			table.insert(messages, { role = "assistant", content = content, tool_calls = calls })
			for _, tc in ipairs(calls) do
				local fn = (tc and tc["function"]) or {}
				local tname = tostring(fn.name or "")
				local targs = {}
				if type(fn.arguments) == "string" and fn.arguments ~= "" then
					pcall(function()
						targs = HttpService:JSONDecode(fn.arguments) or {}
					end)
					if type(targs) ~= "table" then targs = {} end
				elseif type(fn.arguments) == "table" then
					targs = fn.arguments
				end
				if tname ~= "" then
					local out = Tools:run(tname, targs, ctx)
					pushHistory(ctx.player.UserId, "tool", tname .. " -> " .. out:sub(1, 500))
					table.insert(messages, {
						role = "tool",
						tool_call_id = tostring(tc.id or tname),
						content = out:sub(1, 2000),
					})
				end
			end
			-- loop: let the AI see tool results and answer / chain next tool
		else
			-- No native tool call: check text-embedded ```tool {...} (models w/o tools)
			local tname, targs = parseReplyTool(content)
			if tname then
				local out = Tools:run(tname, targs or {}, ctx)
				pushHistory(ctx.player.UserId, "tool", tname .. " -> " .. out:sub(1, 500))
				table.insert(messages, { role = "assistant", content = content })
				table.insert(messages, { role = "user", content = "TOOL RESULT [" .. tname .. "]: " .. out:sub(1, 2000) })
				-- loop for the follow-up answer
			else
				if content == "" then
					return routeLocalMulti(text, ctx)
				end
				return content
			end
		end
	end
	-- Max rounds: return last assistant text if any, else offline.
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" and tostring(messages[i].content or "") ~= "" then
			local tname, targs = parseReplyTool(tostring(messages[i].content))
			if tname then
				return Tools:run(tname, targs or {}, ctx)
			end
			return tostring(messages[i].content)
		end
	end
	return routeLocalMulti(text, ctx)
end

-- Legacy alias: old configs used Mode="bridge" (VPS). Now everything is in-game.
local function askBridge(text, ctx)
	return askAI(text, ctx)
end

local function handleMessage(player, raw)
	-- No allowlist: everyone may talk. Cooldown is the only gate.
	local now = os.clock()
	if lastUse[player.UserId] and now - lastUse[player.UserId] < (Config.Chat.CooldownSec.Value or 2) then return end
	lastUse[player.UserId] = now

	local body = tostring(raw or "")
	if body:gsub("%s+", "") == "" then return end
	if body == "" then return end

	pushHistory(player.UserId, "user", body)
	local ctx = { player = player }
	local reply
	local mode = tostring((Config.Brain.Mode and Config.Brain.Mode.Value) or "local"):lower()
	if mode == "ai" or mode == "bridge" then
		-- "bridge" kept as legacy alias for "ai" (both are direct in-game now)
		reply = askAI(body, ctx)
	else
		reply = routeLocalMulti(body, ctx)
	end
	pushHistory(player.UserId, "assistant", reply)

	-- Deliver to GUI (primary) + attribute (compat). Never rely on bubble chat.
	pcall(function()
		ReplyEvent:FireClient(player, reply:sub(1, 2000))
	end)
	player:SetAttribute("HekzLastReply", reply:sub(1, 500))
	print("[Hekz][" .. player.Name .. "] Q: " .. body:sub(1, 200) .. " A: " .. reply:sub(1, 300))
end

-- PRIMARY: GUI panel -> HekzChat. SECONDARY: legacy Roblox chatted.
ChatEvent.OnServerEvent:Connect(function(player, raw)
	handleMessage(player, raw)
end)
Players.PlayerAdded:Connect(function(p)
	p.Chatted:Connect(function(msg) handleMessage(p, msg) end)
end)
for _, p in ipairs(Players:GetPlayers()) do
	p.Chatted:Connect(function(msg) handleMessage(p, msg) end)
end

print("[Hekz] server online. free chat, no allowlist (pretest).")
