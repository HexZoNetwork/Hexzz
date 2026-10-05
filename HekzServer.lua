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

-- AGENT BUILD: no keyword router. The model reads intent, picks tools,
-- and writes every reply itself. Tool execution lives in askAI below.

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

local reqSeq = {} -- [userId] = latest request no; stale replies are dropped (bots activeReq)

local function offlineNotice()
	return "No AI key set — I can't think yet. Put it in HekzConfig → Brain.AIKey, then just talk to me."
end

local function askAI(text, ctx, isStale)
	-- AGENT LOOP (bots handlePrompt pattern): the MODEL thinks and talks.
	-- Roblox only runs the tools the model asks for and feeds results back.
	-- Every reply is the model's own text, verbatim. No canned replies anywhere.
	isStale = isStale or function() return false end
	local base = tostring((Config.Brain.AIBase and Config.Brain.AIBase.Value) or ""):gsub("/+$", "")
	local key = tostring((Config.Brain.AIKey and Config.Brain.AIKey.Value) or "")
	local model = tostring((Config.Brain.AIModel and Config.Brain.AIModel.Value) or "jmbot/mimo-v2.6-flash")
	local maxRounds = (Config.Brain.MaxRounds and Config.Brain.MaxRounds.Value) or 4
	if maxRounds < 1 then maxRounds = 1 end
	if maxRounds > 8 then maxRounds = 8 end
	if base == "" or key == "" then
		return offlineNotice()
	end
	local url = base .. "/chat/completions"
	local messages = buildAIMessages(text, ctx)
	local toolDefs = Tools:openAIDefs()

	local function query()
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
			return nil, "AI request failed (" .. tostring(dec):sub(1, 150) .. "). Try again in a bit."
		end
		return dec, nil
	end

	local emptyRetries = 0
	for _ = 1, maxRounds do
		if isStale() then return nil end
		local dec, errText = query()
		if not dec then return errText end
		if type(dec) ~= "table" or type(dec.choices) ~= "table" or #dec.choices == 0 then
			local errMsg = ""
			pcall(function() errMsg = tostring(dec.error and dec.error.message or "") end)
			if errMsg ~= "" and errMsg:lower():find("tool") and #toolDefs > 0 then
				toolDefs = {} -- provider rejects tools: go tool-less, ```tool text still works
				continue
			end
			return "AI gave an unreadable reply (" .. errMsg:sub(1, 120) .. "). Try again."
		end
		local msg = dec.choices[1].message or {}
		local content = tostring(msg.content or "")
		local calls = msg.tool_calls
		local hasCalls = type(calls) == "table" and #calls > 0
		if not hasCalls and content:gsub("%s+", "") == "" then
			if emptyRetries == 0 then
				emptyRetries = 1
				toolDefs = {} -- one retry without tools, like bots
				continue
			end
			return "(empty reply)"
		end
		if hasCalls then
			-- model asked for tools: run them HERE, feed results back, re-query
			table.insert(messages, { role = "assistant", content = content, tool_calls = calls })
			for _, tc in ipairs(calls) do
				if isStale() then return nil end
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
		else
			-- no native call: accept ```tool {...} text calls (models without tools)
			local tname, targs = parseReplyTool(content)
			if tname then
				local out = Tools:run(tname, targs or {}, ctx)
				pushHistory(ctx.player.UserId, "tool", tname .. " -> " .. out:sub(1, 500))
				table.insert(messages, { role = "assistant", content = content })
				table.insert(messages, { role = "user", content = "TOOL RESULT [" .. tname .. "]: " .. out:sub(1, 2000) })
			else
				return content -- THE MODEL'S OWN TEXT, verbatim
			end
		end
	end
	-- rounds exhausted while the model still calls tools: run its last text
	-- call once so the work isn't lost, else hand back its last words.
	for i = #messages, 1, -1 do
		local m = messages[i]
		if m.role == "assistant" and tostring(m.content or "") ~= "" then
			local tname, targs = parseReplyTool(tostring(m.content))
			if tname then
				return Tools:run(tname, targs or {}, ctx)
			end
			return tostring(m.content)
		end
	end
	return "(max rounds reached — ask me to continue)"
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
	-- stale supersede (bots activeReq): a newer message cancels this one
	reqSeq[player.UserId] = (reqSeq[player.UserId] or 0) + 1
	local mySeq = reqSeq[player.UserId]
	local reply = askAI(body, ctx, function()
		return reqSeq[player.UserId] ~= mySeq
	end)
	if reply == nil then return end -- superseded, stay silent like bots
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
