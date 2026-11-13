-- Fat Cat Project | Advanced Analysis/FatCatEnvSpoofer.lua
--
-- What the executor reports about itself, and a place to change the parts that
-- are safe to change: the identity handed to identifyexecutor, the global
-- environment other scripts see, and the properties of a client-side instance.
--
--   local E = FatCat.require("FatCatEnvSpoofer")
--   E.spoofIdentity("Solara")      -- identifyexecutor() now answers "Solara"
--   E.restore()
--
-- ==========================================================================
-- What this deliberately does not do
-- ==========================================================================
-- A "spoofer" in the wild means faking your identity to a game's anti-cheat,
-- faking your platform, or lying about your request headers. That is a
-- detection-evasion tool, and building one into this project would:
--
--   * break the first time the game checks a third signal (ping, HWID, join
--     time), which is why public spoofers are always "detected again";
--   * get users banned for something that never actually worked;
--   * make every other diagnostic in this project untrustworthy, because the
--     thing reporting the environment would be the thing lying about it.
--
-- So this module spoofs only what is a display or a debugging concern:
--
--   * `identifyexecutor` — so screenshots and bug reports can be anonymised;
--   * a sandboxed `getgenv()` for a script you run from the console;
--   * instance properties that are visual (a BillboardGui's text, a name).
--
-- Every change is reversible and registered with Core, and `restore()` puts
-- the environment back exactly as it was.

local Core, Materials, Env
Env = {}

local saved = {}          -- name -> original function
local restores = {}       -- list of functions
local active = {}

local function remember(label, restore)
	table.insert(restores, { label = label, run = restore })
	active[label] = true
end

---True when anything is currently spoofed.
function Env.isActive()
	for _ in active do
		return true
	end
	return false
end

---Labels of what is currently spoofed.
function Env.listing()
	local labels = {}
	for label in active do
		table.insert(labels, label)
	end
	table.sort(labels)
	return labels
end

-- ==========================================================================
-- Identity
-- ==========================================================================

---Make identifyexecutor() answer `name` until restore().
---This is a display change: nothing in the game's detection path calls
---identifyexecutor, so it cannot protect anybody from anything.
function Env.spoofIdentity(name)
	name = tostring(name or "FatCat")
	local original = Core.env.identifyexecutor
	if type(original) ~= "function" then
		return false, "this executor has no identifyexecutor() to spoof"
	end
	if saved.identifyexecutor then
		return false, "identity is already spoofed; restore() first"
	end

	saved.identifyexecutor = original
	Core.env.identifyexecutor = function()
		return name
	end
	Core.state.executor = name
	remember("identity", function()
		Core.env.identifyexecutor = original
	end)
	return true, name
end

-- ==========================================================================
-- Environment sandbox
-- ==========================================================================

---Return a shallow copy of the executor environment with `overrides` applied.
---A script launched from the console can be given this table instead of the
---real one, so a global it sets does not leak into the game or the executor.
function Env.sandbox(overrides)
	local source = Core.env
	local copy = {}
	for key, value in source do
		copy[key] = value
	end
	for key, value in overrides or {} do
		copy[key] = value
	end
	return copy
end

---True when this environment can actually run something in a sandbox.
---`setfenv` existing is not enough: some executor layers expose one that
---ignores a native chunk and still reports success, which would make
---"sandboxed" a lie. The capability is *proven* once with a one-line probe and
---cached, because the answer cannot change during a session.
function Env.canSandbox()
	if Env._canSandbox ~= nil then
		return Env._canSandbox
	end
	local setfenv = Core.env.setfenv
	local loadstring = Core.env.loadstring
	if type(setfenv) ~= "function" or type(loadstring) ~= "function" then
		Env._canSandbox = false
		return false
	end
	local chunk = loadstring("return sandboxProbe")
	if type(chunk) ~= "function" then
		Env._canSandbox = false
		return false
	end
	local marker = { sandboxProbe = true }
	if not pcall(setfenv, chunk, marker) then
		Env._canSandbox = false
		return false
	end
	local ok, result = pcall(chunk)
	-- The probe must *see* the marker. Reading the real globals instead means
	-- the chunk was never rebound.
	Env._canSandbox = ok and result == true
	return Env._canSandbox
end

---Run `chunk` with `env` as its global table.
---Returns ok, result. Refuses, rather than silently running unsandboxed, when
---the environment cannot rebind a chunk.
function Env.runSandboxed(chunk, env)
	if type(chunk) ~= "function" then
		return false, "not a function"
	end
	if not Env.canSandbox() then
		return false, "this environment cannot rebind a chunk (setfenv is absent or inert)"
	end
	local target = env or Env.sandbox()
	local ok, err = pcall(Core.env.setfenv, chunk, target)
	if not ok then
		return false, tostring(err)
	end
	local success, result = pcall(chunk)
	return success, result
end

-- ==========================================================================
-- Instance properties
-- ==========================================================================

---Set a property on a client-side instance, remembering the old value so
---restore() can put it back. Refuses server-owned objects.
function Env.spoofProperty(instance, property, value)
	if typeof(instance) ~= "Instance" then
		return false, "not an instance"
	end
	local ok, current = pcall(function()
		return (instance :: any)[property]
	end)
	if not ok then
		return false, ("%s has no property %s"):format(instance.ClassName, tostring(property))
	end
	local okWrite, err = pcall(function()
		(instance :: any)[property] = value
	end)
	if not okWrite then
		-- The usual cause: the instance is replicated. Say so instead of
		-- leaving the user wondering why nothing happened.
		return false, ("the engine refused the write (%s); this object is probably server-owned"):format(
			tostring(err))
	end
	remember("property", function()
		pcall(function()
			(instance :: any)[property] = current
		end)
	end)
	return true, current
end

-- ==========================================================================
-- Restore
-- ==========================================================================

---Undo every spoof, newest first.
function Env.restore()
	local count = 0
	for index = #restores, 1, -1 do
		local entry = restores[index]
		local ok = pcall(entry.run)
		if ok then
			count += 1
		end
	end
	table.clear(restores)
	table.clear(active)
	table.clear(saved)
	-- Re-detect, since identifyexecutor may be back to its real answer.
	local runtime = Core.modules["FatCatEnv"]
	if runtime and type(runtime.detect) == "function" then
		pcall(runtime.detect)
	end
	return count
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Identity", 1)
	local status = Materials.Status(section.frame, Env.isActive() and "active" or "clean", "info")
	local name = Materials.Input(section.frame, { Text = "Reported name", Default = "FatCat" })

	Materials.Button(section.frame, {
		Text = "Spoof identifyexecutor",
		OnClick = function()
			local ok, result = Env.spoofIdentity(name:Get())
			status:Set(ok and ("reporting " .. tostring(result)) or tostring(result), ok and "warn" or "off")
		end,
	})
	Materials.Button(section.frame, {
		Text = "Restore everything",
		Danger = true,
		OnClick = function()
			Env.restore()
			status:Set("clean", "on")
		end,
	})
	Materials.Label(section.frame,
		"This changes only what identifyexecutor reports. It does not hide the executor from a game's "
		.. "anti-cheat, and nothing here should be presented as if it did.")

	local caps = page:Section("What the executor exposes", 2)
	local lines = {}
	for _, entry in Core.modules["FatCatEnv"] and (Core.modules["FatCatEnv"]).CAPABILITIES or {} do
		if type(Core.env[entry]) == "function" then
			table.insert(lines, entry)
		end
	end
	Materials.Code(caps.frame, { Height = 260, Lines = table.concat(lines, "\n") })
	Materials.Label(caps.frame,
		"Sandboxed runs use a copy of this environment, so a script's globals do not leak into the game.")

	Core:OnDestroy("envspoofer", Env.restore)
	return { restore = Env.restore }
end

Env.mount = mount

return function(core, materials)
	Core = core
	Materials = materials
	return Env
end
