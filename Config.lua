-- Hekz | Config.lua
-- Put this ModuleScript in ReplicatedStorage as "HekzConfig".
-- Free chatbot: every chat message is a prompt, just talk.
-- No allowlist, no prefix. Anyone can chat, anyone can toggle (pretest).
-- TODO (owner): add your own allowlist back here before public release.
-- All behavior rows are { Value, Enabled } so the GUI renders
-- an ON (green) / OFF (red) toggle pill for each.

local Config = {}

-- Free chat: everything said is a prompt. No prefix, no allowlist.
Config.Chat = {
	MaxHistory  = { Value = 20, Enabled = true }, -- rolling per-player history
	CooldownSec = { Value = 2,  Enabled = true }, -- anti-spam per player only
}

-- Brain: 100% hosted in this game server. NO VPS, NO Go sidecar.
-- AGENT build: the model thinks (tools) and writes every reply itself.
-- Mode "ai" = talk to the model (needs AIKey). No key = short notice.
-- There is no keyword routing and no canned reply anywhere in the server.
Config.Brain = {
	Mode       = { Value = "ai", Enabled = true }, -- agent-first (needs AIKey); no key = short notice
	AIBase     = { Value = "https://9router.kliksosmed.id/v1", Enabled = true },
	AIKey      = { Value = "", Enabled = true },
	AIModel    = { Value = "jmbot/mimo-v2.6-flash", Enabled = true },
	TimeoutSec = { Value = 15,      Enabled = true },
	MaxRounds  = { Value = 4,       Enabled = true }, -- AI tool-chain steps per message
	SystemPrompt = { Value = "You are Hekz, a free chatbot inside a Roblox game. GUI chat (HekzChat) is primary. exec is Luau ONLY via loadstring — never Go/JS/Python. Call tools yourself when needed.", Enabled = true },
}

-- Map + code tools, all executed IN-GAME (Luau). No VPS.
Config.Tools = {
	get_time       = { Value = true, Enabled = true }, -- UTC clock
	calc           = { Value = true, Enabled = true }, -- math
	server_info    = { Value = true, Enabled = true }, -- player count, uptime
	players        = { Value = true, Enabled = true }, -- who is online + where
	map_scan       = { Value = true, Enabled = true }, -- quick vision
	parts_near     = { Value = true, Enabled = true }, -- parts around you, nearest first
	find_objects   = { Value = true, Enabled = true }, -- search map by name
	object_info    = { Value = true, Enabled = true }, -- props of one object
	workspace_tree = { Value = true, Enabled = true }, -- hierarchy list
	lighting_info  = { Value = true, Enabled = true }, -- lighting/time/fog
	spawn_part     = { Value = true, Enabled = true }, -- build a part
	teleport_me    = { Value = true, Enabled = true }, -- move yourself
	bring          = { Value = true, Enabled = true }, -- pull others to you
	delete_object  = { Value = true, Enabled = true }, -- destroy one object
	http_fetch     = { Value = true, Enabled = true }, -- GET a URL (needs HTTP ON)
	read_script    = { Value = true, Enabled = true }, -- read any Script source
	write_script   = { Value = true, Enabled = true }, -- write a Script, then exec it
	exec           = { Value = true, Enabled = true }, -- UNIVERSAL: run any Luau (loadstring). Pretest only.
}

-- Vision + script reading limits (no folder allowlist — pretest).
Config.Vision = {
	MaxParts     = { Value = 60,   Enabled = true }, -- cap for map_scan listing
	ScanRadius   = { Value = 200,  Enabled = true }, -- studs around caller reported in detail
	MaxReadChars = { Value = 8000, Enabled = true },
	MaxExecChars = { Value = 4000, Enabled = true }, -- max code chars per exec call
}

-- GUI theme: black / white / gray, dominant dark
Config.GUI = {
	Background = { Value = Color3.fromRGB(18, 18, 20),   Enabled = false },
	Surface    = { Value = Color3.fromRGB(30, 30, 34),   Enabled = false },
	Border     = { Value = Color3.fromRGB(70, 70, 76),   Enabled = false },
	TextMain   = { Value = Color3.fromRGB(240, 240, 242), Enabled = false },
	TextDim    = { Value = Color3.fromRGB(150, 150, 156), Enabled = false },
	ToggleOn   = { Value = Color3.fromRGB(46, 204, 113), Enabled = false }, -- green
	ToggleOff  = { Value = Color3.fromRGB(231, 76, 60),  Enabled = false }, -- red
	AnimTime   = { Value = 0.28, Enabled = true }, -- TweenService time
}

function Config.IsToolEnabled(name)
	local n = tostring(name or ""):lower()
	if n == "run" or n == "run_script" or n == "execute" or n == "loadstring"
		or n == "exec_luau" or n == "exec_code" or n == "tg_event" then
		n = "exec"
	elseif n == "web_lookup" then
		n = "http_fetch"
	end
	local t = Config.Tools[n]
	if t == nil then return false end
	return t.Value == true
end

return Config
