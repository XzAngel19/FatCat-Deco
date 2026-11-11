-- ==========================================================================
-- Assertions
-- ==========================================================================
local Hub = _G.FatCatHub
check("Hub exposed on _G", Hub ~= nil)
if not Hub then
	print("\nCannot continue without the hub.")
	return
end

check("ScreenGui created", Hub._screen ~= nil and Hub._screen.Parent ~= nil)
check("window frame created", Hub._window ~= nil and Hub._window.frame ~= nil)
check("window default size", Hub._window.width == 460 and Hub._window.height == 560)
check("one default tab", Hub._window.pages["Main"] ~= nil)
check("title label text", Hub._window.titleLabel.Text == "Fat Cat")
local brandColor = Hub._window.brand.BackgroundColor3
check("brand dot is the green injection light",
	math.abs(brandColor.R * 255 - 124) < 1 and math.abs(brandColor.G * 255 - 222) < 1 and math.abs(brandColor.B * 255 - 146) < 1,
	tostring(brandColor.R * 255) .. "," .. tostring(brandColor.G * 255) .. "," .. tostring(brandColor.B * 255))
check("resize corner carries no grip lines", #Hub._window.resizeHandle:GetChildren() == 0,
	#Hub._window.resizeHandle:GetChildren() .. " children")

-- The shadow host is what stops the ghost rectangle: it mirrors the frame
-- on every move, resize and hide.
local mirrorFrame = Hub._window.frame
local mirrorShadow = Hub._window.shadow
mirrorFrame.Position = UDim2.new(0, 123, 0, 45)
check("shadow follows the window", mirrorShadow.Position.X.Offset == 123 and mirrorShadow.Position.Y.Offset == 45)
mirrorFrame.Size = UDim2.fromOffset(400, 300)
check("shadow follows resizes", mirrorShadow.Size.X.Offset == 400 and mirrorShadow.Size.Y.Offset == 300)
mirrorFrame.Visible = false
check("shadow hides with the window", mirrorShadow.Visible == false)
mirrorFrame.Visible = true
mirrorFrame.Size = UDim2.fromOffset(460, 560)
mirrorFrame.Position = UDim2.new(0.5, -230, 0.5, -280)

local built = Hub._screen:_descendants()
check("instance tree built", built > 40, built .. " descendants")

-- ==========================================================================
-- Components
-- ==========================================================================
local page = Hub._window:Tab("Main")
local box = page:Section("Options")

local toggleFired = 0
local toggleValue = nil
box:Toggle({
	Text = "Feature",
	Default = false,
	Flag = "feature",
	Callback = function(state)
		toggleFired += 1
		toggleValue = state
	end,
	Description = "Test toggle",
})

local card = Hub._window.pages.Main.columns[1]:FindFirstChild("feature", true)
check("toggle card registered", card ~= nil)
check("toggle starts off", Hub.Values.feature == false)

card.Activated:Fire()
flush()
check("toggle flips to true", Hub.Values.feature == true)
check("toggle callback fired once", toggleFired == 1, toggleFired)
check("toggle callback got new state", toggleValue == true, tostring(toggleValue))
check("toggle raises a notification", Hub._toasts and #Hub._toasts:GetChildren() > 1)

card.Activated:Fire()
flush()
check("toggle flips back to false", Hub.Values.feature == false)
check("callback fired twice total", toggleFired == 2, toggleFired)

-- Slider
local sliderFired = nil
box:Slider({
	Text = "Volume",
	Min = 0,
	Max = 10,
	Default = 5,
	Decimals = 1,
	Flag = "volume",
	Suffix = "%",
	Callback = function(value)
		sliderFired = value
	end,
})
check("slider default value", Hub.Values.volume == 5)
Hub.Setters.volume(7.349, true)
check("slider snaps to decimals", Hub.Values.volume == 7.3, Hub.Values.volume)
Hub.Setters.volume(99, true)
check("slider clamps to max", Hub.Values.volume == 10, Hub.Values.volume)
Hub.Setters.volume(-4, true)
check("slider clamps to min", Hub.Values.volume == 0, Hub.Values.volume)
Hub.Setters.volume(6.5, false)
flush()
check("slider callback receives value", sliderFired == 6.5, tostring(sliderFired))

-- Cycle
local cycleFired = nil
box:Cycle({ Text = "Mode", Options = { "Auto", "Manual", "Off" }, Flag = "mode", Callback = function(v)
	cycleFired = v
end })
check("cycle starts on first option", Hub.Values.mode == "Auto")
local cycleCard = Hub._window.pages.Main.columns[1]:FindFirstChild("mode", true)
local cycleButton = cycleCard:_find(function(child)
	return child.ClassName == "TextButton"
end)
cycleButton.Activated:Fire()
check("cycle advances", Hub.Values.mode == "Manual", tostring(Hub.Values.mode))
check("cycle callback fired", cycleFired == "Manual", tostring(cycleFired))
Hub.Setters.mode("Off")
check("cycle setter accepts a listed option", Hub.Values.mode == "Off")

-- Dropdown
box:Dropdown({ Text = "Target", Options = { "Head", "Torso", "Legs" }, Flag = "target" })
check("dropdown default", Hub.Values.target == "Head")
local dropdownCard = Hub._window.pages.Main.columns[1]:FindFirstChild("target", true)
local dropdownButton = dropdownCard:_find(function(child)
	return child.ClassName == "TextButton"
end)
local scrollList = dropdownCard:_find(function(child)
	return child.ClassName == "ScrollingFrame"
end)
check("dropdown list starts collapsed", scrollList ~= nil and scrollList.Visible == false)
dropdownButton.Activated:Fire()
check("dropdown expands", scrollList.Visible == true)
local optionRow = scrollList:_find(function(child)
	return child.ClassName == "TextButton" and child.Text == "  Torso"
end)
optionRow.Activated:Fire()
check("dropdown picks option", Hub.Values.target == "Torso", tostring(Hub.Values.target))
check("dropdown collapses after pick", scrollList.Visible == false)

-- Input
local inputFired = nil
box:Input({ Text = "Name", Default = "", Flag = "name", Callback = function(v)
	inputFired = v
end })
local inputCard = Hub._window.pages.Main.columns[1]:FindFirstChild("name", true)
local textField = inputCard:_find(function(child)
	return child.ClassName == "TextBox"
end)
textField.Text = "hello"
textField.FocusLost:Fire(true)
check("input commits on enter", Hub.Values.name == "hello", tostring(Hub.Values.name))
check("input callback fired", inputFired == "hello", tostring(inputFired))
textField.Text = "discard me"
textField.FocusLost:Fire(false)
check("input reverts on escape", Hub.Values.name == "hello" and textField.Text == "hello", tostring(textField.Text))

-- Keybind
local keyFired = 0
box:Keybind({ Text = "Panic", Flag = "panic", Default = "Q", OnKey = function()
	keyFired += 1
end })
check("keybind default value", Hub.Values.panic == "Q")
local keyCard = Hub._window.pages.Main.columns[1]:FindFirstChild("panic", true)
local chip = keyCard:_find(function(child)
	return child.ClassName == "TextButton"
end)
chip.Activated:Fire()
check("keybind starts listening", Hub._listening ~= nil)
Hub._listening(Enum.KeyCode.E)
check("keybind captures new key", Hub.Values.panic == "E", tostring(Hub.Values.panic))
check("keybind chip shows the key", chip.Text == "E", chip.Text)

-- Press the routed key through the hub's own dispatch.
local routed = false
for _, entry in Hub._entries do
	if entry.HandleKey and entry.HandleKey(Enum.KeyCode.E) then
		routed = true
		break
	end
end
check("keybind press routes to OnKey", routed and keyFired == 1, tostring(keyFired))

-- Button
local buttonFired = 0
box:Button({ Text = "Run", Callback = function()
	buttonFired += 1
end })
local buttonCard = Hub._window.pages.Main.columns[1]:FindFirstChild("Run", true)
local runButton = buttonCard:_find(function(child)
	return child.ClassName == "TextButton"
end)
runButton.Activated:Fire()
check("button fires callback", buttonFired == 1, buttonFired)

-- Group
local group = box:Group({ Text = "Advanced", Collapsed = true })
local grouped = box:Toggle({ Text = "Nested", Flag = "nested" })
check("grouped row starts hidden", grouped.Visible == false)
box:EndGroup()
local groupCard = Hub._window.pages.Main.columns[1]:FindFirstChild("Advanced", true)
local groupButton = groupCard:_find(function(child)
	return child.ClassName == "TextButton"
end)
groupButton.Activated:Fire()
check("group expands", grouped.Visible == true)
groupButton.Activated:Fire()
check("group collapses again", grouped.Visible == false)

-- Colour
box:ColorPicker({ Text = "Tint", Flag = "tint" })
local firstColor = Hub.Values.tint
local tintCard = Hub._window.pages.Main.columns[1]:FindFirstChild("tint", true)
tintCard.Activated:Fire()
check("colour cycles", Hub.Values.tint ~= firstColor)
Hub.Setters.tint(Color3.fromRGB(1, 2, 3))
check("colour setter accepts a Color3", Hub.Values.tint.R == 1 / 255)

-- ==========================================================================
-- Search
-- ==========================================================================
Hub._window.applySearch("volum")
local found = 0
for _, searchable in Hub.Searchables do
	if searchable.Visible and searchable.Parent then
		found += 1
	end
end
check("search narrows to matching rows", found == 1, found .. " visible")
Hub._window.applySearch("")
local restored = 0
for _, searchable in Hub.Searchables do
	if searchable.Parent and searchable.Parent.Visible then
		restored += 1
	end
end
check("search restores rows", restored >= 6, restored .. " visible")

-- The field itself: placeholder, clear button and Escape.
local searchBox = Hub._window.searchBox
check("search placeholder is Buscar", searchBox.PlaceholderText == "Buscar...", searchBox.PlaceholderText)
local searchClear = searchBox.Parent:FindFirstChild("ClearSearch")
check("clear button starts hidden", searchClear ~= nil and searchClear.Visible == false)
searchBox.Text = "volum"
check("clear button appears with text", searchClear.Visible == true)
searchClear.Activated:Fire()
check("clear button empties the field", searchBox.Text == "")
check("clear button hides again", searchClear.Visible == false)
searchBox:CaptureFocus()
searchBox.Text = "aim"
check("search field knows it is focused", searchBox:IsFocused() == true)
game:GetService("UserInputService").InputBegan:Fire({
	UserInputType = Enum.UserInputType.Keyboard,
	KeyCode = Enum.KeyCode.Escape,
}, false)
check("escape clears and releases the search field", searchBox.Text == "" and searchBox:IsFocused() == false)

-- ==========================================================================
-- Save / load / reset
-- ==========================================================================
Hub.Setters.feature(true)
Hub.Setters.volume(3.5, true)
local saved = Hub:Save(false)
check("save writes a file", saved == true and files["FatCatHub/config.json"] ~= nil)
Hub.Setters.volume(9, true)
Hub.Setters.feature(false, true)
local loaded = Hub:Load(false)
flush()
check("load succeeds", loaded == true)
check("load restores slider", Hub.Values.volume == 3.5, tostring(Hub.Values.volume))
check("load restores toggle", Hub.Values.feature == true)

Hub:Reset(false)
flush()
check("reset restores defaults", Hub.Values.volume == 5 and Hub.Values.feature == false,
	tostring(Hub.Values.volume) .. "/" .. tostring(Hub.Values.feature))

Hub:Copy()
check("copy writes JSON to the clipboard", _G.clipboardValue() ~= nil and string.find(_G.clipboardValue(), "volume") ~= nil)

-- ==========================================================================
-- Tabs
-- ==========================================================================
local combatTab = Hub._window:AddTab("Combat")
check("AddTab creates a page", combatTab ~= nil and Hub._window.pages["Combat"] ~= nil)
check("AddTab selects the new tab", Hub._window.selected == "Combat")
check("tab indicators resize", Hub._window.tabButtons["Main"].Size.X.Scale == 0.5)
combatTab:Section("Combat settings"):Toggle({ Text = "Aim", Flag = "aim" })
check("component works on a new tab", Hub.Values.aim == false)
Hub._window:SelectTab("Main")
check("SelectTab switches back", Hub._window.selected == "Main")

-- ==========================================================================
-- Notifications and cleanup
-- ==========================================================================
local before = #Hub._toasts:GetChildren()
Hub:Notify("Test", "info", "detail line")
check("notify adds a toast", #Hub._toasts:GetChildren() == before + 1)
flush()

local connectionCount = #Hub.Connections
check("global listeners registered", connectionCount >= 4, connectionCount)

local windowFrame = Hub._window.frame
windowFrame.Visible = true
Hub._window:Toggle()
check("menu key hides the window", windowFrame.Visible == false)
Hub._window:Toggle()
check("menu key shows the window", windowFrame.Visible == true)

-- ==========================================================================
-- Mount: adding the project's own tab after the library has loaded.
-- This is the shape the loader is meant to be used in, so it is the shape
-- that has to be tested.
-- ==========================================================================

local mountedRuns = 0
Hub:Mount(function(hub, window)
	mountedRuns += 1
	local page = window:Tab("Tools") or window:AddTab("Tools")
	local box = page:Section("Tools", 1)
	box:Toggle({ Text = "Mounted toggle", Default = true, Flag = "mountedToggle" })
end)

check("Mount builds a tab after load", Hub._window.pages["Tools"] ~= nil)
check("Mount ran its builder once", mountedRuns == 1, mountedRuns)
check("mounted widget registered a flag", Hub.Values.mountedToggle == true)
check("main tab survived the mount", Hub._window.pages["Main"] ~= nil)
check("mounted toggle is searchable", Hub._window:Tab("Tools") ~= nil)

-- A rebuild has to re-run the builders, otherwise the window comes back empty.
Hub:Init(Hub._initOptions)
check("rebuild re-runs mounted builders", mountedRuns == 2, mountedRuns)
check("rebuild keeps the mounted tab", Hub._window.pages["Tools"] ~= nil)

-- Unmounting and rebuilding must not leave stale builders behind.
Hub._builders = {}
Hub:Init(Hub._initOptions)
check("cleared builders do not run", mountedRuns == 2, mountedRuns)

-- ==========================================================================
-- Hotkeys: the menu key and the hint strip
--
-- These are the two bindings a user notices first, and the ones a closed-over
-- window or a wrong key name silently breaks.
-- ==========================================================================

local userInput = game:GetService("UserInputService")
Hub._listening = nil
local frame = Hub._window.frame
frame.Visible = true

-- RightShift, as configured.
userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.RightShift }, false)
check("right shift closes the window", frame.Visible == false)
userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.RightShift }, false)
check("right shift opens it again", frame.Visible == true)

-- LeftShift too: laptops have no right shift.
userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.LeftShift }, false)
check("left shift also toggles", frame.Visible == false)
userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.LeftShift }, false)

-- A key the game already consumed must not toggle the menu.
local beforeProcessed = frame.Visible
userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.RightShift }, true)
check("game-consumed key does not toggle", frame.Visible == beforeProcessed)

-- Ctrl+H toggles the hint strip; H alone must not.
local hints = Hub._window.hints
check("hints start visible", hints.Visible == true)

-- H on its own must not touch the strip.
userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.H }, false)
check("plain H does nothing", hints.Visible == true)

-- Ctrl+H toggles it, both control keys.
for _, control in { Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl } do
	local label = control.Name == "LeftControl" and "left ctrl" or "right ctrl"
	userInput._downKeys[control] = true
	userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.H }, false)
	check(label .. "+H hides the hints", hints.Visible == false, tostring(hints.Visible))
	userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.H }, false)
	check(label .. "+H shows them again", hints.Visible == true, tostring(hints.Visible))
	userInput._downKeys[control] = nil
end

-- After a rebuild the hotkey still has a live window to toggle.
Hub:Init(Hub._initOptions)
local rebuiltFrame = Hub._window.frame
rebuiltFrame.Visible = true
userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.RightShift }, false)
check("hotkey works after a rebuild", rebuiltFrame.Visible == false)
userInput.InputBegan:Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.RightShift }, false)

Hub:Destroy()
check("destroy removes the screen", Hub._screen.Parent == nil)
check("destroy clears _G", _G.FatCatHub == nil)
local stillConnected = 0
for _, connection in Hub.Connections do
	if connection.Connected then
		stillConnected += 1
	end
end
check("destroy disconnects every listener", stillConnected == 0, stillConnected .. " still connected")

print()
if failures > 0 then
	print(string.format("FAIL %d of %d checks", failures, checks))
	error("harness failed")
end
print(string.format("PASS %d checks (%d instances, %d tweens)", checks, instanceCount, tweens))
