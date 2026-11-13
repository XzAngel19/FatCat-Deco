-- Fat Cat Project | UI & Styling Engine/FatCatMenu.lua
--
-- The container: it owns the tab layout, wires every feature module into it,
-- and makes the project and the shell behave like one application.
--
-- The window is NOT reimplemented here. src/FatCatHub.lua already owns drag,
-- resize, tabs, search, toasts and teardown, and it is the part the 94
-- harness asserts exercise. This module builds on top of it through
-- Hub:Mount, which means a rebuild (resolution change, tab added later,
-- reload) reruns the same builder and nothing is lost.
--
--   local Menu = FatCat.require("FatCatMenu")
--   Menu.build()             -- register the tab layout, idempotent
--   Menu.tab("Console")
--   Menu.setTheme("glacier")
--
-- Two rules this file exists to enforce:
--
--   1. Tabs are added with Hub._window:AddTab, one at a time. The tab bar
--      divides its width by tab count and the underline recalculates on each
--      add, so passing a list to Init would leave the indicator wrong.
--
--   2. Every control carries a `Flag`. The shell stores each flag's value in
--      Hub.Values and its setter in Hub.Setters, and FatCatConfig saves that
--      exact table - so one preset covers the whole menu for free.
--
-- Tab budget: the window opens at 460 px and the tab bar spends 12 px on its
-- margins, so seven tabs get 64 px each. The widest name here measures 54 px
-- at 13 px Gotham (measured, not guessed); an eighth tab would drop the slot
-- to 56 px and "Settings" would start to crowd its neighbour. A second tool on
-- the same page goes in a section, not in a new tab.

local Core, Design, Menu
Menu = {}

-- name -> module path. Order is the tab order left to right.
Menu.TABS = {
	{ "Home", nil },
	{ "Create", "FatCatCreate" },
	{ "Inspect", "FatCatInspect" },
	{ "Scripts", "FatCatDecompiler" },
	{ "Exploit", "FatCatExtractor" },
	{ "Network", "FatCatSpy" },
	{ "Settings", nil },
}

local built = false

local function shell()
	return _G.FatCatHub
end

---True when the shell finished loading and has a window.
function Menu.ready()
	local base = shell()
	return base ~= nil and base._window ~= nil
end

local function pageFor(window, name)
	local existing = window.pages[name]
	if existing then
		return existing
	end
	return window:AddTab(name)
end

-- ==========================================================================
-- Home
-- ==========================================================================

local function buildHome(window)
	local page = pageFor(window, "Home")

	local status = page:Section("Estado", 1)
	local Env = Core:TryRequire("FatCatEnv")
	status:Status("Fat Cat Project", "on")
	status:Status(("Ejecutor: %s"):format(Env and Env.name or "desconocido"), Env and "on" or "warn")
	status:Status(("%d módulos cargados"):format(#Core.loadOrder), "info")
	if Env then
		for _, row in Env.summary() do
			status:Status(("Capacidades · %s"):format(row.label), row.ok and "on" or (row.partial and "warn" or "off"))
		end
	end

	-- The Unload button is the one control that must always be reachable, so
	-- it lives on Home as well as in Settings: a broken tab is exactly when a
	-- user needs it.
	status:Button({
		Text = "Descargar Fat Cat",
		Callback = function()
			local runtime = Core:TryRequire("FatCatEnv")
			if runtime then
				runtime.unload()
			else
				Menu.notify("No se pudo descargar", "error", "FatCatEnv no cargó")
			end
		end,
	})

	local look = page:Section("Apariencia", 2)
	look:Cycle({
		Text = "Paleta",
		Options = Design.order,
		Default = Design.current,
		Flag = "ui.palette",
		Callback = function(choice)
			Menu.setTheme(choice)
		end,
	})
	look:Toggle({
		Text = "Movimiento reducido",
		Default = false,
		Flag = "ui.reducedMotion",
		Description = "Todas las animaciones pasan a ser instantáneas",
		Callback = function(on)
			Design.setReducedMotion(on)
		end,
	})
	look:Keybind({
		Text = "Abrir menú",
		Default = "RightShift",
		Flag = "ui.menuKey",
		Callback = function(key)
			local base = shell()
			if base then
				base.menuKey = key
			end
		end,
	})
	local contrast, where = Design.auditContrast()
	look:Label(("Contraste mínimo de la paleta: %.1f:1 (%s)"):format(contrast, where))

	local fails = page:Section("Diagnóstico", 1)
	local failures = {}
	for name in Core.loadErrors or {} do
		table.insert(failures, name)
	end
	table.sort(failures)
	if #failures == 0 then
		fails:Status("Ningún módulo falló al cargar", "on")
	else
		for _, name in failures do
			fails:Status(("Falló: %s"):format(name), "off")
		end
	end
	if Env and type(Env.report) == "function" then
		fails:Button({
			Text = "Imprimir informe en la consola",
			Callback = function()
				Env.report()
			end,
		})
	end
end

-- ==========================================================================
-- Settings
-- ==========================================================================

local function buildSettings(window)
	local page = pageFor(window, "Settings")
	local service = page:Section("Presets", 1)
	local Config = Core:TryRequire("FatCatConfig")

	if not Config then
		service:Label("FatCatConfig no se pudo cargar.")
	elseif not Config:Available() then
		service:Label("Guardar presets necesita writefile/readfile. " .. Config:UnavailableReason())
	else
		local names = Config:List()
		service:Label(("%d preset(s) en %s"):format(#names, Config.PRESET_DIR))
		if #names > 0 then
			service:Dropdown({
				Text = "Preset",
				Options = names,
				Default = Config:Active() or names[1],
				Flag = "ui.presetName",
			})
		end
		service:Button({
			Text = "Guardar valores actuales",
			Callback = function()
				local base = shell()
				local name = (base and base.Values and base.Values["ui.presetName"]) or "default"
				local ok, countOrReason = Config:SavePreset(name, (base and base.Values) or {})
				Menu.notify(ok and "Preset guardado" or "No se pudo guardar",
					ok and "success" or "error",
					ok and ("%s · %d valor(es)"):format(name, countOrReason) or tostring(countOrReason))
			end,
		})
		service:Button({
			Text = "Cargar preset",
			Callback = function()
				local base = shell()
				local name = (base and base.Values and base.Values["ui.presetName"]) or (names[1] or "default")
				local values, why = Config:LoadPreset(name)
				if not values then
					Menu.notify("No se pudo cargar", "error", tostring(why))
					return
				end
				-- Setters live on the shell; a preset written by an older build
				-- can name a flag that no longer exists, so each one is skipped
				-- individually instead of aborting the whole load.
				local applied, skipped = 0, 0
				for flag, value in values do
					local setter = base and base.Setters and base.Setters[flag]
					if setter and pcall(setter, value) then
						applied += 1
					else
						skipped += 1
					end
				end
				Menu.notify("Preset cargado", "success",
					("%s · %d aplicado(s), %d omitido(s)"):format(name, applied, skipped))
			end,
		})
		service:Button({
			Text = "Borrar preset",
			Danger = true,
			Callback = function()
				local base = shell()
				local name = (base and base.Values and base.Values["ui.presetName"]) or "default"
				local ok, why = Config:DeletePreset(name)
				Menu.notify(ok and "Preset borrado" or "No se pudo borrar",
					ok and "success" or "error", tostring(why or name))
			end,
		})
	end

	local session = page:Section("Sesión", 2)
	session:Status(("Versión: %s"):format(Core.VERSION), "info")
	session:Status(("Carpeta de datos: %s"):format(Config and Config.FOLDER or "FatCatProject"), "info")
	session:Button({
		Text = "Recargar interfaz",
		Callback = function()
			-- Reducing motion to on/off is the cheapest full repaint that also
			-- proves the design module is responsive; a raw Init would drop
			-- every flag the user just set.
			Design.setReducedMotion(Design.reducedMotion)
			Menu.notify("Interfaz recargada", "success")
		end,
	})
	session:Button({
		Text = "Descargar Fat Cat",
		Danger = true,
		Callback = function()
			local runtime = Core:TryRequire("FatCatEnv")
			if runtime then
				runtime.unload()
			end
		end,
	})
	session:Label("Descargar quita la ventana, los hooks y el ESP, y devuelve walkspeed y salto a su valor original.")
end

-- ==========================================================================
-- Pages with more than one tool
-- ==========================================================================
-- Seven tabs is the budget (see the header). These two pages stack their
-- second tool under the first, in the same scroll column.

local function stackTools(page, firstPath, secondPath, title)
	local module, why = Core:TryRequire(firstPath)
	if not module then
		page:Section(title):Label(("No se pudo cargar %s: %s"):format(firstPath, tostring(why)))
		return
	end
	pcall(module.mount, page)

	local second, secondWhy = Core:TryRequire(secondPath)
	if not second then
		page:Section(title):Label(("No se pudo cargar %s: %s"):format(secondPath, tostring(secondWhy)))
		return
	end
	-- The second tool's own mount() looks for its page sections; passing the
	-- same page puts it underneath the first one instead of over it.
	pcall(second.mount, page)
end

local function attach(window, tabName, modulePath)
	local page = pageFor(window, tabName)
	if tabName == "Exploit" then
		stackTools(page, modulePath, "FatCatProjectiles", tabName)
		return
	end
	local module, why = Core:TryRequire(modulePath)
	if not module then
		page:Section(tabName):Label(("No se pudo cargar %s: %s"):format(modulePath, tostring(why)))
		return
	end
	if type(module.mount) ~= "function" then
		page:Section(tabName):Label(modulePath .. " no expone mount().")
		return
	end
	local ok, err = pcall(module.mount, page)
	if not ok then
		page:Section(tabName):Label(("La pestaña falló: %s"):format(tostring(err)))
		Core:Log("error", ("mount %s: %s"):format(modulePath, tostring(err)))
	end
end

-- ==========================================================================
-- Build
-- ==========================================================================

function Menu.build()
	local base = shell()
	if not base then
		return false, "el shell Fat Cat no está cargado"
	end
	if built then
		base:EnsureBuilt()
		return true
	end
	built = true

	-- The shell ships with a default "Main" tab so it is useful on its own.
	-- The project replaces it: the window takes its tab list from
	-- `Hub._initOptions`, so naming the first real tab here is what stops a
	-- second, empty "Main" from taking a slot in the seven-tab budget. This has
	-- to happen before Mount, because Mount calls EnsureBuilt, which is the
	-- call that builds the window.
	base._initOptions = base._initOptions or {}
	base._initOptions.Tabs = { Menu.TABS[1][1] }

	base:Mount(function(_activeHub, window)
		buildHome(window)
		buildSettings(window)
		for _, entry in Menu.TABS do
			local name, modulePath = entry[1], entry[2]
			if modulePath then
				-- One pcall per page: a broken module costs one tab, never the
				-- menu.
				local ok, err = pcall(attach, window, name, modulePath)
				if not ok then
					Core:Log("error", ("attach %s: %s"):format(name, tostring(err)))
				end
			end
		end
		-- Adding a tab selects it, so the last one added would otherwise be
		-- what the user sees first. Home is the intended landing page.
		window:SelectTab("Home")
	end)

	return true
end

---Select a tab if it exists.
function Menu.tab(name)
	local base = shell()
	if not base then
		return false, "no hay shell"
	end
	if not base._window then
		base:EnsureBuilt()
	end
	if not base._window or not base._window.pages[name] then
		return false, ("no hay pestaña '%s'"):format(tostring(name))
	end
	base._window:SelectTab(name)
	return true
end

---Switch palette and push the accent into the shell.
function Menu.setTheme(name)
	local ok, why = Design.apply(name)
	if not ok then
		return false, why
	end
	local base = shell()
	if base and type(base.SetAccent) == "function" then
		pcall(base.SetAccent, Design.color("accent"), Design.color("accentAlt"))
	end
	return true
end

---Toast through the shell, when it has one.
function Menu.notify(title, kind, detail)
	local base = shell()
	if base and type(base.Notify) == "function" then
		return base.Notify(title, kind, detail)
	end
	return false
end

---Drop the project's view of the shell. The GUI itself is the shell's job:
---its ScreenGui was parented to CoreGui, and destroying it takes the tabs.
function Menu.unmount()
	built = false
end

return function(core, design, _signal, _materials)
	Core = core
	Design = design
	Core:OnDestroy("FatCatMenu", Menu.unmount)
	return Menu
end
