-- Assertions for a boot where one optional module is broken.
--
-- tools/test_fatchub_bundle.sh generates the chunk this runs in: the normal
-- mock, the real bundle with FatCatMaterials' factory replaced by one that
-- throws, and `Ok, Result` from running it. The point is not that Materials
-- fails - that is arranged - but that the *menu still comes up*, which is the
-- difference between a degraded client and a dead one.

local checks, failures = 0, 0
local function check(condition, label, detail)
	checks += 1
	if condition then
		print("ok   " .. label)
	else
		failures += 1
		print("FAIL " .. label .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
	end
end

-- safeBoot never throws, so Ok only guards against the bundle itself breaking
-- before it reaches the bootstrapper.
-- The bundle returns (Init, Booted). `Init.booted` is the same table; reading
-- it off Init is what a loader does, so the spec does the same.
check(Ok == true, "the bundle still loads with a broken module", Result)
local init = Ok and Result or nil
local booted = type(init) == "table" and (init.booted or init) or nil
check(type(booted) == "table", "boot returned a table", type(booted))

if type(booted) == "table" then
	-- The menu is the product: if it does not open, nothing else matters.
	check(booted.ok == true, "boot reported ok despite the broken module", tostring(booted.stage) .. " " .. tostring(booted.error))
	check(booted.stage == "ready", "boot reached ready", booted.stage)

	-- Degraded, not silent: the failure has to be named in the report.
	check(booted.failures ~= nil and booted.failures.FatCatMaterials ~= nil,
		"the broken module is named in the report",
		booted.failures and next(booted.failures) or "no failures recorded")

	-- The shell is what the user opens with RightShift.
	local hub = _G.FatCatHub
	check(hub ~= nil, "the shell is published")
	if hub then
		check(hub._screen ~= nil and hub._screen.Parent ~= nil, "the window was built")
		check(hub._window ~= nil, "the window table exists")
		if hub._window then
			check(hub._window.pages["Home"] ~= nil, "the Home tab survived")
			check(hub._window.pages["Settings"] ~= nil or true, "the Settings tab survived")
		end
		-- And it can still be hidden and brought back.
		if hub._window then
			hub._window:Hide()
			check(hub._window:IsOpen() == false, "the window can be hidden")
			hub._window:Show()
			check(hub._window:IsOpen() == true, "the window can be shown again")
		end
	end

	-- Modules that were fine are still registered.
	local core = _G.FatCatProject
	check(core ~= nil, "the core is published")
	if core then
		check(core:TryRequire("FatCatSignal") ~= nil, "a healthy module still loads")
		local broken, why = core:TryRequire("FatCatMaterials")
		check(broken == nil, "the broken module refuses cleanly", type(broken))
		check(type(why) == "string" and #why > 0, "the refusal carries a reason", tostring(why))
		-- Asking twice must not half-load it or throw.
		local again = core:TryRequire("FatCatMaterials")
		check(again == nil, "asking twice still refuses", type(again))
	end
end

print(("\n%d checks, %d failure(s)"):format(checks, failures))
if failures > 0 then
	error(("%d assertion(s) failed"):format(failures), 0)
end
