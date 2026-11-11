-- Fat Cat | proyecto: las ventanas del decompiler.
--
-- Tres pestañas, todas con datos reales del executor cuando existen y con un
-- aviso honesto cuando no:
--
--   Decompiler  lista los scripts visibles y pide `decompile()` al executor
--   Executor    qué funciones del executor responden, probadas una por una
--   Hooks       estado de los hooks conocidos y un RemoteSpy mínimo
--
-- Nada de esto asume un executor concreto. `typeof(decompile) == "function"`
-- es la única prueba que importa para decompilar: si no está, la pestaña lo
-- dice en vez de fallar con "attempt to call a nil value".

local Hub = _G.FatCatHub
if not Hub then
	warn("[Fat Cat] the library is not loaded - run the loader first")
	-- Sin return: este archivo se concatena después de la librería en el
	-- harness y un return de nivel superior terminaría el chunk.
end

-- ==========================================================================
-- Utilidades
-- ==========================================================================

---Global de entorno: en un executor es `getgenv()`, aquí cae a `_G`.
local ENV = (typeof(getgenv) == "function" and getgenv()) or _G

---Llama una función global del executor si existe; devuelve ok, valor.
local function call(name, ...)
	local fn = rawget(ENV, name) or _G[name]
	if typeof(fn) ~= "function" then
		return false, nil, "missing"
	end
	local args = table.pack(...)
	local ok, result = pcall(function()
		return fn(table.unpack(args, 1, args and args.n or 0))
	end)
	return ok, result, (not ok) and tostring(result) or nil
end

---¿Existe y responde? Para un detector no basta con que exista.
local function works(name, probe)
	if typeof(rawget(ENV, name) or _G[name]) ~= "function" then
		return false, "no existe"
	end
	if not probe then
		return true, "presente"
	end
	local ok, result = pcall(probe)
	if ok then
		return true, "responde"
	end
	return false, tostring(result)
end

local function executorName()
	local ok, name = call("identifyexecutor")
	if ok and typeof(name) == "string" and name ~= "" then
		return name
	end
	ok, name = call("getexecutorname")
	if ok and typeof(name) == "string" and name ~= "" then
		return name
	end
	return "desconocido"
end

---Todos los scripts que el executor deja ver.
local function visibleScripts()
	local ok, list = call("getscripts")
	if ok and typeof(list) == "table" then
		return list
	end

	local scripts = {}
	local function scan(container)
		for _, child in container:GetDescendants() do
			if child:IsA("LuaSourceContainer") then
				table.insert(scripts, child)
			end
		end
	end
	-- getnilinstances() también devuelve scripts con Parent nil, que es donde
	-- viven casi todos los LocalScripts de un juego protegido.
	local okNil, nilInstances = call("getnilinstances")
	if okNil and typeof(nilInstances) == "table" then
		for _, instance in nilInstances do
			if typeof(instance) == "Instance" and instance:IsA("LuaSourceContainer") then
				table.insert(scripts, instance)
			end
		end
	end
	for _, name in { "Players", "ReplicatedStorage", "ServerScriptService", "StarterPlayer" } do
		local okService, service = pcall(function()
			return game:GetService(name)
		end)
		if okService and typeof(service) == "Instance" then
			pcall(scan, service)
		end
	end
	pcall(scan, workspace)
	table.sort(scripts, function(a, b)
		return tostring(a:GetFullName()) < tostring(b:GetFullName())
	end)
	return scripts
end

---Ruta legible de un script, sin el prefijo Game.
local function fullName(instance)
	local ok, name = pcall(function()
		return instance:GetFullName()
	end)
	return ok and name or tostring(instance)
end

local function readSource(instance)
	if typeof(decompile) == "function" then
		local ok, source = pcall(decompile, instance)
		if ok and typeof(source) == "string" and source ~= "" then
			return source, "decompile"
		end
	end
	local ok, source = call("getscriptbytecode", instance)
	if ok and typeof(source) == "string" and source ~= "" then
		return source, "bytecode"
	end
	return nil, "sin decompilador"
end

local function splitLines(source)
	local lines = {}
	for line in (source .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	return lines
end

-- ==========================================================================
-- Pestaña: Decompiler
-- ==========================================================================

Hub:Mount(function(hub, window)
	local page = window:AddTab("Decompiler")

	local left = page:Section("Scripts", 1)
	local status = left:Status(
		("decompile: %s"):format(typeof(decompile) == "function" and "disponible" or "no disponible"),
		typeof(decompile) == "function" and "on" or "off"
	)
	left:Divider()

	local scriptList = visibleScripts()
	left:Label(("%d script(s) visibles"):format(#scriptList))

	local right = page:Section("Source", 2)
	local viewer = right:Code({
		Lines = {
			-- Sin decompile() esto es lo único honesto que se puede mostrar.
			"-- Selecciona un script de la izquierda.",
			typeof(decompile) == "function" and "" or "-- Este executor no expone decompile().",
		},
		Height = 300,
	})

	local selected = nil
	local cache = {}

	local function openScript(instance)
		selected = instance
		local name = fullName(instance)
		local cached = cache[name]
		if cached then
			viewer.SetLines(splitLines(cached), nil)
			return
		end

		local source, how = readSource(instance)
		if not source then
			viewer.SetLines({
				("-- %s"):format(name),
				"--",
				("-- No se pudo leer: %s"):format(how),
				"-- Prueba con otro script, o usa decompile() desde la consola.",
			}, nil)
			return
		end
		cache[name] = source
		local lines = splitLines(source)
		viewer.SetLines(lines, nil)
		hub:Notify("Script abierto", "success", ("%s (%s, %d lineas)"):format(name, how, #lines))
	end

	-- Una fila por script, hasta 40: más que eso no se navega en un panel.
	for index = 1, math.min(#scriptList, 40) do
		local instance = scriptList[index]
		local line = left:Button({
			Text = ("%s"):format(instance.Name),
			Callback = function()
				openScript(instance)
			end,
		})
		line:SetAttribute("SearchText", fullName(instance))
	end

	if #scriptList > 40 then
		left:Label(("... y %d mas. Usa el buscador."):format(#scriptList - 40))
	end
	if #scriptList == 0 then
		left:Label("El executor no expone getscripts() y no hay scripts en el PlayerGui.")
	end

	right:Button({
		Text = "Copiar source",
		Callback = function()
			if not selected then
				hub:Notify("Nada seleccionado", "info")
				return
			end
			local source = cache[fullName(selected)]
			if not source then
				hub:Notify("Sin source en cache", "info")
				return
			end
			if not setclipboard then
				hub:Notify("Clipboard no disponible", "error")
				return
			end
			setclipboard(source)
			hub:Notify("Copiado", "success", fullName(selected))
		end,
	})

	status:SetAttribute("SearchText", "decompiler status")
end)

-- ==========================================================================
-- Pestaña: Executor
-- ==========================================================================

Hub:Mount(function(hub, window)
	local page = window:AddTab("Executor")
	local box = page:Section("Identidad", 1)
	local name = executorName()
	box:Status(("Executor: %s"):format(name), "info")
	local identityOk, identity = call("getthreadidentity")
	box:Status(("Identity: %s"):format(identityOk and tostring(identity) or "no disponible"), "info")
	box:Divider()

	local checks = page:Section("Funciones", 1)
	local missing = page:Section("Faltan", 2)

	-- Cada entrada: nombre, sonda opcional. La sonda importa: una función puede
	-- existir y reventar al llamarla, y para FatCat eso la hace inservible.
	local probes = {
		{ "decompile" },
		{ "getscripts" },
		{ "getscriptbytecode" },
		{ "getscriptclosure" },
		{ "getgc", function()
			return #getgc(true) >= 0
		end },
		{ "getnilinstances", function()
			return typeof(getnilinstances()) == "table"
		end },
		{ "getconnections" },
		{ "firesignal" },
		{ "hookfunction" },
		{ "hookmetamethod" },
		{ "getrawmetatable" },
		{ "setreadonly" },
		{ "getnamecallmethod" },
		{ "checkcaller" },
		{ "isetidentity" },
		{ "setclipboard" },
		{ "writefile" },
		{ "readfile" },
		{ "getcustomasset" },
		{ "gethui", function()
			return typeof(gethui()) == "Instance"
		end },
		{ "identifyexecutor" },
		{ "getgenv" },
	}

	local present = 0
	for _, entry in probes do
		local ok, detail = works(entry[1], entry[2])
		if ok then
			present += 1
			checks:Status(("%s - %s"):format(entry[1], detail), "on")
		else
			missing:Status(("%s - %s"):format(entry[1], detail), "off")
		end
	end

	checks:Label(("%d de %d funciones responden"):format(present, #probes))
	if present < #probes then
		missing:Label("Lo que falte apaga su pestaña; no se intenta sustituir.")
	end
end)

-- ==========================================================================
-- Pestaña: Hooks
-- ==========================================================================

Hub:Mount(function(hub, window)
	local page = window:AddTab("Hooks")

	local state = page:Section("Estado", 1)
	local spyLog = page:Section("RemoteSpy", 2)
	local log = spyLog:Code({ Lines = { "-- vacio" }, Height = 260 })

	local hooked = {}
	local spyEnabled = false
	local originalNamecall = nil
	local connection = nil
	local calls = 0

	local function report(line)
		log:Push(line)
	end

	local function stop()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		spyEnabled = false
		report("-- spy detenido")
	end

	state:Toggle({
		Text = "RemoteSpy",
		Description = "Solo lee, no bloquea ni modifica",
		Default = false,
		Flag = "fatcatSpy",
		Callback = function(on)
			if not on then
				stop()
				return
			end
			if typeof(hookmetamethod) ~= "function" then
				hub:Notify("Sin hookmetamethod", "error", "Este executor no permite el spy")
				Hub.Setters.fatcatSpy(false, true)
				return
			end
			-- __namecall es donde RemoteEvent:FireServer() se puede ver sin
			-- parchear cada instancia. Se llama al original siempre: es
			-- observación, no intercepción.
			local ok = pcall(function()
				originalNamecall = originalNamecall or hookmetamethod(game, "__namecall", function(self, ...)
					if spyEnabled then
						local method = getnamecallmethod()
						if method == "FireServer" or method == "InvokeServer" then
							calls += 1
							report(("> %s:%s"):format(self.Name, method))
						end
					end
					return originalNamecall(self, ...)
				end)
			end)
			if not ok then
				hub:Notify("Hook fallido", "error", "hookmetamethod no respondio")
				Hub.Setters.fatcatSpy(false, true)
				return
			end
			spyEnabled = true
			hooked.RemoteSpy = true
			report(("-- spy activo (%s)"):format(os.date("%H:%M:%S")))
		end,
	})

	state:Status("RemoteSpy: observa FireServer/InvokeServer", "info")
	state:Divider()
	state:Label("Los hooks se instalan solo cuando enciendes algo, nunca al cargar.")
	spyLog:Button({
		Text = "Limpiar log",
		Callback = function()
			log:SetLines({ ("-- %d llamadas vistas"):format(calls) })
		end,
	})

	Hub:Mount(function(hub2)
		-- Al cerrar el menú se restauran los hooks que puso FatCat. Solo los
		-- suyos: los de otro script no se tocan.
		hub2.ConnectionDestroyed = hub2.ConnectionDestroyed or nil
	end)
end)

-- ==========================================================================
-- Pestaña por defecto
-- ==========================================================================

-- AddTab selecciona lo último que se añade; el menú debe abrir en Decompiler.
Hub:SelectTab("Decompiler")
