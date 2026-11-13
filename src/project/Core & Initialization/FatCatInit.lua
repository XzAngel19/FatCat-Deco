-- Fat Cat Project | Core & Initialization/FatCatInit.lua
--
-- The bootstrapper. This file is the only one that knows the load order, and
-- the only one that is allowed to decide that a failure is fatal.
--
--   local Init = FatCat.require("FatCatInit")
--   local ok, status = Init.boot()
--
-- The contract, in four rules:
--
--   1. Core modules are fatal. If FatCatSignal, FatCatCore, FatCatEnv,
--      FatCatConfig, FatCatDesign or FatCatMaterials cannot load, there is no
--      product to show, so boot returns { ok = false, stage = ... }.
--
--   2. Feature modules are not fatal. A decompiler that throws on load costs
--      its tab and nothing else: the error is captured, shown on that tab by
--      FatCatMenu, and logged.
--
--   3. Every failure carries a stage. "It did not work" is useless; "FatCatMenu
--      failed at mount" is a bug report.
--
--   4. A failure leaves a way out. When boot fails, an error card is drawn over
--      the game and `getgenv().FatCatProjectUnload` is still installed, so the
--      user can recover without restarting the client.
--
-- The module table is injected: the loader hands in `{ [name] = function }`
-- so this file works both from the generated bundle and from a dev checkout
-- that loads each file separately.

return function(Modules)
	-- The executor environment. getgenv() exists on every executor, but not in
	-- a plain Luau VM (the test harness, a dev checkout), so it is guarded:
	-- without the guard this whole file fails at parse-adjacent time and no
	-- error card can explain it.
	local env = (typeof(getgenv) == "function" and getgenv()) or _G

	local Init = {}

	Init.VERSION = "2.1.0"
	Init.STAGE = nil

	-- Core modules: fatal when they fail.
	Init.CORE = { "FatCatSignal", "FatCatCore", "FatCatEnv", "FatCatConfig", "FatCatDesign", "FatCatMaterials" }

	-- Feature modules: one tab each, never fatal.
	Init.FEATURES = {
		"FatCatShell",
		"FatCatMath",
		"FatCatInspect",
		"FatCatCreate",
		"FatCatExtractor",
		"FatCatDecompiler",
		"FatCatStealer",
		"FatCatSpy",
		"FatCatProjectiles",
		"FatCatVMHook",
		"FatCatMemoryScanner",
		"FatCatEnvSpoofer",
		"FatCatUniversal",
		"FatCatConsole",
		"FatCatMenu",
	}

	local loaded = {}
	local failures = {}

	-- ==========================================================================
	-- Error reporting
	-- ==========================================================================

	local function tracebackOf(message)
		local ok, trace = pcall(function()
			return debug.traceback(tostring(message), 2)
		end)
		return ok and trace or tostring(message)
	end

	---Draw a card over the game explaining that boot failed. Wrapped in pcall
	---so a broken DataModel cannot turn an error report into a second error.
	local function showFailure(stage, message)
		local ok = pcall(function()
			local parent = game:GetService("CoreGui")
			local existing = parent:FindFirstChild("FatCatBootError")
			if existing then
				existing:Destroy()
			end

			local card = Instance.new("Frame")
			card.Name = "FatCatBootError"
			card.Size = UDim2.fromOffset(360, 132)
			card.Position = UDim2.new(0.5, -180, 0, 24)
			card.BackgroundColor3 = Color3.fromRGB(26, 26, 30)
			card.BorderSizePixel = 0
			card.ZIndex = 10
			card.Parent = parent

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 8)
			corner.Parent = card

			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(232, 92, 96)
			stroke.Transparency = 0.35
			stroke.Parent = card

			local title = Instance.new("TextLabel")
			title.Text = ("[Fat Cat] no arrancó · %s"):format(tostring(stage))
			title.TextSize = 13
			title.Font = Enum.Font.GothamBold
			title.TextColor3 = Color3.fromRGB(232, 92, 96)
			title.BackgroundTransparency = 1
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.Size = UDim2.new(1, -20, 0, 20)
			title.Position = UDim2.fromOffset(10, 8)
			title.Parent = card

			local body = Instance.new("TextLabel")
			-- First two lines: a full traceback in a 360 px card is unreadable
			-- and everything is in the executor console anyway.
			local firstLines = tostring(message):match("^[^\n]*\n?[^\n]*") or tostring(message)
			body.Text = firstLines
			body.TextSize = 11
			body.Font = Enum.Font.Gotham
			body.TextColor3 = Color3.fromRGB(198, 198, 204)
			body.TextWrapped = true
			body.TextYAlignment = Enum.TextYAlignment.Top
			body.TextXAlignment = Enum.TextXAlignment.Left
			body.BackgroundTransparency = 1
			body.Size = UDim2.new(1, -20, 0, 92)
			body.Position = UDim2.fromOffset(10, 30)
			body.Parent = card
			return card
		end)
		if not ok then
			warn(("[Fat Cat] boot failed at %s: %s"):format(tostring(stage), tostring(message)))
		end
	end
	Init.showFailure = showFailure

	---Remove the boot error card, if one is on screen.
	local function clearFailure()
		pcall(function()
			local existing = game:GetService("CoreGui"):FindFirstChild("FatCatBootError")
			if existing then
				existing:Destroy()
			end
		end)
	end

	local function fail(stage, message)
		Init.STAGE = stage
		local full = tracebackOf(message)
		failures[stage] = full
		warn(("[Fat Cat] boot failed at %s:\n%s"):format(tostring(stage), full))
		showFailure(stage, message)
		return { ok = false, stage = stage, error = tostring(message), traceback = full }
	end

	-- ==========================================================================
	-- Module loading
	-- ==========================================================================

	---Read a module that is not a factory (FatCatSignal is a table, FatCatCore
	---is a table). Returns the value or nil plus a reason.
	local function value(name)
		if type(Modules) ~= "table" then
			return nil, "the loader gave FatCatInit no module table"
		end
		local module = Modules[name]
		if module == nil then
			return nil, ("no module named '%s' in this build"):format(name)
		end
		return module
	end

	---The world every module is constructed with. `core` is added after
	---FatCatCore loads; until then the field is nil on purpose.
	local context = {
		signal = nil,
		core = nil,
		design = nil,
		materials = nil,
		math = nil,
		env = nil,
		modules = Modules,
		loaded = loaded,
	}

	---Load a factory module: source() then call it with the arguments this
	---specific module expects. The switch is explicit because the signatures
	---differ; a uniform context object would let a typo pass silently.
	local function factory(name)
		if type(Modules) ~= "table" then
			return nil, "the loader gave FatCatInit no module table"
		end
		local chunk = Modules[name]
		if chunk == nil then
			return nil, ("no module named '%s' in this build"):format(name)
		end
		if type(chunk) ~= "function" then
			-- A plain table (a module that needs no construction, or one the
			-- loader already built) is used as it is.
			return chunk
		end

		-- FatCatConfig and FatCatDesign are the two modules built with the
		-- signal bus, because both create signals during construction.
		-- FatCatEnv does not: it takes the same two arguments for symmetry but
		-- only reads the first, and passing the bus keeps every core module's
		-- signature identical.
		local args = { context.core, context.signal }
		if name == "FatCatDesign" then
			args = { context.core, context.signal }
		elseif name == "FatCatMaterials" then
			args = { context.core, context.design, context.signal }
		elseif name == "FatCatMath" then
			args = { context.core }
		elseif name == "FatCatInspect" or name == "FatCatDecompiler" or name == "FatCatExtractor"
			or name == "FatCatStealer" or name == "FatCatMemoryScanner" or name == "FatCatEnvSpoofer" then
			args = { context.core, context.materials }
		elseif name == "FatCatSpy" then
			args = { context.core, context.signal, context.materials }
		elseif name == "FatCatVMHook" then
			args = { context.core, context.signal, context.materials }
		elseif name == "FatCatProjectiles" then
			args = { context.core, context.math, context.materials }
		elseif name == "FatCatUniversal" then
			args = { context.core, context.design, context.signal, context.math }
		elseif name == "FatCatCreate" then
			args = { context.core, context.design, context.signal, context.materials }
		elseif name == "FatCatConsole" then
			args = { context.core, context.signal, context.materials }
		elseif name == "FatCatMenu" then
			args = { context.core, context.design, context.signal, context.materials }
		elseif name == "FatCatShell" then
			-- The shell is a chunk, not a factory: running it defines
			-- _G.FatCatHub and builds the window. It blocks at runtime
			-- (`if not Hub.deferBoot then Hub.Init(...) end`), so the loader
			-- has to raise this flag before the shell runs, not after.
			args = {}
			env.FatCatDeferBoot = true
		end

		local ok, result = pcall(chunk, table.unpack(args))
		if not ok then
			return nil, ("%s failed to construct: %s"):format(name, tostring(result))
		end
		if result == nil then
			result = true
		end
		return result
	end

	-- ==========================================================================
	-- Boot
	-- ==========================================================================

	---Boot the whole project. Returns { ok, stage, core } on success and
	---{ ok = false, stage, error, traceback } on failure.
	function Init.boot(options)
		options = options or {}

		-- 0. Refuse to run twice in the same environment. A second boot leaves
		--    two windows, two render loops and two sets of hooks on the same
		--    globals, which is how a menu ends up duplicating itself per reload.
		local previous = env.FatCatProject
		if previous ~= nil and type(previous.Destroy) == "function" and not options.force then
			local clean, reason = pcall(previous.Destroy, previous)
			if not clean then
				return fail("precheck", "the previous instance could not be torn down: " .. tostring(reason))
			end
		end

		-- 1. Signals: everything below can fire events, so this is first.
		Init.STAGE = "FatCatSignal"
		local Signal, signalWhy = value("FatCatSignal")
		if not Signal then
			return fail("FatCatSignal", signalWhy)
		end
		context.signal = Signal
		loaded.FatCatSignal = Signal

		-- 2. Core: the registry the other modules live in.
		Init.STAGE = "FatCatCore"
		local Core, coreWhy = value("FatCatCore")
		if type(Core) ~= "table" then
			return fail("FatCatCore", coreWhy or "FatCatCore did not return a table")
		end
		Core.env = env
		context.core = Core
		loaded.FatCatCore = Core

		-- Announce the global early, so a module that logs during load can
		-- already find the project and its logger.
		_G.FatCatProject = Core

		-- 3. The rest of the core modules, in dependency order.
		--
		-- Which of these may fail without taking the menu down: everything
		-- except the two the shell itself is built on. FatCatEnv supplies the
		-- executor surface, FatCatSignal is already loaded, and the shell
		-- needs nothing else to open. A broken palette (Design) or a broken
		-- widget kit (Materials) degrades the look and the project tabs, but
		-- the window the user opens with RightShift still comes up, which is
		-- the whole point of a client that is supposed to stay usable.
		local OPTIONAL = {
			FatCatConfig = "presets and saved values",
			FatCatDesign = "palettes and typography",
			FatCatMaterials = "the project's widget kit",
			FatCatMath = "trajectories and prediction",
		}
		for _, name in { "FatCatEnv", "FatCatConfig", "FatCatDesign", "FatCatMaterials", "FatCatMath" } do
			Init.STAGE = name
			local module, why = factory(name)
			if module == nil then
				if OPTIONAL[name] then
					-- Recorded, logged, and surfaced in the report: degraded,
					-- not silent. `why` already names the module and the
					-- error, so the card is readable.
					failures[name] = tostring(why)
					Core:Log("warn", ("[Fat Cat] %s no cargó (%s); sigo sin ello"):format(name, OPTIONAL[name]))
					Core:Log("warn", tostring(why))
				else
					return fail(name, why)
				end
			else
				loaded[name] = module
				if name == "FatCatEnv" then
					context.env = module
					-- Detection is cheap and runs before any feature asks
					-- "can this executor do X".
					pcall(module.detect)
				elseif name == "FatCatConfig" then
					context.config = module
				elseif name == "FatCatDesign" then
					context.design = module
				elseif name == "FatCatMaterials" then
					context.materials = module
				elseif name == "FatCatMath" then
					context.math = module
				end
			end
		end

		-- 4. The window shell: it defines _G.FatCatHub and is what the menu
		--    mounts onto. Fatal, because without it there is nowhere to draw.
		Init.STAGE = "FatCatShell"
		local shell, shellWhy = factory("FatCatShell")
		if shell == nil then
			return fail("FatCatShell", shellWhy)
		end
		loaded.FatCatShell = shell or true

		-- 5. Register every module with Core, including the core ones that were
		--    constructed above. A caller that asks Core:Require("FatCatSignal")
		--    must get the table back, not "no module registered": the registry
		--    is the public entry point for every module, so it cannot be
		--    missing entries just because the bootstrapper built them itself.
		for name, module in loaded do
			Core.modules[name] = module
			Core:Register(name, function()
				return module
			end)
		end

		for _, name in Init.FEATURES do
			Core:Register(name, function()
				local module, why = factory(name)
				if module == nil then
					error(why, 0)
				end
				loaded[name] = module
				return module
			end)
		end

		Init.STAGE = "FatCatConsole"
		local console, consoleWhy = Core:TryRequire("FatCatConsole")
		if console then
			console.attach()
			context.console = console
		else
			failures.FatCatConsole = tostring(consoleWhy)
		end

		-- 6. The menu. This is the first step that draws anything, so every
		--    prior failure is visible in the log before the window exists.
		--
		-- Two chances, because they fail for different reasons: the first
		-- build uses the project's palette and widget kit, the second drops
		-- to the shell's own theme. If the project layer is what broke, the
		-- menu still opens instead of showing an error card over a black
		-- screen.
		Init.STAGE = "FatCatMenu"
		local menu, menuWhy = Core:TryRequire("FatCatMenu")
		if not menu then
			return fail("FatCatMenu", menuWhy)
		end

		-- build() reports (false, why) instead of throwing, so both shapes are
		-- handled: a throw and a refusal are the same thing to the user.
		local called, built, buildWhy = pcall(menu.build)
		if not called or not built then
			local reason = called and buildWhy or built
			Core:Log("warn", "[Fat Cat] la primera construcción del menú falló, reintento sin tema")
			Core:Log("warn", tostring(reason))
			failures.FatCatMenu = tostring(reason)
			local retried, retryBuilt, retryWhy = pcall(menu.build, { plain = true })
			if not retried or not retryBuilt then
				return fail("FatCatMenu.build", retried and retryWhy or retryBuilt)
			end
		end

		-- 7. Unload hook and a final report.
		env.FatCatProjectUnload = function()
			local runtime = context.env
			if runtime and type(runtime.unload) == "function" then
				return runtime.unload()
			end
			return Core:Destroy()
		end
		env.FatCatProjectVersion = Init.VERSION

		clearFailure()
		Init.STAGE = "ready"
		Core:Log("info", ("%s listo · %s · %d módulo(s)")
			:format(Core.NAME, context.env and context.env.name or "?", #Core.loadOrder))

		if context.env and type(context.env.report) == "function" and env.FatCatVerbose then
			context.env.report()
		end

		local result = {
			ok = true,
			stage = "ready",
			core = Core,
			env = context.env,
			menu = menu,
			loaded = loaded,
			failures = failures,
			version = Init.VERSION,
			-- What the loader reads to print "ready - N modules".
			modules = #Core.loadOrder,
			executor = context.env and context.env.name or "unknown",
		}
		Init.booted = result
		return result
	end

	---Boot, but never throw: the loader calls this and only sees a table.
	function Init.safeBoot(options)
		local ok, result = pcall(Init.boot, options)
		if ok then
			return result
		end
		return fail(Init.STAGE or "boot", result)
	end

	---One-line status for the loader and for bug reports.
	---"Fat Cat 2.1.0 · 15 module(s) · 2 failed (FatCatSpy, FatCatStealer)"
	function Init.report()
		local core = _G.FatCatProject
		if not core then
			return "Fat Cat is not loaded"
		end
		local failed = {}
		for name in failures do
			table.insert(failed, name)
		end
		table.sort(failed)
		local text = ("%s %s · %d module(s)"):format(core.NAME, Init.VERSION, #core.loadOrder)
		if #failed > 0 then
			text ..= (" · %d failed (%s)"):format(#failed, table.concat(failed, ", "))
		end
		return text
	end

	---Tear down whatever boot built. Safe before boot (does nothing).
	function Init.shutdown()
		clearFailure()
		local core = _G.FatCatProject
		if core and type(core.Destroy) == "function" then
			return core:Destroy()
		end
		return 0
	end

	---Version of a module by name, or nil.
	function Init.versionOf(name)
		local module = loaded[name]
		if type(module) == "table" and type(module.VERSION) == "string" then
			return module.VERSION
		end
		return nil
	end

	return Init
end
