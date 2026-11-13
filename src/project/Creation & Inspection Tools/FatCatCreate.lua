-- Fat Cat Project | Creation & Inspection Tools/FatCatCreate.lua
--
-- A visual GUI builder: a design surface, a property list, and a tree, all
-- editing one plain data table. The data table is the thing that matters —
-- it serialises to a preset, round-trips through FatCatConfig, and can be
-- turned into live instances at any point.
--
--   local Create = FatCat.require("FatCatCreate")
--   Create.mount(page)                    -- the editor tab
--   local doc = Create.new("My Panel")    -- programmatic document
--   Create.add(doc, "TextButton", { ... })
--   Create.build(doc, parentGui)          -- instantiate for real
--   Create.serialize(doc)                  -- JSON-safe table
--
-- The document shape:
--
--   {
--     name = "My Panel",
--     tree = {                        -- every node is a child by `parent`
--       { id = 1, class = "ScreenGui", props = {...}, parent = nil },
--       { id = 2, class = "Frame", props = {...}, parent = 1 },
--     },
--     nextId = 3,
--     selection = 2,
--   }
--
-- A tree in an array (ids, not nested tables) makes reordering, deletion and
-- JSON round-trips trivial; nesting re-introduces the deep-copy problems the
-- document exists to avoid.

local Core, Design, Materials, Create
Create = {}

-- Classes the editor offers. Deliberately short: these are the ones with a
-- stable property set, and every entry has defaults so a new node is valid.
Create.CLASSES = {
	{ class = "ScreenGui", label = "Screen", defaults = { ResetOnSpawn = false } },
	{ class = "Frame", label = "Frame", defaults = { Size = { 0.4, 0, 0.3, 0 }, BackgroundColor3 = "card" } },
	{ class = "TextLabel", label = "Label", defaults = { Text = "Label", TextSize = 13, Size = { 0.4, 0, 0, 20 } } },
	{ class = "TextButton", label = "Button", defaults = { Text = "Button", TextSize = 13, Size = { 0.4, 0, 0, 28 } } },
	{ class = "TextBox", label = "Input", defaults = { Text = "", PlaceholderText = "Type...", Size = { 0.4, 0, 0, 24 } } },
	{ class = "ScrollingFrame", label = "Scroll", defaults = { ScrollBarThickness = 2, Size = { 0.4, 0, 0.3, 0 } } },
	{ class = "ImageLabel", label = "Image", defaults = { Size = { 0.1, 0, 0.1, 0 } } },
}

local defaultsById = {}
for _, entry in Create.CLASSES do
	defaultsById[entry.class] = entry
end

-- ==========================================================================
-- Document
-- ==========================================================================

---A new document with a single ScreenGui root.
function Create.new(name)
	local document = {
		name = name or "Untitled",
		tree = {},
		nextId = 1,
		selection = nil,
	}
	local root = Create.add(document, "ScreenGui", { Name = name or "ScreenGui" })
	document.selection = root.id
	return document
end

---Add a node. Returns the node, or nil plus a reason for an unknown class.
function Create.add(document, class, props)
	local entry = defaultsById[class]
	if not entry then
		return nil, ("unknown class '%s'"):format(tostring(class))
	end

	local merged = {}
	for key, value in entry.defaults do
		merged[key] = value
	end
	for key, value in props or {} do
		merged[key] = value
	end

	local node = {
		id = document.nextId,
		class = class,
		props = merged,
		parent = document.selection,
	}
	document.nextId += 1
	table.insert(document.tree, node)
	return node
end

---Find a node by id.
function Create.get(document, id)
	for _, node in document.tree do
		if node.id == id then
			return node
		end
	end
	return nil
end

---Children of `id` (nil = roots).
function Create.children(document, id)
	local list = {}
	for _, node in document.tree do
		if node.parent == id then
			table.insert(list, node)
		end
	end
	return list
end

---Remove a node and everything under it. Returns the removed nodes.
function Create.remove(document, id)
	local doomed, stack = {}, { id }
	while #stack > 0 do
		local current = table.remove(stack)
		doomed[current] = true
		for _, child in Create.children(document, current) do
			table.insert(stack, child.id)
		end
	end

	local kept = {}
	for _, node in document.tree do
		if not doomed[node.id] then
			table.insert(kept, node)
		end
	end
	document.tree = kept
	if doomed[document.selection] then
		document.selection = nil
	end
	return doomed
end

---Reparent. Refuses a cycle (dropping a node into its own descendant).
function Create.reparent(document, id, newParent)
	if id == newParent then
		return false, "a node cannot be its own parent"
	end
	local node = Create.get(document, id)
	if not node then
		return false, "no such node"
	end
	-- Walk up from the target: if we meet `id`, this would make a loop.
	local cursor = newParent
	while cursor do
		if cursor == id then
			return false, "that would put the node inside itself"
		end
		local parent = Create.get(document, cursor)
		cursor = parent and parent.parent or nil
	end
	node.parent = newParent
	return true
end

---Set one property, validating the two that cause the worst breakage.
function Create.setProperty(document, id, key, value)
	local node = Create.get(document, id)
	if not node then
		return false, "no such node"
	end
	if key == "Name" and (type(value) ~= "string" or value == "") then
		return false, "a name cannot be empty"
	end
	if key == "class" then
		return false, "changing a class would drop its properties"
	end
	node.props[key] = value
	return true
end

---JSON-safe copy: colours become palette keys, UDim2 becomes 4 numbers, so a
---preset written today still loads if a palette changes tomorrow.
function Create.serialize(document)
	local tree = {}
	for _, node in document.tree do
		local props = {}
		for key, value in node.props do
			local kind = typeof(value)
			if kind == "Color3" then
				props[key] = { rgb = {
					math.round(value.R * 255),
					math.round(value.G * 255),
					math.round(value.B * 255),
				} }
			elseif kind == "UDim2" then
				props[key] = {
					xs = value.X.Scale, xo = value.X.Offset,
					ys = value.Y.Scale, yo = value.Y.Offset,
				}
			elseif kind == "string" or kind == "number" or kind == "boolean" then
				props[key] = value
			end
		end
		table.insert(tree, { id = node.id, class = node.class, props = props, parent = node.parent })
	end
	return { name = document.name, tree = tree, nextId = document.nextId }
end

---Rebuild a document from Create.serialize output.
function Create.deserialize(payload)
	if type(payload) ~= "table" or type(payload.tree) ~= "table" then
		return nil, "not a document"
	end
	local document = {
		name = payload.name or "Untitled",
		tree = {},
		nextId = payload.nextId or 1,
		selection = nil,
	}
	for _, entry in payload.tree do
		table.insert(document.tree, {
			id = entry.id or document.nextId,
			class = entry.class,
			props = entry.props or {},
			parent = entry.parent,
		})
	end
	return document
end

-- ==========================================================================
-- Instantiation
-- ==========================================================================

local function applyProps(instance, props)
	for key, value in props do
		if key == "Size" or key == "Position" then
			if type(value) == "table" then
				instance[key] = UDim2.new(value[1] or 0, value[2] or 0, value[3] or 0, value[4] or 0)
			end
		elseif key == "BackgroundColor3" and type(value) == "string" then
			-- A palette key, resolved at build time so a theme switch is one
			-- palette change, not a rebuild.
			instance.BackgroundColor3 = Design.color(value)
		else
			local ok = pcall(function()
				(instance :: any)[key] = value
			end)
			-- A property the class does not have is skipped, not fatal: a
			-- document written for a newer class must still load.
			if not ok then
				Core:Log("debug", ("%s has no property %s"):format(instance.ClassName, key))
			end
		end
	end
end

---Turn the document into real instances under `parent`.
function Create.build(document, parent)
	local created = {}
	local function buildNode(node, target)
		local ok, instance = pcall(Instance.new, node.class)
		if not ok then
			Core:Log("error", ("cannot create %s: %s"):format(tostring(node.class), tostring(instance)))
			return
		end
		applyProps(instance :: Instance, node.props)
		instance.Parent = target
		created[node.id] = instance
		for _, child in Create.children(document, node.id) do
			buildNode(child, instance)
		end
	end

	for _, rootNode in Create.children(document, nil) do
		buildNode(rootNode, parent)
	end
	return created
end

---Destroy instances returned by build.
function Create.clear(created)
	for _, instance in created or {} do
		pcall(function()
			instance:Destroy()
		end)
	end
end

-- ==========================================================================
-- Editor tab
-- ==========================================================================

local function describe(node)
	local name = node.props.Name or node.class
	return ("%s (%s)"):format(tostring(name), node.class)
end

---Build the Create tab into a page.
---@param page table  a Page from the shell (has :Section)
function Create.mount(page)
	local section = page:Section("Builder", 1)
	Materials.Label(section.frame,
		"Pick a class, click Add, then edit its properties. Every change is written "
		.. "to the document immediately; Save writes it as a preset.")
	Materials.Divider(section.frame)

	local document = Create.new("Untitled")
	Core.state.createDocument = document

	local treeSection = page:Section("Tree", 2)
	local listHolder = treeSection.frame
	local selectedLabel = Materials.Status(listHolder, "nothing selected", "info")

	local properties = Materials.Section(listHolder, "Properties")
	local propertyRows = {}
	local refreshProperties -- defined below; the tree rows call it

	local function refreshTree()
		for _, handle in propertyRows do
			handle:Destroy()
		end
		table.clear(propertyRows)

		local nodes = Create.children(document, nil)
		local function walk(id, depth)
			for _, node in Create.children(document, id) do
				local prefix = string.rep("  ", depth)
				local row = Materials.Button(listHolder, {
					Text = prefix .. describe(node),
					Height = 26,
					OnClick = function()
						document.selection = node.id
						selectedLabel:Set(describe(node), "on")
						refreshProperties()
					end,
				})
				table.insert(propertyRows, row)
				walk(node.id, depth + 1)
			end
		end
		walk(nil, 0)
		if #nodes == 0 then
			table.insert(propertyRows, Materials.Label(listHolder, "The document is empty. Add a class above."))
		end
	end

	refreshProperties = function()
		local node = document.selection and Create.get(document, document.selection) or nil
		if not node then
			return
		end
		for _, key in { "Name", "Text", "TextSize" } do
			if node.props[key] ~= nil then
				local field = Materials.Input(properties.frame, {
					Text = key,
					Default = tostring(node.props[key]),
					OnSubmit = function(value)
						local converted = value
						if key == "TextSize" then
							converted = tonumber(value) or node.props.TextSize
						end
						Create.setProperty(document, node.id, key, converted)
						refreshTree()
					end,
				})
				table.insert(propertyRows, field)
			end
		end
	end

	local picker = Materials.Dropdown(section.frame, {
		Text = "Class",
		Options = (function()
			local names = {}
			for _, entry in Create.CLASSES do
				table.insert(names, entry.label)
			end
			return names
		end)(),
		Default = "Frame",
	})
	local classByLabel = {}
	for _, entry in Create.CLASSES do
		classByLabel[entry.label] = entry.class
	end

	Materials.Button(section.frame, {
		Text = "Add child",
		OnClick = function()
			local chosen = classByLabel[picker:Get()] or "Frame"
			local node = Create.add(document, chosen, {})
			if node then
				document.selection = node.id
				selectedLabel:Set(describe(node), "on")
				refreshTree()
				refreshProperties()
			end
		end,
	})
	Materials.Button(section.frame, {
		Text = "Delete selected",
		Danger = true,
		OnClick = function()
			if not document.selection then
				return
			end
			Create.remove(document, document.selection)
			selectedLabel:Set("nothing selected", "info")
			refreshTree()
		end,
	})
	Materials.Button(section.frame, {
		Text = "Preview on screen",
		OnClick = function()
			local previous = Core:GetService("createPreview")
			if previous then
				Create.clear(previous)
			end
			local layer = Design.canvas
			if not layer then
				return
			end
			local created = Create.build(document, layer)
			Core:SetService("createPreview", created, function()
				Create.clear(created)
			end)
		end,
	})

	refreshTree()
	return {
		document = document,
		refresh = refreshTree,
	}
end

return function(core, design, _signal, materials)
	Core = core
	Design = design
	Materials = materials
	return Create
end
