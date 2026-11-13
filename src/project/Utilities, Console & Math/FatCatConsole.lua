-- Fat Cat Project | Utilities, Console & Math/FatCatConsole.lua
--
-- The floating terminal: a log, a filter, and a place to run one-liners
-- without leaving the menu.
--
--   local Console = FatCat.require("FatCatConsole")
--   Console.write("info", "spy started")     -- also feeds Core.logSink
--   Console.log                              -- array of entries
--   Console.run("return 1 + 1")              -- 2
--   Console.errorsOnly()                      -- filter
--
-- Why a console matters here: every other module in this project talks to the
-- executor, and the executor's own console is usually hidden behind the game
-- or shared with every other script in the session. When the spy hooks a
-- hundred remotes, the only place to see a hook fail is here.
--
-- The runner is deliberately narrow. It compiles with `loadstring`, runs in a
-- sandboxed environment by default (see FatCatEnv.sandbox), and prints
-- nothing it was not asked to. `Console.run` never lets a thrown error reach
-- the menu: the error text becomes a log entry, which is the whole point.

local Core, Signal, Materials, Console
Console = {}

Console.MAX_ENTRIES = 400
Console.log = {}
Console.filter = nil       -- nil | "error" | "warn" | "info" | "debug"
Console.subscribers = {}

local changed = nil

-- ==========================================================================
-- Log
-- ==========================================================================

local function levelAllowed(level)
	if not Console.filter then
		return true
	end
	-- "error" and "warn" are always shown, even under a floor: hiding a
	-- failure behind a filter is how a broken module goes unnoticed.
	if level == "error" or level == "warn" then
		return true
	end
	return level == Console.filter
end

local function notify(entry)
	if changed then
		changed:Fire(entry)
	end
	for index = #Console.subscribers, 1, -1 do
		local handler = Console.subscribers[index]
		local ok = pcall(handler, entry)
		if not ok then
			table.remove(Console.subscribers, index)
		end
	end
end

---Append one entry. `level` is error | warn | info | debug.
function Console.write(level, message, ...)
	local text = tostring(message)
	local extra = select("#", ...)
	if extra > 0 then
		local parts = {}
		for index = 1, extra do
			parts[index] = tostring((select(index, ...)))
		end
		text = text .. " " .. table.concat(parts, " ")
	end

	local entry = {
		level = level or "info",
		text = text,
		time = os.clock(),
		clock = ("%02d:%02d:%02d"):format(
			math.floor(os.clock() / 3600) % 24,
			math.floor(os.clock() / 60) % 60,
			math.floor(os.clock()) % 60),
	}
	table.insert(Console.log, entry)
	while #Console.log > Console.MAX_ENTRIES do
		table.remove(Console.log, 1)
	end
	notify(entry)
	return entry
end

---Subscribe to new entries; returns an unsubscribe function.
function Console.subscribe(handler)
	table.insert(Console.subscribers, handler)
	return function()
		for index = #Console.subscribers, 1, -1 do
			if Console.subscribers[index] == handler then
				table.remove(Console.subscribers, index)
			end
		end
	end
end

---The text the code view shows, honouring the active filter.
function Console.format()
	local lines = {}
	for _, entry in Console.log do
		if levelAllowed(entry.level) then
			table.insert(lines, ("%s %-5s %s"):format(entry.clock, entry.level:upper(), entry.text))
		end
	end
	return lines
end

function Console.setFilter(level)
	Console.filter = level
end

function Console.clear()
	table.clear(Console.log)
end

---Count entries per level, for the tab badges.
function Console.counts()
	local counts = { error = 0, warn = 0, info = 0, debug = 0 }
	for _, entry in Console.log do
		counts[entry.level] = (counts[entry.level] or 0) + 1
	end
	return counts
end

-- ==========================================================================
-- Runner
-- ==========================================================================

local function compile(source, chunkName)
	local loadstring = Core.env.loadstring
	if type(loadstring) ~= "function" then
		return nil, "this executor has no loadstring()"
	end
	local chunk, err = loadstring(source, chunkName or "=fatcat-console")
	if not chunk then
		return nil, tostring(err)
	end
	return chunk
end

---Run one line of Luau. Sandboxed by default: globals the line sets do not
---escape into the game. Pass { sandbox = false } to run in the real env.
---Returns ok, results (packed), or ok=false, error text.
function Console.run(source, options)
	options = options or {}
	if type(source) ~= "string" or source == "" then
		return false, "nothing to run"
	end

	local chunk, compileError = compile(source, options.chunkName)
	if not chunk then
		Console.write("error", "compile: " .. tostring(compileError))
		return false, compileError
	end

	-- A copy of the executor environment by default: a global the snippet sets
	-- lands in the copy, not in the game. Whether that is possible is *proven*
	-- once by FatCatEnv.canSandbox (a setfenv that exists and does nothing is a
	-- real thing, and "sandboxed" must not be a claim). When it is not
	-- possible the snippet runs in the real environment and the log says so.
	if options.sandbox ~= false then
		local EnvModule = Core:TryRequire("FatCatEnvSpoofer")
		if EnvModule and type(EnvModule.canSandbox) == "function" and EnvModule.canSandbox() then
			pcall(Core.env.setfenv, chunk, EnvModule.sandbox())
		else
			Console.write("warn", "este entorno no puede aislar un chunk; el snippet corre en el real")
		end
	end

	local results = table.pack(pcall(chunk))
	local ok = results[1]
	if not ok then
		Console.write("error", tostring(results[2]))
		return false, tostring(results[2])
	end
	table.remove(results, 1)
	if results.n > 0 then
		local parts = {}
		for index = 1, results.n do
			parts[index] = tostring(results[index])
		end
		Console.write("info", "→ " .. table.concat(parts, ", "))
	end
	return true, results
end

---Compile only, for the "check syntax" button.
function Console.check(source)
	local chunk, err = compile(source)
	if not chunk then
		return false, err
	end
	return true
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Log", 1)
	local status = Materials.Status(section.frame, "0 entries", "info")
	local output = Materials.Code(section.frame, { Height = 300 })

	local function repaint()
		output:SetLines(Console.format(), Console.MAX_ENTRIES)
		output:ScrollToBottom()
		local counts = Console.counts()
		status:Set(("%d entry(s) · %d error(s) · %d warning(s)"):format(
			#Console.log, counts.error, counts.warn),
			counts.error > 0 and "off" or (counts.warn > 0 and "warn" or "info"))
	end

	Materials.Button(section.frame, {
		Text = "Show all",
		OnClick = function()
			Console.setFilter(nil)
			repaint()
		end,
	})
	Materials.Button(section.frame, {
		Text = "Errors and warnings only",
		OnClick = function()
			Console.setFilter("warn")
			repaint()
		end,
	})
	Materials.Button(section.frame, {
		Text = "Clear",
		OnClick = function()
			Console.clear()
			repaint()
		end,
	})

	local runner = page:Section("Run Luau", 2)
	Materials.Label(runner.frame,
		"Runs in a copy of the executor environment, so a global it sets does not leak. "
		.. "Errors are logged here instead of breaking the menu.")
	local sourceField = Materials.Input(runner.frame, {
		Text = "Code",
		Placeholder = "return 1 + 1",
	})
	local runStatus = Materials.Status(runner.frame, "idle", "info")
	Materials.Button(runner.frame, {
		Text = "Run",
		OnClick = function()
			local ok, results = Console.run(sourceField:Get())
			if ok then
				runStatus:Set("ran without errors", "on")
			else
				runStatus:Set(tostring(results), "off")
			end
			repaint()
		end,
	})
	Materials.Button(runner.frame, {
		Text = "Check syntax",
		OnClick = function()
			local ok, err = Console.check(sourceField:Get())
			runStatus:Set(ok and "syntax is valid" or tostring(err), ok and "on" or "off")
		end,
	})

	-- Live feed: every module that logs lands here without polling.
	Console.subscribe(function()
		repaint()
	end)
	repaint()

	Core:OnDestroy("console:ui", function()
		Console.subscribers = {}
	end)
	return { repaint = repaint }
end

Console.mount = mount

---Install Console as the Core log sink, so Core:Log() shows up here.
---FatCatInit calls this once, after the module loads.
function Console.attach()
	Core:SetLogger(function(level, message, ...)
		Console.write(level, message, ...)
	end)
	Signal.errorHandler = function(name, message)
		Console.write("error", ("signal %s: %s"):format(tostring(name), tostring(message)))
	end
	-- Anything the shell warns about is worth seeing next to our own lines.
	return true
end

return function(core, signal, materials)
	Core = core
	Signal = signal
	Materials = materials
	changed = Signal.new("console:entry")
	return Console
end
