-- Fat Cat Project | Core & Initialization/FatCatCore.lua
--
-- The single global the project hangs off: service registry, module cache,
-- shared state, and one teardown that runs in reverse load order.
--
--   local Core = FatCat                     -- set by FatCatInit
--   local Config = Core.require("FatCatConfig")
--   Core:OnDestroy("my module", function() ... end)
--
-- Three rules this file exists to enforce:
--
--   1. Load once, in any order. `require` caches a module table, remembers a
--      module that failed (so a second caller gets the first error instead of
--      retrying into a different failure), and refuses a cycle with a readable
--      message rather than blowing the stack.
--
--   2. Everything that allocates registers a teardown. A leftover Connection,
--      a running RenderStepped, or a frame still parented to CoreGui is the
--      difference between "unloaded" and "still running under the map".
--
--   3. State lives here, not in module locals. `Core.state.selectedScript` is
--      shared by the inspector, the decompiler and the console; three copies
--      of the same local would drift apart on the first rebuild.

local Core = {}
Core.VERSION = "2.1.0"
Core.NAME = "Fat Cat"
Core.TAG = "[Fat Cat]"

-- Executor environment: getgenv() when the executor provides it, _G otherwise.
-- FatCatInit may replace this before any module loads.
Core.env = (typeof(getgenv) == "function" and getgenv()) or _G

Core.modules = {}     -- path -> module table
Core.loadErrors = {}  -- path -> message
Core.loadOrder = {}   -- paths, in load order
Core.teardowns = {}   -- { { name = string, run = function }, ... }
Core.services = {}    -- name -> any (window, connections, threads)
Core.state = {}       -- shared scratch: selectedScript, theme, executor, ...
Core.destroyed = false

-- ==========================================================================
-- Logging
-- ==========================================================================
-- Console installs a real sink; before that, errors go to warn() so a module
-- that fails during boot still leaves a trace in the executor log.

Core.logSink = nil

function Core:SetLogger(sink)
	self.logSink = sink
end

function Core:Log(level, message, ...)
	local sink = self.logSink
	if type(sink) == "function" then
		if pcall(sink, level, message, ...) then
			return
		end
	end
	if level == "error" or level == "warn" then
		pcall(warn, ("%s %s"):format(self.TAG, tostring(message)))
	end
end

-- ==========================================================================
-- Services
-- ==========================================================================
-- Named singletons with a teardown attached: `Core:SetService("window", w)`
-- then `Core:GetService("window")`. Registering the same name twice destroys
-- the previous value first, which is what makes rebuilds safe.

function Core:SetService(name, value, teardown)
	local previous = self.services[name]
	if previous ~= nil and teardown == nil then
		-- No teardown supplied: the caller owns both values, just replace it.
		self.services[name] = value
		return value
	end
	if previous ~= nil and teardown ~= nil and type(previous.Destroy) == "function" then
		pcall(function()
			previous:Destroy()
		end)
	end
	self.services[name] = value
	if type(teardown) == "function" then
		self:OnDestroy("service:" .. name, teardown)
	end
	return value
end

function Core:GetService(name)
	return self.services[name]
end

function Core:DropService(name)
	local value = self.services[name]
	self.services[name] = nil
	if value ~= nil and type(value.Destroy) == "function" then
		pcall(function()
			value:Destroy()
		end)
	end
	return value
end

-- ==========================================================================
-- Modules
-- ==========================================================================

---Register the loader for a module path. FatCatInit does this for the tree.
---@param path string       e.g. "FatCatConfig"
---@param loader function   (core) -> module table
function Core:Register(path, loader)
	self._loaders = self._loaders or {}
	self._loaders[path] = loader
end

---Return the module at `path`, loading it on first use.
function Core:Require(path)
	if self.modules[path] ~= nil then
		return self.modules[path]
	end
	if self.destroyed then
		error(("%s cannot require '%s' after Unload"):format(self.TAG, path), 2)
	end
	if self.loadErrors[path] then
		error(("%s module '%s' failed earlier: %s"):format(self.TAG, path, self.loadErrors[path]), 2)
	end

	local loader = self._loaders and self._loaders[path]
	if type(loader) ~= "function" then
		error(("%s no module registered as '%s'"):format(self.TAG, path), 2)
	end

	self._loading = self._loading or {}
	if self._loading[path] then
		error(("%s circular require at '%s'"):format(self.TAG, path), 2)
	end
	self._loading[path] = true
	local ok, result = pcall(loader, self)
	self._loading[path] = nil

	if not ok then
		self.loadErrors[path] = tostring(result)
		error(("%s module '%s' failed to load: %s"):format(self.TAG, path, tostring(result)), 2)
	end
	if result == nil then
		result = true
	end

	self.modules[path] = result
	table.insert(self.loadOrder, path)
	self:Log("debug", "loaded " .. path)
	return result
end

---Never throws: returns the module, or nil plus the reason it failed.
function Core:TryRequire(path)
	local ok, result = pcall(self.Require, self, path)
	if ok then
		return result
	end
	return nil, tostring(result)
end

Core.require = Core.Require

---True when the module is already in the cache.
function Core:IsLoaded(path)
	return self.modules[path] ~= nil
end

-- ==========================================================================
-- Teardown
-- ==========================================================================

---Register teardown work. Runs newest-first, each under pcall, so one
---failure cannot strand the modules registered before it.
function Core:OnDestroy(name, run)
	if self.destroyed then
		pcall(run)
		return
	end
	table.insert(self.teardowns, { name = name or ("teardown #" .. (#self.teardowns + 1)), run = run })
end

function Core:IsDestroyed()
	return self.destroyed
end

---Tear the project down. Returns how many teardowns ran.
function Core:Destroy()
	if self.destroyed then
		return 0
	end
	self.destroyed = true

	local ran, failed = 0, 0
	for index = #self.teardowns, 1, -1 do
		local entry = self.teardowns[index]
		local ok, err = pcall(entry.run)
		ran += 1
		if not ok then
			failed += 1
			self:Log("error", ("teardown '%s' failed: %s"):format(tostring(entry.name), tostring(err)))
		end
	end
	table.clear(self.teardowns)
	table.clear(self.services)
	table.clear(self.modules)
	table.clear(self.loadOrder)
	table.clear(self.state)

	-- Only release the global if it is still us: a reload may have replaced
	-- it while our teardown was running.
	if _G.FatCatProject == self then
		_G.FatCatProject = nil
	end
	if failed > 0 then
		self:Log("warn", ("Unload finished with %d failed teardown(s)"):format(failed))
	end
	return ran
end

---`Fat Cat 2.1.0 · 9 modules` for a status row.
function Core:Describe()
	return ("%s %s · %d module(s)"):format(self.NAME, self.VERSION, #self.loadOrder)
end

return Core
