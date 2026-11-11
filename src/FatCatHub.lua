-- FatCat Hub | library, loader and UI builder.
-- Derived from the FatCat Hub menu (KaliHub shell): the game-specific code is gone, the
-- shell is rebuilt. Exposes _G.FatCatHub for loader scripts and game modules.
--
--   local Hub = loadstring(game:HttpGet("<url>"))()
--   local Window = Hub:Window({ Title = "My Hub", Tabs = { "Main" } })
--   local tab = Window:Tab("Main")
--   local box = tab:Section("Options")
--   box:Toggle({ Text = "Feature", Default = false, Flag = "feature" })
--
-- Structure:
--   theme / animations / config   constants and small helpers
--   hub                           state, input, notifications, storage
--   components                    card, section, toggle, slider, cycle,
--                                 input, dropdown, keybind, button, group,
--                                 color, label, divider
--   window                        frame, title bar, tab bar, pages, resize
--   loader                        boot, xpcall diagnostics

if _G.FatCatHub then
	pcall(function()
		_G.FatCatHub:Destroy()
	end)
end

do
	-- ======================================================================
	-- Services
	-- ======================================================================
	local playersService = game:GetService("Players")
	local userInputService = game:GetService("UserInputService")
	local httpService = game:GetService("HttpService")
	local tweenService = game:GetService("TweenService")

	local localPlayer = playersService.LocalPlayer

	-- ======================================================================
	-- Config
	-- ======================================================================
	local CONFIG = {
		title = "FatCat Hub",
		version = "1.0.0",
		width = 460,
		height = 560,
		minWidth = 380,
		minHeight = 380,
		maxWidth = 900,
		maxHeight = 820,
		titleHeight = 40,
		tabHeight = 34,
		footerHeight = 22,
		cornerRadius = 12,
		cardRadius = 8,
		tabs = { "Main" },
		-- Both shifts: a laptop keyboard has no right shift, and a menu that
		-- only opens with a key you do not have looks like a broken menu.
		menuKey = { "RightShift", "LeftShift" },
		hintsKeys = { "H" },
		saveFolder = "FatCatHub",
		saveFile = "FatCatHub/config.json",
		prefsFile = "FatCatHub/preferences.json",
	}

	local THEME = {
		backgroundTop = Color3.fromRGB(26, 26, 30),
		backgroundBottom = Color3.fromRGB(12, 12, 14),
		card = Color3.fromRGB(38, 38, 43),
		cardHover = Color3.fromRGB(47, 47, 53),
		element = Color3.fromRGB(19, 19, 22),
		elementHover = Color3.fromRGB(45, 45, 51),
		chip = Color3.fromRGB(28, 28, 32),
		section = Color3.fromRGB(17, 17, 20),
		outline = Color3.fromRGB(104, 104, 114),
		text = Color3.fromRGB(240, 240, 243),
		textOff = Color3.fromRGB(198, 198, 204),
		textDim = Color3.fromRGB(126, 126, 134),
		accent = Color3.fromRGB(236, 236, 240),
		accentAlt = Color3.fromRGB(138, 138, 148),
		negative = Color3.fromRGB(232, 92, 96),
		positive = Color3.fromRGB(124, 222, 146),
		onAccent = Color3.fromRGB(18, 18, 21),
	}

	-- Swappable at runtime: Hub:SetAccent(color1, color2).
	local colorA = THEME.accent
	local colorB = THEME.accentAlt

	local FONT = Enum.Font.Gotham
	local FONT_BOLD = Enum.Font.GothamBold
	-- Gotham renders every glyph at its own optical size; MediumBold keeps
	-- headings and values the same weight as their row text.
	local FONT_MEDIUM = Enum.Font.GothamMedium
	-- Monospace for anything that is code: a proportional face makes column
	-- alignment in a decompiled listing unreadable.
	local FONT_MONO = Enum.Font.RobotoMono

	local ANIM = {
		fast = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		slide = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		medium = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		pop = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		-- Opening eases out of the overshoot instead of slamming in.
		open = TweenInfo.new(0.36, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	}

	local TEXT_SIZE = { title = 14, tab = 13, label = 13, value = 13, section = 11, hint = 11, code = 11 }

	local UIELEMENT = Enum.RenderPriority.Character.Value + 100

	-- Forward declaration: the helpers below (retween in particular) touch the
	-- shared state table, which is filled in further down.
	local Hub = {
		Values = {},
		Defaults = {},
		Setters = {},
		Keybinds = {},
		Searchables = {},
		Connections = {},
		_entries = {},
		_cancels = setmetatable({}, { __mode = "k" }),
		_gradients = setmetatable({}, { __mode = "k" }),
		_listening = nil,
		_window = nil,
		_screen = nil,
		_toasts = nil,
	}

	-- ======================================================================
	-- Helpers
	-- ======================================================================

	---Create an instance with properties and a parent.
	local function create(className, properties, parent)
		local instance = Instance.new(className)
		for key, value in properties do
			instance[key] = value
		end
		instance.Parent = parent
		return instance
	end

	---Play a tween.
	local function tween(instance, info, goal)
		local newTween = tweenService:Create(instance, info, goal)
		newTween:Play()
		return newTween
	end

	---Kill any tween already running on an object, then play a new one.
	---Without this, a fast hover in/out leaves two tweens fighting over the same
	---property and the row sticks in its hovered colour. The handle is stored on
	---the (weak) registry and dropped when the tween completes, so a row that is
	---hovered ten thousand times keeps exactly one entry.
	local function retween(instance, info, goal)
		local running = Hub._cancels[instance]
		if running then
			for _, handle in running do
				pcall(function()
					handle:Cancel()
				end)
			end
			running = nil
		end
		local newTween = tweenService:Create(instance, info, goal)
		Hub._cancels[instance] = { newTween }
		newTween.Completed:Connect(function()
			local current = Hub._cancels[instance]
			if current and current[1] == newTween then
				Hub._cancels[instance] = nil
			end
		end)
		newTween:Play()
		return newTween
	end

	---Rounded corners plus an optional border stroke, in one call.
	local function round(instance, radius, outline)
		local corner = create("UICorner", { CornerRadius = UDim.new(0, radius) }, instance)
		if outline then
			create("UIStroke", {
				Color = THEME.outline,
				Transparency = outline.transparency or 0.6,
				Thickness = outline.thickness or 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}, instance)
		end
		return corner
	end

	---Rotation-honest gradient. The base uses the live accent pair; a caller can
	---override the sequence for one-off tints (toasts, swatches).
	local function gradient(parent, rotation, sequence)
		return create("UIGradient", {
			Color = sequence or ColorSequence.new(colorA, colorB),
			Rotation = rotation or 0,
		}, parent)
	end

	---Format a slider value without trailing noise: 3 -> "3", 0.30 -> "0.3".
	local function formatNumber(value, decimals)
		if decimals <= 0 then
			return tostring(math.floor(value + 0.5))
		end
		local text = string.format("%." .. decimals .. "f", value)
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
		return text
	end

	---Clamp a UDim2 position so the frame stays on screen after a resolution
	---change or a drag past the viewport edge.
	local function clampToViewport(target)
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
		local size = target.AbsoluteSize
		local position = target.Position
		local x = position.X.Offset
		local y = position.Y.Offset
		local minX = -size.X + 64
		local maxX = viewport.X - 64
		local minY = 0
		local maxY = viewport.Y - CONFIG.titleHeight
		if x < minX then
			x = minX
		elseif x > maxX then
			x = maxX
		end
		if y < minY then
			y = minY
		elseif y > maxY then
			y = maxY
		end
		target.Position = UDim2.new(0, x, 0, y)
	end

	---True when an input is a primary press (mouse or touch).
	local function isPress(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end

	---True when an input is pointer movement.
	local function isMove(input)
		return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
	end

	---Darken or lighten a colour by a factor, clamped to [0, 1].
	local function shade(color, factor)
		if factor >= 0 then
			return Color3.new(
				color.R + (1 - color.R) * factor,
				color.G + (1 - color.G) * factor,
				color.B + (1 - color.B) * factor
			)
		end
		return Color3.new(color.R * (1 + factor), color.G * (1 + factor), color.B * (1 + factor))
	end

	-- ======================================================================
	-- Hub state
	-- ======================================================================
	Hub._initOptions = { Title = CONFIG.title, Tabs = CONFIG.tabs }
	Hub._currentGroup = nil
	Hub._builders = {}
	Hub.deferBoot = false

	_G.FatCatHub = Hub

	---Track a global connection so Destroy can close it.
	local function connect(signal, callback)
		local connection = signal:Connect(callback)
		table.insert(Hub.Connections, connection)
		return connection
	end

	---Look up a KeyCode by name, nil when the name is unknown.
	---True when `keyCode` is any of `names` (a string or a list of strings).
	---Comparing KeyCodes by .Name keeps a typo in the config from silently
	---killing the hotkey: "RightShift" and Enum.KeyCode.RightShift match.
	local function matchesKey(keyCode, names)
		if keyCode == nil or names == nil then
			return false
		end
		if typeof(names) == "string" then
			return keyCode.Name == names
		end
		for _, name in names do
			if keyCode.Name == name then
				return true
			end
		end
		return false
	end

	---Any of the modifiers the hint strip accepts as "ctrl".
	local function isAnyControlDown()
		for _, code in { Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl } do
			local ok, down = pcall(function()
				return userInputService:IsKeyDown(code)
			end)
			if ok and down then
				return true
			end
		end
		return false
	end

	local function keyCodeFromName(name)
		if typeof(name) ~= "string" or name == "" then
			return nil
		end
		for _, item in Enum.KeyCode:GetEnumItems() do
			if item.Name == name then
				return item
			end
		end
		return nil
	end

	---Save or read a JSON file when the executor allows it.
	local function writeJson(path, data)
		if not (writefile and httpService) then
			return false, "Saving is not supported by this executor."
		end
		local ok, result = pcall(function()
			if makefolder and isfolder then
				local folder = string.match(path, "^(.-)/[^/]+$")
				if folder and not isfolder(folder) then
					makefolder(folder)
				end
			end
			writefile(path, httpService:JSONEncode(data))
		end)
		return ok, result
	end

	local function readJson(path)
		if not (readfile and isfile and httpService and isfile(path)) then
			return nil
		end
		local ok, data = pcall(function()
			return httpService:JSONDecode(readfile(path))
		end)
		if ok and typeof(data) == "table" then
			return data
		end
		return nil
	end

	-- ======================================================================
	-- Theme API
	-- ======================================================================

	---Recolour the whole interface at runtime.
	function Hub:SetAccent(primary, secondary)
		colorA = primary or THEME.accent
		colorB = secondary or shade(colorA, -0.45)

		for instance, _ in pairs(Hub._gradients) do
			if instance.Parent then
				instance.Color = ColorSequence.new(colorA, colorB)
			end
		end
	end

	---Create a gradient and register it for recolouring.
	local function liveGradient(parent, rotation)
		local instance = gradient(parent, rotation)
		Hub._gradients[instance] = true
		return instance
	end

	-- ======================================================================
	-- Notifications
	-- ======================================================================
	local function ensureToasts()
		if Hub._toasts and Hub._toasts.Parent then
			return Hub._toasts
		end
		local holder = create("Frame", {
			Name = "Notifications",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -16, 1, -16),
			Size = UDim2.fromOffset(252, 340),
			BackgroundTransparency = 1,
			ZIndex = 50,
		}, Hub._screen)
		create("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
		}, holder)
		Hub._toasts = holder
		return holder
	end

	---Show a stacked toast. `kind` is "on", "off" or "info".
	function Hub:Notify(title, kind, detail)
		if not (Hub._screen and Hub._screen.Parent) then
			return false
		end

		local holder = ensureToasts()
		local positive = kind == "on" or kind == "success"
		local negative = kind == "off" or kind == "error"
		local tint = positive and THEME.positive or (negative and THEME.negative or colorA)

		local toast = create("CanvasGroup", {
			Size = UDim2.fromOffset(252, 40),
			BackgroundColor3 = Color3.fromRGB(18, 18, 21),
			BorderSizePixel = 0,
			GroupTransparency = 1,
		}, holder)
		round(toast, 9)
		create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.72,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, toast)

		local bar = create("Frame", {
			Size = UDim2.new(0, 3, 1, -14),
			Position = UDim2.fromOffset(7, 7),
			BackgroundColor3 = tint,
			BorderSizePixel = 0,
		}, toast)
		round(bar, 2)

		create("TextLabel", {
			Size = UDim2.new(1, -92, 0, 16),
			Position = UDim2.fromOffset(19, 5),
			BackgroundTransparency = 1,
			Text = tostring(title),
			TextColor3 = THEME.text,
			TextSize = 13,
			Font = FONT_MEDIUM,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, toast)

		if detail then
			create("TextLabel", {
				Size = UDim2.new(1, -92, 0, 14),
				Position = UDim2.fromOffset(19, 21),
				BackgroundTransparency = 1,
				Text = tostring(detail),
				TextColor3 = THEME.textDim,
				TextSize = 11,
				Font = FONT,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, toast)
		end

		local badge = create("TextLabel", {
			Size = UDim2.fromOffset(52, 16),
			Position = UDim2.new(1, -60, 0, 5),
			BackgroundTransparency = 1,
			Text = positive and "ON" or (negative and "OFF" or "INFO"),
			TextColor3 = tint,
			TextSize = 11,
			Font = FONT_BOLD,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, toast)

		local scale = create("UIScale", { Scale = 0.94 }, toast)
		retween(scale, ANIM.pop, { Scale = 1 })
		tween(toast, ANIM.fast, { GroupTransparency = 0 })

		if detail then
			badge.Position = UDim2.new(1, -60, 0, 7)
		end

		task.delay(detail and 3.4 or 2.4, function()
			if not toast.Parent then
				return
			end
			tween(toast, ANIM.medium, { GroupTransparency = 1 }).Completed:Connect(function()
				toast:Destroy()
			end)
		end)

		return true
	end

	---Older name kept so game modules written for FatCat Hub do not break.
	Hub.notify = function(title, enabled)
		Hub:Notify(title, enabled and "on" or "off")
	end

	-- ======================================================================
	-- Components
	-- ======================================================================

	local Components = {}
	Hub.Components = Components

	---Ripple that expands from the cursor inside a clipped card.
	local function addRipple(card)
		card.InputBegan:Connect(function(input)
			if not isPress(input) then
				return
			end
			local offset = Vector2.new(input.Position.X, input.Position.Y) - card.AbsolutePosition
			local ripple = create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(offset.X, offset.Y),
				Size = UDim2.fromOffset(0, 0),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BackgroundTransparency = 0.86,
				BorderSizePixel = 0,
				ZIndex = 0,
			}, card)
			round(ripple, 999)
			local diameter = math.max(card.AbsoluteSize.X, card.AbsoluteSize.Y) * 2
			tween(ripple, ANIM.medium, {
				Size = UDim2.fromOffset(diameter, diameter),
				BackgroundTransparency = 1,
			}).Completed:Connect(function()
				ripple:Destroy()
			end)
		end)
	end

	---A rounded row card. Hover lifts the card instead of the old 0.35 <-> 0.65
	---transparency jump, and the stroke fades with it so the edge never flickers.
	---Register a new card with the open collapsible group, if any.
	local function adoptIntoGroup(card)
		local group = Hub._currentGroup
		if not group then
			return
		end
		table.insert(group.cards, card)
		card:SetAttribute("GroupHidden", group.collapsed)
		card.Visible = not group.collapsed
	end

	local function createCard(parent, text, height, interactive)
		local card = create(interactive and "TextButton" or "Frame", {
			Name = text,
			Size = UDim2.new(1, 0, 0, height),
			BackgroundColor3 = THEME.card,
			BackgroundTransparency = 0.06,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			ClipsDescendants = true,
			LayoutOrder = parent and parent:GetAttribute("CardCount") or nil,
		}, parent)

		if parent then
			parent:SetAttribute("CardCount", (parent:GetAttribute("CardCount") or 0) + 1)
		end

		round(card, CONFIG.cardRadius)
		local stroke = create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.66,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, card)

		card:SetAttribute("SearchText", text)
		addRipple(card)
		adoptIntoGroup(card)

		card.MouseEnter:Connect(function()
			retween(card, ANIM.fast, { BackgroundTransparency = 0, BackgroundColor3 = THEME.cardHover })
			retween(stroke, ANIM.fast, { Transparency = 0.4 })
		end)

		card.MouseLeave:Connect(function()
			retween(card, ANIM.fast, { BackgroundTransparency = 0.06, BackgroundColor3 = THEME.card })
			retween(stroke, ANIM.fast, { Transparency = 0.66 })
		end)

		return card, stroke
	end

	---A section header: uppercase caption, accent tick and a hairline divider.
	function Components.SectionHeader(parent, text)
		local holder = create("Frame", {
			Name = tostring(text) .. " Header",
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			LayoutOrder = #parent:GetChildren() + 1,
		}, parent)

		local marker = create("Frame", {
			Size = UDim2.fromOffset(3, 11),
			Position = UDim2.new(0, 2, 0.5, -5),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, holder)
		round(marker, 2)
		liveGradient(marker, 90)

		create("TextLabel", {
			Size = UDim2.new(1, -16, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			BackgroundTransparency = 1,
			Text = string.upper(tostring(text)),
			TextColor3 = THEME.textOff,
			TextSize = TEXT_SIZE.section,
			Font = FONT_BOLD,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, holder)

		local line = create("Frame", {
			Size = UDim2.new(1, 0, 0, 1),
			Position = UDim2.new(0, 0, 1, -1),
			BackgroundColor3 = THEME.outline,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
		}, holder)
		create("UIGradient", {
			Transparency = NumberSequence.new(0.1, 1),
			Rotation = 0,
		}, line)

		return holder
	end

	---A bordered group box. Rows added to `Components.Section` land inside it.
	function Components.Section(parent, text)
		local box = create("Frame", {
			Name = tostring(text),
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = THEME.section,
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			LayoutOrder = #parent:GetChildren() + 1,
		}, parent)
		round(box, CONFIG.cardRadius + 2)
		create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.7,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, box)
		create("UIPadding", {
			PaddingTop = UDim.new(0, 6),
			PaddingBottom = UDim.new(0, 6),
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
		}, box)
		create("UIListLayout", {
			Padding = UDim.new(0, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, box)

		Components.SectionHeader(box, text)
		return box
	end

	---Toggle row: checkbox with a pop, sliding label, optional keybind chip.
	function Components.Toggle(parent, options)
		options = options or {}
		local text = options.Text or options.Name or "Toggle"
		local default = options.Default == true
		local flag = options.Flag or text
		local callback = options.Callback
		local description = options.Description

		local iconColumn = options.Icon and 44 or 32
		local card = createCard(parent, flag, description and 46 or 32, true)

		local box = create("Frame", {
			Size = UDim2.fromOffset(18, 18),
			Position = UDim2.new(0, 9, 0, description and 9 or 7),
			BackgroundColor3 = THEME.element,
			BorderSizePixel = 0,
		}, card)
		round(box, 5)
		local boxStroke = create("UIStroke", {
			Color = default and colorA or THEME.outline,
			Transparency = default and 0 or 0.4,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, box)

		local check = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = default and UDim2.fromOffset(10, 10) or UDim2.fromOffset(0, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, box)
		round(check, 3)
		liveGradient(check, 45)

		local label = create("TextLabel", {
			Size = UDim2.new(1, -(iconColumn + 12), 0, description and 18 or 32),
			Position = UDim2.fromOffset(iconColumn, description and 7 or 0),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = default and THEME.text or THEME.textOff,
			TextSize = TEXT_SIZE.label,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, card)

		if description then
			create("TextLabel", {
				Size = UDim2.new(1, -(iconColumn + 12), 0, 14),
				Position = UDim2.fromOffset(iconColumn, 25),
				BackgroundTransparency = 1,
				Text = description,
				TextColor3 = THEME.textDim,
				TextSize = 11,
				Font = FONT,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, card)
		end

		-- Glow rail on the left edge, only while enabled.
		local rail = create("Frame", {
			Size = UDim2.new(0, 3, 1, -12),
			Position = UDim2.fromOffset(0, 6),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = default and 0 or 1,
			BorderSizePixel = 0,
		}, card)
		round(rail, 2)
		liveGradient(rail, 90)

		local state = default
		local entry = { Flag = flag, Kind = "toggle", Card = card, Set = nil }

		local function set(value, silent)
			state = value == true
			Hub.Values[flag] = state

			retween(check, ANIM.pop, { Size = state and UDim2.fromOffset(10, 10) or UDim2.fromOffset(0, 0) })
			retween(boxStroke, ANIM.fast, {
				Color = state and colorA or THEME.outline,
				Transparency = state and 0 or 0.4,
			})
			retween(label, ANIM.fast, { TextColor3 = state and THEME.text or THEME.textOff })
			retween(rail, ANIM.fast, { BackgroundTransparency = state and 0 or 1 })

			if not silent and callback then
				local ok, err = pcall(callback, state)
				if not ok then
					Hub:Notify(tostring(flag), "error", tostring(err))
				end
			end
		end

		entry.Set = set
		Hub.Setters[flag] = set
		Hub.Defaults[flag] = default
		Hub.Values[flag] = default
		table.insert(Hub._entries, entry)

		card.Activated:Connect(function()
			set(not state)
			Hub:Notify(text, state and "on" or "off")
		end)

		table.insert(Hub.Searchables, card)
		return card
	end

	---Slider row: filled gradient track, draggable knob, click-anywhere track.
	function Components.Slider(parent, options)
		options = options or {}
		local text = options.Text or options.Name or "Slider"
		local minValue = options.Min or 0
		local maxValue = options.Max or 100
		local decimals = options.Decimals or 0
		local default = math.clamp(options.Default or minValue, minValue, maxValue)
		local flag = options.Flag or text
		local callback = options.Callback
		local suffix = options.Suffix or ""

		assert(maxValue > minValue, "Slider max must be greater than min for '" .. tostring(text) .. "'")

		local card = createCard(parent, flag, 46, false)
		local span = maxValue - minValue
		local startAlpha = (default - minValue) / span

		create("TextLabel", {
			Size = UDim2.new(1, -104, 0, 20),
			Position = UDim2.fromOffset(11, 5),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = THEME.text,
			TextSize = TEXT_SIZE.label,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, card)

		local valueLabel = create("TextLabel", {
			Size = UDim2.fromOffset(86, 20),
			Position = UDim2.new(1, -97, 0, 5),
			BackgroundTransparency = 1,
			Text = formatNumber(default, decimals) .. suffix,
			TextColor3 = THEME.textOff,
			TextSize = TEXT_SIZE.value,
			Font = FONT_MEDIUM,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, card)

		local track = create("Frame", {
			Size = UDim2.new(1, -22, 0, 5),
			Position = UDim2.fromOffset(11, 32),
			BackgroundColor3 = THEME.element,
			BorderSizePixel = 0,
		}, card)
		round(track, 999)

		local fill = create("Frame", {
			Size = UDim2.fromScale(startAlpha, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, track)
		round(fill, 999)
		liveGradient(fill, 0)

		local knob = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(13, 13),
			Position = UDim2.new(startAlpha, 0, 0.5, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ZIndex = 2,
		}, track)
		round(knob, 999)
		create("UIStroke", {
			Color = THEME.backgroundBottom,
			Thickness = 2,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, knob)
		local knobScale = create("UIScale", {}, knob)

		local hitbox = create("TextButton", {
			Size = UDim2.new(1, -14, 0, 24),
			Position = UDim2.fromOffset(7, 21),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
		}, card)

		local entry = { Flag = flag, Kind = "slider", Card = card, Set = nil }
		local dragging = false

		local function set(value, silent)
			local factor = 10 ^ decimals
			value = math.clamp(tonumber(value) or minValue, minValue, maxValue)
			value = math.floor(value * factor + 0.5) / factor
			local alpha = (value - minValue) / span

			retween(fill, ANIM.slide, { Size = UDim2.fromScale(alpha, 1) })
			retween(knob, ANIM.slide, { Position = UDim2.new(alpha, 0, 0.5, 0) })

			valueLabel.Text = formatNumber(value, decimals) .. suffix
			Hub.Values[flag] = value

			if not silent and callback then
				task.spawn(pcall, callback, value)
			end
		end

		entry.Set = set
		Hub.Setters[flag] = set
		Hub.Defaults[flag] = default
		Hub.Values[flag] = default
		table.insert(Hub._entries, entry)

		local function updateFromX(positionX)
			local width = track.AbsoluteSize.X
			if width <= 0 then
				return
			end
			local alpha = math.clamp((positionX - track.AbsolutePosition.X) / width, 0, 1)
			set(minValue + span * alpha)
		end

		hitbox.InputBegan:Connect(function(input)
			if not isPress(input) then
				return
			end
			dragging = true
			retween(knobScale, ANIM.pop, { Scale = 1.3 })
			retween(valueLabel, ANIM.fast, { TextColor3 = colorA })
			updateFromX(input.Position.X)
		end)

		connect(userInputService.InputChanged, function(input)
			if dragging and isMove(input) then
				updateFromX(input.Position.X)
			end
		end)

		connect(userInputService.InputEnded, function(input)
			if not dragging or not isPress(input) then
				return
			end
			dragging = false
			retween(knobScale, ANIM.pop, { Scale = 1 })
			retween(valueLabel, ANIM.fast, { TextColor3 = THEME.textOff })
		end)

		table.insert(Hub.Searchables, card)
		return card
	end

	---Cycle row: label plus a button that steps through the options.
	function Components.Cycle(parent, options)
		options = options or {}
		local text = options.Text or options.Name or "Option"
		local list = options.Options or { "Off", "On" }
		local flag = options.Flag or text
		local callback = options.Callback
		local default = options.Default or list[1]

		local card = createCard(parent, flag, 56, false)

		create("TextLabel", {
			Size = UDim2.new(1, -22, 0, 20),
			Position = UDim2.fromOffset(11, 5),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = THEME.text,
			TextSize = TEXT_SIZE.label,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, card)

		local button = create("TextButton", {
			Size = UDim2.new(1, -22, 0, 24),
			Position = UDim2.fromOffset(11, 28),
			BackgroundColor3 = THEME.element,
			BorderSizePixel = 0,
			Text = default,
			TextColor3 = THEME.textOff,
			TextSize = 12,
			Font = FONT,
			AutoButtonColor = false,
		}, card)
		round(button, 5)
		local buttonStroke = create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.55,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, button)

		local index = math.max(1, table.find(list, default) or 1)
		local entry = { Flag = flag, Kind = "cycle", Card = card, Set = nil }

		local function set(value, silent)
			local found = table.find(list, value)
			if not found then
				return
			end
			index = found
			Hub.Values[flag] = list[index]
			button.Text = tostring(list[index])

			if not silent and callback then
				task.spawn(pcall, callback, list[index])
			end
		end

		entry.Set = set
		Hub.Setters[flag] = set
		Hub.Defaults[flag] = default
		Hub.Values[flag] = default
		table.insert(Hub._entries, entry)

		button.MouseEnter:Connect(function()
			retween(buttonStroke, ANIM.fast, { Color = colorA, Transparency = 0 })
			retween(button, ANIM.fast, { BackgroundColor3 = THEME.elementHover })
		end)
		button.MouseLeave:Connect(function()
			retween(buttonStroke, ANIM.fast, { Color = THEME.outline, Transparency = 0.55 })
			retween(button, ANIM.fast, { BackgroundColor3 = THEME.element })
		end)

		button.Activated:Connect(function()
			index = index % #list + 1
			Hub.Values[flag] = list[index]
			button.Text = tostring(list[index])
			button.TextTransparency = 1
			retween(button, ANIM.fast, { TextTransparency = 0 })
			if callback then
				task.spawn(pcall, callback, list[index])
			end
		end)

		table.insert(Hub.Searchables, card)
		return card
	end

	---Dropdown: collapsed cycle-shaped button that expands a native scroll list.
	---Constrained to four rows so a long option list cannot push the window
	---layout, and the list closes on pick, on outside click or on tab switch.
	function Components.Dropdown(parent, options)
		options = options or {}
		local text = options.Text or options.Name or "Dropdown"
		local list = options.Options or {}
		local flag = options.Flag or text
		local callback = options.Callback
		local default = options.Default or list[1]

		local card = createCard(parent, flag, 56, false)
		local openHeight = 56 + math.min(#list, 4) * 22 + 8

		create("TextLabel", {
			Size = UDim2.new(1, -22, 0, 20),
			Position = UDim2.fromOffset(11, 5),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = THEME.text,
			TextSize = TEXT_SIZE.label,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, card)

		local button = create("TextButton", {
			Size = UDim2.new(1, -22, 0, 24),
			Position = UDim2.fromOffset(11, 28),
			BackgroundColor3 = THEME.element,
			BorderSizePixel = 0,
			Text = "  " .. tostring(default) .. "      v",
			TextColor3 = THEME.textOff,
			TextSize = 12,
			Font = FONT,
			AutoButtonColor = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			ClipsDescendants = true,
		}, card)
		round(button, 5)
		local arrow = create("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Size = UDim2.fromOffset(6, 6),
			Position = UDim2.new(1, -11, 0.5, 0),
			BackgroundColor3 = THEME.textDim,
			BorderSizePixel = 0,
			Rotation = 0,
		}, button)

		local scroll = create("ScrollingFrame", {
			Size = UDim2.new(1, -22, 0, 0),
			Position = UDim2.fromOffset(11, 56),
			BackgroundColor3 = THEME.element,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Visible = false,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 2,
			ScrollBarImageColor3 = THEME.outline,
			ZIndex = 3,
		}, card)
		round(scroll, 5)
		create("UIListLayout", { Padding = UDim.new(0, 1), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)
		create("UIPadding", {
			PaddingTop = UDim.new(0, 3),
			PaddingBottom = UDim.new(0, 3),
		}, scroll)

		local optionButtons = {}
		local expanded = false

		local function collapse()
			expanded = false
			scroll.Visible = false
			tween(card, ANIM.fast, { Size = UDim2.new(1, 0, 0, 56) })
			retween(arrow, ANIM.fast, { Rotation = 0 })
		end

		for index, option in list do
			local row = create("TextButton", {
				Size = UDim2.new(1, 0, 0, 21),
				BackgroundColor3 = THEME.element,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Text = "  " .. tostring(option),
				TextColor3 = THEME.textOff,
				TextSize = 12,
				Font = FONT,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutoButtonColor = false,
				LayoutOrder = index,
				ZIndex = 4,
			}, scroll)
			round(row, 4)

			row.MouseEnter:Connect(function()
				retween(row, ANIM.fast, { BackgroundTransparency = 0, BackgroundColor3 = THEME.elementHover })
				retween(row, ANIM.fast, { TextColor3 = THEME.text })
			end)
			row.MouseLeave:Connect(function()
				retween(row, ANIM.fast, { BackgroundTransparency = 1, BackgroundColor3 = THEME.element })
				retween(row, ANIM.fast, { TextColor3 = THEME.textOff })
			end)

			optionButtons[index] = row

			row.Activated:Connect(function()
				Hub.Values[flag] = option
				button.Text = "  " .. tostring(option)
				collapse()
				if callback then
					task.spawn(pcall, callback, option)
				end
			end)
		end

		local entry = { Flag = flag, Kind = "dropdown", Card = card, Set = nil }

		local function set(value, silent)
			if not table.find(list, value) then
				return
			end
			Hub.Values[flag] = value
			button.Text = "  " .. tostring(value)
			collapse()
			if not silent and callback then
				task.spawn(pcall, callback, value)
			end
		end

		entry.Set = set
		Hub.Setters[flag] = set
		Hub.Defaults[flag] = default
		Hub.Values[flag] = default
		table.insert(Hub._entries, entry)

		button.Activated:Connect(function()
			expanded = not expanded
			scroll.Visible = expanded
			tween(card, ANIM.fast, { Size = UDim2.new(1, 0, 0, expanded and openHeight or 56) })
			retween(arrow, ANIM.fast, { Rotation = expanded and 180 or 0 })
		end)

		table.insert(Hub.Searchables, card)
		return card
	end

	---Text input row. Enter commits, Escape reverts to the last committed value.
	function Components.Input(parent, options)
		options = options or {}
		local text = options.Text or options.Name or "Input"
		local flag = options.Flag or text
		local placeholder = options.Placeholder or "Type here"
		local default = options.Default or ""
		local callback = options.Callback

		local card = createCard(parent, flag, 52, false)

		create("TextLabel", {
			Size = UDim2.new(1, -22, 0, 18),
			Position = UDim2.fromOffset(11, 4),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = THEME.text,
			TextSize = TEXT_SIZE.label,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, card)

		local field = create("TextBox", {
			Size = UDim2.new(1, -22, 0, 24),
			Position = UDim2.fromOffset(11, 24),
			BackgroundColor3 = THEME.element,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			PlaceholderText = placeholder,
			PlaceholderColor3 = THEME.textDim,
			Text = tostring(default),
			TextColor3 = THEME.text,
			TextSize = 12,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			ClearTextOnFocus = false,
		}, card)
		round(field, 5)
		create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, field)
		local stroke = create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.55,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, field)

		local committed = tostring(default)
		local entry = { Flag = flag, Kind = "input", Card = card, Set = nil }

		local function set(value, silent)
			committed = tostring(value or "")
			field.Text = committed
			Hub.Values[flag] = committed
			if not silent and callback then
				task.spawn(pcall, callback, committed)
			end
		end

		entry.Set = set
		Hub.Setters[flag] = set
		Hub.Defaults[flag] = default
		Hub.Values[flag] = default
		table.insert(Hub._entries, entry)

		field.Focused:Connect(function()
			retween(stroke, ANIM.fast, { Color = colorA, Transparency = 0 })
		end)
		field.FocusLost:Connect(function(enter)
			retween(stroke, ANIM.fast, { Color = THEME.outline, Transparency = 0.55 })
			if enter then
				set(field.Text)
			else
				field.Text = committed
			end
		end)

		table.insert(Hub.Searchables, card)
		return card
	end

	---Keybind row. Click the chip, press a key, Escape clears it.
	---`options.OnKey` gets the KeyCode on every press, so a module can own the
	---behaviour instead of the hub guessing what the key should do.
	function Components.Keybind(parent, options)
		options = options or {}
		local text = options.Text or options.Name or "Keybind"
		local flag = options.Flag or text
		local default = options.Default or ""
		local onKey = options.OnKey

		local card = createCard(parent, flag, 32, false)

		create("TextLabel", {
			Size = UDim2.new(1, -100, 1, 0),
			Position = UDim2.fromOffset(11, 0),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = THEME.text,
			TextSize = TEXT_SIZE.label,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, card)

		local chip = create("TextButton", {
			Size = UDim2.fromOffset(84, 22),
			Position = UDim2.new(1, -95, 0.5, -11),
			BackgroundColor3 = THEME.chip,
			BorderSizePixel = 0,
			Text = default ~= "" and tostring(default) or "None",
			TextColor3 = THEME.text,
			TextSize = 12,
			Font = FONT_MEDIUM,
			AutoButtonColor = false,
		}, card)
		round(chip, 5)
		local chipStroke = create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.35,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, chip)

		local listening = false
		local current = nil

		local function applyName(name, silent)
			current = keyCodeFromName(name)
			chip.Text = current and current.Name or "None"
			Hub.Values[flag] = current and name or ""
			Hub.Keybinds[flag] = current
			if not silent then
				Hub:_refreshHints()
			end
		end

		applyName(default, true)

		local entry = { Flag = flag, Kind = "keybind", Card = card, Set = applyName }
		Hub.Setters[flag] = applyName
		Hub.Defaults[flag] = default
		Hub.Values[flag] = default
		table.insert(Hub._entries, entry)

		chip.MouseEnter:Connect(function()
			retween(chipStroke, ANIM.fast, { Color = colorA, Transparency = 0 })
		end)
		chip.MouseLeave:Connect(function()
			if not listening then
				retween(chipStroke, ANIM.fast, { Color = THEME.outline, Transparency = 0.35 })
			end
		end)

		chip.Activated:Connect(function()
			if Hub._cancelListening then
				Hub._cancelListening()
			end
			listening = true
			chip.Text = "Press a key"
			retween(chipStroke, ANIM.fast, { Color = colorA, Transparency = 0 })

			Hub._cancelListening = function()
				listening = false
				Hub._cancelListening = nil
				retween(chipStroke, ANIM.fast, { Color = THEME.outline, Transparency = 0.35 })
				chip.Text = current and tostring(current.Name) or "None"
			end

			Hub._listening = function(keyCode)
				listening = false
				Hub._cancelListening = nil
				retween(chipStroke, ANIM.fast, { Color = THEME.outline, Transparency = 0.35 })
				applyName(keyCode == Enum.KeyCode.Escape and "" or keyCode.Name)
			end
		end)

		-- The hub routes a press here only when the chip owns it.
		entry.HandleKey = function(keyCode)
			if listening then
				Hub._listening(keyCode)
				return true
			end
			if current and keyCode == current and onKey then
				task.spawn(pcall, onKey, keyCode)
				return true
			end
			return false
		end

		table.insert(Hub.Searchables, card)
		return card
	end

	---Action button row.
	function Components.Button(parent, options)
		options = options or {}
		local text = options.Text or options.Name or "Button"
		local callback = options.Callback
		local danger = options.Danger == true

		local card = createCard(parent, text, 36, false)
		local button = create("TextButton", {
			Size = UDim2.new(1, -16, 0, 26),
			Position = UDim2.fromOffset(8, 5),
			BackgroundColor3 = THEME.element,
			BorderSizePixel = 0,
			Text = text,
			TextColor3 = danger and THEME.negative or THEME.textOff,
			TextSize = 12,
			Font = FONT_MEDIUM,
			AutoButtonColor = false,
		}, card)
		round(button, 5)
		local stroke = create("UIStroke", {
			Color = danger and THEME.negative or THEME.outline,
			Transparency = 0.55,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, button)

		button.MouseEnter:Connect(function()
			retween(stroke, ANIM.fast, { Color = danger and THEME.negative or colorA, Transparency = 0 })
			retween(button, ANIM.fast, { BackgroundColor3 = THEME.elementHover })
		end)
		button.MouseLeave:Connect(function()
			retween(stroke, ANIM.fast, { Color = danger and THEME.negative or THEME.outline, Transparency = 0.55 })
			retween(button, ANIM.fast, { BackgroundColor3 = THEME.element })
		end)
		button.MouseButton1Down:Connect(function()
			retween(button, ANIM.fast, { BackgroundColor3 = shade(THEME.elementHover, 0.12) })
		end)
		button.MouseButton1Up:Connect(function()
			retween(button, ANIM.fast, { BackgroundColor3 = THEME.elementHover })
		end)

		button.Activated:Connect(function()
			if callback then
				local ok, err = pcall(callback)
				if not ok then
					Hub:Notify(text, "error", tostring(err))
				end
			end
		end)

		table.insert(Hub.Searchables, card)
		return card
	end

	---Collapsible group: a header that shows or hides the rows added after it.
	function Components.Group(parent, options)
		options = options or {}
		local text = options.Text or "Options"
		local collapsed = options.Collapsed ~= false

		-- The header belongs to the parent, not to the group it opens: clear the
		-- open group first or the header adopts itself and hides on collapse.
		local parentGroup = Hub._currentGroup
		Hub._currentGroup = nil
		local group = { cards = {}, collapsed = collapsed }
		local card = createCard(parent, text, 32, false)
		Hub._currentGroup = group
		group.parent = parentGroup
		local button = create("TextButton", {
			Size = UDim2.new(1, -16, 0, 24),
			Position = UDim2.fromOffset(8, 4),
			BackgroundColor3 = THEME.element,
			BorderSizePixel = 0,
			Text = (collapsed and "+   " or "-   ") .. text,
			TextColor3 = THEME.textOff,
			TextSize = 12,
			Font = FONT_MEDIUM,
			AutoButtonColor = false,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, card)
		round(button, 5)
		create("UIPadding", { PaddingLeft = UDim.new(0, 8) }, button)
		local stroke = create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.55,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, button)

		button.MouseEnter:Connect(function()
			retween(stroke, ANIM.fast, { Color = colorA, Transparency = 0 })
		end)
		button.MouseLeave:Connect(function()
			retween(stroke, ANIM.fast, { Color = THEME.outline, Transparency = 0.55 })
		end)

		button.Activated:Connect(function()
			group.collapsed = not group.collapsed
			button.Text = (group.collapsed and "+   " or "-   ") .. text
			for _, child in group.cards do
				child.Visible = not group.collapsed
			end
		end)

		Hub._currentGroup = group
		return group
	end

	---Close the group opened by Components.Group.
	function Components.EndGroup()
		Hub._currentGroup = nil
	end

	---Colour swatch row: cycles the palette and exposes the raw Color3.
	function Components.ColorPicker(parent, options)
		options = options or {}
		local text = options.Text or "Color"
		local flag = options.Flag or text
		local palette = options.Palette or {
			Color3.fromRGB(255, 255, 255),
			Color3.fromRGB(255, 92, 96),
			Color3.fromRGB(124, 222, 146),
			Color3.fromRGB(96, 156, 255),
			Color3.fromRGB(255, 212, 90),
			Color3.fromRGB(196, 122, 255),
		}
		local callback = options.Callback
		local index = math.max(1, table.find(palette, options.Default) or 1)

		local card = createCard(parent, flag, 40, true)

		create("TextLabel", {
			Size = UDim2.new(1, -70, 1, 0),
			Position = UDim2.fromOffset(11, 0),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = THEME.text,
			TextSize = TEXT_SIZE.label,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, card)

		local swatch = create("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Size = UDim2.fromOffset(38, 18),
			Position = UDim2.new(1, -11, 0.5, 0),
			BackgroundColor3 = palette[index],
			BorderSizePixel = 0,
		}, card)
		round(swatch, 5)
		create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, swatch)

		local entry = { Flag = flag, Kind = "color", Card = card, Set = nil }

		local function set(value, silent)
			if typeof(value) == "Color3" then
				table.insert(palette, 1, value)
				index = 1
			else
				local found = table.find(palette, value)
				if not found then
					return
				end
				index = found
			end
			Hub.Values[flag] = palette[index]
			swatch.BackgroundColor3 = palette[index]
			if not silent and callback then
				task.spawn(pcall, callback, palette[index])
			end
		end

		entry.Set = set
		Hub.Setters[flag] = set
		Hub.Defaults[flag] = palette[index]
		Hub.Values[flag] = palette[index]
		table.insert(Hub._entries, entry)

		card.Activated:Connect(function()
			index = index % #palette + 1
			Hub.Values[flag] = palette[index]
			swatch.BackgroundColor3 = palette[index]
			if callback then
				task.spawn(pcall, callback, palette[index])
			end
		end)

		table.insert(Hub.Searchables, card)
		return card
	end

	---Dimmed descriptive paragraph.
	function Components.Label(parent, text)
		local card = createCard(parent, tostring(text), 34, false)
		card.BackgroundTransparency = 1

		create("TextLabel", {
			Size = UDim2.new(1, -18, 1, -8),
			Position = UDim2.fromOffset(9, 4),
			BackgroundTransparency = 1,
			Text = tostring(text),
			TextColor3 = THEME.textDim,
			TextSize = 12,
			Font = FONT,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}, card)

		return card
	end

	---A status row: dot + text, no card, no interaction. Used for the
	---executor/library readout where a card would look like a button.
	function Components.Status(parent, text, state)
		local colors = {
			on = THEME.positive,
			off = THEME.negative,
			warn = THEME.accentAlt,
			info = colorA,
		}
		local dotColor = colors[state or "info"] or colorA

		local row = create("Frame", {
			Name = tostring(text),
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			LayoutOrder = parent and parent:GetAttribute("CardCount") or nil,
		}, parent)
		if parent then
			parent:SetAttribute("CardCount", (parent:GetAttribute("CardCount") or 0) + 1)
		end
		adoptIntoGroup(row)
		row:SetAttribute("SearchText", tostring(text))

		local dot = create("Frame", {
			Size = UDim2.fromOffset(6, 6),
			Position = UDim2.fromOffset(4, 8),
			BackgroundColor3 = dotColor,
			BorderSizePixel = 0,
		}, row)
		round(dot, 999)

		create("TextLabel", {
			Size = UDim2.new(1, -20, 1, 0),
			Position = UDim2.fromOffset(16, 0),
			BackgroundTransparency = 1,
			Text = tostring(text),
			TextColor3 = THEME.textOff,
			TextSize = TEXT_SIZE.label,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, row)

		table.insert(Hub.Searchables, row)
		return row
	end

	---Scrolling code block. `lines` is a list of strings; `highlight` is an
	---optional function(line, index) -> Color3 to tint a line (the script
	---viewer uses it for matches).
	function Components.CodeView(parent, options)
		options = options or {}
		local lines = options.Lines or {}
		local height = options.Height or 220

		local holder = create("Frame", {
			Name = options.Text or "Code",
			Size = UDim2.new(1, 0, 0, height),
			BackgroundColor3 = THEME.element,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			LayoutOrder = parent and parent:GetAttribute("CardCount") or nil,
		}, parent)
		if parent then
			parent:SetAttribute("CardCount", (parent:GetAttribute("CardCount") or 0) + 1)
		end
		round(holder, CONFIG.cardRadius)
		create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.7,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, holder)

		local scroll = create("ScrollingFrame", {
			Size = UDim2.new(1, -8, 1, -8),
			Position = UDim2.fromOffset(4, 4),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = THEME.outline,
			ScrollBarImageTransparency = 0.4,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
		}, holder)

		create("UIListLayout", {
			Padding = UDim.new(0, 0),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, scroll)
		create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingTop = UDim.new(0, 6) }, scroll)

		local renderLine = function(index, text)
			local color = THEME.textOff
			if options.Highlight then
				local ok, tinted = pcall(options.Highlight, text, index)
				if ok and typeof(tinted) == "Color3" then
					color = tinted
				end
			end
			local row = create("TextLabel", {
				Size = UDim2.new(1, -8, 0, TEXT_SIZE.code + 4),
				BackgroundTransparency = 1,
				Text = ("%3d  %s"):format(index, text),
				TextColor3 = color,
				TextSize = TEXT_SIZE.code,
				Font = FONT_MONO,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, scroll)
			return row
		end

		local rendered = 0
		local function append(chunk)
			for _, line in chunk do
				rendered += 1
				renderLine(rendered, line)
				if options.MaxLines and rendered >= options.MaxLines then
					return
				end
			end
		end

		append(lines)

		---Replace the whole body. Cheap enough for a few thousand lines and
		---it keeps the canvas in step with the content.
		local function setLines(nextLines, nextHighlight)
			for _, child in scroll:GetChildren() do
				if child:IsA("TextLabel") then
					child:Destroy()
				end
			end
			lines = nextLines or {}
			options.Highlight = nextHighlight or options.Highlight
			rendered = 0
			append(lines)
			holder:SetAttribute("LineCount", rendered)
		end

		---Append without rebuilding, for streaming logs.
		local function push(line)
			rendered += 1
			renderLine(rendered, line)
			holder:SetAttribute("LineCount", rendered)
		end

		holder:SetAttribute("LineCount", rendered)
		holder.setLines = setLines
		holder.push = push
		holder.scroll = scroll
		holder.SetLines = setLines
		holder.Push = push
		return holder
	end

	---Thin divider.
	function Components.Divider(parent)
		local holder = create("Frame", {
			Size = UDim2.new(1, 0, 0, 8),
			BackgroundTransparency = 1,
			LayoutOrder = #parent:GetChildren() + 1,
		}, parent)
		local line = create("Frame", {
			Size = UDim2.new(1, -12, 0, 1),
			Position = UDim2.fromOffset(6, 3),
			BackgroundColor3 = THEME.outline,
			BackgroundTransparency = 0.6,
			BorderSizePixel = 0,
		}, holder)
		-- Fade the divider in and out at its ends: keypoints, not three numbers.
		create("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0.2),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}, line)
		return holder
	end

	-- ======================================================================
	-- Section surface
	-- ======================================================================
	-- Components.Section returns the box frame; this wraps it so callers write
	-- box:Toggle{...} instead of Components.Toggle(box, {...}). Every method is
	-- a thin forwarder: no state lives here, the box frame is still the parent
	-- and reaching `box.frame` gives the raw GUI object.
	local Section = {}
	Section.__index = Section

	local function sectionSurface(box, page)
		return setmetatable({ frame = box, page = page, columns = page and page.columns }, Section)
	end

	function Section:Toggle(options)
		return Components.Toggle(self.frame, options)
	end

	function Section:Slider(options)
		return Components.Slider(self.frame, options)
	end

	function Section:Cycle(options)
		return Components.Cycle(self.frame, options)
	end

	function Section:Dropdown(options)
		return Components.Dropdown(self.frame, options)
	end

	function Section:Input(options)
		return Components.Input(self.frame, options)
	end

	function Section:Keybind(options)
		return Components.Keybind(self.frame, options)
	end

	function Section:Button(options)
		return Components.Button(self.frame, options)
	end

	function Section:Color(options)
		return Components.ColorPicker(self.frame, options)
	end

	---Alias: the row is a colour picker, `Color` reads better on a chain.
	Section.ColorPicker = Section.Color

	function Section:Status(text, state)
		return Components.Status(self.frame, text, state)
	end

	function Section:Code(options)
		return Components.CodeView(self.frame, options)
	end

	function Section:Label(text)
		return Components.Label(self.frame, text)
	end

	function Section:Divider()
		return Components.Divider(self.frame)
	end

	---Nested group box inside this section.
	function Section:Section(text)
		return sectionSurface(Components.Section(self.frame, text), self.page)
	end

	---Collapsible group; the following rows join it until EndGroup().
	function Section:Group(options)
		return Components.Group(self.frame, options)
	end

	function Section:EndGroup()
		Components.EndGroup()
	end

	-- ======================================================================
	-- Page (tab body)
	-- ======================================================================
	local Page = {}
	Page.__index = Page

	---One scrolling column. Two columns by default so rows never stretch.
	function Page:Column(index, count)
		local total = count or 2
		local width = 1 / total
		-- One 6 px gutter between columns, 4 px reserved for the scrollbar, so
		-- both columns end up exactly the same width.
		local gutter = (index < total) and 3 or 0
		local column = create("ScrollingFrame", {
			Size = UDim2.new(width, -6 - gutter, 1, 0),
			Position = UDim2.new((index - 1) * width, (index - 1) * 6 + gutter, 0, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 2,
			ScrollBarImageColor3 = THEME.outline,
			ScrollBarImageTransparency = 0.4,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
		}, self.frame)
		create("UIListLayout", {
			Padding = UDim.new(0, 5),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, column)
		create("UIPadding", {
			PaddingRight = UDim.new(0, 4),
			PaddingBottom = UDim.new(0, 6),
		}, column)
		return column
	end

	---Section box in a column (default: first column). Returns a section
	---surface: box:Toggle{...}, box:Slider{...}, box:Group{...}.
	function Page:Section(text, columnIndex)
		local target = self.columns[columnIndex or 1]
		return sectionSurface(Components.Section(target, text), self)
	end

	---Single-column scroll area that spans the full body.
	function Page:FullColumn()
		self.columns[1] = self:Column(1, 1)
		return self.columns[1]
	end

	-- ======================================================================
	-- Window
	-- ======================================================================
	local Window = {}
	Window.__index = Window

	---Switch the visible tab.
	function Window:SelectTab(name)
		if not self.pages[name] then
			return
		end
		for pageName, page in self.pages do
			local selected = pageName == name
			if selected and not page.frame.Visible then
				page.frame.Visible = true
				page.frame.GroupTransparency = 1
				tween(page.frame, ANIM.open, { GroupTransparency = 0 })
			elseif not selected then
				page.frame.Visible = false
			end
			retween(self.tabButtons[pageName], ANIM.fast, {
				TextColor3 = selected and THEME.text or THEME.textDim,
			})
			retween(self.tabUnderline[pageName], ANIM.fast, {
				BackgroundTransparency = selected and 0 or 1,
			})
		end
		self.selected = name
		tween(self.indicator, ANIM.medium, {
			Position = UDim2.new((self.tabIndexes[name] - 1) / #self.tabNames, 6, 0, 3),
		})
	end

	function Window:Tab(name)
		return self.pages[name]
	end

	---Hub-level convenience: the loader and game modules call Hub:Toggle()
	---rather than reaching into Hub._window.
	function Hub:Toggle()
		if Hub._window then
			Hub._window:Toggle()
		end
	end

	function Hub:Minimize()
		if Hub._window then
			Hub._window:ToggleMinimize()
		end
	end

	function Hub:SelectTab(name)
		if Hub._window then
			Hub._window:SelectTab(name)
		end
	end

	---Add a tab after the window exists (used by game modules).
	function Window:AddTab(name)
		if self.pages[name] then
			return self.pages[name]
		end
		table.insert(self.tabNames, name)
		self:_buildTab(name, #self.tabNames)
		self:_layoutTabs()
		self:SelectTab(name)
		return self.pages[name]
	end

	function Window:_layoutTabs()
		local count = #self.tabNames
		for index, name in self.tabNames do
			local button = self.tabButtons[name]
			button.Size = UDim2.fromScale(1 / count, 1)
			button.Position = UDim2.fromScale((index - 1) / count, 0)
			self.tabIndexes[name] = index
		end
		self.indicator.Size = UDim2.new(1 / count, -12, 1, -6)
		local selected = self.selected or self.tabNames[1]
		self.indicator.Position = UDim2.new((self.tabIndexes[selected] - 1) / count, 6, 0, 3)
	end

	function Window:_buildTab(name, index)
		local count = #self.tabNames
		local button = create("TextButton", {
			Size = UDim2.fromScale(1 / count, 1),
			Position = UDim2.fromScale((index - 1) / count, 0),
			BackgroundTransparency = 1,
			Text = name,
			TextColor3 = THEME.textDim,
			TextSize = TEXT_SIZE.tab,
			Font = FONT_MEDIUM,
			AutoButtonColor = false,
		}, self.tabBar)

		local underline = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Size = UDim2.new(0.42, 0, 0, 2),
			Position = UDim2.fromScale(0.5, 1),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, button)
		round(underline, 999)
		liveGradient(underline, 0)

		local frame = create("CanvasGroup", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Visible = false,
		}, self.content)

		button.MouseEnter:Connect(function()
			if self.selected ~= name then
				retween(button, ANIM.fast, { TextColor3 = THEME.textOff })
			end
		end)
		button.MouseLeave:Connect(function()
			if self.selected ~= name then
				retween(button, ANIM.fast, { TextColor3 = THEME.textDim })
			end
		end)
		button.Activated:Connect(function()
			self:SelectTab(name)
		end)

		self.tabButtons[name] = button
		self.tabUnderline[name] = underline
		self.tabIndexes[name] = index

		local page = setmetatable({ name = name, frame = frame, columns = {} }, Page)
		page.columns[1] = page:Column(1, 2)
		page.columns[2] = page:Column(2, 2)
		self.pages[name] = page
		return page
	end

	---Minimise or restore the window body.
	function Window:ToggleMinimize()
		self.minimized = not self.minimized
		self.resizeHandle.Visible = not self.minimized
		self.body.Visible = not self.minimized
		tween(self.frame, ANIM.medium, {
			Size = UDim2.fromOffset(self.width, self.minimized and CONFIG.titleHeight or self.height),
		})
	end

	---Restore the default size and centre the window.
	function Window:ResetPosition()
		self.width, self.height = CONFIG.width, CONFIG.height
		self.minimized = false
		self.body.Visible = true
		self.resizeHandle.Visible = true
		tween(self.frame, ANIM.medium, {
			Size = UDim2.fromOffset(self.width, self.height),
			Position = UDim2.new(0.5, -self.width / 2, 0.5, -self.height / 2),
		})
	end

	function Window:Toggle()
		self.frame.Visible = not self.frame.Visible
		if self.frame.Visible then
			local scale = self.frame:FindFirstChildOfClass("UIScale")
			if scale then
				scale.Scale = 0.94
				retween(scale, ANIM.pop, { Scale = 1 })
			end
			-- Re-clamp every open: a resolution change while hidden can strand
			-- the window off screen.
			task.defer(clampToViewport, self.frame)
		end
	end

	-- ======================================================================
	-- Build the window
	-- ======================================================================

	---Rebuild the whole interface. Called once by the loader and again by
	---Hub:Rebuild() when the tab list changes.
	local function buildWindow()
		-- Prefer the hidden GUI container when the executor provides one: some
		-- games' anticheat only skims PlayerGui.
		local guiParent = localPlayer and localPlayer:FindFirstChild("PlayerGui") or nil
		if typeof(gethui) == "function" then
			local ok, hidden = pcall(gethui)
			if ok and hidden then
				guiParent = hidden
			end
		end

		local screen = create("ScreenGui", {
			Name = "FatCatHub",
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			DisplayOrder = UIELEMENT,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, guiParent)
		Hub._screen = screen

		-- Every global listener dies with the GUI.
		connect(screen.Destroying, function()
			for _, connection in Hub.Connections do
				pcall(function()
					connection:Disconnect()
				end)
			end
			table.clear(Hub.Connections)
			if _G.FatCatHub == Hub then
				_G.FatCatHub = nil
			end
		end)

		local window = setmetatable({
			pages = {},
			tabButtons = {},
			tabUnderline = {},
			tabIndexes = {},
			tabNames = table.clone(CONFIG.tabs),
			width = CONFIG.width,
			height = CONFIG.height,
			minimized = false,
			screen = screen,
		}, Window)
		Hub._window = window

		local frame = create("Frame", {
			Name = "Window",
			Size = UDim2.fromOffset(CONFIG.width, CONFIG.height),
			Position = UDim2.new(0.5, -CONFIG.width / 2, 0.5, -CONFIG.height / 2),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ClipsDescendants = true,
		}, screen)
		window.frame = frame
		round(frame, CONFIG.cornerRadius)

		create("UIGradient", {
			Color = ColorSequence.new(THEME.backgroundTop, THEME.backgroundBottom),
			Rotation = 90,
		}, frame)

		local windowStroke = create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.35,
			Thickness = 1.5,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, frame)
		liveGradient(windowStroke, 45)

		-- Soft drop shadow: three offset frames, cheap enough to keep on a
		-- 60 fps UI and it stops the window floating flat over bright maps.
		-- ipairs: a `for k, v in array` walk yields (index, value), not pairs.
		for _, layer in { { offset = 2, alpha = 0.86 }, { offset = 5, alpha = 0.92 }, { offset = 9, alpha = 0.96 } } do
			local offset = layer.offset
			local alpha = layer.alpha
			local shadow = create("Frame", {
				Size = UDim2.fromOffset(CONFIG.width, CONFIG.height),
				Position = UDim2.new(0.5, -CONFIG.width / 2 + offset, 0.5, -CONFIG.height / 2 + offset),
				BackgroundColor3 = Color3.new(0, 0, 0),
				BackgroundTransparency = alpha,
				BorderSizePixel = 0,
				ZIndex = -1,
			}, screen)
			round(shadow, CONFIG.cornerRadius)
			window.shadow = shadow
		end

		local windowScale = create("UIScale", { Scale = 0.94 }, frame)
		retween(windowScale, ANIM.pop, { Scale = 1 })

		-- Top sheen.
		local sheen = create("Frame", {
			Size = UDim2.new(1, 0, 0, 150),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, frame)
		create("UIGradient", {
			Transparency = NumberSequence.new(0.972, 1),
			Rotation = 90,
		}, sheen)

		-- ---------------------------------------------------------------- title
		local titleBar = create("Frame", {
			Size = UDim2.new(1, 0, 0, CONFIG.titleHeight),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, frame)
		create("UIGradient", {
			Transparency = NumberSequence.new(0.82, 0.94),
			Rotation = 90,
		}, titleBar)
		local titleLine = create("Frame", {
			Size = UDim2.new(1, 0, 0, 1),
			Position = UDim2.new(0, 0, 1, -1),
			BackgroundColor3 = THEME.outline,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
		}, titleBar)
		create("UIGradient", { Transparency = NumberSequence.new(0.2, 0.9), Rotation = 0 }, titleLine)

		-- Brand dot.
		local brand = create("Frame", {
			Size = UDim2.fromOffset(9, 9),
			Position = UDim2.fromOffset(14, CONFIG.titleHeight / 2 - 4.5),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
		}, titleBar)
		round(brand, 999)
		liveGradient(brand, 45)
		tweenService:Create(
			brand,
			TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.55 }
		):Play()

		local titleLabel = create("TextLabel", {
			Size = UDim2.new(1, -220, 1, 0),
			Position = UDim2.fromOffset(30, 0),
			BackgroundTransparency = 1,
			Text = CONFIG.title,
			TextColor3 = THEME.text,
			TextSize = TEXT_SIZE.title,
			Font = FONT_BOLD,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, titleBar)
		window.titleLabel = titleLabel

		local searchBox = create("TextBox", {
			Size = UDim2.fromOffset(124, 24),
			Position = UDim2.new(1, -202, 0.5, -12),
			BackgroundColor3 = THEME.element,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			PlaceholderText = "Search",
			PlaceholderColor3 = THEME.textDim,
			Text = "",
			TextColor3 = THEME.text,
			TextSize = 12,
			Font = FONT,
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, titleBar)
		round(searchBox, 6)
		create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, searchBox)
		local searchStroke = create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.55,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, searchBox)
		window.searchBox = searchBox

		searchBox.Focused:Connect(function()
			retween(searchStroke, ANIM.fast, { Color = colorA, Transparency = 0 })
		end)
		searchBox.FocusLost:Connect(function()
			retween(searchStroke, ANIM.fast, { Color = THEME.outline, Transparency = 0.55 })
		end)

		---Title bar button.
		local function titleButton(text, offset, hoverColor)
			local button = create("TextButton", {
				-- 28 wide with a 2px gap between the two, so the pair fills the
				-- right edge of the bar instead of floating in it.
				Size = UDim2.fromOffset(28, 24),
				Position = UDim2.new(1, offset, 0.5, -12),
				BackgroundColor3 = THEME.element,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				Text = text,
				TextColor3 = THEME.textOff,
				TextSize = 16,
				Font = FONT_BOLD,
				AutoButtonColor = false,
			}, titleBar)
			round(button, 6)

			button.MouseEnter:Connect(function()
				retween(button, ANIM.fast, { BackgroundColor3 = hoverColor, BackgroundTransparency = 0.05 })
				retween(button, ANIM.fast, { TextColor3 = THEME.text })
			end)
			button.MouseLeave:Connect(function()
				retween(button, ANIM.fast, { BackgroundColor3 = THEME.element, BackgroundTransparency = 0.35 })
				retween(button, ANIM.fast, { TextColor3 = THEME.textOff })
			end)
			return button
		end

		-- En dashes and a multiplication sign: a hyphen and the letter x look
		-- thin and off-centre next to each other at this size.
		local minimizeButton = titleButton("–", -62, THEME.accentAlt)
		local closeButton = titleButton("×", -32, THEME.negative)

		-- ------------------------------------------------------------ drag
		local dragStart, startPosition
		titleBar.InputBegan:Connect(function(input)
			if not isPress(input) then
				return
			end
			dragStart = input.Position
			startPosition = frame.Position
		end)
		connect(userInputService.InputChanged, function(input)
			if not dragStart or not isMove(input) then
				return
			end
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(
				startPosition.X.Scale,
				startPosition.X.Offset + delta.X,
				startPosition.Y.Scale,
				startPosition.Y.Offset + delta.Y
			)
			if window.shadow and window.shadow.Parent then
				window.shadow.Position = UDim2.new(
					0,
					frame.Position.X.Offset + 5,
					0,
					frame.Position.Y.Offset + 5
				)
			end
		end)
		connect(userInputService.InputEnded, function(input)
			if not isPress(input) or not dragStart then
				return
			end
			dragStart = nil
			clampToViewport(frame)
			if window.shadow and window.shadow.Parent then
				window.shadow.Position = UDim2.new(0, frame.Position.X.Offset + 5, 0, frame.Position.Y.Offset + 5)
			end
		end)

		minimizeButton.Activated:Connect(function()
			window:ToggleMinimize()
		end)
		closeButton.Activated:Connect(function()
			tween(windowScale, ANIM.fast, { Scale = 0 }).Completed:Connect(function()
				screen:Destroy()
			end)
		end)

		-- ------------------------------------------------------------- tabs
		local tabBar = create("Frame", {
			Size = UDim2.new(1, 0, 0, CONFIG.tabHeight),
			Position = UDim2.fromOffset(0, CONFIG.titleHeight),
			BackgroundTransparency = 1,
		}, frame)
		window.tabBar = tabBar

		local indicator = create("Frame", {
			Size = UDim2.new(1 / #window.tabNames, -12, 1, -8),
			Position = UDim2.new(0, 6, 0, 4),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.93,
			BorderSizePixel = 0,
		}, tabBar)
		round(indicator, 7)
		create("UIStroke", {
			Color = THEME.outline,
			Transparency = 0.85,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, indicator)
		window.indicator = indicator

		local body = create("CanvasGroup", {
			Name = "Body",
			Size = UDim2.new(1, 0, 1, -(CONFIG.titleHeight + CONFIG.tabHeight + CONFIG.footerHeight)),
			Position = UDim2.fromOffset(0, CONFIG.titleHeight + CONFIG.tabHeight),
			BackgroundTransparency = 1,
		}, frame)
		window.body = body

		local content = create("Frame", {
			Size = UDim2.new(1, -20, 1, -16),
			Position = UDim2.fromOffset(10, 6),
			BackgroundTransparency = 1,
		}, body)
		window.content = content

		-- ------------------------------------------------------------ resize
		local resizeHandle = create("TextButton", {
			AnchorPoint = Vector2.new(1, 1),
			Size = UDim2.fromOffset(20, 20),
			Position = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			ZIndex = 12,
		}, frame)
		window.resizeHandle = resizeHandle

		for index = 1, 3 do
			local grip = create("Frame", {
				AnchorPoint = Vector2.new(1, 1),
				Size = UDim2.fromOffset(index * 4, 1),
				Position = UDim2.new(1, -4, 1, -4 - (3 - index) * 4),
				BackgroundColor3 = THEME.textDim,
				BorderSizePixel = 0,
			}, resizeHandle)
			round(grip, 999)
		end

		local resizing = false
		local resizeStart, startWidth, startHeight

		local function paintGrips(color)
			for _, grip in resizeHandle:GetChildren() do
				if grip:IsA("Frame") then
					retween(grip, ANIM.fast, { BackgroundColor3 = color })
				end
			end
		end

		resizeHandle.MouseEnter:Connect(function()
			paintGrips(colorA)
		end)
		resizeHandle.MouseLeave:Connect(function()
			if not resizing then
				paintGrips(THEME.textDim)
			end
		end)
		resizeHandle.InputBegan:Connect(function(input)
			if not isPress(input) then
				return
			end
			resizing = true
			resizeStart = input.Position
			startWidth, startHeight = window.width, window.height
		end)
		connect(userInputService.InputChanged, function(input)
			if not resizing or not isMove(input) then
				return
			end
			local delta = input.Position - resizeStart
			window.width = math.clamp(startWidth + delta.X, CONFIG.minWidth, CONFIG.maxWidth)
			window.height = math.clamp(startHeight + delta.Y, CONFIG.minHeight, CONFIG.maxHeight)
			frame.Size = UDim2.fromOffset(window.width, window.height)
		end)
		connect(userInputService.InputEnded, function(input)
			if not resizing or not isPress(input) then
				return
			end
			resizing = false
			paintGrips(THEME.textDim)
		end)

		-- ------------------------------------------------------------- search
		---Hide rows that do not match, then collapse empty boxes. Restoring is
		---the same walk with an empty query, so a collapsed group stays
		---collapsed instead of every row popping back.
		local function applySearch(query)
			local lowered = string.lower(query or "")
			local matched = {}
			for _, card in Hub.Searchables do
				if card.Parent then
					local groupHidden = card:GetAttribute("GroupHidden")
					local haystack = string.lower(tostring(card:GetAttribute("SearchText") or card.Name))
					local hit = lowered == "" or string.find(haystack, lowered, 1, true) ~= nil
					-- A row inside a collapsed group only reappears when the
					-- group itself is open again.
					card.Visible = hit and not groupHidden
					matched[card] = true
				end
			end
			for _, page in window.pages do
				for _, column in page.columns do
					for _, child in column:GetChildren() do
						if child:IsA("Frame") and child:FindFirstChildOfClass("UIListLayout") then
							local any = lowered == ""
							if not any then
								for _, inner in child:GetChildren() do
									if matched[inner] and inner.Visible then
										any = true
										break
									end
								end
							end
							child.Visible = any
						end
					end
				end
			end
		end

		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			applySearch(searchBox.Text)
		end)
		window.applySearch = applySearch

		-- --------------------------------------------------------------- tabs
		for index, name in window.tabNames do
			window:_buildTab(name, index)
		end
		window:SelectTab(window.tabNames[1])

		-- ---------------------------------------------------------- keybind
		---Key hints row: lists every bound key, toggled with the hints key.
		local hints = create("Frame", {
			Name = "KeyHints",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 10, 1, -6),
			Size = UDim2.new(1, -34, 0, 14),
			BackgroundTransparency = 1,
			ZIndex = 5,
		}, frame)
		create("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			TextColor3 = THEME.textDim,
			TextSize = 11,
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, hints)
		window.hints = hints

		Hub:_refreshHints()

		local hintsVisible = true
		Hub.SetHintsVisible = function(_, visible)
			hintsVisible = visible
			hints.Visible = visible
		end
		Hub.GetHintsVisible = function()
			return hintsVisible
		end

		connect(userInputService.InputBegan, function(input, gameProcessed)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				return
			end

			-- Diagnostics first: whatever happens below, the last key the hub
			-- saw is visible from the console.
			Hub._lastKey = input.KeyCode
			Hub._lastKeyProcessed = gameProcessed == true
			Hub._inputHandler = (Hub._inputHandler or 0) + 1

			-- A keybind chip is waiting for the next key. This runs before the
			-- gameProcessed check on purpose: while typing a new key into a
			-- chip, the game is usually eating the keystroke.
			if Hub._listening then
				Hub._listening(input.KeyCode)
				return
			end

			if gameProcessed then
				-- Only for the keys we own: the user pressed the menu key and
				-- Roblox handed the event to the game (a chat box, a TextBox).
				local wanted = matchesKey(input.KeyCode, Hub.menuKey or CONFIG.menuKey)
					or (matchesKey(input.KeyCode, CONFIG.hintsKeys) and isAnyControlDown())
				if wanted and not Hub._processedWarned then
					Hub._processedWarned = true
					Hub:Notify(
						"Key taken by the game",
						"error",
						("Press %s with the chat closed"):format(input.KeyCode.Name)
					)
				end
				return
			end

			if matchesKey(input.KeyCode, CONFIG.hintsKeys) and isAnyControlDown() then
				Hub:SetHintsVisible(not Hub:GetHintsVisible())
				return
			end

			if matchesKey(input.KeyCode, Hub.menuKey or CONFIG.menuKey) then
				-- Go through Hub:Toggle() rather than the closed-over window: a
				-- rebuild replaces Hub._window, and the old frame would be dead.
				Hub:Toggle()
				return
			end

			-- Route the press to whichever keybind owns it.
			for _, entry in Hub._entries do
				if entry.HandleKey and entry.HandleKey(input.KeyCode) then
					return
				end
			end
		end)

		-- Keep the window inside the viewport when the game window resizes.
		if workspace.CurrentCamera then
			connect(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), function()
				if frame.Visible then
					clampToViewport(frame)
				end
			end)
		end

		return window
	end

	---Human list of bound keys for the hint row.
	function Hub:_refreshHints()
		local parts = {}
		for _, entry in Hub._entries do
			if entry.Kind == "keybind" then
				local keyName = Hub.Values[entry.Flag]
				if keyName and keyName ~= "" then
					table.insert(parts, keyName .. " - " .. tostring(entry.Flag))
				end
			end
		end
		local hints = Hub._window and Hub._window.hints
		local label = hints and hints:FindFirstChildOfClass("TextLabel")
		if not label then
			return
		end
		if #parts == 0 then
			local key = Hub.menuKey or CONFIG.menuKey
			local name = type(key) == "table" and (key[1] or "RightShift") or tostring(key)
			label.Text = string.format("%s to toggle  |  ctrl+%s for hints", name, CONFIG.hintsKeys[1])
		else
			label.Text = table.concat(parts, "   |   ")
		end
	end

	-- Called by Components.Keybind through Hub.Values changes.
	local function refreshHintsSoon()
		task.defer(function()
			if Hub._window then
				Hub:_refreshHints()
			end
		end)
	end

	-- ======================================================================
	-- Public API
	-- ======================================================================

	---Build (or rebuild) the interface. Returns the hub table.
	function Hub:Init(options)
		options = options or {}
		if options.Title then
			CONFIG.title = options.Title
		end
		if options.Version then
			CONFIG.version = options.Version
		end
		if options.Tabs then
			CONFIG.tabs = options.Tabs
		end
		if options.MenuKey then
			Hub.menuKey = options.MenuKey
		end

		if Hub._screen and Hub._screen.Parent then
			Hub._screen:Destroy()
		end
		table.clear(Hub.Connections)
		table.clear(Hub.Searchables)
		table.clear(Hub._entries)

		buildWindow()

		-- Builders run against the fresh window, in the order they were added,
		-- so a mounted module survives a rebuild.
		for _, builder in Hub._builders do
			local ok, builderError = pcall(builder, Hub, Hub._window)
			if not ok then
				warn("[FatCat Hub] a mounted builder failed: " .. tostring(builderError))
			end
		end

		if Hub._window then
			local first = Hub._window.tabNames[1]
			if first and not Hub._window.selected then
				Hub._window:SelectTab(first)
			end
		end
		return Hub
	end

	---Build the window only once, on demand.
	function Hub:EnsureBuilt()
		if not Hub._window then
			Hub:Init(Hub._initOptions)
		end
		return Hub
	end

	---Destroy the GUI and every listener.
	function Hub:Destroy()
		if Hub._screen then
			Hub._screen:Destroy()
		end
		table.clear(Hub.Connections)
		if _G.FatCatHub == Hub then
			_G.FatCatHub = nil
		end
	end

	---Public "unload" alias used by loaders and game modules.
	function Hub:Unload()
		Hub:Destroy()
	end

	---Save every flag to disk. Called by the Config tab and by Auto Save.
	function Hub:Save(notify)
		local ok, result = writeJson(CONFIG.saveFile, Hub.Values)
		if notify then
			if ok then
				Hub:Notify("Settings saved", "success")
			else
				Hub:Notify("Save failed", "error", tostring(result))
			end
		end
		return ok, result
	end

	---Load flags from disk and apply them through their setters.
	function Hub:Load(notify)
		local data = readJson(CONFIG.saveFile)
		if not data then
			if notify then
				Hub:Notify("No settings found", "info", CONFIG.saveFile)
			end
			return false
		end
		for flag, value in data do
			local setter = Hub.Setters[flag]
			if setter then
				pcall(setter, value)
			end
		end
		refreshHintsSoon()
		if notify then
			Hub:Notify("Settings loaded", "success")
		end
		return true
	end

	---Reset every flag to its default.
	function Hub:Reset(notify)
		for flag, value in Hub.Defaults do
			local setter = Hub.Setters[flag]
			if setter then
				pcall(setter, value)
			end
		end
		refreshHintsSoon()
		if notify then
			Hub:Notify("Settings reset", "info")
		end
	end

	---Copy every flag to the clipboard as JSON.
	function Hub:Copy()
		if not setclipboard then
			Hub:Notify("Clipboard unavailable", "error")
			return false
		end
		setclipboard(httpService:JSONEncode(Hub.Values))
		Hub:Notify("Settings copied", "success")
		return true
	end

	---Register a builder that runs against the window once it exists.
	---Building the GUI immediately would make the library useless as a base:
	---anything added afterwards would need its own Hub:Init() call, which
	---throws the current window away.
	---
	---   Hub:Mount(function(hub, window)
	---       local page = window:Tab("Main")
	---       page:Section("Options"):Toggle({ Text = "Feature", Flag = "feature" })
	---   end)
	function Hub:Mount(builder)
		if type(builder) ~= "function" then
			return Hub
		end
		table.insert(Hub._builders, builder)
		Hub:EnsureBuilt()
		if Hub._window then
			local ok, builderError = pcall(builder, Hub, Hub._window)
			if not ok then
				warn("[FatCat Hub] a mounted builder failed: " .. tostring(builderError))
			end
		end
		return Hub
	end

	---Forget every mounted builder and drop the window.
	function Hub:ClearBuilders()
		table.clear(Hub._builders)
		table.clear((Hub.Values))
		table.clear((Hub.Defaults))
		table.clear((Hub.Setters))
		table.clear((Hub.Keybinds))
		table.clear(Hub.Searchables)
		table.clear(Hub._entries)
		if Hub._window then
			Hub._window:AddTab(CONFIG.tabs[1])
		end
		return Hub
	end

	---Build the window and run the tabs in CONFIG.tabs, then every builder.
	---LazyBoot (the loader, or a project that wants to prepare first) can set
	---Hub.deferBoot = true before the library finishes loading; the window is
	---then only built by the first Hub:Init()/Hub:Mount().
	if not Hub.deferBoot then
		Hub.Init(Hub._initOptions)
	end

	-- No `return` here on purpose: a return inside a do-block at the top level
	-- ends the whole chunk, so anything the loader appends after this file
	-- (a second module, a test spec) would never run. Loaders read
	-- _G.FatCatHub instead.
end
