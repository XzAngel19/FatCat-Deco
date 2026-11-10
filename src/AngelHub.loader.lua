-- Angel Hub | loader.
--
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/main/src/AngelHub.loader.lua"))()
--
-- What it does, in order:
--   1. fetches src/AngelHub.lua from the branch (raw GitHub, cached per call),
--   2. compiles it and reports the exact line on a syntax error,
--   3. runs it, then hands back _G.AngelHub,
--   4. knows how to clean up: getgenv().AngelHubUnload() destroys the GUI.
--
-- The hub itself never assumes it was loaded this way: it also works pasted
-- straight into an executor.

local BASE = "https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/main/src"
local HUB_URL = BASE .. "/AngelHub.lua"

-- One key so a re-run replaces the previous copy instead of stacking two.
getgenv().AngelHubUnload = function()
	if _G.AngelHub then
		pcall(function()
			_G.AngelHub:Destroy()
		end)
	end
end

local ok, source = pcall(function()
	return game:HttpGet(HUB_URL, true)
end)

if not ok or type(source) ~= "string" or #source < 1000 then
	warn("[Angel Hub] could not download the library from " .. HUB_URL)
	warn("[Angel Hub] " .. tostring(source))
	return
end

local chunk, compileError = loadstring(source, "AngelHub")

if not chunk then
	warn("[Angel Hub] the downloaded library did not compile: " .. tostring(compileError))
	return
end

local ran, runtimeError = pcall(chunk)

if not ran then
	warn("[Angel Hub] the library failed at runtime: " .. tostring(runtimeError))
	return
end

local Hub = _G.AngelHub

if not Hub or not Hub._window then
	warn("[Angel Hub] the library ran but built no window.")
	return
end

-- Anything the executor shows in its console.
pcall(function()
	print(("[Angel Hub] ready - %s / %s to toggle"):format(
		Hub._window.selected or "Main",
		tostring(Hub.menuKey or "RightShift")
	))
end)

return Hub
