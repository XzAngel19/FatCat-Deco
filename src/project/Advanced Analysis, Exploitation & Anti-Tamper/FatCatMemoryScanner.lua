-- Fat Cat Project | Advanced Analysis/FatCatMemoryScanner.lua
--
-- Search the client's live object graph for values: strings, numbers, and
-- booleans reachable from `getgc()`, plus Roblox instances via `getinstances()`.
--
--   local Scan = FatCat.require("FatCatMemoryScanner")
--   local hits = Scan.scan(1337)                  -- number under every table key
--   local hits = Scan.scan("aimbot", { strings = true })
--   Scan.setPath("config/settings.lua", "fov", 120)  -- write back
--
-- Honest naming: this is a *graph* scanner, not a process memory scanner. It
-- reads what Luau's GC and the instance registry expose. It cannot read
-- arbitrary RAM, another process, or addresses the executor hides.
--
-- Writing back is deliberately narrow. `setPath` starts from a table you
-- found in a scan (or a global), walks named keys, and assigns one value. It
-- never scans for an address and pokes it, because that is the difference
-- between a debugging tool and a crash generator.

local Core, Materials, Scan
Scan = {}

Scan.MAX_RESULTS = 200

-- ==========================================================================
-- Value matching
-- ==========================================================================

local function matches(value, query, options)
	local kind = typeof(value)
	if options.strings and kind == "string" then
		if options.exact then
			return value == query
		end
		return value:find(tostring(query), 1, true) ~= nil
	end
	if options.numbers and kind == "number" then
		local target = tonumber(query)
		if not target then
			return false
		end
		if options.tolerance and options.tolerance > 0 then
			return math.abs(value - target) <= options.tolerance
		end
		return value == target
	end
	if options.booleans and kind == "boolean" then
		if type(query) == "boolean" then
			return value == query
		end
		local text = tostring(query):lower()
		return (value == true and text == "true") or (value == false and text == "false")
	end
	return false
end

-- ==========================================================================
-- Graph scan
-- ==========================================================================

---Scan the object graph.
---@param query any          string, number or boolean
---@param options table|nil  { strings, numbers, booleans, tolerance, limit }
---@return table hits        { { container, key, value, kind, path } }
function Scan.scan(query, options)
	options = options or {}
	-- Default: infer the mode from the query, so scan("abc") searches strings
	-- and scan(120) searches numbers without extra arguments.
	if options.strings == nil and options.numbers == nil and options.booleans == nil then
		local kind = typeof(query)
		options.strings = kind == "string"
		options.numbers = kind == "number"
		options.booleans = kind == "boolean"
	end
	local limit = options.limit or Scan.MAX_RESULTS
	local hits = {}
	local seen = {}

	local getgc = Core.env.getgc
	local getinstances = Core.env.getinstances
	if type(getgc) ~= "function" and type(getinstances) ~= "function" then
		return hits, "neither getgc() nor getinstances() is available"
	end

	-- 1. Tables reachable from the GC.
	if type(getgc) == "function" then
		local ok, objects = pcall(getgc, true)
		if ok then
			for _, object in objects do
				if #hits >= limit then
					break
				end
				if type(object) == "table" and not seen[object] then
					seen[object] = true
					for key, value in object do
						if #hits >= limit then
							break
						end
						if matches(value, query, options) then
							table.insert(hits, {
								container = object,
								key = key,
								value = value,
								kind = typeof(value),
								path = ("%s.%s"):format(tostring(object), tostring(key)),
							})
						end
					end
				end
			end
		end
	end

	-- 2. Instance properties, which the GC scan does not see (they live in C).
	if type(getinstances) == "function" then
		local ok, instances = pcall(getinstances)
		if ok then
			for _, instance in instances do
				if #hits >= limit then
					break
				end
				for _, property in options.properties or { "Name", "Text", "Value", "IntValue", "StringValue" } do
					local success, value = pcall(function()
						return (instance :: any)[property]
					end)
					if success and matches(value, query, options) then
						table.insert(hits, {
							container = instance,
							key = property,
							value = value,
							kind = "Instance",
							path = ("%s.%s"):format(instance:GetFullName(), property),
						})
					end
				end
			end
		end
	end

	return hits
end

-- ==========================================================================
-- Write back
-- ==========================================================================

---Resolve `root` then walk `path`. Returns the last table plus its key.
function Scan.resolve(root, path)
	local keys = {}
	for piece in tostring(path):gmatch("[^/%.]+") do
		table.insert(keys, piece)
	end
	if #keys == 0 then
		return nil, nil, "empty path"
	end

	local current = root
	for index = 1, #keys - 1 do
		local key = keys[index]
		local numeric = tonumber(key)
		local nextValue = (current :: any)[numeric or key]
		if type(nextValue) ~= "table" then
			return nil, nil, ("%s is not a table"):format(key)
		end
		current = nextValue
	end
	return current, keys[#keys]
end

---Set one value at a slash-separated path from `root`.
---   Scan.setPath("config/settings.lua", "aim/fov", 120)
---`root` is a path from the globals table: "config" is `_G.config`, and
---"config/settings.lua" walks `_G.config["settings.lua"]`.
function Scan.setPath(rootPath, path, value)
	local keys = {}
	for piece in tostring(rootPath):gmatch("[^/%.]+") do
		table.insert(keys, piece)
	end
	local current = Core.env
	for _, key in keys do
		if type(current) ~= "table" then
			return false, ("%s is not a table"):format(key)
		end
		current = (current :: any)[key]
	end
	if type(current) ~= "table" then
		return false, ("%s did not resolve to a table"):format(rootPath)
	end

	local holder, lastKey, reason = Scan.resolve(current, path)
	if not holder then
		return false, reason
	end
	local numeric = tonumber(lastKey)
	local target = (holder :: any)
	target[numeric or lastKey] = value
	return true
end

---Convenience: write a value into a hit returned by scan().
function Scan.writeHit(hit, value)
	if not hit or hit.container == nil then
		return false, "no hit"
	end
	local key = hit.key
	if typeof(hit.container) == "Instance" then
		local ok, err = pcall(function()
			(hit.container :: any)[key] = value
		end)
		if not ok then
			return false, tostring(err)
		end
		return true
	end
	(hit.container :: any)[key] = value
	return true
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Search", 1)
	local query = Materials.Input(section.frame, { Text = "Value", Default = "0" })
	local strings = Materials.Toggle(section.frame, { Text = "Search strings", Default = true })
	local numbers = Materials.Toggle(section.frame, { Text = "Search numbers", Default = true })
	local booleans = Materials.Toggle(section.frame, { Text = "Search booleans", Default = false })
	local tolerance = Materials.Input(section.frame, { Text = "Number tolerance", Default = "0" })
	local output = Materials.Code(section.frame, { Height = 280 })
	local hits = {}

	Materials.Button(section.frame, {
		Text = "Scan",
		OnClick = function()
			local raw = query:Get()
			local numeric = tonumber(raw)
			hits = Scan.scan(numeric or raw, {
				strings = strings:Get(),
				numbers = numbers:Get() and numeric ~= nil,
				booleans = booleans:Get(),
				tolerance = tonumber(tolerance:Get()) or 0,
			})
			local lines = {}
			for index = 1, math.min(#hits, 120) do
				local hit = hits[index]
				table.insert(lines, ("%3d %s = %s"):format(index, hit.path, tostring(hit.value)))
			end
			output:SetLines(#lines > 0 and lines or { "No match. Try a tolerance for numbers." }, 300)
		end,
	})

	local writer = page:Section("Write back", 2)
	local indexField = Materials.Input(writer.frame, { Text = "Hit number", Default = "1" })
	local valueField = Materials.Input(writer.frame, { Text = "New value", Default = "" })
	Materials.Button(writer.frame, {
		Text = "Write to that hit",
		OnClick = function()
			local index = math.floor(tonumber(indexField:Get()) or 0)
			local hit = hits[index]
			if not hit then
				return
			end
			local raw = valueField:Get()
			local value = tonumber(raw)
			if value == nil then
				if raw == "true" then
					value = true
				elseif raw == "false" then
					value = false
				else
					value = raw
				end
			end
			Scan.writeHit(hit, value)
		end,
	})
	Materials.Label(writer.frame,
		"Only values that live in a Luau table or on an instance property can be written. "
		.. "Values inside the engine's C++ structures are read-only from here.")

	return { scan = Scan.scan, hits = function()
		return hits
	end }
end

Scan.mount = mount

return function(core, materials)
	Core = core
	Materials = materials
	return Scan
end
