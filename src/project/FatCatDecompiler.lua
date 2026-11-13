-- Fat Cat Project | Advanced Analysis/FatCatDecompiler.lua
--
-- A decompiler front end: pick a script, call the executor's decompiler, show
-- the result with line numbers, and save it. Nothing here is a decompiler
-- itself — writing one is a year of work and every serious executor already
-- ships one. What is missing in practice is a UI that:
--
--   * refuses to call a nil function and says why, instead of throwing;
--   * falls back from decompile → getscriptclosure → getscriptbytecode in a
--     defined order, and reports which one it used;
--   * keeps the last 20 results so a second look does not re-run the work;
--   * writes to a predictable folder with a predictable name.
--
--   local D = FatCat.require("FatCatDecompiler")
--   local text, how = D.decompile(scriptInstance)
--   D.open(text)               -- fill the tab's code view
--   D.save("Remote.lua", text)

local Core, Materials, Decompiler
Decompiler = {}

Decompiler.OUTPUT = "FatCatProject/decompiled"
Decompiler.MAX_CACHE = 20
Decompiler.cache = {}          -- name -> { text = string, how = string, at = number }

-- ==========================================================================
-- Decompiler discovery
-- ==========================================================================

local KNOWN = { "decompile", "decompilefunction", "decompiler" }

---The decompiler this executor has, or nil.
function Decompiler.impl()
	for _, name in KNOWN do
		local fn = Core.env[name]
		if type(fn) == "function" then
			return fn, name
		end
	end
	local ok, module = pcall(require, "decompiler")
	if ok and type(module) == "function" then
		return module, "require(decompiler)"
	end
	return nil
end

---True/false plus a sentence for the status row.
function Decompiler.available()
	local _, name = Decompiler.impl()
	if name then
		return true, name .. "()"
	end
	return false, "no decompiler on this executor"
end

-- ==========================================================================
-- Decompile
-- ==========================================================================

local function closureFor(instance)
	local getClosure = Core.env.getscriptclosure
	if type(getClosure) ~= "function" then
		return nil
	end
	local ok, result = pcall(getClosure, instance)
	if ok then
		return result
	end
	return nil
end

local function cacheGet(key)
	for _, entry in Decompiler.cache do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

local function cachePut(entry)
	table.insert(Decompiler.cache, entry)
	while #Decompiler.cache > Decompiler.MAX_CACHE do
		table.remove(Decompiler.cache, 1)
	end
end

---Decompile one script. Returns text, how, or nil plus a reason.
---`how` is "decompiled", "source" or "bytecode".
function Decompiler.decompile(instance, options)
	options = options or {}
	if not instance then
		return nil, nil, "no script selected"
	end

	local key = tostring(instance) .. instance.Name
	if not options.refresh then
		local hit = cacheGet(key)
		if hit then
			return hit.text, hit.how
		end
	end

	-- 1. The client's own Source, when the executor exposes it at all.
	local ok, source = pcall(function()
		return instance.Source
	end)
	if ok and type(source) == "string" and source ~= "" then
		cachePut({ key = key, text = source, how = "source", at = os.clock() })
		return source, "source"
	end

	-- 2. The executor's decompiler, on the script's closure.
	local impl, implName = Decompiler.impl()
	if impl then
		local closure = closureFor(instance)
		if closure then
			local success, text = pcall(impl, closure)
			if success and type(text) == "string" and text ~= "" then
				cachePut({ key = key, text = text, how = "decompiled", at = os.clock() })
				return text, "decompiled"
			end
			if not success then
				Core:Log("warn", ("%s failed on %s: %s"):format(
					tostring(implName), instance.Name, tostring(text)))
			end
		end
		-- Some builds accept the instance directly.
		local direct, directText = pcall(impl, instance)
		if direct and type(directText) == "string" and directText ~= "" then
			cachePut({ key = key, text = directText, how = "decompiled", at = os.clock() })
			return directText, "decompiled"
		end
	end

	-- 3. Bytecode as hex, which is what is left when there is no decompiler.
	local getBytecode = Core.env.getscriptbytecode
	if type(getBytecode) == "function" then
		local success, raw = pcall(getBytecode, instance)
		if success and type(raw) == "string" and raw ~= "" then
			local parts = {}
			for index = 1, math.min(#raw, 100000) do
				parts[#parts + 1] = ("%02x"):format(string.byte(raw, index))
			end
			local text = table.concat(parts)
			cachePut({ key = key, text = text, how = "bytecode", at = os.clock() })
			return text, "bytecode"
		end
	end

	return nil, nil, "no source, no decompiler, no bytecode: this script cannot be read"
end

-- ==========================================================================
-- Output helpers
-- ==========================================================================

---Number every line: "  12 | local x = 1". A decompiled listing without line
---numbers is a listing nobody can point at in a bug report.
function Decompiler.numbered(text)
	local lines = {}
	local index = 0
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		index += 1
		table.insert(lines, ("%4d | %s"):format(index, line))
		-- A 20 000-line script would freeze the label; 2 000 is plenty to
		-- read and the rest is saved to disk instead.
		if index >= 2000 then
			table.insert(lines, "… truncated; save the file to see the rest")
			break
		end
	end
	return lines
end

---Write text to the project folder.
function Decompiler.save(fileName, text)
	if type(text) ~= "string" then
		return nil, "nothing to save"
	end
	local write = Core.env.writefile
	if type(write) ~= "function" then
		return nil, "this executor has no writefile()"
	end
	local makeFolder = Core.env.makefolder
	if type(makeFolder) == "function" then
		pcall(makeFolder, "FatCatProject")
		pcall(makeFolder, Decompiler.OUTPUT)
	end
	local safe = tostring(fileName):gsub("[^%w_%-%. ]", "_")
	if not safe:match("%.luau?$") then
		safe ..= ".lua"
	end
	local path = Decompiler.OUTPUT .. "/" .. safe
	local ok, err = pcall(write, path, text)
	if not ok then
		return nil, tostring(err)
	end
	return path
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Decompiler", 1)
	local ok, how = Decompiler.available()
	local status = Materials.Status(section.frame, how, ok and "on" or "warn")
	local output = Materials.Code(section.frame, { Height = 320 })

	local listing = {}

	Materials.Button(section.frame, {
		Text = "List scripts",
		OnClick = function()
			local Extractor = Core:TryRequire("FatCatExtractor")
			if not Extractor then
				output:SetLines({ "FatCatExtractor failed to load." })
				return
			end
			listing = Extractor.sources()
			local lines = {}
			for index, entry in listing do
				table.insert(lines, ("%3d  %s"):format(index, entry.name))
			end
			output:SetLines(#lines > 0 and lines or { "No scripts reachable." }, 300)
			status:Set(("%d script(s)"):format(#listing), "info")
		end,
	})

	local pick = Materials.Input(section.frame, { Text = "Index", Default = "1" })

	local function show(index)
		local entry = listing[index]
		if not entry then
			output:SetLines({ "List scripts first, then type an index from that list." })
			return
		end
		local text, method, why = Decompiler.decompile(entry.instance)
		if not text then
			output:SetLines({ ("%s: %s"):format(entry.name, tostring(why)) })
			status:Set("failed", "off")
			return
		end
		output:SetLines(Decompiler.numbered(text), 400)
		status:Set(("%s via %s · %d byte(s)"):format(entry.name, method, #text), "on")
	end

	Materials.Button(section.frame, {
		Text = "Decompile",
		OnClick = function()
			show(math.floor(tonumber(pick:Get()) or 0))
		end,
	})
	Materials.Button(section.frame, {
		Text = "Save this result",
		OnClick = function()
			local entry = listing[math.floor(tonumber(pick:Get()) or 0)]
			if not entry then
				return
			end
			local text = Decompiler.decompile(entry.instance)
			if type(text) ~= "string" then
				return
			end
			local path, err = Decompiler.save(entry.name, text)
			status:Set(path or tostring(err), path and "on" or "off")
		end,
	})

	local notes = page:Section("Notes", 2)
	Materials.Label(notes.frame,
		"Source is tried first, then the executor's decompiler, then bytecode. "
		.. "The status row says which one produced what you are reading.")
	Materials.Label(notes.frame,
		("Results are cached (last %d), so opening the same script twice does not re-run the decompiler.")
			:format(Decompiler.MAX_CACHE))

	return { show = show, save = Decompiler.save }
end

Decompiler.mount = mount

return function(core, materials)
	Core = core
	Materials = materials
	return Decompiler
end
