-- Fat Cat Project | Core & Initialization/FatCatSignal.lua
--
-- Pub/Sub for the whole project. One object per event, three verbs.
--
--   local Signal = FatCat.require("FatCatSignal")
--   local changed = Signal.new("config:changed")
--   local link = changed:Connect(function(value) print(value) end)
--   changed:Fire("accent")
--   link:Disconnect()
--
-- Why not just a table of callbacks: a module that is torn down during
-- Unload must not leave another module parked in Wait(), and a callback that
-- throws must not swallow the callbacks registered after it. Both rules are
-- enforced here, once, so no feature module has to think about them.
--
--   * Fire copies the dispatch list first, so Connect/Disconnect from inside
--     a callback is safe and a link cut mid-fire stops receiving immediately;
--   * every callback runs under pcall, and the error is handed to
--     Signal.errorHandler when one is installed (FatCatConsole installs it);
--   * Wait() resolves on the next Fire *or* on Destroy, so teardown cannot
--     strand a coroutine.

local Signal = {}
Signal.__index = Signal

---Installed by FatCatConsole so a broken callback is visible instead of silent.
Signal.errorHandler = nil

local function reportError(name, message)
	local handler = Signal.errorHandler
	if type(handler) == "function" then
		pcall(handler, name, message)
	end
end

---Create a signal. `name` only shows up in diagnostics and the console.
function Signal.new(name)
	return setmetatable({
		name = name or "signal",
		_links = {},
		_waiters = {},
		_destroyed = false,
	}, Signal)
end

---Connect `callback`. Returns a link with :Disconnect().
function Signal:Connect(callback)
	if type(callback) ~= "function" then
		error("Signal:Connect expects a function, got " .. type(callback), 2)
	end
	if self._destroyed then
		-- Connecting to a dead signal is a caller bug, not a crash: hand back
		-- an inert link so their code still runs to completion.
		return { Connected = false, Disconnect = function() end }
	end

	local link = { Connected = true, _signal = self, _callback = callback }
	table.insert(self._links, link)

	function link:Disconnect()
		if not self.Connected then
			return
		end
		self.Connected = false
		local links = self._signal._links
		for index = #links, 1, -1 do
			if links[index] == self then
				table.remove(links, index)
				return
			end
		end
	end

	return link
end

---Connect for a single fire, then disconnect itself.
function Signal:Once(callback)
	local link
	link = self:Connect(function(...)
		link:Disconnect()
		callback(...)
	end)
	return link
end

---Fire every callback in connection order.
function Signal:Fire(...)
	if self._destroyed then
		return
	end
	local snapshot = table.clone(self._links)
	for _, link in snapshot do
		if link.Connected then
			local ok, err = pcall(link._callback, ...)
			if not ok then
				reportError(self.name, tostring(err))
			end
		end
	end
	-- Waiters are one-shot: hand them the values and drop them.
	if #self._waiters > 0 then
		local waiters = self._waiters
		self._waiters = {}
		for _, waiter in waiters do
			if waiter.Connected then
				waiter.Connected = false
				local thread = waiter._thread :: thread?
				if thread and coroutine.status(thread) == "suspended" then
					task.spawn(thread, ...)
				end
			end
		end
	end
end

---Yields until the next Fire. Returns the fired values, or nothing at all if
---the signal is destroyed while waiting.
function Signal:Wait()
	if self._destroyed then
		return
	end
	local thread = coroutine.running()
	-- A waiter is its own record, not a Connect()ed callback: a callback would
	-- be invoked by Fire and would resume its own thread from *inside* the
	-- dispatch loop, which is how you get "cannot resume non-suspended
	-- coroutine" when two signals are involved. Fire collects the queue and
	-- hands the values to whichever coroutine asks for them next.
	local waiter = { _thread = thread, Connected = true }
	table.insert(self._waiters, waiter)
	return coroutine.yield()
end

---Stop accepting connections, drop every link, and release any Wait().
function Signal:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, link in self._links do
		link.Connected = false
	end
	table.clear(self._links)
	for _, waiter in self._waiters do
		local thread = waiter._thread :: thread?
		if thread and coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
	table.clear(self._waiters)
end

---True when at least one live connection exists.
function Signal:HasConnections()
	return #self._links > 0
end

---Live connection count. The harness uses it to prove Unload dropped them.
function Signal:Count()
	return #self._links
end

return Signal
