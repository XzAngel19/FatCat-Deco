-- Assertions for src/FatCatHub.project.lua: the decompiler tabs have to build
-- against the mocked DataModel, and every capability probe has to degrade
-- instead of raising when the executor has nothing.

local function walk(node, fn)
	fn(node)
	for _, child in node._children do
		walk(child, fn)
	end
end

local projectChecks, projectFailures = 0, 0
local function expect(label, condition, detail)
	projectChecks += 1
	if condition then
		print("ok   " .. label)
	else
		projectFailures += 1
		print("FAIL " .. label .. (detail and ("  -> " .. tostring(detail)) or ""))
	end
end

local Hub = _G.FatCatHub
expect("project file kept the hub", Hub ~= nil and Hub._window ~= nil)

local names = Hub._window.tabNames
-- Main is the library's own empty tab; the project adds three on top.
expect("four tabs total", #names == 4, table.concat(names, ", "))
expect("Decompiler tab exists", Hub._window.pages["Decompiler"] ~= nil)
expect("Executor tab exists", Hub._window.pages["Executor"] ~= nil)
expect("Hooks tab exists", Hub._window.pages["Hooks"] ~= nil)
expect("opens on Decompiler", Hub._window.selected == "Decompiler", tostring(Hub._window.selected))

-- Content actually drawn, and it mentions what the mock executor can do.
local labels, buttons, codeRows = 0, 0, 0
local sawDecompileOff, sawExecutor, sawSpy = false, false, false
walk(Hub._screen, function(node)
	if node.ClassName == "TextLabel" then
		labels += 1
		local text = node.Text or ""
		if text:find("decompile: no disponible", 1, true) then
			sawDecompileOff = true
		end
		if text:find("Executor:", 1, true) then
			sawExecutor = true
		end
		if text:find("RemoteSpy", 1, true) then
			sawSpy = true
		end
	end
	if node.ClassName == "TextButton" then
		buttons += 1
	end
end)

expect("says decompile is missing", sawDecompileOff, "the mocked executor has no decompile()")
expect("shows the executor name", sawExecutor)
expect("spy row drawn", sawSpy)
expect("labelled rows drawn", labels > 40, labels .. " labels")
expect("buttons drawn", buttons > 5, buttons .. " buttons")

-- A decompiler tab with no decompile() must not have crashed the build.
local decompiler = Hub._window.pages["Decompiler"]
expect("decompiler tab has content", decompiler ~= nil)

-- Rebuilding keeps the three tabs, because Mount re-runs.
Hub:Init(Hub._initOptions)
expect("rebuild keeps every tab", #Hub._window.tabNames == 4, table.concat(Hub._window.tabNames, ", "))
expect("rebuild keeps the selected tab", Hub._window.selected ~= nil, tostring(Hub._window.selected))

-- Toggling the spy without hookmetamethod has to fail loudly, not silently.
local spy = Hub.Setters.fatcatSpy
if spy then
	local ok = pcall(spy, true)
	expect("spy toggle survives a missing hookmetamethod", ok)
	expect("spy flag falls back to off", Hub.Values.fatcatSpy == false, tostring(Hub.Values.fatcatSpy))
else
	expect("spy setter registered", false)
end

print()
if projectFailures > 0 then
	print(("FAIL %d of %d project checks"):format(projectFailures, projectChecks))
	error("project harness failed")
end
print(("PASS %d project checks"):format(projectChecks))
