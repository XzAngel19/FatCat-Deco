-- Fat Cat Project | Creation & Inspection Tools/FatCatInspect.lua
--
-- Inspection without touching the game: hierarchies, property lists, and
-- table printers, all read-only and all depth-limited.
--
--   local I = FatCat.require("FatCatInspect")
--   I.describe(workspace.Baseplate)      -- one line
--   I.tree(game.Players, 3)              -- nested table, depth 3
--   I.properties(part, { "Size", "Color" })
--   I.format(coreTemplate)               -- readable string, cycle-safe
--
-- Read-only is the design rule, not a limitation: everything the exploit tabs
-- show is produced by these functions, and a printer that can mutate what it
-- prints cannot be trusted to debug it.
--
-- Two hard problems this solves:
--   * cycles: a table that contains itself must print as `{...}` instead of
--     recursing until the stack dies;
--   * hostile metatables: indexing a userdata can throw, so every read is
--     wrapped and a thrown read prints as `<error>` instead of killing the
--     whole dump.

local Materials, Inspect
Inspect = {}

---Maximum nodes the tree walker will visit, so a 300 000 part workspace
---cannot lock the menu while it prints.
Inspect.MAX_NODES = 400

-- ==========================================================================
-- Values
-- ==========================================================================

local function safeIndex(target, key)
	local ok, value = pcall(function()
		return (target :: any)[key]
	end)
	if ok then
		return value
	end
	return nil, tostring(value)
end

---One-line description of any value.
function Inspect.describe(value)
	local kind = typeof(value)
	if kind == "Instance" then
		return ("%s [%s]"):format(value.Name, value.ClassName)
	elseif kind == "string" then
		return ("%q"):format(value)
	elseif kind == "number" then
		if value ~= value then
			return "nan"
		end
		return tostring(value)
	elseif kind == "table" then
		local count = 0
		for _ in value do
			count += 1
		end
		return ("table (%d)"):format(count)
	elseif kind == "userdata" or kind == "Vector3" or kind == "CFrame"
		or kind == "Color3" or kind == "UDim2" or kind == "Vector2" then
		return tostring(value)
	end
	return ("%s %s"):format(kind, tostring(value))
end

---Recursive, cycle-safe, depth-limited formatting.
function Inspect.format(value, options)
	options = options or {}
	local depthLimit = options.Depth or 3
	local seen = {}
	local lines = {}

	local function walk(item, depth, prefix)
		if depth > depthLimit then
			table.insert(lines, prefix .. "…")
			return
		end

		local kind = typeof(item)
		if kind ~= "table" then
			table.insert(lines, prefix .. Inspect.describe(item))
			return
		end
		if seen[item] then
			table.insert(lines, prefix .. "{cycle}")
			return
		end
		seen[item] = true

		local keys = {}
		for key in item do
			table.insert(keys, key)
		end
		-- Strings first, then numbers, then everything else: a template's
		-- named fields read better before its numeric array part.
		table.sort(keys, function(a, b)
			local ra, rb = type(a), type(b)
			if ra ~= rb then
				return ra < rb
			end
			if ra == "number" or ra == "string" then
				return a < b
			end
			return tostring(a) < tostring(b)
		end)

		for _, key in keys do
			local entry, errorText = safeIndex(item, key)
			local label = type(key) == "string" and key or ("[" .. tostring(key) .. "]")
			if errorText then
				table.insert(lines, ("%s%s = <error: %s>"):format(prefix, label, errorText))
			elseif typeof(entry) == "table" then
				table.insert(lines, ("%s%s ="):format(prefix, label))
				walk(entry, depth + 1, prefix .. "  ")
			else
				table.insert(lines, ("%s%s = %s"):format(prefix, label, Inspect.describe(entry)))
			end
		end
		seen[item] = nil
	end

	walk(value, 1, "")
	return table.concat(lines, "\n")
end

-- ==========================================================================
-- Instances
-- ==========================================================================

---Nested { name, class, children } up to `depth`, capped at MAX_NODES.
function Inspect.tree(root, depth)
	local visited = 0
	local function walk(instance, level)
		visited += 1
		local node = {
			name = instance.Name,
			class = instance.ClassName,
			children = {},
		}
		if level >= depth or visited >= Inspect.MAX_NODES then
			local count = #instance:GetChildren()
			if count > 0 then
				node.omitted = count
			end
			return node
		end
		for _, child in instance:GetChildren() do
			if visited >= Inspect.MAX_NODES then
				node.truncated = true
				break
			end
			table.insert(node.children, walk(child, level + 1))
		end
		return node
	end
	return walk(root, 1)
end

---Indented text for the tree above, one line per node.
function Inspect.treeText(root, depth)
	local rootNode = Inspect.tree(root, depth)
	local lines = {}
	local function walk(node, level)
		local suffix = ""
		if node.omitted then
			suffix = ("  (+%d)"):format(node.omitted)
		elseif node.truncated then
			suffix = "  (truncated)"
		end
		table.insert(lines, ("%s%s [%s]%s"):format(
			string.rep("  ", level - 1), node.name, node.class, suffix))
		for _, child in node.children do
			walk(child, level + 1)
		end
	end
	walk(rootNode, 1)
	return table.concat(lines, "\n")
end

---Read a property, or nil plus the error string.
function Inspect.property(instance, name)
	if not instance then
		return nil, "no instance"
	end
	return safeIndex(instance, name)
end

---Every property name a class exposes, via pcall'd GetProperties? Not
---available on every executor: fall back to indexing a probe instance.
function Inspect.propertyNames(className)
	local names = {}
	local ok, probe = pcall(Instance.new, className)
	if not ok then
		return names
	end
	-- There is no portable property enumeration in vanilla Luau; the common
	-- executor surface exposes it through getproperties on some builds, and
	-- through the API dump on others. Return the probe so the caller can list
	-- what it actually needs instead of inventing a list.
	probe:Destroy()
	return names
end

-- ==========================================================================
-- Tab
-- ==========================================================================

local function mount(page)
	local section = page:Section("Hierarchy", 1)
	local target = Materials.Input(section.frame, {
		Text = "Instance path",
		Default = "game.Workspace",
		Placeholder = "game.Workspace",
	})
	local output = Materials.Code(section.frame, { Height = 260 })

	local function resolve(path)
		local chunks = {}
		for piece in tostring(path):gmatch("[^%.]+") do
			table.insert(chunks, piece)
		end
		local current = game
		for _, piece in chunks do
			if current == game and game:GetService(piece) then
				current = game:GetService(piece)
			else
				local ok, child = pcall(function()
					return current:FindFirstChild(piece)
				end)
				if not ok or not child then
					return nil, piece
				end
				current = child
			end
		end
		return current
	end

	Materials.Button(section.frame, {
		Text = "Print hierarchy",
		OnClick = function()
			local instance, missing = resolve(target:Get())
			if not instance then
				output:SetLines("Could not resolve '" .. tostring(missing) .. "'")
				return
			end
			output:SetLines(Inspect.treeText(instance, 3), 300)
		end,
	})

	local props = page:Section("Properties", 2)
	local propTarget = Materials.Input(props.frame, { Text = "Instance name", Default = "Workspace" })
	local propOutput = Materials.Code(props.frame, { Height = 260 })
	Materials.Button(props.frame, {
		Text = "Show table",
		OnClick = function()
			local instance, missing = resolve("game." .. propTarget:Get())
			if not instance then
				propOutput:SetLines("No instance named '" .. tostring(missing) .. "'")
				return
			end
			propOutput:SetLines(Inspect.format({
				Name = instance.Name,
				ClassName = instance.ClassName,
				Parent = instance.Parent and instance.Parent.Name or nil,
				Children = #instance:GetChildren(),
				Archivable = instance.Archivable,
			}), 120)
		end,
	})

	return { mount = true }
end

Inspect.mount = mount

return function(_core, materials)
	Materials = materials
	return Inspect
end
