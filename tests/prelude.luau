-- Bundle prelude: wire preloaded modules + server globals (main chunk).
__MOD_Tools = __MOD_ToolRegistry.new(__MOD_Config)
__MOD_Config.Chat.CooldownSec.Value = 0 -- no cooldown in tests
M.Tools = __MOD_Tools
M.Config = __MOD_Config
M.preloads = { HekzConfig = __MOD_Config, HekzBook = __MOD_Book }
script = { Parent = { WaitForChild = function(_, n)
	if n == "ToolRegistry" then return __MOD_ToolRegistry end
	return nil
end } }
require = function(x) return x end -- server requires resolve to preloads
HekzTest = M
