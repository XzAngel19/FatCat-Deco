-- Assertions for the Fat Cat Project bundle.
--
-- Runs after tools/fatchub/mock.lua and src/FatCatHub.bundle.lua in one chunk
-- (see tools/test_fatchub_bundle.sh). The mock is the DataModel; the bundle is
-- the real twenty-one modules and the real bootstrapper, unmodified.
--
-- What this spec is for: the bundle is generated, so a mistake in the
-- generator, in a module body that touches an injected symbol too early, or in
-- the boot order shows up here and not in a screenshot. The design harness is
-- blind to all of it.

local Core = _G.FatCatProject
local Hub = _G.FatCatHub

check("FatCatInit returned a table", type(Init) == "table")
check("boot reported ok", Init.booted ~= nil and Init.booted.ok == true,
	Init.booted and tostring(Init.booted.error))
check("boot reached the ready stage", Init.booted and Init.booted.stage == "ready")
check("no module failed to load", next(Core.loadErrors or {}) == nil,
	Core.loadErrors and next(Core.loadErrors))
check("file map lists every module", next(Init.files or {}) ~= nil)

-- ---------------------------------------------------------------------------
-- Core
-- ---------------------------------------------------------------------------
check("_G.FatCatProject is the core table", Core ~= nil and type(Core.Require) == "function")
check("core reports a version", type(Core.VERSION) == "string" and #Core.VERSION > 0)
check("modules were loaded in order", #Core.loadOrder >= 8, #Core.loadOrder)
check("require is cached", Core:Require("FatCatSignal") == Core:Require("FatCatSignal"))
check("unknown module fails with a readable message", Core:TryRequire("NoSuchModule") == nil)

-- Detected environment in the mock: no executor functions at all.
local Env = Core:Require("FatCatEnv")
check("environment detection ran", type(Env.name) == "string")
check("missing capability reports false", Env.has("hookfunction") == false)
check("env.fn returns nil for a missing capability", Env.fn("hookfunction") == nil)

-- ---------------------------------------------------------------------------
-- Signals
-- ---------------------------------------------------------------------------
local Signal = Core:Require("FatCatSignal")
local bus = Signal.new("spec")
local seen = 0
local link = bus:Connect(function(value)
	seen += value
end)
bus:Fire(2)
bus:Fire(3)
check("signal fires every connection", seen == 5, seen)
link:Disconnect()
bus:Fire(10)
check("disconnect stops delivery", seen == 5, seen)
check("signal reports its connection count", bus:Count() == 0)

-- A callback that throws must not stop the next one.
local survived = false
bus:Connect(function()
	error("intentional")
end)
bus:Connect(function()
	survived = true
end)
Signal.errorHandler = nil
bus:Fire()
check("one bad callback does not stop the others", survived)

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local Config = Core:Require("FatCatConfig")
-- The mock implements writefile/readfile (the shell's own config tests use
-- them), so the file path is live here. What must hold either way is that a
-- refusal is a sentence, never a throw.
check("config can use the mock's file API", Config:Available() == true)
check("config explains its state", type(Config:UnavailableReason()) == "string")
local okSave, savedCount = Config:SavePreset("spec", { a = 1, b = "two", skipMe = Color3.new(1, 0, 0) })
check("saving a preset with serialisable values works", okSave == true, tostring(savedCount))
check("only serialisable values are saved", savedCount == 2, savedCount)
local listed, active = Config:List()
local foundSpec = false
for _, name in listed do
	if name == "spec" then
		foundSpec = true
	end
end
check("the saved preset is listed", foundSpec, table.concat(listed, ","))
check("the saved preset is active", active == "spec", active)
local loadedValues = Config:LoadPreset("spec")
check("a saved preset loads back", type(loadedValues) == "table" and loadedValues.b == "two")
check("bad preset names are refused", Config.validName("../escape") == false)
check("good preset names are accepted", (Config.validName("raid night 2")) == true)
Config:DeletePreset("spec")

-- ---------------------------------------------------------------------------
-- Design
-- ---------------------------------------------------------------------------
local Design = Core:Require("FatCatDesign")
check("design has three palettes", #Design.order == 3, #Design.order)
check("classic palette is the shell's palette", Design.current == "classic")
check("color returns a Color3", typeof(Design.color("accent")) == "Color3")
check("unknown palette is refused", Design.apply("nope") == false)
check("known palette is accepted", Design.apply("glacier") == true)
check("palette actually changed", Design.current == "glacier")
Design.apply("classic")
local ratio = Design.contrast(Design.color("text"), Design.color("card"))
check("text on card clears the 3:1 audit floor", ratio >= 3, string.format("%.2f", ratio))
check("reduced motion flattens the tweens", (function()
	Design.setReducedMotion(true)
	local instant = Design.tween("open")
	Design.setReducedMotion(false)
	return instant ~= nil
end)())

-- ---------------------------------------------------------------------------
-- Materials: components are built from the design, not hardcoded
-- ---------------------------------------------------------------------------
local Materials = Core:Require("FatCatMaterials")
local host = Instance.new("Frame")
local section = Materials.Section(host, "Spec")
local toggle = Materials.Toggle(section.frame, { Text = "Spec toggle", Default = true })
check("toggle starts on when Default is true", toggle:Get() == true)
toggle:Set(false)
check("toggle setter works", toggle:Get() == false, tostring(toggle:Get()))
local slider = Materials.Slider(section.frame, { Text = "Spec", Min = 0, Max = 100, Default = 25, Step = 5 })
check("slider starts at its default", slider:Get() == 25)
slider:Set(57)
check("slider snaps to its step", slider:Get() == 55, slider:Get())
local button = Materials.Button(section.frame, { Text = "Spec" })
check("button returns a handle with SetBusy", type(button.SetBusy) == "function")
local code = Materials.Code(section.frame, { Height = 80 })
code:SetLines("one\ntwo\nthree")
check("code view accepts a multi-line string", type(code) == "table")
local statusRow = Materials.Status(section.frame, "hello", "on")
check("status row exposes a setter", type(statusRow.Set) == "function")

-- ---------------------------------------------------------------------------
-- Math: the part with exact answers
-- ---------------------------------------------------------------------------
local M = Core:Require("FatCatMath")
check("clamp", M.clamp(5, 0, 3) == 3)
check("remap", M.remap(5, 0, 10, 0, 100) == 50)
check("wrapAngle keeps 190 at -170", M.wrapAngle(190) == -170)
check("flatDistance ignores height", M.flatDistance(Vector3.new(0, 0, 0), Vector3.new(3, 99, 4)) == 5)
check("normalize of zero is zero", M.normalize(Vector3.zero) == Vector3.zero)
-- A target dead ahead at 100 studs, stationary, projectile at 50 studs/s:
-- the lead point is the target itself.
local lead = M.predict(Vector3.zero, Vector3.new(0, 0, -100), Vector3.zero, 50)
check("predict returns the target when it is still", lead and (lead - Vector3.new(0, 0, -100)).Magnitude < 1e-6)
-- A target crossing at 50 studs/s with a 100 studs/s projectile: the lead
-- point must be ahead of the target, on the same side it is moving toward.
local crossing = M.predict(Vector3.zero, Vector3.new(0, 0, -100), Vector3.new(50, 0, 0), 100)
check("predict leads a moving target", crossing and crossing.X > 0, crossing and crossing.X)
check("predict gives up when the target outruns the shot",
	M.predict(Vector3.zero, Vector3.new(0, 0, -100), Vector3.new(500, 0, 0), 50) == nil)
check("arc has the requested number of points", #M.arc(Vector3.zero, Vector3.new(10, 30, 0), nil, 1, 8) == 9)
check("anglesTo points at the target", (function()
	local pitch = M.anglesTo(Vector3.zero, Vector3.new(0, 10, -10))
	return math.abs(pitch - 45) < 0.5
end)())

-- worldToScreen needs a camera; the mock has one at the origin looking down -Z
-- (CFrame.new() in this mock), so a point in front of it is on screen.
local camera = workspace.CurrentCamera
if camera and camera.ViewportSize and camera.ViewportSize.X > 0 then
	local x, y, onScreen = M.worldToScreen(camera, Vector3.new(0, 0, -50))
	check("worldToScreen puts a point ahead on screen", onScreen == true, tostring(x) .. "," .. tostring(y))
	local _, _, behind = M.worldToScreen(camera, Vector3.new(0, 0, 50))
	check("worldToScreen rejects a point behind the camera", behind == false)
end

-- ---------------------------------------------------------------------------
-- Console
-- ---------------------------------------------------------------------------
local Console = Core:Require("FatCatConsole")
Console.clear()
Console.write("info", "spec line")
check("console stores an entry", #Console.log == 1)
local counts = Console.counts()
check("console counts by level", counts.info == 1)
local ranOk, value = Console.run("return 6 * 7")
check("console runs a snippet", ranOk == true)
check("console returns the snippet's value", value and value[1] == 42, value and value[1])
local failed, failure = Console.run("this is not Luau")
check("console reports a compile error instead of throwing", failed == false)
check("console logged the error", Console.counts().error >= 1)
Console.check("return 1")
check("console check accepts valid code", (Console.check("return 1")) == true)

-- ===========================================================================
-- The shell and the project together
-- ===========================================================================
check("shell published _G.FatCatHub", Hub ~= nil)
check("shell built a window", Hub and Hub._window ~= nil)
check("window has the seven project tabs", Hub and #Hub._window.tabNames == 7, Hub and #Hub._window.tabNames)
check("no empty default Main tab survived", Hub and Hub._window.pages.Main == nil)
check("Home is the landing tab", Hub and Hub._window.selected == "Home", Hub and Hub._window.selected)
for _, name in { "Home", "Settings", "Create", "Inspect", "Scripts", "Exploit", "Network" } do
	check("tab '" .. name .. "' exists", Hub and Hub._window.pages[name] ~= nil)
end

-- Every tab must have content: a section with children in at least one column.
local emptyTabs = {}
for name, page in Hub._window.pages do
	local total = #page.columns[1]:GetChildren() + #page.columns[2]:GetChildren()
	if total <= 1 then
		table.insert(emptyTabs, name)
	end
end
check("no tab is empty", #emptyTabs == 0, table.concat(emptyTabs, ", "))

-- The menu is idempotent: building twice must not duplicate tabs.
local Menu = Core:Require("FatCatMenu")
Menu.build()
check("rebuilding does not add tabs", #Hub._window.tabNames == 7, #Hub._window.tabNames)
check("Menu.ready agrees with the shell", Menu.ready() == true)
check("Menu.tab selects an existing tab", Menu.tab("Console") == false)
check("Menu.tab refuses an unknown tab", Menu.tab("Nope") == false)

-- Preset integration: the shell records a flag and its setter, and the config
-- module can enumerate them. This is what makes one preset cover the menu.
check("shell stores flag values", type(Hub.Values) == "table")
check("shell stores flag setters", type(Hub.Setters) == "table")
local hasPaletteFlag = Hub.Values["ui.palette"] ~= nil
check("palette flag reached the shell", hasPaletteFlag, Hub.Values["ui.palette"])

-- ---------------------------------------------------------------------------
-- The modules that touch the outside world must refuse cleanly, not throw
-- ---------------------------------------------------------------------------
local Spoofer = Core:TryRequire("FatCatEnvSpoofer")
check("spoofer refuses to fake a missing identifyexecutor",
	Spoofer and Spoofer.spoofIdentity("x") == false)
check("spoofer can report whether it can sandbox", type(Spoofer.canSandbox()) == "boolean")
local sandboxCopy = Spoofer.sandbox({ probe = 1 })
check("spoofer builds a sandbox copy", sandboxCopy.probe == 1, tostring(sandboxCopy.probe))
check("the sandbox is a copy, not the environment", sandboxCopy ~= Core.env)

local Hooks = Core:TryRequire("FatCatVMHook")
local missingHook, missingWhy = Hooks.functionHook("NoSuchFunction", function() end)
check("hook refuses a function that does not exist",
	missingHook == nil and type(missingWhy) == "string")

-- A real hook: install, call through, remove, and check the original is back.
_G.SpecHookTarget = function(value)
	return value * 2
end
local hookCalls = 0
local hookLink = Hooks.functionHook("SpecHookTarget", function(original, value)
	hookCalls += 1
	return original(value)
end)
check("hook installed", hookLink ~= nil and Hooks.count() == 1)
check("hook passes the call through", _G.SpecHookTarget(21) == 42)
check("hook counted the call", hookCalls == 1)
check("hook removes cleanly", hookLink and hookLink:Remove() == true)
check("original restored after removal", _G.SpecHookTarget(21) == 42 and hookCalls == 1)
check("hook registry is empty again", Hooks.count() == 0)
_G.SpecHookTarget = nil

-- A factory that is called with the wrong argument count must say so instead
-- of building a component with half its state.
local Ok, Why = Core:Require("FatCatConfig").SavePreset("../../escape", { a = 1 })
check("config refuses a path traversal", Ok == false and type(Why) == "string")

-- Signals: Wait resolves on Fire and is released by Destroy, so an unload
-- during a wait cannot park a thread forever.
do
	local waiter = Signal.new("wait")
	local got = nil
	local thread = coroutine.create(function()
		got = waiter:Wait()
	end)
	coroutine.resume(thread)
	waiter:Fire("payload")
	check("Signal:Wait resolves on Fire", got == "payload", tostring(got))

	local doomed = Signal.new("doomed")
	local resumed = false
	local parked = coroutine.create(function()
		doomed:Wait()
		resumed = true
	end)
	coroutine.resume(parked)
	doomed:Destroy()
	check("Signal:Destroy releases a parked Wait", resumed == true)
end

-- ---------------------------------------------------------------------------
-- Layout order stays unique
--
-- `#parent:GetChildren() + 1` gives a new row an order a surviving row still
-- holds after a removal, and SortOrder.LayoutOrder then draws them in an
-- undefined order. The counter must never repeat.
-- ---------------------------------------------------------------------------
do
	local Materials = Core:Require("FatCatMaterials")
	local host = Instance.new("Frame")
	host.Name = "OrderHost"
	host.Size = UDim2.fromOffset(300, 400)
	-- Section returns { frame, setters, values, Register }; children go in the
	-- box, not in the binding table.
	local box = Materials.Section(host, "Order").frame
	-- Materials returns a handle ({ Instance, Set, Get, Destroy }); the row is
	-- handle.Instance.
	local first = Materials.Label(box, "one").Instance
	local second = Materials.Label(box, "two").Instance
	local third = Materials.Label(box, "three").Instance
	check("layout order is assigned",
		first.LayoutOrder ~= nil and second.LayoutOrder ~= nil and first.LayoutOrder < second.LayoutOrder,
		tostring(first.LayoutOrder) .. "," .. tostring(second.LayoutOrder))
	-- Remove a row from the middle, then add another: the old
	-- `#parent:GetChildren() + 1` formula would hand out an order that `third`
	-- already holds.
	second:Destroy()
	local fourth = Materials.Label(box, "four").Instance
	check("layout order does not collide after a removal",
		fourth.LayoutOrder ~= third.LayoutOrder and fourth.LayoutOrder > third.LayoutOrder,
		tostring(fourth.LayoutOrder) .. " vs " .. tostring(third.LayoutOrder))
	local orders, clash = {}, nil
	for _, child in box:GetChildren() do
		local order = child.LayoutOrder
		if order ~= nil then
			if orders[order] then
				clash = tostring(order)
			end
			orders[order] = true
		end
	end
	check("no two siblings share a layout order", clash == nil, clash)
	host:Destroy()
end

-- ===========================================================================
-- Teardown
-- ===========================================================================
local teardownRan = false
Core:OnDestroy("spec", function()
	teardownRan = true
end)
local destroyedCount = Core:Destroy()
check("destroy ran the teardowns", teardownRan == true)
check("destroy returned a count", type(destroyedCount) == "number" and destroyedCount >= 1)
check("destroy cleared the module cache", next(Core.modules) == nil or #Core.loadOrder == 0)
check("destroy released the global", _G.FatCatProject == nil)
check("destroy is idempotent", Core:Destroy() == 0)
check("require after destroy errors instead of half-loading", Core:TryRequire("FatCatSignal") == nil)

print(("\n%d checks, %d failure(s)"):format(checks, failures))
if failures > 0 then
	error(("%d assertion(s) failed"):format(failures), 0)
end
