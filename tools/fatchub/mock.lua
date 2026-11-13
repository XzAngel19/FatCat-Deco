-- Roblox DataModel mock for src/FatCatHub.lua.
--
-- Not run directly: tools/test_fatchub.sh concatenates this file, the hub
-- source and tools/fatchub/spec.lua into build/test_fatchub.lua and runs
-- that. One chunk, no loadstring: the wasm VM cannot re-enter its own compiler
-- from a JS callback, and the original FatCat Hub shipped the same way (shell
-- and features as two blocks of one script).
--
-- The Luau VM here is the real one; Roblox is simulated. Every property write
-- on an instance is recorded, every signal can be fired, tweens apply their
-- goal immediately (so assertions see the end state), and the scheduler is
-- manual so `task.delay` work can be flushed deterministically.
--
-- Assertions cover the parts a screenshot cannot: values reaching the setters,
-- callbacks firing once, search filtering, save/load round trips, tab
-- switching, cleanup.

local failures = 0
local checks = 0

local function check(name, condition, detail)
	checks += 1
	if condition then
		print("ok   " .. name)
	else
		failures += 1
		print("FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
	end
end

-- ==========================================================================
-- Enum / datatypes
-- ==========================================================================
local function makeEnumItem(name, value)
	return setmetatable({ Name = name, Value = value }, { __tostring = function(self)
		return "Enum." .. self.Name
	end })
end

-- Enum proxy. `GetEnumItems` is answered by __index; every missing key
-- returns nil instead of walking back into the metatable.
local enumItems = {}
local function makeEnum(name, names)
	local items = {}
	local list = {}
	for index, itemName in names do
		local item = { Name = itemName, Value = index }
		items[itemName] = item
		table.insert(list, item)
	end
	enumItems[name] = list
	return setmetatable(items, {
		__index = function(_, key)
			if key == "GetEnumItems" then
				return function()
					return list
				end
			end
			return nil
		end,
	})
end

Enum = {
	Font = {
		Gotham = { Name = "Gotham", Value = 1 },
		GothamBold = { Name = "GothamBold", Value = 2 },
		GothamMedium = { Name = "GothamMedium", Value = 3 },
		RobotoMono = { Name = "RobotoMono", Value = 6 },
		Code = { Name = "Code", Value = 7 },
		SourceSans = { Name = "SourceSans", Value = 4 },
		SourceSansBold = { Name = "SourceSansBold", Value = 5 },
	},
	-- Every letter is here: a harness that silently drops Enum.KeyCode.H turns
	-- a working hotkey into a failing test.
	KeyCode = makeEnum("KeyCode", {
		"Unknown", "Escape", "Tab", "RightShift", "LeftShift", "Insert", "Delete", "End", "Home",
		"PageUp", "PageDown", "F1", "F2", "F3",
		"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
		"Zero", "One", "Two", "Three", "Four",
		"LeftControl", "RightControl", "LeftAlt", "RightAlt", "Space",
	}),
	UserInputType = makeEnum("UserInputType", { "MouseButton1", "MouseMovement", "Touch", "Keyboard" }),
	EasingStyle = makeEnum("EasingStyle", { "Linear", "Quad", "Quint", "Sine", "Back" }),
	EasingDirection = makeEnum("EasingDirection", { "In", "Out", "InOut" }),
	ZIndexBehavior = makeEnum("ZIndexBehavior", { "Sibling", "Global" }),
	SortOrder = makeEnum("SortOrder", { "LayoutOrder", "Name" }),
	AutomaticSize = makeEnum("AutomaticSize", { "None", "X", "Y", "XY" }),
	AutomaticCanvasSize = makeEnum("AutomaticCanvasSize", { "None", "X", "Y", "XY" }),
	TextXAlignment = makeEnum("TextXAlignment", { "Left", "Center", "Right" }),
	TextYAlignment = makeEnum("TextYAlignment", { "Top", "Center", "Bottom" }),
	TextTruncate = makeEnum("TextTruncate", { "None", "AtEnd" }),
	ApplyStrokeMode = makeEnum("ApplyStrokeMode", { "Border", "Contextual" }),
	ScrollingDirection = makeEnum("ScrollingDirection", { "X", "Y", "XY" }),
	HorizontalAlignment = makeEnum("HorizontalAlignment", { "Left", "Center", "Right" }),
	VerticalAlignment = makeEnum("VerticalAlignment", { "Top", "Center", "Bottom" }),
	RenderPriority = { Character = { Value = 200 } },
}

local function newUDim(scale, offset)
	return { Scale = scale or 0, Offset = offset or 0 }
end

UDim = { new = newUDim }
UDim2 = {
	new = function(xs, xo, ys, yo)
		return { X = newUDim(xs, xo), Y = newUDim(ys, yo) }
	end,
	fromOffset = function(x, y)
		return { X = newUDim(0, x), Y = newUDim(0, y) }
	end,
	fromScale = function(x, y)
		return { X = newUDim(x or 1, 0), Y = newUDim(y or 1, 0) }
	end,
}
Vector2 = {
	new = function(x, y)
		return setmetatable({ X = x, Y = y }, {
			__sub = function(a, b)
				return Vector2.new(a.X - b.X, a.Y - b.Y)
			end,
		})
	end,
}
Color3 = {
	new = function(r, g, b)
		return setmetatable({ R = r or 0, G = g or 0, B = b or 0 },
			{ __type = "Color3", __tostring = function() return "Color3" end })
	end,
	fromRGB = function(r, g, b)
		return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
}

-- Roblox's typeof() names datatypes exactly; the mock tags the tables so the
-- hub's Color3 checks behave the same way they do in game.
local realTypeof = typeof
typeof = function(value)
	if realTypeof(value) == "table" then
		local meta = getmetatable(value)
		if meta and meta.__type then
			return meta.__type
		end
	end
	return realTypeof(value)
end
-- Roblox sequences expose Keypoints; the renderer samples those. Both
-- constructors accept one value, two values, or a table of keypoints.
local function makeSequence(...)
	local args = { ... }
	local keypoints = {}
	if #args == 1 and type(args[1]) == "table" then
		for _, point in args[1] do
			table.insert(keypoints, { Time = point.Time or 0, Value = point.Value })
		end
	elseif #args == 2 then
		table.insert(keypoints, { Time = 0, Value = args[1] })
		table.insert(keypoints, { Time = 1, Value = args[2] })
	else
		table.insert(keypoints, { Time = 0, Value = args[1] })
	end
	return { Keypoints = keypoints, Points = keypoints }
end

NumberSequenceKeypoint = {
	new = function(time, value)
		return { Time = time, Value = value }
	end,
}
NumberSequence = {
	new = makeSequence,
}
ColorSequenceKeypoint = {
	new = function(time, value)
		return { Time = time, Value = value }
	end,
}
ColorSequence = {
	new = makeSequence,
}
TweenInfo = {
	new = function(time, style, direction, repeatCount, reverses)
		return {
			Time = time or 1,
			Style = style,
			Direction = direction,
			RepeatCount = repeatCount or 0,
			Reverses = reverses or false,
		}
	end,
}

-- ==========================================================================
-- Scheduler
-- ==========================================================================
local pending = {}
local taskMock = {
	wait = function(seconds)
		return seconds or 0
	end,
	spawn = function(fn, ...)
		-- Roblox's task.spawn accepts a function OR a suspended thread. A
		-- signal that parks a coroutine in Wait() and resumes it with the
		-- fired values needs the thread form, and a mock that only handles
		-- functions turns "resume that thread" into "call a thread value".
		if type(fn) == "thread" then
			local ok, err = coroutine.resume(fn, ...)
			if not ok then
				print("  spawn error: " .. tostring(err))
			end
			return
		end
		local ok, err = pcall(fn, ...)
		if not ok then
			print("  spawn error: " .. tostring(err))
		end
	end,
	defer = function(fn, ...)
		table.insert(pending, { fn = fn, args = { ... } })
	end,
	delay = function(seconds, fn, ...)
		table.insert(pending, { at = seconds, fn = fn, args = { ... } })
	end,
	cancel = function() end,
}

---Run every deferred/delayed callback registered so far.
local function flush()
	local guard = 0
	while #pending > 0 do
		guard += 1
		if guard > 200 then
			error("scheduler flush did not settle")
		end
		local job = table.remove(pending, 1)
		local ok, err = pcall(job.fn, table.unpack(job.args or {}))
		if not ok then
			print("  delayed error: " .. tostring(err))
		end
	end
end

-- ==========================================================================
-- Instances
-- ==========================================================================
local Instance = {}
local classOrder = {}
local instanceCount = 0

local function newSignal(name, owner)
	local signal = { _name = name, _owner = owner, _connections = {} }
	function signal:Connect(callback)
		local connection = { Connected = true }
		table.insert(self._connections, { callback = callback, connection = connection })
		function connection:Disconnect()
			self.Connected = false
			for index, entry in self._connections do
				if entry.connection == self then
					table.remove(self._connections, index)
					break
				end
			end
		end
		return connection
	end
	function signal:Once(callback)
		local connection
		connection = self:Connect(function(...)
			connection:Disconnect()
			callback(...)
		end)
		return connection
	end
	function signal:Wait()
		return nil
	end
	function signal:Fire(...)
		for _, entry in table.clone(self._connections) do
			if entry.connection.Connected then
				local ok, err = pcall(entry.callback, ...)
				if not ok then
					print("  signal error (" .. self._name .. "): " .. tostring(err))
				end
			end
		end
	end
	function signal:Count()
		return #self._connections
	end
	return signal
end

local function isA(className, target)
	if className == target then
		return true
	end
	local chain = {
		TextButton = { GuiButton = true, GuiObject = true, Frame = true, Instance = true },
		TextBox = { GuiObject = true, Frame = true, Instance = true },
		Frame = { GuiObject = true, Instance = true },
		CanvasGroup = { GuiObject = true, Frame = true, Instance = true },
		ScrollingFrame = { GuiObject = true, Frame = true, Instance = true },
		ScreenGui = { LayerCollector = true, Instance = true },
	}
	local set = chain[target]
	return set ~= nil and set[className] == true
end

local signalNames = {
	"Activated", "MouseEnter", "MouseLeave", "MouseButton1Down", "MouseButton1Up",
	"InputBegan", "InputChanged", "InputEnded", "Focused", "FocusLost", "Destroying",
	"ChildAdded", "ChildRemoved", "AncestryChanged",
}

function Instance.new(className)
	instanceCount += 1
	local instance
	-- Name/Visible/Text live in _props, not in raw fields: Lua only runs
	-- __newindex for keys the table does NOT have, so a raw field would
	-- swallow every later assignment and its GetPropertyChangedSignal fire.
	-- Every property goes through _props so property signals are real.
	instance = {
		ClassName = className,
		_children = {},
		_attributes = {},
		_props = { Name = className, Visible = true, Text = "" },
		_parent = nil,
		Destroyed = false,
	}

	local changed = {}

	for _, signalName in signalNames do
		instance[signalName] = newSignal(signalName, instance)
	end

	-- TextBox focus API: the shell drives it with Escape and with the search
	-- clear button, so a harness without it would silently skip both paths.
	if className == "TextBox" then
		instance._focused = false
		function instance:CaptureFocus()
			if self._focused then
				return
			end
			self._focused = true
			self.Focused:Fire()
		end
		function instance:ReleaseFocus()
			if not self._focused then
				return
			end
			self._focused = false
			self.FocusLost:Fire(false)
		end
		function instance:IsFocused()
			return self._focused == true
		end
	end

	function instance:GetPropertyChangedSignal(property)
		if not changed[property] then
			changed[property] = newSignal(property, self)
		end
		return changed[property]
	end

	-- Every class that can carry Size/Position/Background: a TextLabel is a
	-- GuiObject too, and leaving it out hides every row caption from the
	-- layout pass.
	local GUI_CLASSES = {
		Frame = true, TextButton = true, TextBox = true, TextLabel = true,
		ImageLabel = true, ImageButton = true, CanvasGroup = true, ScrollingFrame = true,
		ViewportFrame = true, VideoFrame = true,
	}

	function instance:IsA(query)
		if query == "GuiObject" then
			return GUI_CLASSES[self.ClassName] == true
		end
		if query == "GuiBase2d" then
			return GUI_CLASSES[self.ClassName] == true or self.ClassName == "LayerCollector"
		end
		return isA(self.ClassName, query)
	end

	function instance:GetChildren()
		return table.clone(self._children)
	end

	function instance:FindFirstChild(name, recursive)
		for _, child in self._children do
			if child.Name == name then
				return child
			end
		end
		if recursive then
			for _, child in self._children do
				local found = child:FindFirstChild(name, true)
				if found then
					return found
				end
			end
		end
		return nil
	end

	function instance:FindFirstChildOfClass(className)
		for _, child in self._children do
			if child.ClassName == className then
				return child
			end
		end
		return nil
	end

	function instance:FindFirstAncestorOfClass(className)
		local current = self._parent
		while current do
			if current.ClassName == className then
				return current
			end
			current = current._parent
		end
		return nil
	end

	function instance:WaitForChild(name)
		return self:FindFirstChild(name) or Instance.new("Folder")
	end

	function instance:GetAttribute(name)
		return self._attributes[name]
	end

	function instance:SetAttribute(name, value)
		self._attributes[name] = value
	end

	function instance:Destroy()
		self.Destroyed = true
		if self.Destroying then
			self.Destroying:Fire()
		end
		if self._parent then
			self._parent:_remove(self)
			self._parent = nil
		end
		self.Visible = false
	end

	function instance:_remove(child)
		for index, entry in self._children do
			if entry == child then
				table.remove(self._children, index)
				break
			end
		end
	end

	function instance:ClearAllChildren()
		for _, child in table.clone(self._children) do
			child:Destroy()
		end
	end

	-- Descendant count helper for the harness.
	function instance:_descendants()
		local total = 0
		for _, child in self._children do
			total += 1 + child:_descendants()
		end
		return total
	end

	-- Recursive search used by the assertions.
	function instance:_find(predicate)
		for _, child in self._children do
			if predicate(child) then
				return child
			end
			local found = child:_find(predicate)
			if found then
				return found
			end
		end
		return nil
	end

	---TextBounds: what Roblox reports after wrapping. The design harness needs
	---it because components size themselves from it, and a mock that returns 0
	---makes every wrapped label look one line tall.
	---
	---Real measurements come from _G.TextMetrics when tools/design.sh has packed
	---the font tables in (see tools/fatchub/metrics.py). Without it the fallback
	---is a per-character width estimate, which keeps test_fatchub.sh
	---independent of whatever fonts the machine happens to have.
	local function measureText(self)
		local text = self.Text or ""
		local size = self.TextSize or 14
		local width = self.Size and self.Size.X.Offset or 0
		local metrics = _G.TextMetrics
		local function charWidth(char)
			if metrics and metrics.advance then
				local units = metrics.advance[char]
				if units then
					return units
				end
			end
			-- Rough: narrow letters, wide letters, everything else.
			if string.find("iIl.,:;'!|", char, 1, true) then
				return 0.30
			elseif string.find("mMW@%", char, 1, true) then
				return 0.95
			end
			return 0.55
		end

		local function lineWidth(line)
			local total = 0
			for index = 1, #line do
				total += charWidth(string.sub(line, index, index))
			end
			return total * size
		end

		local lines = 1
		local widest = 0
		-- A label sized in scale (1, -18) reports Offset 0 but its real width
		-- comes from the parent. Without walking that up, every wrapped label
		-- in the harness measures against 1px and claims one line.
		if width <= 0 then
			local ancestor = self.Parent
			while ancestor and width <= 0 do
				if ancestor.AbsoluteSize then
					local parentWidth = ancestor.AbsoluteSize.X
					if parentWidth and parentWidth > 0 then
						width = parentWidth - 18
					end
				end
				ancestor = ancestor.Parent
			end
		end
		local available = math.max(1, width)
		local line = ""
		for word in string.gmatch(text, "[^ ]+") do
			local candidate = line == "" and word or (line .. " " .. word)
			if self.TextWrapped and lineWidth(candidate) > available and line ~= "" then
				widest = math.max(widest, lineWidth(line))
				lines += 1
				line = word
			else
				line = candidate
			end
		end
		widest = math.max(widest, lineWidth(line))
		if self.TextWrapped then
			widest = math.min(available, math.max(widest, 1))
		end
		-- Metrics carry the face's real ascent+descent when design.sh packed
		-- them in; 1.16 em is the fallback, and the PNG uses the same line box.
		local lineHeight = metrics and metrics.lineHeight or 1.16
		return Vector2.new(widest, size * lineHeight * lines)
	end

	return setmetatable(instance, {
		__index = function(self, key)
			if key == "Parent" then
				return self._parent
			end
			if key == "TextBounds" then
				return measureText(self)
			end
			if key == "AbsoluteSize" then
				-- Scale is resolved against the parent, one level up, so a label
				-- sized `(1, -18)` reports the width it really has in game.
				local w = self.Size and self.Size.X or nil
				local h = self.Size and self.Size.Y or nil
				local parentW, parentH = 0, 0
				local parent = self._parent
				if parent and parent.ClassName ~= "ScreenGui" then
					local parentAbsolute = parent.AbsoluteSize
					if parentAbsolute then
						parentW, parentH = parentAbsolute.X, parentAbsolute.Y
					end
				end
				return Vector2.new(
					(w and ((w.Scale or 0) * parentW + (w.Offset or 0))) or 0,
					(h and ((h.Scale or 0) * parentH + (h.Offset or 0))) or 0
				)
			end
			if key == "AbsolutePosition" then
				local x = self.Position and self.Position.X.Offset or 0
				local y = self.Position and self.Position.Y.Offset or 0
				return Vector2.new(x, y)
			end
			if key == "Children" then
				return self._children
			end
			local props = rawget(self, "_props")
			if props and props[key] ~= nil then
				return props[key]
			end
			return nil
		end,
		__newindex = function(self, key, value)
			if key == "Parent" then
				local old = self._parent
				if old then
					old:_remove(self)
				end
				self._parent = value
				if value then
					table.insert(value._children, self)
				end
				if changed.Parent then
					changed.Parent:Fire()
				end
				return
			end
			self._props[key] = value
			if changed[key] then
				changed[key]:Fire()
			end
		end,
	})
end

-- ==========================================================================
-- Services
-- ==========================================================================
local function makeService(name, extra)
	local service
	service = { Name = name }
	service.InputBegan = newSignal("InputBegan", service)
	service.InputChanged = newSignal("InputChanged", service)
	service.InputEnded = newSignal("InputEnded", service)
	for key, value in extra or {} do
		service[key] = value
	end
	-- Real IsKeyDown so the harness can hold a modifier while firing a key.
	service._downKeys = {}
	function service:IsKeyDown(keyCode)
		return service._downKeys[keyCode] == true
	end
	return service
end

local playerGui = Instance.new("Folder")
playerGui.Name = "PlayerGui"

local localPlayer = Instance.new("Player")
localPlayer.Name = "Tester"
localPlayer.Parent = playerGui

-- The projection fields are attached at the end of this file, once CFrame and
-- Vector3 exist: FatCatMath.worldToScreen needs CFrame.PointToObjectSpace and
-- a FieldOfView, and a camera without them silently reports "off screen".
local camera = { ViewportSize = Vector2.new(1280, 720) }
camera.GetPropertyChangedSignal = function()
	return newSignal("ViewportSize", camera)
end

local players = makeService("Players", { LocalPlayer = localPlayer })
local userInput = makeService("UserInputService")

-- HttpService with a real JSON round trip for the save/load test.
local httpService = {}
function httpService:JSONEncode(value)
	local function encode(v)
		local kind = typeof(v)
		if kind == "table" then
			local isArray = #v > 0
			local parts = {}
			if isArray then
				for _, item in v do
					table.insert(parts, encode(item))
				end
				return "[" .. table.concat(parts, ",") .. "]"
			end
			for key, item in v do
				table.insert(parts, '"' .. tostring(key) .. '":' .. encode(item))
			end
			table.sort(parts)
			return "{" .. table.concat(parts, ",") .. "}"
		elseif kind == "boolean" then
			return v and "true" or "false"
		elseif kind == "number" then
			return tostring(v)
		end
		return '"' .. tostring(v) .. '"'
	end
	return encode(value)
end
function httpService:JSONDecode(text)
	-- Only the shapes this harness produces are supported: flat tables of
	-- string/number/boolean values nested one level.
	local index = 1
	local function skip()
		while index <= #text and string.find(string.sub(text, index, index), "[%s,]") do
			index += 1
		end
	end
	local parse
	parse = function()
		skip()
		local char = string.sub(text, index, index)
		if char == "{" then
			index += 1
			local result = {}
			skip()
			while string.sub(text, index, index) ~= "}" do
				skip()
				local keyEnd = string.find(text, '"', index + 1)
				local key = string.sub(text, index + 1, keyEnd - 1)
				index = keyEnd + 1
				skip()
				index += 1 -- colon
				result[key] = parse()
				skip()
			end
			index += 1
			return result
		elseif char == "[" then
			index += 1
			local result = {}
			skip()
			while string.sub(text, index, index) ~= "]" do
				table.insert(result, parse())
				skip()
			end
			index += 1
			return result
		elseif char == '"' then
			local keyEnd = string.find(text, '"', index + 1)
			local value = string.sub(text, index + 1, keyEnd - 1)
			index = keyEnd + 1
			return value
		else
			-- Literal: true / false / number. Scan to the next delimiter so the
			-- cursor always advances.
			local stop = index
			while stop <= #text and not string.find(string.sub(text, stop, stop), "[,}%]]") do
				stop += 1
			end
			local raw = string.sub(text, index, stop - 1)
			index = stop
			if raw == "true" then
				return true
			elseif raw == "false" then
				return false
			end
			return tonumber(raw) or raw
		end
	end
	return parse()
end

local tweens = 0
local tweenService = {}
function tweenService:Create(instance, info, goal)
	tweens += 1
	local tweenObject = { Completed = newSignal("Completed", instance), _cancelled = false }
	function tweenObject:Play()
		for key, value in goal do
			instance[key] = value
		end
		self.Completed:Fire()
	end
	function tweenObject:Cancel()
		self._cancelled = true
	end
	function tweenObject:Pause() end
	return tweenObject
end

-- Mock file system.
local files = {}
writefile = function(path, contents)
	files[path] = contents
end
readfile = function(path)
	return files[path]
end
isfile = function(path)
	return files[path] ~= nil
end
isfolder = function()
	return true
end
makefolder = function() end
local clipboard = nil
setclipboard = function(value)
	clipboard = value
end
gethui = function()
	return playerGui
end

_G.clipboardValue = function()
	return clipboard
end

game = {
	GetService = function(_, name)
		if name == "Players" then
			return players
		elseif name == "UserInputService" then
			return userInput
		elseif name == "HttpService" then
			return httpService
		elseif name == "TweenService" then
			return tweenService
		elseif name == "Workspace" then
			return { CurrentCamera = camera }
		elseif name == "RunService" then
			return { Heartbeat = newSignal("Heartbeat"), RenderStepped = newSignal("RenderStepped") }
		end
		return makeService(name)
	end,
}

-- workspace.Gravity is real (196.2 by default) and FatCatMath reads it. A nil
-- there turns every trajectory call into "arithmetic on nil" three frames deep.
workspace = { CurrentCamera = camera, Gravity = 196.2 }

task = taskMock

-- getgenv(): the executor environment. src/FatCatInit and src/FatCatHub.loader
-- both call it unguarded (it exists on every executor), so the mock has to
-- provide it or every boot path fails before the first line of Luau runs.
-- Returns the global table itself, which is exactly what the harness wants: a
-- value set there is visible to the next chunk in the same run.
getgenv = function()
	return _G
end

-- warn(): every executor has it, and both the loader and FatCatInit report
-- failures through it. Without this the mock turns "report a error" into
-- "attempt to call a nil value", which hides the error being reported.
warn = function(...)
	local parts = {}
	for index = 1, select("#", ...) do
		parts[index] = tostring((select(index, ...)))
	end
	print("WARN " .. table.concat(parts, " "))
end


-- ==========================================================================
-- Datatypes the project modules use
-- ==========================================================================
-- The shell only ever needed Color3, UDim2 and Vector2, so this block landed
-- with the project bundle rather than with the window. Everything here matches
-- Roblox's arithmetic where the modules rely on it: Vector3 supports + - * /,
-- Magnitude, Unit, Dot, Cross; CFrame supports * and PointToObjectSpace;
-- Enum fills in on demand so a key nobody wrote yet still resolves.

local VECTOR_META = {}
VECTOR_META.__index = VECTOR_META
VECTOR_META.__type = "Vector3"

local function vector(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, VECTOR_META)
end

function VECTOR_META.__add(a, b)
	return vector(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
function VECTOR_META.__sub(a, b)
	return vector(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
function VECTOR_META.__mul(a, b)
	if type(b) == "number" then
		return vector(a.X * b, a.Y * b, a.Z * b)
	end
	if type(a) == "number" then
		return vector(b.X * a, b.Y * a, b.Z * a)
	end
	return vector(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
function VECTOR_META.__div(a, b)
	if type(b) == "number" then
		return vector(a.X / b, a.Y / b, a.Z / b)
	end
	return vector(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
function VECTOR_META.__unm(a)
	return vector(-a.X, -a.Y, -a.Z)
end
function VECTOR_META.__eq(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
function VECTOR_META.__tostring(a)
	return ("%.3f, %.3f, %.3f"):format(a.X, a.Y, a.Z)
end
function VECTOR_META.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function VECTOR_META.Cross(a, b)
	return vector(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
VECTOR_META.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif key == "Unit" then
		local magnitude = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if magnitude == 0 then
			return vector(0, 0, 0)
		end
		return vector(self.X / magnitude, self.Y / magnitude, self.Z / magnitude)
	end
	return VECTOR_META[key]
end

Vector3 = {
	new = vector,
	zero = vector(0, 0, 0),
	one = vector(1, 1, 1),
	xAxis = vector(1, 0, 0),
	yAxis = vector(0, 1, 0),
	zAxis = vector(0, 0, 1),
}

local CFrame = {}
CFrame.__index = CFrame
CFrame.__type = "CFrame"

local function frame(position, look)
	return setmetatable({ Position = position or Vector3.zero, _look = look or Vector3.new(0, 0, -1) }, CFrame)
end

CFrame.new = function(a, b)
	if typeof(a) == "Vector3" then
		return frame(a)
	end
	return frame(Vector3.new(a or 0, b or 0, 0))
end
CFrame.lookAt = function(from, to)
	local look = (to - from).Unit
	return frame(from, look)
end
CFrame.__mul = function(a, b)
	if typeof(b) == "CFrame" then
		return frame(a.Position + b.Position, a._look)
	end
	return a.Position + b
end
function CFrame:PointToObjectSpace(point)
	return point - self.Position
end
function CFrame:PointToWorldSpace(point)
	return point + self.Position
end
CFrame.LookVector = Vector3.new(0, 0, -1)
CFrame.RightVector = Vector3.new(1, 0, 0)
CFrame.UpVector = Vector3.new(0, 1, 0)
CFrame.__index = function(self, key)
	if key == "LookVector" then
		return self._look or Vector3.new(0, 0, -1)
	elseif key == "RightVector" then
		return Vector3.new(1, 0, 0)
	elseif key == "UpVector" then
		return Vector3.new(0, 1, 0)
	end
	return CFrame[key]
end

_G.CFrame = CFrame
Vector3 = Vector3

-- typeof() has to name CFrame and Vector3 like Roblox does.
local previousTypeof = typeof
typeof = function(value)
	if type(value) == "table" then
		local meta = getmetatable(value)
		if meta and meta.__type then
			return meta.__type
		end
	end
	return previousTypeof(value)
end

Vector2.new = function(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, { __sub = function(a, b)
		return Vector2.new(a.X - b.X, a.Y - b.Y)
	end })
end

-- The camera, now that the datatypes exist. Positioned at the origin looking
-- down -Z with the engine's default field of view, which is what the math
-- spec's assertions assume.
camera.FieldOfView = 70
camera.CFrame = CFrame.new(Vector3.zero)
