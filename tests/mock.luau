-- Hekz CLI test mocks: minimal Roblox API so server files run under real Luau.
-- No Roblox needed. Loaded first by tests/run.luau via mock.setup(realRequire).

local M = {}
M.captured = { replies = {}, remotes = {} }
M.prints = {}

-- capture print noise, keep a real printer for the harness
local realPrint = print
M.realPrint = realPrint
print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end
	table.insert(M.prints, table.concat(parts, " "))
end

-- task stub (server files barely use it; executor file is not CLI-tested)
task = {
	spawn = function(f, ...) if type(f) == "function" then f(...) end end,
	defer = function(f, ...) if type(f) == "function" then f(...) end end,
	delay = function() end,
	wait = function() end,
}

-- Vector3 with real arithmetic
local function V3(x, y, z)
	local t = { X = x, Y = y, Z = z }
	setmetatable(t, {
		__add = function(a, b) return V3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end,
		__sub = function(a, b) return V3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end,
		__index = function(tt, k)
			if k == "Magnitude" then
				return math.sqrt(tt.X * tt.X + tt.Y * tt.Y + tt.Z * tt.Z)
			end
			return nil
		end,
	})
	return t
end
Vector3 = { new = function(x, y, z) return V3(x, y, z) end }
Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end }
CFrame = { new = function(pos) return { Position = pos } end }
Enum = { HttpContentType = { ApplicationJson = "ApplicationJson" } }

-- generic instance with a real tree (Parent assignment maintains children)
local function newInst(class)
	local o = { ClassName = class, Name = class, Source = "", _children = {}, _parent = nil, _destroyed = false }
	o.IsA = function(self, c) return self.ClassName == c end
	o.FindFirstChild = function(self, n, rec)
		for _, c in ipairs(self._children) do
			if c.Name == n then return c end
		end
		if rec then
			for _, c in ipairs(self._children) do
				local f = c:FindFirstChild(n, true)
				if f then return f end
			end
		end
		return nil
	end
	o.GetChildren = function(self) return self._children end
	o.GetDescendants = function(self)
		local r = {}
		local function w(t)
			for _, c in ipairs(t._children) do
				table.insert(r, c)
				w(c)
			end
		end
		w(self)
		return r
	end
	o.GetFullName = function(self)
		local parts = {}
		local cur = self
		while cur and cur.Name do
			table.insert(parts, 1, cur.Name)
			cur = cur._parent
		end
		return table.concat(parts, ".")
	end
	o.Destroy = function(self)
		self._destroyed = true
		if self._parent then
			for i, c in ipairs(self._parent._children) do
				if c == self then table.remove(self._parent._children, i) break end
			end
			self._parent = nil
		end
	end
	setmetatable(o, {
		__newindex = function(t, k, v)
			if k == "Parent" then
				if t._parent then
					for i, c in ipairs(t._parent._children) do
						if c == t then table.remove(t._parent._children, i) break end
					end
				end
				rawset(t, "_parent", v)
				if v ~= nil then table.insert(v._children, t) end
			else
				rawset(t, k, v)
			end
		end,
	})
	if class == "RemoteEvent" then
		o.OnServerEvent = { Connect = function(_, fn) o._serverFn = fn end }
		o.FireClient = function(_, pl, msg)
			table.insert(M.captured.replies, { player = pl, msg = msg })
		end
		table.insert(M.captured.remotes, o)
	end
	return o
end
Instance = { new = function(class) return newInst(class) end }
M.newInst = newInst

-- players
local playersList = {}
M.playersList = playersList
local function makePlayer(name, uid, withChar)
	local p = { Name = name, UserId = uid, attrs = {} }
	p.SetAttribute = function(self, k, v) self.attrs[k] = v end
	p.GetAttribute = function(self, k) return self.attrs[k] end
	p.Chatted = { Connect = function() end }
	p.FindFirstChild = function(_, _) return nil end -- no leaderstats in tests
	if withChar ~= false then
		local char = { HumanoidRootPart = { Position = V3(0, 10, 0) } }
		char.FindFirstChild = function(self, n)
			if n == "HumanoidRootPart" then return self.HumanoidRootPart end
			return nil
		end
		char.PivotTo = function(self, cf) self._pivoted = cf end
		p.Character = char
	end
	return p
end
M.makePlayer = makePlayer
local playersSvc = {
	GetPlayers = function(_) return playersList end,
	PlayerAdded = { Connect = function() end },
}

-- services
-- minimal JSON codecs (enough for completions bodies + scripted test replies)
local function jenc(v)
	local t = typeof(v)
	if t == "nil" then return "null" end
	if t == "boolean" then return tostring(v) end
	if t == "number" then return tostring(v) end
	if t == "string" then
		return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
			if c == '"' then return '\\"'
			elseif c == "\\" then return "\\\\"
			elseif c == "\n" then return "\\n"
			elseif c == "\r" then return "\\r"
			elseif c == "\t" then return "\\t"
			else return string.format("\\u%04x", string.byte(c)) end
		end) .. '"'
	end
	if t == "table" then
		local n = #v
		local isArr = n > 0
		if isArr then
			for i = 1, n do
				if v[i] == nil then isArr = false break end
			end
		end
		if isArr then
			local parts = {}
			for i = 1, n do parts[i] = jenc(v[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			table.insert(parts, jenc(tostring(k)) .. ":" .. jenc(val))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("jenc: unsupported " .. t)
end
local function jdec(s)
	local i = 1
	local function ws()
		while i <= #s and s:sub(i, i):match("%s") do i += 1 end
	end
	local parse -- forward
	local function pstr()
		i += 1 -- opening quote
		local out = {}
		while i <= #s do
			local c = s:sub(i, i)
			if c == '"' then i += 1 return table.concat(out) end
			if c == "\\" then
				local e = s:sub(i + 1, i + 1)
				if e == "n" then table.insert(out, "\n")
				elseif e == "r" then table.insert(out, "\r")
				elseif e == "t" then table.insert(out, "\t")
				elseif e == "u" then
					local hex = s:sub(i + 2, i + 5)
					table.insert(out, utf8.char(tonumber(hex, 16) or 63))
					i += 4
				else table.insert(out, e) end
				i += 2
			else
				table.insert(out, c)
				i += 1
			end
		end
		error("jdec: unterminated string")
	end
	local function pnum()
		local j = i
		while j <= #s and s:sub(j, j):match("[%d%.%+%-%eE]") do j += 1 end
		local n = tonumber(s:sub(i, j - 1))
		i = j
		if n == nil then error("jdec: bad number") end
		return n
	end
	parse = function()
		ws()
		local c = s:sub(i, i)
		if c == "{" then
			i += 1
			local o = {}
			ws()
			if s:sub(i, i) == "}" then i += 1 return o end
			while true do
				ws()
				local k = pstr()
				ws()
				if s:sub(i, i) ~= ":" then error("jdec: want :") end
				i += 1
				o[k] = parse()
				ws()
				local d = s:sub(i, i)
				if d == "}" then i += 1 return o end
				if d ~= "," then error("jdec: want ,") end
				i += 1
			end
		elseif c == "[" then
			i += 1
			local a = {}
			ws()
			if s:sub(i, i) == "]" then i += 1 return a end
			while true do
				table.insert(a, parse())
				ws()
				local d = s:sub(i, i)
				if d == "]" then i += 1 return a end
				if d ~= "," then error("jdec: want ,") end
				i += 1
			end
		elseif c == '"' then
			return pstr()
		elseif c == "t" and s:sub(i, i + 3) == "true" then
			i += 4
			return true
		elseif c == "f" and s:sub(i, i + 4) == "false" then
			i += 5
			return false
		elseif c == "n" and s:sub(i, i + 3) == "null" then
			i += 4
			return nil
		else
			return pnum()
		end
	end
	local v = parse()
	ws()
	return v
end
M.jsonEncode = jenc
M.jsonDecode = jdec
-- scripted model: tests set M.aiResponder(url, bodyTable) -> response table
M.aiResponder = nil
local httpSvc = {
	JSONEncode = function(_, v) return jenc(v) end,
	JSONDecode = function(_, str) return jdec(str) end,
	RequestAsync = function(_) error("no HTTP in CLI tests") end,
	PostAsync = function(_, url, json)
		if M.aiResponder then
			local body = jdec(json)
			local dec = M.aiResponder(url, body)
			return jenc(dec)
		end
		error("no HTTP in CLI tests (set M.aiResponder for agent tests)")
	end,
}
local function folder(name)
	local f = newInst("Folder")
	f.Name = name
	return f
end
local rsFolder = folder("ReplicatedStorage")
local wsFolder = folder("Workspace")
local sssFolder = folder("ServerScriptService")
local sstFolder = folder("ServerStorage")
local spFolder = folder("StarterPlayer")
local sgFolder = folder("StarterGui")
local lightingSvc = {
	ClockTime = 12, TimeOfDay = "12:00:00", Brightness = 2, GlobalShadows = true,
	Ambient = {}, OutdoorAmbient = {}, FogEnd = 1000, FogStart = 0,
}

game = {
	Name = "game",
	PlaceId = 123456,
	JobId = "testjob-1234",
	Players = playersSvc,
	Workspace = wsFolder,
	ReplicatedStorage = rsFolder,
	ServerScriptService = sssFolder,
	ServerStorage = sstFolder,
	StarterPlayer = spFolder,
	StarterGui = sgFolder,
	_children = { rsFolder, wsFolder, sssFolder, sstFolder, spFolder, sgFolder },
	GetService = function(self, n)
		if n == "Players" then return playersSvc end
		if n == "HttpService" then return httpSvc end
		if n == "ReplicatedStorage" then return rsFolder end
		if n == "Workspace" then return wsFolder end
		if n == "Lighting" then return lightingSvc end
		if n == "ServerScriptService" then return sssFolder end
		if n == "ServerStorage" then return sstFolder end
		if n == "StarterPlayer" then return spFolder end
		if n == "StarterGui" then return sgFolder end
		return nil
	end,
	FindFirstChild = function(self, n)
		for _, c in ipairs(self._children) do
			if c.Name == n then return c end
		end
		return nil
	end,
}
for _, f in ipairs({ rsFolder, wsFolder, sssFolder, sstFolder, spFolder, sgFolder }) do
	f._parent = game
end
workspace = wsFolder

-- ReplicatedStorage doubles as module registry for the server file
rsFolder.WaitForChild = function(self, n)
	if M.preloads and M.preloads[n] then return M.preloads[n] end
	error("WaitForChild(" .. tostring(n) .. ") with no preload")
end

-- one demo part so map_scan is non-empty
local demoPart = newInst("Part")
demoPart.Name = "Spawn"
demoPart.Position = V3(10, 0, 5)
demoPart.Size = V3(4, 1, 4)
demoPart.Parent = wsFolder

function M.chatRemote()
	for _, r in ipairs(M.captured.remotes) do
		if r.Name == "HekzChat" then return r end
	end
	return nil
end

local passCount, failCount = 0, 0
function M.check(ok, label, extra)
	if ok then
		passCount += 1
		realPrint("  ok   " .. label)
	else
		failCount += 1
		realPrint("  FAIL " .. label .. (extra and ("  :: " .. tostring(extra):sub(1, 300)) or ""))
	end
end
function M.summary()
	realPrint(string.format("== %d passed, %d failed ==", passCount, failCount))
	return failCount
end
-- (bundled: M stays in scope for the snippets below; no return here)
