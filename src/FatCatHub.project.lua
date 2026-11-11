-- FatCat Hub | project file.
--
-- This is the file a game ships: the library in src/FatCatHub.lua is the shell,
-- this is what fills it. It is empty on purpose - the window, tabs and search
-- are all there, but nothing is wired to a game yet.
--
--   loadstring(game:HttpGet("<url to this file>"))()
--
-- Everything below runs *after* the library has built its window, through
-- Hub:Mount. That is the whole point of Mount: a plain Hub:Init() call would
-- throw the window away and start over.

local Hub = _G.FatCatHub
if not Hub then
	warn("[FatCat Hub] the library is not loaded - run the loader first")
	-- No `return` here: this file gets concatenated after the library in the
	-- test harness, and a top-level return would end that chunk.
end

-- ==========================================================================
-- Tab
-- ==========================================================================

Hub:Mount(function(hub, window)
	local page = window:Tab("Main") or window:AddTab("Main")
	local box = page:Section("FatCat Hub", 1)
	box:Label("Empty for now - the shell is done, nothing is wired to a game yet.")
	box:Divider()
	box:Button({
		Text = "Reload window",
		Callback = function()
			hub:Init(hub._initOptions)
		end,
	})
end)

-- ==========================================================================
-- How a feature plugs in
-- ==========================================================================
--
-- Uncomment, then mirror the flag in your own code:
--
--   Hub:Mount(function(hub, window)
--       local box = window:Tab("Main"):Section("Movement", 1)
--       box:Toggle({
--           Text = "Sprint",
--           Description = "Hold LeftShift to run",
--           Default = false,
--           Flag = "sprint",
--           Callback = function(on) print("sprint", on) end,
--       })
--   end)
--
--   local looping = false
--   task.spawn(function()
--       while task.wait(0.1) do
--           local on = Hub.Values.sprint and true or false
--           if on ~= looping then
--               looping = on
--               -- apply it
--           end
--       end
--   end)
--
-- Hub.Setters.sprint(true)  -- same call the toggle makes
-- Hub.Values.sprint         -- always the current value
-- Hub:Save() / Hub:Load()   -- one JSON file for every flag
