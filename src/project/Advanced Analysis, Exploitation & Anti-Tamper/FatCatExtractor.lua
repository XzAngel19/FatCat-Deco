-- Fat Cat Project | Advanced Analysis/FatCatExtractor.lua
--
-- Extract a script's source from the running client: bytecode if that is all
-- the executor can give, decompiled text if a decompiler is available.
--
--   local X = FatCat.require("FatCatExtractor")
--   local sources = X.sources()          -- every script it can reach, with flags
--   local text, how = X.source(script)   -- "source" | "bytecode" | nil
--   X.save("extracted/Remote.lua", text)
--
-- Two realities this module is built around:
--
--   * `script.Source` is empty on the client for every server script. A tool
--     that reads Source and reports "empty script" is useless. Real
--     extraction goes through getscriptbytecode / getscriptclosure, and the
--     result is bytecode, not source.
--   * decompilation is a separate, optional capability. When the executor
--     ships a decompiler (decompile, or the requirement "decompiler") this
--     module calls it; when it does not, it returns the bytecode and says so
--     plainly instead of pretending the text is source.
--
-- This is read-only: it never writes back to a script, never replaces a
-- closure, and never modifies the running game.

local Core, Materials, Extractor
Extractor = {}

Extractor.OUTPUT = "FatCatProject/extracted"

-- ==========================================================================
-- Discovery
-- ==========================================================================

local function kindOf(instance)
	local ok, isLua = pcall(function()
		return instance:IsA("LuaSourceContainer")
	end)
	if ok and isLua then
		return "script"
	end
	return nil
end

---Every script instance reachable from a service, plus nil-parented ones.
---Returns a list of { instance, name, class, parent, local }.
function Extractor.sources(limit)
	limit = limit or 2000
	local found = {}
	local seen = {}

	local function visit(root)
		if not root then
			return
		end
		local ok, descendants = pcall(function()
			return root:GetDescendants()
		end)
		if not ok then
			return
		end
		for _, descendant in descendants do
			if #found >= limit then
				return
			end
			if not seen[descendant] and kindOf(descendant) then
				seen[descendant] = true
				local parent = descendant.Parent
				table.insert(found, {
					instance = descendant,
					name = descendant.Name,
					class = descendant.ClassName,
					parent = parent and parent.Name or "<nil>",
					localScript = descendant:IsA("LocalScript"),
				})
			end
		end
	end

	visit(game:GetService("ReplicatedStorage"))
	visit(game:GetService("ReplicatedFirst"))
	visit(game:GetService("StarterPlayer"))
	visit(game:GetService("StarterGui"))
	visit(game:GetService("Workspace"))
	visit(game:GetService("Players"))

	-- getnilinstances finds scripts whose parent is nil, which is where a lot
	-- of anti-cheat and loader scripts live.
	local nilInstances = Core.env.getnilinstances
	if type(nilInstances) == "function" then
		local ok, list = pcall(nilInstances)
		if ok then
			for _, instance in list do
				if #found >= limit then
					break
				end
				if not seen[instance] and kindOf(instance) then
					seen[instance] = true
					table.insert(found, {
						instance = instance,
						name = instance.Name,
						class = instance.ClassName,
						parent = "<nil>",
						localScript = instance:IsA("LocalScript"),
					})
				end
			end
		end
	end

	return found
end

-- ==========================================================================
-- Bytecode and decompilation
-- ==========================================================================

local function bytesToString(bytecode)
	if type(bytecode) == "string" then
		return bytecode
	end
	if typeof(bytecode) == "buffer" then
		local asBuffer = bytecode :: buffer
		return buffer.tostring(asBuffer)
	end
	return nil
end

---The raw bytecode of a script, or nil plus a reason.
function Extractor.bytecode(instance)
	local getBytecode = Core.env.getscriptbytecode
	if type(getBytecode) ~= "function" then
		return nil, "this executor has no getscriptbytecode()"
	end
	local ok, result = pcall(getBytecode, instance)
	if not ok then
		return nil, tostring(result)
	end
	local text = bytesToString(result)
	if not text or text == "" then
		return nil, "the executor returned no bytecode (the script may be C-protected)"
	end
	return text, "bytecode"
end

---A decompiler function, when the executor has one.
local function decompiler()
	local candidates = { "decompile", "decompilefunction", "decompiler" }
	for _, name in candidates do
		local impl = Core.env[name]
		if type(impl) == "function" then
			return impl, name
		end
	end
	local ok, module = pcall(require, "decompiler")
	if ok and type(module) == "function" then
		return module, "require(decompiler)"
	end
	return nil
end

---True when source text can be produced (a decompiler exists).
function Extractor.canDecompile()
	return decompiler() ~= nil
end

---Try source first, then decompile, then bytecode.
---Returns text, how, where "how" is "source" | "decompiled" | "bytecode".
function Extractor.source(instance)
	local ok, source = pcall(function()
		return instance.Source
	end)
	if ok and type(source) == "string" and source ~= "" then
		return source, "source"
	end

	local decompile = decompiler()
	if decompile then
		local closure = nil
		if type(Core.env.getscriptclosure) == "function" then
			local gotClosure, result = pcall(Core.env.getscriptclosure, instance)
			if gotClosure then
				closure = result
			end
		end
		if closure then
			local success, text = pcall(decompile, closure)
			if success and type(text) == "string" and text ~= "" then
				return text, "decompiled"
			end
		end
	end

	local raw, why = Extractor.bytecode(instance)
	if not raw then
		return nil, nil, why
	end
	raw = raw :: string
	-- Bytecode is bytes; store it escaped so the file survives a round trip.
	local hex = {}
	for index = 1, math.min(#raw, 200000) do
		hex[#hex + 1] = ("%02x"):format(string.byte(raw, index))
	end
	return table.concat(hex), "bytecode"
end

-- ==========================================================================
-- Saving
-- ==========================================================================

---Write text to the project folder. Returns path, or nil plus a reason.
function Extractor.save(relativePath, text)
	if type(text) ~= "string" then
		return nil, "nothing to save"
	end
	local write = Core.env.writefile
	if type(write) ~= "function" then
		return nil, "this executor has no writefile()"
	end
	if type(Core.env.makefolder) == "function" then
		pcall(Core.env.makefolder, "FatCatProject")
		pcall(Core.env.makefolder, Extractor.OUTPUT)
	end
	local path = Extractor.OUTPUT .. "/" .. relativePath
	local ok, err = pcall(write, path, text)
	if not ok then
		return nil, tostring(err)
	end
	return path
end

---Strip characters an executor filesystem may reject, then add the extension.
function Extractor.fileName(entry, how)
	local base = entry.name:gsub("[^%w_%- ]", "_")
	if base == "" then
		base = "script"
	end
	local extension = ".lua"
	if how == "bytecode" then
		extension = ".luac.hex"
	end
	return ("%s_%s%s"):format(base, entry.class, extension)
end

---Extract everything reachable and save it. `onProgress(done, total, name)`.
---Returns { saved = n, skipped = n, reasons = { ... } }.
function Extractor.extractAll(options)
	options = options or {}
	local onProgress = options.onProgress
	local entries = Extractor.sources(options.limit)
	local report = { saved = 0, skipped = 0, reasons = {} }

	for index, entry in entries do
		if onProgress then
			onProgress(index, #entries, entry.name)
		end
		local text, how, why = Extractor.source(entry.instance)
		if text then
			local path, saveError = Extractor.save(Extractor.fileName(entry, how), text)
			if path then
				report.saved += 1
			else
				report.skipped += 1
				table.insert(report.reasons, ("%s: %s"):format(entry.name, tostring(saveError)))
			end
		else
			report.skipped += 1
			table.insert(report.reasons, ("%s: %s"):format(entry.name, tostring(why)))
		end
	end
	return report
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Scripts", 1)
	local status = Materials.Status(section.frame, "not scanned", "info")
	local output = Materials.Code(section.frame, { Height = 300 })
	local listing = {}

	Materials.Button(section.frame, {
		Text = "List scripts",
		OnClick = function()
			listing = Extractor.sources()
			local lines = {}
			for index, entry in listing do
				table.insert(lines, ("%3d  %-14s %s"):format(index, entry.class, entry.name))
			end
			output:SetLines(#lines > 0 and lines or { "No scripts reachable." }, 300)
			status:Set(("%d script(s)"):format(#listing), #listing > 0 and "on" or "warn")
		end,
	})

	local indexField = Materials.Input(section.frame, { Text = "Index from the list", Default = "1" })

	Materials.Button(section.frame, {
		Text = "Decompile one",
		OnClick = function()
			local index = math.floor(tonumber(indexField:Get()) or 0)
			local entry = listing[index]
			if not entry then
				output:SetLines({ "Run 'List scripts' first, then pick an index from it." })
				return
			end
			local text, how, why = Extractor.source(entry.instance)
			if not text then
				output:SetLines({ ("%s: %s"):format(entry.name, tostring(why)) })
				return
			end
			local lines = { ("-- %s (%s) via %s"):format(entry.name, entry.class, how) }
			for line in (text .. "\n"):gmatch("([^\n]*)\n") do
				table.insert(lines, line)
			end
			output:SetLines(lines, 400)
			status:Set(("showing %s (%s)"):format(entry.name, how), how == "source" and "on" or "warn")
		end,
	})

	Materials.Button(section.frame, {
		Text = "Extract everything",
		OnClick = function()
			local report = Extractor.extractAll({
				onProgress = function(done, total, name)
					if done % 10 == 0 or done == total then
						status:Set(("%d/%d · %s"):format(done, total, name), "info")
					end
				end,
			})
			local lines = {
				("saved %d, skipped %d to %s"):format(report.saved, report.skipped, Extractor.OUTPUT),
			}
			for index = 1, math.min(#report.reasons, 40) do
				table.insert(lines, report.reasons[index])
			end
			output:SetLines(lines, 300)
			status:Set(("saved %d"):format(report.saved), report.saved > 0 and "on" or "off")
		end,
	})

	local tools = page:Section("Capabilities", 2)
	local lines = {
		("getscriptbytecode: %s"):format(Core.env.getscriptbytecode ~= nil and "yes" or "no"),
		("getscriptclosure: %s"):format(Core.env.getscriptclosure ~= nil and "yes" or "no"),
		("getnilinstances: %s"):format(Core.env.getnilinstances ~= nil and "yes" or "no"),
		("decompiler: %s"):format(Extractor.canDecompile() and "yes" or "no"),
		("writefile: %s"):format(Core.env.writefile ~= nil and "yes" or "no"),
	}
	Materials.Code(tools.frame, { Height = 132, Lines = table.concat(lines, "\n") })
	Materials.Label(tools.frame,
		"When no decompiler is installed, extraction returns bytecode and says so. "
		.. "That is the honest result: the client never holds server source text.")

	return { extract = Extractor.extractAll }
end

Extractor.mount = mount

return function(core, materials)
	Core = core
	Materials = materials
	return Extractor
end
