-- Sample content used by the visual harness only: fills the shell with one of
-- every component so the render shows real rows instead of an empty window.
local Hub = _G.FatCatHub
local page = Hub._window:Tab("Main")

-- The project tabs, when the renderer is asked for them. They are mounted by
-- src/FatCatHub.project.lua, which the render script loads when present.
for _, name in { "Decompiler", "Executor", "Hooks" } do
	local existing = Hub._window.pages[name]
	if existing and not Hub._window.selected then
		Hub._window:SelectTab(name)
	end
end
if Hub._window.selected == "Decompiler" then
	local box = Hub._window.pages["Decompiler"]:Section("Scripts", 1)
	box:Status("decompile: no disponible", "off")
	box:Divider()
	box:Label("0 script(s) visibles")
	local code = Hub._window.pages["Decompiler"]:Section("Source", 2)
	code:Code({
		Lines = {
			"-- Selecciona un script de la izquierda.",
			"",
			"-- Este executor no expone decompile().",
			'local function ejemplo()',
			'    return "hola"',
			"end",
		},
		Height = 300,
	})
	_G.__SAMPLE_DONE = true
end

local left = page:Section("Toggles")
left:Toggle({ Text = "Auto Protect", Flag = "autoProtect", Default = true })
left:Toggle({ Text = "Silent Aim", Flag = "silentAim", Description = "Uses the camera ray" })
left:Toggle({ Text = "Auto Reload", Flag = "autoReload", Default = true })

local sliders = page:Section("Values", 2)
sliders:Slider({ Text = "Field of View", Min = 0, Max = 120, Default = 70, Flag = "fov", Suffix = " deg" })
sliders:Slider({ Text = "Sensitivity", Min = 0.1, Max = 2, Default = 0.8, Decimals = 2, Flag = "sens" })
sliders:Cycle({ Text = "Aim Part", Options = { "Head", "Torso", "Nearest" }, Flag = "aimPart" })

local right = page:Section("Input", 2)
right:Input({ Text = "Webhook", Placeholder = "https://...", Flag = "webhook" })
right:Dropdown({ Text = "Priority", Options = { "Low", "Normal", "High" }, Flag = "priority" })
right:Keybind({ Text = "Panic Key", Flag = "panicKey", Default = "Q" })
right:Button({ Text = "Apply Changes", Flag = "apply" })
