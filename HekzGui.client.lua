-- Hekz | HekzGui.client.lua
-- Put as LocalScript in StarterPlayerScripts (name it HekzGui).
-- Builds the whole GUI in code: no .rbxm needed.
-- Theme: black / white / gray, dominant dark.
-- Animation: TweenService only (Luau has no react-motion; TweenService with
-- Quart/Quint easing is the native equivalent).
-- Every row: label + value + green(ON)/red(OFF) toggle pill.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("HekzConfig"))

-- Book is optional on client (server owns the AI text). Show powers locally if present.
local BookText = ""
pcall(function()
	local b = require(ReplicatedStorage:WaitForChild("HekzBook"))
	if type(b) == "table" then
		if type(b.get) == "function" then BookText = b.get() or "" end
		if BookText == "" and type(b.TEXT) == "string" then BookText = b.TEXT end
	end
end)

local G = Config.GUI
local BG, SURF, BORDER = G.Background.Value, G.Surface.Value, G.Border.Value
local TXT, DIM = G.TextMain.Value, G.TextDim.Value
local ON, OFF = G.ToggleOn.Value, G.ToggleOff.Value
local T = G.AnimTime.Value or 0.28

local function tween(obj, props, time, style, dir)
	TweenService:Create(obj, TweenInfo.new(time or T, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out), props):Play()
end

-- Root
local gui = Instance.new("ScreenGui")
gui.Name = "Hekz"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

-- Floating open button (dark circle)
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

-- Panel (taller: toggles + GUI chat log + input). GUI chat is PRIMARY.
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.new(0, 340, 0, 540)
panel.Position = UDim2.new(1, -364, 1, -700)
panel.BackgroundColor3 = BG
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
local pCorner = Instance.new("UICorner") pCorner.CornerRadius = UDim.new(0, 14) pCorner.Parent = panel
local pStroke = Instance.new("UIStroke") pStroke.Color = BORDER pStroke.Thickness = 1 pStroke.Parent = panel

local header = Instance.new("TextLabel")
header.Size = UDim2.new(1, -64, 0, 40)
header.Position = UDim2.new(0, 12, 0, 8)
header.BackgroundTransparency = 1
header.Text = "HEKZ  ·  tools"
header.Font = Enum.Font.GothamBold
header.TextSize = 16
header.TextXAlignment = Enum.TextXAlignment.Left
header.TextColor3 = TXT
header.Parent = panel

-- Close (X) button: hides panel, H button reopens it
local closeBtn = Instance.new("TextButton")
closeBtn.Name = "Close"
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -38, 0, 12)
closeBtn.BackgroundColor3 = SURF
closeBtn.Text = "X"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 14
closeBtn.TextColor3 = OFF
closeBtn.AutoButtonColor = false
closeBtn.Parent = panel
local xCorner = Instance.new("UICorner") xCorner.CornerRadius = UDim.new(1, 0) xCorner.Parent = closeBtn
local xStroke = Instance.new("UIStroke") xStroke.Color = BORDER xStroke.Thickness = 1 xStroke.Parent = closeBtn

-- Draggable panel: drag by the header (mouse + touch)
local UserInputService = game:GetService("UserInputService")
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
sub.Text = "GUI chat is primary — Luau only, no restriction (pretest)"
sub.Font = Enum.Font.Gotham
sub.TextSize = 12
sub.TextXAlignment = Enum.TextXAlignment.Left
sub.TextColor3 = DIM
sub.Parent = panel

local togLabel = Instance.new("TextLabel")
togLabel.Size = UDim2.new(1, -24, 0, 16)
togLabel.Position = UDim2.new(0, 12, 0, 62)
togLabel.BackgroundTransparency = 1
togLabel.Text = "TOGGLES"
togLabel.Font = Enum.Font.GothamBold
togLabel.TextSize = 11
togLabel.TextXAlignment = Enum.TextXAlignment.Left
togLabel.TextColor3 = DIM
togLabel.Parent = panel

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -24, 0, 150)
list.Position = UDim2.new(0, 12, 0, 80)
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
chatLabel.Position = UDim2.new(0, 12, 0, 238)
chatLabel.BackgroundTransparency = 1
chatLabel.Text = "CHAT (GUI — primary, Luau only)"
chatLabel.Font = Enum.Font.GothamBold
chatLabel.TextSize = 11
chatLabel.TextXAlignment = Enum.TextXAlignment.Left
chatLabel.TextColor3 = DIM
chatLabel.Parent = panel

local chatLog = Instance.new("ScrollingFrame")
chatLog.Name = "ChatLog"
chatLog.Size = UDim2.new(1, -24, 0, 200)
chatLog.Position = UDim2.new(0, 12, 0, 256)
chatLog.BackgroundColor3 = SURF
chatLog.BorderSizePixel = 0
chatLog.ScrollBarThickness = 4
chatLog.ScrollBarImageColor3 = BORDER
chatLog.CanvasSize = UDim2.new(0, 0, 0, 0)
chatLog.AutomaticCanvasSize = Enum.AutomaticSize.Y
chatLog.Parent = panel
local chatCorner = Instance.new("UICorner") chatCorner.CornerRadius = UDim.new(0, 10) chatCorner.Parent = chatLog
local chatPad = Instance.new("UIPadding")
chatPad.PaddingTop = UDim.new(0, 8)
chatPad.PaddingBottom = UDim.new(0, 8)
chatPad.PaddingLeft = UDim.new(0, 10)
chatPad.PaddingRight = UDim.new(0, 10)
chatPad.Parent = chatLog
local chatLayout = Instance.new("UIListLayout")
chatLayout.Padding = UDim.new(0, 6)
chatLayout.SortOrder = Enum.SortOrder.LayoutOrder
chatLayout.Parent = chatLog

local input = Instance.new("TextBox")
input.Size = UDim2.new(1, -24, 0, 36)
input.Position = UDim2.new(0, 12, 1, -46)
input.BackgroundColor3 = SURF
input.PlaceholderText = "talk here (GUI chat) — run print('hi')…"
input.PlaceholderColor3 = DIM
input.Text = ""
input.Font = Enum.Font.Gotham
input.TextSize = 13
input.TextColor3 = TXT
input.ClearTextOnFocus = false
input.Parent = panel
local iCorner = Instance.new("UICorner") iCorner.CornerRadius = UDim.new(0, 10) iCorner.Parent = input
local iStroke = Instance.new("UIStroke") iStroke.Color = BORDER iStroke.Parent = input

-- Chat history (GUI is primary path, NOT Roblox bubble chat)
local chatOrder = 0
local lastShown = ""
local function addChat(who, text)
	text = tostring(text or "")
	if text == "" then return end
	-- dedupe attribute + RemoteEvent double delivery
	if who == "Hekz" and text == lastShown then return end
	if who == "Hekz" then lastShown = text end
	chatOrder += 1
	local lbl = Instance.new("TextLabel")
	lbl.LayoutOrder = chatOrder
	lbl.Size = UDim2.new(1, -4, 0, 0)
	lbl.AutomaticSize = Enum.AutomaticSize.Y
	lbl.BackgroundTransparency = 1
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Top
	lbl.TextWrapped = true
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 12
	lbl.TextColor3 = (who == "You") and TXT or DIM
	lbl.Text = who .. ": " .. text:sub(1, 800)
	lbl.Parent = chatLog
	task.delay(0.05, function()
		pcall(function()
			chatLog.CanvasPosition = Vector2.new(0, math.max(0, chatLog.AbsoluteCanvasSize.Y - chatLog.AbsoluteWindowSize.Y))
		end)
	end)
end

if BookText ~= "" then
	addChat("Hekz", "Powers loaded: time | calc | server_info | players | map_scan | read_script (ANY) | exec (Luau ONLY, no restriction). Just talk here.")
end

local toggleEvent = ReplicatedStorage:WaitForChild("HekzToggle")
local chatEvent = ReplicatedStorage:WaitForChild("HekzChat")
local replyEvent = ReplicatedStorage:WaitForChild("HekzReply")

local function makeRow(section, key, entry)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundColor3 = SURF
	row.BorderSizePixel = 0
	row.Parent = list
	local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 10) c.Parent = row

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, -84, 1, 0)
	lbl.Position = UDim2.new(0, 10, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.TextColor3 = TXT
	lbl.Text = section .. "." .. key .. "  [" .. tostring(entry.Value) .. "]"
	lbl.Parent = row

	local pill = Instance.new("TextButton")
	pill.Size = UDim2.new(0, 58, 0, 26)
	pill.Position = UDim2.new(1, -68, 0.5, -13)
	pill.Text = (entry.Value == true) and "ON" or "OFF"
	pill.Font = Enum.Font.GothamBold
	pill.TextSize = 12
	pill.TextColor3 = Color3.fromRGB(255, 255, 255)
	pill.BackgroundColor3 = (entry.Value == true) and ON or OFF
	pill.AutoButtonColor = false
	pill.Parent = row
	local pc = Instance.new("UICorner") pc.CornerRadius = UDim.new(1, 0) pc.Parent = pill

	-- press animation: quick shrink then spring back (motion-like)
	pill.MouseButton1Click:Connect(function()
		tween(pill, { Size = UDim2.new(0, 50, 0, 22) }, 0.08, Enum.EasingStyle.Quad)
		task.wait(0.08)
		tween(pill, { Size = UDim2.new(0, 58, 0, 26) }, 0.16, Enum.EasingStyle.Back)
		if type(entry.Value) == "boolean" then
			entry.Value = not entry.Value
			tween(pill, { BackgroundColor3 = entry.Value and ON or OFF }, 0.18)
			pill.Text = entry.Value and "ON" or "OFF"
			lbl.Text = section .. "." .. key .. "  [" .. tostring(entry.Value) .. "]"
			toggleEvent:FireServer(section, key) -- pretest: open, no allowlist
		end
	end)
end

for _, section in ipairs({ "Chat", "Brain", "Tools" }) do
	local s = Config[section]
	if type(s) == "table" then
		for key, entry in pairs(s) do
			if type(entry) == "table" and entry.Enabled ~= false and type(entry.Value) == "boolean" then
				makeRow(section, key, entry)
			end
		end
	end
end

-- Open / close animation (fade + slide, our stand-in for motion divs)
local open = false
local function setOpen(v)
	open = v
	if v then
		panel.Visible = true
		panel.BackgroundTransparency = 1
		panel.Position = UDim2.new(anchor.X.Scale, anchor.X.Offset, anchor.Y.Scale, anchor.Y.Offset + 20)
		tween(panel, { BackgroundTransparency = 0, Position = anchor }, T)
		tween(fab, { Rotation = 45 }, T)
	else
		tween(panel, { BackgroundTransparency = 1, Position = UDim2.new(anchor.X.Scale, anchor.X.Offset, anchor.Y.Scale, anchor.Y.Offset + 20) }, T * 0.8)
		tween(fab, { Rotation = 0 }, T)
		task.delay(T * 0.8, function() if not open then panel.Visible = false end end)
	end
end
local function fabPop()
	tween(fab, { Size = UDim2.new(0, 44, 0, 44) }, 0.08, Enum.EasingStyle.Quad)
	task.wait(0.08)
	tween(fab, { Size = UDim2.new(0, 52, 0, 52) }, 0.16, Enum.EasingStyle.Back)
end
fab.MouseButton1Click:Connect(function() fabPop() setOpen(not open) end)
closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)

-- PRIMARY inbox: server fires HekzReply to this player (full text, GUI log)
replyEvent.OnClientEvent:Connect(function(msg)
	if type(msg) == "string" and #msg > 0 then
		input.Text = ""
		input.PlaceholderText = msg:sub(1, 60)
		addChat("Hekz", msg)
		if not open then setOpen(true) end
	end
end)

-- Compat inbox: older server sets HekzLastReply attribute (deduped in addChat)
player:GetAttributeChangedSignal("HekzLastReply"):Connect(function()
	local msg = player:GetAttribute("HekzLastReply")
	if type(msg) == "string" and #msg > 0 then
		input.Text = ""
		input.PlaceholderText = msg:sub(1, 60)
		addChat("Hekz", msg)
		if not open then setOpen(true) end
	end
end)

-- Enter-to-chat: GUI -> server via HekzChat (PRIMARY). Bubble chat is fallback only.
input.FocusLost:Connect(function(enter)
	if enter and #input.Text > 0 then
		local msg = input.Text
		input.Text = ""
		input.PlaceholderText = "sending…"
		addChat("You", msg)
		chatEvent:FireServer(msg)
		-- Fallback: also try bubble chat so legacy Chatted path hears it.
		-- Primary path is HekzChat above; ignore errors here.
		pcall(function()
			local tc = game:GetService("TextChatService")
			local ch = tc:FindFirstChildOfClass("TextChannel")
			if ch then ch:SendAsync(msg) end
		end)
	end
end)
