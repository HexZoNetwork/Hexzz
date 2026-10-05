-- HekzServer AGENT tests via captured HekzChat handler. Returns via __F2.
-- A scripted fake model (M.aiResponder) plays the AI: native tool_calls,
-- ```tool text calls, and direct replies. No network, no Roblox.
local T = HekzTest
local failsB = 0
local function markB(ok, label, extra)
	if not ok then failsB += 1 end
	T.check(ok, label, extra)
end

local chat = T.chatRemote()
markB(chat ~= nil and chat._serverFn ~= nil, "chat handler captured")
if chat ~= nil and chat._serverFn ~= nil then

-- agent mode with scripted model
T.Config.Brain.AIKey.Value = "test-key"
T.Config.Brain.AIBase.Value = "https://fake.test/v1"
T.aiResponder = function(url, body)
	local last = body.messages[#body.messages]
	if last.role == "tool" then
		-- echo what the tool actually produced: proves tools ran for real
		return { choices = { { message = { role = "assistant", content = "noted :: " .. last.content:sub(1, 120) } } } }
	end
	local lastUser = ""
	for i = #body.messages, 1, -1 do
		if body.messages[i].role == "user" then
			lastUser = body.messages[i].content
			break
		end
	end
	if lastUser == "hi" then
		return { choices = { { message = { role = "assistant", content = "Hey! I'm Hekz, what are we building?" } } } }
	elseif lastUser:find("TOOL RESULT", 1, true) then
		-- fenced ```tool path appends results as user text: echo them back
		return { choices = { { message = { role = "assistant", content = "noted :: " .. lastUser:sub(1, 120) } } } }
	elseif lastUser == "fenced please" then
		return { choices = { { message = {
			role = "assistant",
			content = "```tool\n{\"tool\": \"calc\", \"args\": {\"expression\": \"9*9\"}}\n```",
		} } } }
	else
		return { choices = { { message = { role = "assistant", content = "", tool_calls = {
			{ id = "call_1", type = "function", ["function"] = {
				name = "calc",
				arguments = T.jsonEncode({ expression = "(2+3)*4" }),
			} },
		} } } } }
	end
end

local uid = 500
local function say(text)
	uid += 1
	local p = T.makePlayer("Tester", uid)
	T.playersList[1] = p
	T.captured.replies = {}
	chat._serverFn(p, text)
	local last = T.captured.replies[#T.captured.replies]
	return last and last.msg or ""
end

-- 1. the model's own words come back verbatim (AI generates text directly)
local hi = say("hi")
markB(hi == "Hey! I'm Hekz, what are we building?", "model text verbatim", hi:sub(1, 80))

-- 2. native tool_call loop: model asks calc, tool REALLY runs, model answers
local c = say("do some math")
markB(c:find("= 20", 1, true) ~= nil, "agent ran calc, echoed result", c:sub(1, 140))

-- 3. ```tool text fallback: model without function-calling still drives tools
local f = say("fenced please")
markB(f:find("81", 1, true) ~= nil, "text tool-call ran (9*9)", f:sub(1, 140))

-- 4. no key = honest offline notice, never a fake chat reply
T.Config.Brain.AIKey.Value = ""
local off = say("hi")
markB(off:find("No AI key", 1, true) ~= nil, "no-key notice", off:sub(1, 100))
T.Config.Brain.AIKey.Value = "test-key"
end

__F2 = failsB
