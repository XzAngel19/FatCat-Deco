-- Fat Cat Project | Advanced Analysis/FatCatSpy.lua
--
-- Remote spy: logs every RemoteEvent / RemoteFunction the client fires or
-- receives, with argument types and a short preview of each value.
--
--   local Spy = FatCat.require("FatCatSpy")
--   Spy.start()                       -- hook and begin logging
--   Spy.stop()                        -- restore the originals
--   Spy.entries                       -- ring buffer, newest last
--   Spy.subscribe(function(entry) ... end)
--
-- How the hook works, and why it is written this way:
--
--   * the originals are looked up once and stored, so stop() restores exactly
--     what was there before and can never leave a remote permanently wrapped;
--   * every hook is wrapped in newcclosure when the executor has it, so the
--     game cannot detect a foreign Luau closure on the remote;
--   * the call is passed through with pcall and the original error is
--     re-raised: a spy that swallows errors would hide the game's own bugs;
--   * arguments are rendered eagerly into strings, not stored as references.
--     A RemoteEvent argument can be a table the game mutates a frame later;
--     keeping the reference would make every log entry show the final state.
--
-- This is a diagnostic. It does not modify arguments, drop calls, or replay
-- them, and that is on purpose: a spy that can also forge remotes is a griefing
-- tool, not an analysis one.

local Core, Signal, Materials, Spy
Spy = {}

Spy.MAX_ENTRIES = 200
Spy.entries = {}
Spy.listening = false

local originals = {}   -- remote -> { FireServer = fn, ... }
local subscriptions = {}
local changed = nil

-- ==========================================================================
-- Argument rendering
-- ==========================================================================

local function describe(value, depth)
	depth = depth or 0
	local kind = typeof(value)
	if kind == "string" then
		local shown = value
		if #shown > 60 then
			shown = shown:sub(1, 57) .. "..."
		end
		return ("%q"):format(shown)
	elseif kind == "number" or kind == "boolean" or kind == "nil" then
		return tostring(value)
	elseif kind == "Instance" then
		return ("%s[%s]"):format(value.Name, value.ClassName)
	elseif kind == "Vector3" then
		return ("V3(%.1f, %.1f, %.1f)"):format(value.X, value.Y, value.Z)
	elseif kind == "CFrame" then
		local p = value.Position
		return ("CF(%.0f, %.0f, %.0f)"):format(p.X, p.Y, p.Z)
	elseif kind == "Color3" then
		return ("RGB(%d, %d, %d)"):format(
			math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255))
	elseif kind == "table" then
		if depth >= 1 then
			return "{...}"
		end
		local parts = {}
		local count = 0
		for key, entry in value do
			count += 1
			if count > 6 then
				table.insert(parts, "…")
				break
			end
			table.insert(parts, ("%s=%s"):format(tostring(key), describe(entry, depth + 1)))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif kind == "userdata" then
		return "<userdata>"
	end
	return ("<%s>"):format(kind)
end

Spy.describe = describe

local function describeAll(...)
	local count = select("#", ...)
	local parts = {}
	for index = 1, count do
		table.insert(parts, describe(select(index, ...)))
	end
	return table.concat(parts, ", ")
end

-- ==========================================================================
-- Ring buffer
-- ==========================================================================

local function push(entry)
	table.insert(Spy.entries, entry)
	while #Spy.entries > Spy.MAX_ENTRIES do
		table.remove(Spy.entries, 1)
	end
	if changed then
		changed:Fire(entry)
	end
	for _, handler in subscriptions do
		pcall(handler, entry)
	end
end

---Subscribe to new entries. Returns an unsubscribe function.
function Spy.subscribe(handler)
	table.insert(subscriptions, handler)
	return function()
		for index = #subscriptions, 1, -1 do
			if subscriptions[index] == handler then
				table.remove(subscriptions, index)
			end
		end
	end
end

---Clear the log without stopping the hook.
function Spy.clear()
	table.clear(Spy.entries)
end

-- ==========================================================================
-- Hooks
-- ==========================================================================

local function hookMethod(remote, methodName, direction, namecallName)
	local original = (remote :: any)[methodName]
	if type(original) ~= "function" then
		return false
	end

	originals[remote] = originals[remote] or {}
	originals[remote][methodName] = original

	local replacement = function(self, ...)
		-- checkcaller tells us the call came from executor code (us) rather
		-- than from the game; only the game's calls are interesting.
		local fromGame = true
		if Spy._checkCaller then
			local ok, result = pcall(Spy._checkCaller)
			fromGame = ok and not result
		end

		if fromGame then
			push({
				remote = remote,
				name = remote.Name,
				className = remote.ClassName,
				method = namecallName or methodName,
				direction = direction,
				args = describeAll(...),
				time = os.clock(),
			})
		end

		local results = table.pack(original(self, ...))
		return table.unpack(results, 1, results.n)
	end

	local expose = Core.env.newcclosure
	if type(expose) == "function" then
		local ok, wrapped = pcall(expose, replacement)
		if ok then
			replacement = wrapped
		end
	end

	(remote :: any)[methodName] = replacement
	return true
end

local function restoreAll()
	for remote, methods in originals do
		for methodName, original in methods do
			pcall(function()
				(remote :: any)[methodName] = original
			end)
		end
	end
	table.clear(originals)
end

---Start spying. Returns true, and the number of remotes hooked.
function Spy.start()
	if Spy.listening then
		return true, #originals
	end
	if Core.env.checkcaller then
		Spy._checkCaller = Core.env.checkcaller
	end

	local hooked = 0
	local function visit(parent)
		if not parent then
			return
		end
		local ok, descendants = pcall(function()
			return parent:GetDescendants()
		end)
		if not ok then
			return
		end
		for _, child in descendants do
			if child:IsA("RemoteEvent") then
				if hookMethod(child, "FireServer", "→") then
					hooked += 1
				end
				if hookMethod(child, "OnClientEvent", "←") then
					hooked += 1
				end
			elseif child:IsA("RemoteFunction") then
				if hookMethod(child, "InvokeServer", "→", "InvokeServer") then
					hooked += 1
				end
				if hookMethod(child, "OnClientInvoke", "←", "OnClientInvoke") then
					hooked += 1
				end
			elseif child:IsA("UnreliableRemoteEvent") then
				if hookMethod(child, "FireServer", "→") then
					hooked += 1
				end
			elseif child:IsA("BindableEvent") then
				if hookMethod(child, "Fire", "·", "Fire") then
					hooked += 1
				end
			end
		end
	end

	visit(game:GetService("ReplicatedStorage"))
	visit(game:GetService("ReplicatedFirst"))
	visit(game:GetService("Workspace"))

	Spy.listening = true
	Core:OnDestroy("spy", Spy.stop)
	return true, hooked
end

---Restore every hooked remote.
function Spy.stop()
	if not Spy.listening then
		return true
	end
	restoreAll()
	Spy.listening = false
	return true
end

---Readable log: one line per entry, newest last.
function Spy.report()
	local lines = {}
	for _, entry in Spy.entries do
		table.insert(lines, ("%6.2f %s %s:%s(%s)"):format(
			entry.time % 1000, entry.direction, entry.name, entry.method, entry.args))
	end
	return table.concat(lines, "\n")
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Remote spy", 1)
	local status = Materials.Status(section.frame, "stopped", "off")
	local output = Materials.Code(section.frame, { Height = 300 })
	local live = {}

	Materials.Button(section.frame, {
		Text = "Start",
		OnClick = function()
			local ok, count = Spy.start()
			if ok then
				status:Set(("listening · %d hook(s)"):format(count or 0), "on")
			else
				status:Set(tostring(count), "off")
			end
		end,
	})
	Materials.Button(section.frame, {
		Text = "Stop",
		Danger = true,
		OnClick = function()
			Spy.stop()
			status:Set("stopped", "off")
		end,
	})
	Materials.Button(section.frame, {
		Text = "Clear",
		OnClick = function()
			Spy.clear()
			table.clear(live)
			output:SetLines({})
		end,
	})

	Spy.subscribe(function(entry)
		table.insert(live, ("%s %s:%s(%s)"):format(
			entry.direction, entry.name, entry.method, entry.args))
		while #live > 200 do
			table.remove(live, 1)
		end
		output:SetLines(live, 200)
		output:ScrollToBottom()
	end)

	return { clear = Spy.clear, entries = function()
		return Spy.entries
	end }
end

Spy.mount = mount

return function(core, signal, materials)
	Core = core
	Signal = signal
	Materials = materials
	changed = Signal.new("spy:entry")
	return Spy
end
