-- Fat Cat Project | UI & Styling Engine/FatCatMaterials.lua
--
-- The component library: every interactive thing in the project is built from
-- these, and nothing else in the tree calls Instance.new for UI.
--
--   local M = FatCat.require("FatCatMaterials")
--   M.Button(section, { Text = "Run", OnClick = run })
--   M.Toggle(section, { Text = "ESP", Flag = "visual.esp", OnChange = ... })
--   M.Slider(section, { Text = "FOV", Min = 40, Max = 140, Default = 70 })
--
-- Why not reuse the shell's Components? Because the shell's are closures over
-- its own THEME local, captured when the module loaded: they cannot follow a
-- palette switch and they cannot be unit tested without the whole window.
-- These read Design.color on demand, take an explicit parent, and return a
-- handle with :Set/:Get/:Destroy so a rebuild can drop them cleanly.
--
-- Every component:
--   * sizes itself on the 4 px grid and never overlaps its neighbour;
--   * takes { Flag }, and registers its setter with the owning section when
--     one is passed, so presets can drive it;
--   * returns { Instance, Set, Get, Destroy }.

local Core, Design, Materials
Materials = {}

local function create(className, properties, parent)
	local instance = Instance.new(className)
	for key, value in properties or {} do
		(instance :: any)[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function corner(instance, radius)
	create("UICorner", { CornerRadius = UDim.new(0, radius or Design.radius.card) }, instance)
end

local function stroke(instance, color, transparency)
	return create("UIStroke", {
		Color = color or Design.color("outline"),
		Transparency = transparency or 0.6,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, instance)
end

---Standard label: 13 px, left aligned, truncated rather than overflowing.
local function label(parent, text, size, color, position, width)
	return create("TextLabel", {
		Text = tostring(text),
		TextSize = size or Design.text.label,
		Font = Design.fonts.regular,
		TextColor3 = color or Design.color("text"),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundTransparency = 1,
		Size = width or UDim2.new(1, 0, 1, 0),
		Position = position or UDim2.new(),
	}, parent)
end

---Recolour a frame with a tween when the engine has that method. Falls back
---to an instant set so the same code runs under a test stub.
local function tintTo(instance, color, tweenInfo)
	local method = (instance :: any).TweenBackgroundColor3
	if type(method) == "function" then
		method(instance, tweenInfo or Design.tween("fast"), color)
	else
		instance.BackgroundColor3 = color
	end
end

---Every component returns this shape: { Instance, Set, Get, Destroy }.
---
---Call them with a colon: `handle:Set(70)`, `handle:Get()`. The methods below
---are written as `Set = function(self, value)` rather than
---`function handle:Set(value)` for the same result, but the `self` parameter
---is explicit - omitting it is the bug that shifts every argument by one when
---the caller uses `:`, and it is silent: the value arrives in `self`, the real
---parameter is nil, and a numeric setter's guard swallows it.
local function handle(instance, setter, getter)
	local self = {
		Instance = instance,
	}

	self.Set = function(_, value)
		if setter then
			setter(value)
		end
	end

	self.Get = function(_)
		if getter then
			return getter()
		end
		return nil
	end

	self.Destroy = function(_)
		if instance and instance.Parent then
			instance:Destroy()
		end
	end

	return self
end

-- ==========================================================================
-- Section binding
-- ==========================================================================
-- A Section is { frame, setters, values }. Components register their setter
-- there so a preset load can drive every control on a tab at once, without
-- walking the instance tree looking for matches.

---Create a section box with the design's own chrome.
function Materials.Section(parent, title, height)
	local box = create("Frame", {
		Name = tostring(title),
		Size = UDim2.new(1, 0, 0, height or 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Design.color("section"),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	corner(box, Design.radius.card)
	create("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 8),
	}, box)
	create("UIListLayout", {
		Padding = UDim.new(0, Design.space.xs + 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, box)

	local header = create("TextLabel", {
		Text = tostring(title):upper(),
		TextSize = Design.text.section,
		Font = Design.fonts.bold,
		TextColor3 = Design.color("textDim"),
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
		LayoutOrder = 0,
	}, box)

	return {
		frame = box,
		header = header,
		setters = {},
		values = {},
		Register = function(section, flag, setter, getter)
			if not flag then
				return
			end
			section.setters[flag] = setter
			if getter then
				section.values[flag] = getter
			end
		end,
		Apply = function(section, values)
			for flag, value in values do
				local setter = section.setters[flag]
				if setter then
					pcall(setter, value)
				end
			end
		end,
	}
end

-- ==========================================================================
-- Button
-- ==========================================================================
-- options: Text, Description, OnClick, Danger, Height

function Materials.Button(parent, options)
	options = options or {}
	local height = options.Height or (options.Description and 48 or 32)
	local button = create("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = options.Danger and Design.color("negative") or Design.color("card"),
		BackgroundTransparency = options.Danger and 0.55 or 0.15,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	corner(button, Design.radius.field)
	local border = stroke(button)

	local title = label(button, options.Text or "Button", Design.text.label, Design.color("text"),
		UDim2.fromOffset(10, options.Description and 6 or 0),
		UDim2.new(1, -20, 0, options.Description and 18 or height))
	title.TextYAlignment = Enum.TextYAlignment.Center
	if options.Description then
		label(button, options.Description, Design.text.hint, Design.color("textDim"),
			UDim2.fromOffset(10, 24), UDim2.new(1, -20, 0, 16))
	end

	local function tint(hovering)
		local target = hovering and Design.color("cardHover") or Design.color("card")
		tintTo(button, target)
		border.Transparency = hovering and 0.35 or 0.6
	end

	button.MouseEnter:Connect(function()
		tint(true)
	end)
	button.MouseLeave:Connect(function()
		tint(false)
	end)
	button.Activated:Connect(function()
		if type(options.OnClick) == "function" then
			local ok, err = pcall(options.OnClick, button)
			if not ok then
				Core:Log("error", "button '" .. tostring(options.Text) .. "': " .. tostring(err))
			end
		end
	end)

	local self = handle(button, nil, nil)
	-- Assignment, not `function self.X(...)`: when the caller writes
	-- `handle:SetBusy(true)` the method syntax passes `self` first, so the
	-- implicit-self form would shift every argument by one.
	self.SetBusy = function(_, busy)
		button.Active = not busy
		title.TextTransparency = busy and 0.5 or 0
	end
	---Change the caption at runtime (a Run button that becomes Stop).
	self.SetText = function(_, text)
		title.Text = tostring(text)
	end
	return self
end

-- ==========================================================================
-- Toggle
-- ==========================================================================
-- options: Text, Description, Default, Flag, OnChange

function Materials.Toggle(parent, options)
	options = options or {}
	local height = options.Description and 46 or 32
	local card = create("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Design.color("card"),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	corner(card, Design.radius.field)
	-- The border exists so the row reads as a control at rest; the hover
	-- state below only recolours the fill, and dropping the stroke would make
	-- a disabled-looking row slightly lighter than its neighbours.
	stroke(card)

	-- 18x18 box at x=9: the shell's checkbox, kept identical on purpose so
	-- the project tab and the base tab cannot drift apart.
	local box = create("Frame", {
		Size = UDim2.fromOffset(18, 18),
		Position = UDim2.new(0, 9, 0.5, -9),
		BackgroundColor3 = Design.color("element"),
		BorderSizePixel = 0,
	}, card)
	corner(box, 4)
	local boxBorder = stroke(box, Design.color("outline"), 0.4)

	local tick = label(box, "✓", 12, Design.color("onAccent"), UDim2.new(), UDim2.new(1, 0, 1, 0))
	tick.TextXAlignment = Enum.TextXAlignment.Center
	tick.Font = Design.fonts.bold
	tick.TextTransparency = 1

	local textX = 32
	label(card, options.Text or "Toggle", Design.text.label, Design.color("text"),
		UDim2.fromOffset(textX, options.Description and 6 or 0),
		UDim2.new(1, -textX - 10, 0, options.Description and 18 or height))
	if options.Description then
		label(card, options.Description, Design.text.hint, Design.color("textDim"),
			UDim2.fromOffset(textX, 24), UDim2.new(1, -textX - 10, 0, 16))
	end

	local value = options.Default == true
	local handlers = {}

	local function paint()
		tick.TextTransparency = value and 0 or 1
		box.BackgroundColor3 = value and Design.color("accent") or Design.color("element")
		boxBorder.Color = value and Design.color("accent") or Design.color("outline")
	end

	local function set(nextValue, silent)
		value = nextValue and true or false
		paint()
		if silent then
			return
		end
		for _, handler in handlers do
			local ok, err = pcall(handler, value)
			if not ok then
				Core:Log("error", "toggle '" .. tostring(options.Text) .. "': " .. tostring(err))
			end
		end
	end

	paint()

	card.MouseEnter:Connect(function()
		card.BackgroundColor3 = Design.color("cardHover")
		card.BackgroundTransparency = 0
	end)
	card.MouseLeave:Connect(function()
		card.BackgroundColor3 = Design.color("card")
		card.BackgroundTransparency = 0.15
	end)
	card.Activated:Connect(function()
		set(not value)
	end)

	local self = handle(card, set, function()
		return value
	end)
	-- Colon-called (`handle:OnChange(fn)`), so the first parameter is `self`.
	self.OnChange = function(this, handler)
		table.insert(handlers, handler)
		return this
	end
	self:OnChange(options.OnChange)
	if parent.Register then
		parent.Register(parent, options.Flag, function(nextValue)
			set(nextValue and nextValue ~= false)
		end, function()
			return value
		end)
	end
	if value then
		set(true, true)
	end
	return self
end

-- ==========================================================================
-- Slider
-- ==========================================================================
-- options: Text, Min, Max, Default, Suffix, Step, Flag, OnChange

function Materials.Slider(parent, options)
	options = options or {}
	local min = tonumber(options.Min) or 0
	local max = tonumber(options.Max) or 100
	if max <= min then
		max = min + 1
	end
	local step = tonumber(options.Step) or 1
	local suffix = options.Suffix or ""

	local holder = create("Frame", {
		Name = tostring(options.Text or "Slider"),
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundColor3 = Design.color("card"),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	corner(holder, Design.radius.field)
	stroke(holder)

	label(holder, options.Text or "Slider", Design.text.label, Design.color("text"),
		UDim2.fromOffset(10, 5), UDim2.new(1, -60, 0, 16))

	local readout = label(holder, "", Design.text.value, Design.color("accent"),
		UDim2.new(1, -56, 0, 5), UDim2.fromOffset(46, 16))
	readout.TextXAlignment = Enum.TextXAlignment.Right

	-- 6 px hit area: a 4 px track is impossible to grab on a phone.
	local track = create("Frame", {
		Size = UDim2.new(1, -20, 0, 6),
		Position = UDim2.new(0, 10, 1, -16),
		BackgroundColor3 = Design.color("element"),
		BorderSizePixel = 0,
	}, holder)
	corner(track, 3)

	local fill = create("Frame", {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Design.color("accent"),
		BorderSizePixel = 0,
	}, track)
	corner(fill, 3)

	local knob = create("Frame", {
		Size = UDim2.fromOffset(12, 12),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = Design.color("text"),
		BorderSizePixel = 0,
	}, track)
	corner(knob, Design.radius.pill)

	local value = math.clamp(tonumber(options.Default) or min, min, max)
	local handlers = {}
	local dragging = false

	local function format(number)
		if step < 1 then
			return ("%.2f%s"):format(number, suffix)
		end
		return ("%d%s"):format(math.floor(number + 0.5), suffix)
	end

	local function paint()
		local alpha = (value - min) / (max - min)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		readout.Text = format(value)
	end

	local function commit(nextValue, silent)
		local snapped = math.round((nextValue - min) / step) * step + min
		value = math.clamp(snapped, min, max)
		paint()
		if silent then
			return
		end
		for _, handler in handlers do
			pcall(handler, value)
		end
	end

	paint()

	local function valueAtX(x)
		local relative = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		return min + relative * (max - min)
	end

	local stepLink = Core:GetService("renderConnection") -- shared heartbeat
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			commit(valueAtX(input.Position.X))
		end
	end)
	track.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	if stepLink then
		-- One shared RenderStepped for every slider, owned by FatCatCore, so
		-- dragging five sliders does not create five global loops.
		stepLink(function()
			if not dragging then
				return
			end
			local mouse = Core:GetService("mouse")
			if not mouse then
				return
			end
			commit(valueAtX(mouse.X))
		end)
	end

	local self = handle(holder, nil, function()
		return value
	end)
	---Set the slider. Coerced here, not in `commit`, because a preset can
	---carry a string ("70") after a round trip through JSON and arithmetic on
	---it would throw inside the button callback with no link back to here.
	-- `self.Set = function(nextValue)` and NOT `function self.Set(nextValue)`:
	-- the colon-free method syntax still passes `self` as the first argument
	-- when the field is called as `handle:Set(57)`, so the number would arrive
	-- in `self` and the real value would be nil.
	self.Set = function(_, nextValue)
		local number = tonumber(nextValue)
		if number == nil then
			Core:Log("warn", ("slider '%s' ignored a non-number value (%s)"):format(
				tostring(options.Text), typeof(nextValue)))
			return
		end
		commit(number)
	end
	-- Colon-called (`handle:OnChange(fn)`), so the first parameter is `self`.
	self.OnChange = function(this, handler)
		table.insert(handlers, handler)
		return this
	end
	self:OnChange(options.OnChange)
	if parent.Register then
		parent.Register(parent, options.Flag, function(nextValue)
			commit(tonumber(nextValue) or min)
		end, function()
			return value
		end)
	end
	return self
end

-- ==========================================================================
-- Dropdown
-- ==========================================================================
-- options: Text, Options, Default, Flag, OnChange

function Materials.Dropdown(parent, options)
	options = options or {}
	local choices = options.Options or {}
	local current = options.Default or choices[1]

	local holder = create("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Design.color("card"),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	corner(holder, Design.radius.field)
	stroke(holder)

	label(holder, options.Text or "Select", Design.text.label, Design.color("textOff"),
		UDim2.fromOffset(10, 0), UDim2.new(0.45, -10, 1, 0))
	local shown = label(holder, tostring(current), Design.text.value, Design.color("text"),
		UDim2.new(0.45, 0, 0, 0), UDim2.new(0.55, -26, 1, 0))
	shown.TextXAlignment = Enum.TextXAlignment.Right
	label(holder, "▾", Design.text.hint, Design.color("textDim"),
		UDim2.new(1, -18, 0, 0), UDim2.fromOffset(12, 32))

	local handlers = {}
	local popup = nil

	local function close()
		if popup then
			popup:Destroy()
			popup = nil
		end
	end

	local function choose(choice, silent)
		current = choice
		shown.Text = tostring(choice)
		close()
		if silent then
			return
		end
		for _, handler in handlers do
			pcall(handler, choice)
		end
	end

	holder.Activated:Connect(function()
		if popup then
			close()
			return
		end
		-- Parented to the screen, positioned under this row: a list inside a
		-- scrolling column would be clipped by the column's canvas.
		local layer = options.Layer or Design.canvas or holder.Parent
		popup = create("Frame", {
			BackgroundColor3 = Design.color("element"),
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(holder.AbsoluteSize.X, math.min(#choices, 6) * 24 + 8),
			Position = UDim2.fromOffset(holder.AbsolutePosition.X, holder.AbsolutePosition.Y + holder.AbsoluteSize.Y + 4),
			ZIndex = 40,
		}, layer)
		corner(popup, Design.radius.field)
		stroke(popup, Design.color("outline"), 0.25)
		create("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }, popup)
		for index, choice in choices do
			local item = create("TextButton", {
				Text = tostring(choice),
				TextSize = Design.text.body,
				Font = Design.fonts.regular,
				TextColor3 = choice == current and Design.color("accent") or Design.color("text"),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -8, 0, 24),
				Position = UDim2.fromOffset(4, 4 + (index - 1) * 24),
				ZIndex = 41,
			}, popup)
			item.Activated:Connect(function()
				choose(choice)
			end)
		end
	end)

	local self = handle(holder, function(nextValue)
		choose(nextValue)
	end, function()
		return current
	end)
	-- Colon-called (`handle:OnChange(fn)`), so the first parameter is `self`.
	self.OnChange = function(this, handler)
		table.insert(handlers, handler)
		return this
	end
	self:OnChange(options.OnChange)
	self.Destroy = function(_)
		close()
		holder:Destroy()
	end
	if parent.Register then
		parent.Register(parent, options.Flag, function(nextValue)
			choose(nextValue)
		end, function()
			return current
		end)
	end
	return self
end

-- ==========================================================================
-- Input
-- ==========================================================================
-- options: Text, Placeholder, Default, Flag, OnSubmit

function Materials.Input(parent, options)
	options = options or {}
	local card = create("Frame", {
		BackgroundColor3 = Design.color("card"),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 50),
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	corner(card, Design.radius.field)
	stroke(card)

	label(card, options.Text or "Input", Design.text.label, Design.color("text"),
		UDim2.fromOffset(10, 4), UDim2.new(1, -20, 0, 16))

	local field = create("TextBox", {
		Size = UDim2.new(1, -20, 0, 22),
		Position = UDim2.fromOffset(10, 22),
		BackgroundColor3 = Design.color("element"),
		BorderSizePixel = 0,
		PlaceholderText = options.Placeholder or "Type here",
		PlaceholderColor3 = Design.color("textDim"),
		Text = tostring(options.Default or ""),
		TextColor3 = Design.color("text"),
		TextSize = Design.text.body,
		Font = Design.fonts.regular,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ClearTextOnFocus = false,
	}, card)
	corner(field, Design.radius.field)
	create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, field)
	stroke(field, Design.color("outline"), 0.55)

	field.Focused:Connect(function()
		field.Size = UDim2.new(1, -20, 0, 22)
	end)
	field.FocusLost:Connect(function()
		if type(options.OnSubmit) == "function" then
			pcall(options.OnSubmit, field.Text)
		end
	end)

	local self = handle(card, function(nextValue)
		field.Text = tostring(nextValue)
	end, function()
		return field.Text
	end)
	if parent.Register then
		parent.Register(parent, options.Flag, function(nextValue)
			field.Text = tostring(nextValue)
		end, function()
			return field.Text
		end)
	end
	return self
end

-- ==========================================================================
-- Status / label / divider
-- ==========================================================================

---Dot + text, no card. For readouts that must not look clickable.
function Materials.Status(parent, text, state)
	local row = create("Frame", {
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	local colors = {
		on = Design.color("positive"),
		off = Design.color("negative"),
		warn = Design.color("accentAlt"),
		info = Design.color("accent"),
	}
	local dot = create("Frame", {
		Size = UDim2.fromOffset(6, 6),
		Position = UDim2.fromOffset(2, 7),
		BackgroundColor3 = colors[state or "info"] or Design.color("accent"),
		BorderSizePixel = 0,
	}, row)
	corner(dot, Design.radius.pill)
	local cap = label(row, text, Design.text.body, Design.color("textOff"),
		UDim2.fromOffset(14, 0), UDim2.new(1, -16, 1, 0))

	local self = handle(row, function(nextText, nextState)
		cap.Text = tostring(nextText)
		dot.BackgroundColor3 = colors[nextState or "info"] or Design.color("accent")
	end, function()
		return cap.Text
	end)
	return self
end

function Materials.Label(parent, text)
	local card = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	local cap = create("TextLabel", {
		Text = tostring(text),
		TextSize = Design.text.body,
		Font = Design.fonts.regular,
		TextColor3 = Design.color("textDim"),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, card)
	local self = handle(card, function(nextText)
		cap.Text = tostring(nextText)
	end, function()
		return cap.Text
	end)
	return self
end

function Materials.Divider(parent)
	local holder = create("Frame", {
		Size = UDim2.new(1, 0, 0, 9),
		BackgroundTransparency = 1,
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	local line = create("Frame", {
		Size = UDim2.new(1, -12, 0, 1),
		Position = UDim2.fromOffset(6, 4),
		BackgroundColor3 = Design.color("outline"),
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
	}, holder)
	Design.fade(1, line)
	return handle(holder, nil, nil)
end

---Code viewer: monospaced, scrolls both ways, capped line count.
function Materials.Code(parent, options)
	options = options or {}
	local card = create("Frame", {
		BackgroundColor3 = Design.color("element"),
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, options.Height or 140),
		LayoutOrder = #parent:GetChildren() + 1,
	}, parent)
	corner(card, Design.radius.field)
	stroke(card, Design.color("outline"), 0.6)

	local scroll = create("ScrollingFrame", {
		Size = UDim2.new(1, -8, 1, -8),
		Position = UDim2.fromOffset(4, 4),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = Design.color("outline"),
		ScrollBarImageTransparency = 0.4,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.XY,
	}, card)
	local text = create("TextLabel", {
		Text = "",
		TextSize = Design.text.code,
		Font = Design.fonts.mono,
		TextColor3 = Design.color("textOff"),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
	}, scroll)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.XY

	local lines = {}
	local self = handle(card, nil, nil)
	---Replace the buffer and keep only the newest `limit` lines.
	---Accepts a table of lines or one multi-line string.
	self.SetLines = function(_, newLines, limit)
		table.clear(lines)
		if type(newLines) == "string" then
			for line in (newLines .. "\n"):gmatch("([^\n]*)\n") do
				table.insert(lines, line)
			end
		else
			for _, line in newLines or {} do
				table.insert(lines, line)
			end
		end
		local cap = limit or 300
		while #lines > cap do
			table.remove(lines, 1)
		end
		text.Text = table.concat(lines, "\n")
	end
	self.Push = function(_, line)
		table.insert(lines, tostring(line))
		while #lines > 300 do
			table.remove(lines, 1)
		end
		text.Text = table.concat(lines, "\n")
	end
	self.ScrollToBottom = function(_)
		scroll.CanvasPosition = Vector2.new(0, math.max(text.AbsoluteSize.Y - scroll.AbsoluteSize.Y, 0))
	end
	self.SetLines(options.Lines or options.Text or "")
	return self
end

return function(core, design, _signal)
	Core = core
	Design = design
	return Materials
end
