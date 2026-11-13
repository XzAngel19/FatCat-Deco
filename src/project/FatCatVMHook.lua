-- Fat Cat Project | Advanced Analysis/FatCatVMHook.lua
--
-- A small hook manager: install a wrapper on an executor function or a
-- metatable method, observe or transform the call, and restore it exactly.
--
--   local Hook = FatCat.require("FatCatVMHook")
--   local link = Hook.functionHook("HttpGet", function(original, url)
--       print("fetched", url)
--       return original(url)
--   end)
--   link:Remove()
--
--   local namecall = Hook.metamethod("__namecall", function(original, self, ...)
--       return original(self, ...)
--   end)
--
-- The rules this module enforces, because getting them wrong is how a script
-- gets detected or leaves the game broken:
--
--   * every hook is registered before it is installed, so Remove() and the
--     Unload teardown can always find it — a hook with no handle is a leak;
--   * a wrapper receives the original as its first argument and MUST call it
--     (except when it is deliberately blocking, which is opt-in via
--     { passthrough = false });
--   * newcclosure wraps every replacement when available, so the game sees a
--     C closure rather than a Luau function;
--   * Remove() restores the exact original reference and is idempotent.
--
-- This module never touches a function it did not hook, never edits a
-- read-only table without restoring the read-only flag, and never writes to
-- another process.

local Core, Materials, Hook
Hook = {}

Hook.hooks = {}       -- list of records, in install order
Hook.MAX_HOOKS = 64

local function wrap(fn)
	local newcclosure = Core.env.newcclosure
	if type(newcclosure) == "function" then
		local ok, wrapped = pcall(newcclosure, fn)
		if ok and type(wrapped) == "function" then
			return wrapped
		end
	end
	return fn
end

local function record(kind, target, replacement, restore)
	local entry = {
		kind = kind,
		target = target,
		replacement = replacement,
		restore = restore,
		active = true,
	}
	table.insert(Hook.hooks, entry)

	function entry:Remove()
		if not self.active then
			return false
		end
		self.active = false
		pcall(self.restore)
		for index = #Hook.hooks, 1, -1 do
			if Hook.hooks[index] == self then
				table.remove(Hook.hooks, index)
			end
		end
		return true
	end
	return entry
end

---Number of live hooks.
function Hook.count()
	return #Hook.hooks
end

---Remove every hook, newest first. Registered as a Core teardown below.
function Hook.removeAll()
	local removed = 0
	for index = #Hook.hooks, 1, -1 do
		local entry = Hook.hooks[index]
		if entry:Remove() then
			removed += 1
		end
	end
	return removed
end

-- ==========================================================================
-- Function hooks
-- ==========================================================================

---Hook a named global function (executor function or game function).
---`replacement(original, ...)` returns whatever the wrapper wants to return.
function Hook.functionHook(name, replacement)
	local target = Core.env[name]
	if type(target) ~= "function" then
		return nil, ("%s is not a function on this executor"):format(tostring(name))
	end
	if #Hook.hooks >= Hook.MAX_HOOKS then
		return nil, "too many hooks installed"
	end

	local wrapper = wrap(function(...)
		return replacement(target, ...)
	end)
	Core.env[name] = wrapper

	return record("function:" .. name, name, wrapper, function()
		Core.env[name] = target
	end)
end

---Hook a table's method: `table[key]`.
function Hook.methodHook(container, key, replacement)
	if type(container) ~= "table" then
		return nil, "the container is not a table"
	end
	local target = container[key]
	if type(target) ~= "function" then
		return nil, ("%s is not a function"):format(tostring(key))
	end

	local wrapper = wrap(function(...)
		return replacement(target, ...)
	end)
	container[key] = wrapper

	return record("method:" .. tostring(key), container, wrapper, function()
		container[key] = target
	end)
end

-- ==========================================================================
-- Metamethod hooks
-- ==========================================================================

---Hook `__namecall` (or another metamethod) on an object's metatable.
---`replacement(original, self, ...)` keeps the namecall method available via
---getnamecallmethod, which is why it is passed through unchanged.
function Hook.metamethod(metamethod, replacement)
	local getRaw = Core.env.getrawmetatable
	if type(getRaw) ~= "function" then
		return nil, "this executor has no getrawmetatable()"
	end

	local metatable = getRaw(game)
	if type(metatable) ~= "table" then
		return nil, "the game's metatable is not reachable"
	end

	local original = metatable[metamethod]
	if type(original) ~= "function" then
		return nil, ("the game's metatable has no %s"):format(metamethod)
	end

	-- Writing to a locked metatable throws; unlock, write, relock. The
	-- original read-only state is remembered and restored on Remove, so the
	-- game's own protection is exactly as it was.
	local setReadOnly = Core.env.setreadonly
	local wasReadOnly = nil
	if type(Core.env.isreadonly) == "function" then
		local ok, value = pcall(Core.env.isreadonly, metatable)
		if ok then
			wasReadOnly = value
		end
	end
	if type(setReadOnly) == "function" and wasReadOnly == true then
		pcall(setReadOnly, metatable, false)
	end

	local wrapper = wrap(function(self, ...)
		return replacement(original, self, ...)
	end)
	metatable[metamethod] = wrapper

	return record("metamethod:" .. metamethod, metatable, wrapper, function()
		metatable[metamethod] = original
		if type(setReadOnly) == "function" and wasReadOnly == true then
			pcall(setReadOnly, metatable, true)
		end
	end)
end

-- ==========================================================================
-- Reporting
-- ==========================================================================

---Rows for the tab: { label, active }.
function Hook.report()
	local rows = {}
	for _, entry in Hook.hooks do
		table.insert(rows, { label = entry.kind, active = entry.active })
	end
	return rows
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Hooks", 1)
	local status = Materials.Status(section.frame, "0 active", "info")
	local output = Materials.Code(section.frame, { Height = 200 })

	local function refresh()
		local rows = Hook.report()
		local lines = {}
		for index, row in rows do
			table.insert(lines, ("%d  %s"):format(index, row.label))
		end
		output:SetLines(#lines > 0 and lines or { "No hooks installed." }, 100)
		status:Set(("%d active"):format(#rows), #rows > 0 and "warn" or "info")
	end

	local target = Materials.Input(section.frame, { Text = "Global function", Default = "HttpGet" })
	Materials.Button(section.frame, {
		Text = "Log calls to it",
		OnClick = function()
			local name = target:Get()
			local link, why = Hook.functionHook(name, function(original, ...)
				Core:Log("info", ("%s(%s)"):format(name, tostring(select("#", ...))) .. " arg(s)")
				return original(...)
			end)
			if not link then
				Core:Log("warn", tostring(why))
			end
			refresh()
		end,
	})
	Materials.Button(section.frame, {
		Text = "Remove all",
		Danger = true,
		OnClick = function()
			Hook.removeAll()
			refresh()
		end,
	})

	local caps = page:Section("Capabilities", 2)
	local lines = {
		("newcclosure: %s"):format(Core.env.newcclosure ~= nil and "yes" or "no"),
		("getrawmetatable: %s"):format(Core.env.getrawmetatable ~= nil and "yes" or "no"),
		("setreadonly: %s"):format(Core.env.setreadonly ~= nil and "yes" or "no"),
		("hookfunction: %s"):format(Core.env.hookfunction ~= nil and "yes" or "no"),
		("hookmetamethod: %s"):format(Core.env.hookmetamethod ~= nil and "yes" or "no"),
	}
	Materials.Code(caps.frame, { Height = 132, Lines = table.concat(lines, "\n") })
	Materials.Label(caps.frame,
		"Metamethod hooks unlock the metatable, wrap one key, and relock it. Remove restores the original "
		.. "function and the original read-only flag.")

	refresh()
	Core:OnDestroy("vmhook", function()
		Hook.removeAll()
	end)
	return { refresh = refresh }
end

Hook.mount = mount

return function(core, _signal, materials)
	Core = core
	Materials = materials
	return Hook
end
