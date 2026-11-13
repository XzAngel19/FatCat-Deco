-- Fat Cat Project | Core & Initialization/FatCatEnv.lua
--
-- The executor boundary: one place that touches capabilities the base game
-- does not have, so every module above it can stay plain Luau.
--
--   local Env = FatCat.require("FatCatEnv")
--   Env.name                 -- "synapse", "Solara", or "unknown"
--   Env.has("hookfunction")  -- boolean, checked once and cached
--   Env.unload()             -- the whole product, in the right order
--
-- Nothing here pokes at metatables, hooks game methods, or edits the global
-- environment. It *detects* what is available and *reports* it. The detection
-- helpers exist because the analysis modules need to know whether a hook is
-- possible before they offer a button that would otherwise do nothing.
--
-- Unload order matters and is the reason this module exists at all:
--
--   1. stop the render loop           (the harness owns it, via Core)
--   2. drop the window                (the shell, via Hub:Destroy)
--   3. run module teardowns           (reverse load order, via Core:Destroy)
--   4. clear the project global       (last, so step 3 could still reach it)
--
-- Doing 4 before 3 is the classic unload bug: a module's teardown then reads
-- a nil global and throws into the void.

local Core, Env
Env = {}

---Capabilities this product actually uses. A capability that is not listed is
---reported as false even if the executor has it, so a typo cannot silently
---turn into "supported".
Env.CAPABILITIES = {
	"writefile", "readfile", "isfile", "makefolder", "delfile", "appendfile",
	"getgenv", "getrenv", "getreg", "getgc", "getinstances", "getnilinstances",
	"getloadedmodules", "getscriptbytecode", "getscriptclosure", "getscripts",
	"hookfunction", "hookmetamethod", "replaceclosure", "newcclosure",
	"getrawmetatable", "setreadonly", "isreadonly", "getnamecallmethod",
	"setnamecallmethod", "checkcaller", "islclosure", "iscclosure",
	"getconnections", "firesignal", "fireclickdetector", "firetouchinterest",
	"queue_on_teleport", "setclipboard", "identifyexecutor", "request",
	"http_request", "syn", "fluxus", "is_sirhurt_closure", "getthreadidentity",
	"setthreadidentity",
}

-- Name -> executor label. First match wins; the order puts the specific
-- identifiers before the generic ones so a Synapse fork that also defines
-- `fluxus` is still reported as what it is.
local IDENTIFIERS = {
	{ "synapse", "Synapse X" },
	{ "krnl", "Krnl" },
	{ "fluxus", "Fluxus" },
	{ "solara", "Solara" },
	{ "swift", "Swift" },
	{ "wave", "Wave" },
	{ "codex", "Codex" },
	{ "hydrogen", "Hydrogen" },
	{ "delta", "Delta" },
	{ "arcturus", "Arcturus" },
	{ "sirhurt", "SirHurt" },
	{ "electron", "Electron" },
	{ "scriptware", "ScriptWare" },
}

Env.name = "unknown"
Env.caps = {}
Env.detectedAt = os.clock()

---True when the executor exposes `name` as a function.
function Env.has(name)
	if Env.caps[name] == nil then
		Env.caps[name] = type(Core.env[name]) == "function"
	end
	return Env.caps[name]
end

---The live function, or nil. Prefer this over indexing Core.env directly:
---the cache is invalidated when the environment is re-inspected.
function Env.fn(name)
	if not Env.has(name) then
		return nil
	end
	return Core.env[name]
end

---First working file-API call, with a clear error when there is none.
function Env.fs(name, ...)
	local impl = Env.fn(name)
	if not impl then
		return false, ("this executor has no %s()"):format(name)
	end
	local ok, result = pcall(impl, ...)
	if not ok then
		return false, tostring(result)
	end
	return true, result
end

---Identify the executor. Detection is cheap and runs once at boot; the name
---is shown on the Home tab and stored in Core.state for telemetry-free logs.
function Env.detect()
	Env.caps = {}
	for _, capability in Env.CAPABILITIES do
		Env.caps[capability] = type(Core.env[capability]) == "function"
	end

	local label = "unknown"
	local identify = Env.fn("identifyexecutor")
	if identify then
		local ok, name = pcall(identify)
		if ok and type(name) == "string" and name ~= "" then
			label = name
		end
	end

	if label == "unknown" then
		for _, pair in IDENTIFIERS do
			if type(Core.env[pair[1]]) ~= "nil" then
				label = pair[2]
				break
			end
		end
	end

	Env.name = label
	Core.state.executor = label
	Core.state.script = "standard"

	-- A handful of executors flag their own identity differently; keep both
	-- spellings so a user's bug report is useful.
	if Env.has("getthreadidentity") then
		local ok, identity = pcall(Core.env.getthreadidentity)
		if ok then
			Core.state.threadIdentity = identity
		end
	end
	return label
end

---Capabilities grouped for the Home tab. Returns rows of { label, ok }.
function Env.summary()
	local groups = {
		{ label = "files", caps = { "writefile", "readfile", "isfile", "makefolder" } },
		{ label = "introspection", caps = { "getgc", "getinstances", "getrawmetatable", "getconnections" } },
		{ label = "hooking", caps = { "hookfunction", "hookmetamethod", "newcclosure" } },
		{ label = "scripts", caps = { "getscriptbytecode", "getscripts", "getloadedmodules" } },
		{ label = "http", caps = { "request", "http_request" } },
	}
	local rows = {}
	for _, group in groups do
		local present, total = 0, #group.caps
		for _, capability in group.caps do
			if Env.has(capability) then
				present += 1
			end
		end
		table.insert(rows, {
			label = ("%s %d/%d"):format(group.label, present, total),
			ok = present == total,
			partial = present > 0 and present < total,
		})
	end
	return rows
end

-- ==========================================================================
-- Unload
-- ==========================================================================

---Tear the product down. Safe to call twice, and safe to call from inside a
---button callback (the window it lives in is destroyed by this).
function Env.unload()
	Core:Log("info", "unload requested")

	-- 1. Connections and render steps the project owns.
	local stopLoops = Core:GetService("stopLoops")
	if type(stopLoops) == "function" then
		pcall(stopLoops)
	end

	-- 2. The window. Hub:Destroy drops the GUI and every global connection it
	--    made; the project's own components die with their parent. The service
	--    lookup is the project's own registration; the global is what the shell
	--    publishes, and it survives Core:Destroy unless it is torn down here.
	local hub = Core:GetService("hub") or _G.FatCatHub
	if hub then
		local destroy = (hub :: any).Destroy
		if type(destroy) == "function" then
			pcall(destroy, hub)
		end
	end
	local Menu = Core.modules["FatCatMenu"]
	if Menu and type(Menu.unmount) == "function" then
		pcall(Menu.unmount)
	end

	-- 3. Module teardowns, reverse load order.
	local ran = Core:Destroy()

	-- 4. The loader's own unload hook, so the next run starts clean.
	local runtime = Core.env
	if runtime.FatCatProjectUnload == Env.unload then
		runtime.FatCatProjectUnload = nil
	end
	if (runtime :: any).FatCatHubUnload ~= nil and _G.FatCatHub == nil then
		(runtime :: any).FatCatHubUnload = nil
	end

	pcall(print, ("[Fat Cat] unloaded (%d teardown(s))"):format(ran))
	return ran
end

---Print a one-line environment report to the executor console. Called by
---FatCatInit when FatCatVerbose is on.
function Env.report()
	local caps = 0
	for _, capability in Env.CAPABILITIES do
		if Env.has(capability) then
			caps += 1
		end
	end
	print(("[Fat Cat] executor: %s · %d/%d capabilities · %d module(s)")
		:format(Env.name, caps, #Env.CAPABILITIES, #Core.loadOrder))
end

return function(core, _signal)
	Core = core
	return Env
end
