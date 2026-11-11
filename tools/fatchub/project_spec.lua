-- Assertions for src/FatCatHub.project.lua: the shell has to survive being
-- filled by a project file, and the project file has to run after the window
-- exists instead of throwing it away.

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

-- The shared helper from mock.lua counts into the library spec's totals, which
-- are already reported by the time this file runs.
check = expect

local function walk(node, fn)
	fn(node)
	for _, child in node._children do
		walk(child, fn)
	end
end

check("project file ran", _G.FatCatHub ~= nil)

local Hub = _G.FatCatHub
check("project file kept the hub", Hub ~= nil and Hub._window ~= nil, "no window")
check("project file kept the default tab", Hub._window.pages["Main"] ~= nil)
check("project file selected a tab", Hub._window.selected == "Main", tostring(Hub._window.selected))

local labels, foundTitle, foundBody, foundButton = 0, false, false, false
walk(Hub._screen, function(node)
	if node.ClassName == "TextLabel" then
		labels += 1
		if node.Text == "FATCAT HUB" then
			foundTitle = true
		end
		if node.Text:find("Empty for now", 1, true) then
			foundBody = true
		end
	end
	if node.ClassName == "TextButton" and node.Text == "Reload window" then
		foundButton = true
	end
end)

check("project section header drawn", foundTitle)
check("project label drawn", foundBody)
check("project button drawn", foundButton, "no Reload window button")
check("window has content", labels >= 4, labels .. " labels")

-- Reloading the window from the project file must not lose the project rows.
local before = labels
Hub:Init(Hub._initOptions)
local after = 0
walk(Hub._screen, function(node)
	if node.ClassName == "TextLabel" then
		after += 1
	end
end)
check("reload keeps the mounted rows", after >= before, ("%d -> %d"):format(before, after))

print()
if projectFailures > 0 then
	print(("FAIL %d of %d project checks"):format(projectFailures, projectChecks))
	error("project harness failed")
end
print(("PASS %d project checks"):format(projectChecks))
