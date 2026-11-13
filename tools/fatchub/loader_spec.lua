-- Assertions for src/FatCatHub.loader.lua. Every case is a response body the
-- loader has to survive: an HTML error page, a truncated file, a file that is
-- not the bundle, a syntax error in the bundle, an HttpGet that throws, and
-- the happy path.
--
-- The loader now downloads src/FatCatHub.bundle.lua (twenty-one modules plus
-- the bootstrapper) instead of src/FatCatHub.lua. The mock's fake body still
-- has to satisfy looksLikeSource, so the happy path carries the two markers
-- the real bundle has in its header: "Fat Cat Project" and "FatCatInit".

-- A body that satisfies the loader's two markers, then whatever the case adds.
local function bundleBody(payload, lines)
	local header = "-- Fat Cat Project 2.1.0 -- generated\n-- see FatCatInit\n"
	-- 64 chars per line: the loader rejects a body under 2000 characters, so
	-- 40 lines is the cheapest body that clears its "probably an error page"
	-- check with room to spare.
	local filler = string.rep("--" .. string.rep("x", 60) .. "\n", lines or 40)
	return header .. filler .. (payload or "")
end

local cases = {
	{ name = "html error page", body = "<!DOCTYPE html><body>404 not found</body>", expect = "fail" },
	{ name = "truncated body", body = string.rep("-- filler\n", 10), expect = "fail" },
	{ name = "wrong file", body = string.rep("local a = 1\n", 400), expect = "fail" },
	{ name = "syntax error", body = bundleBody("local broken = )(\n"), expect = "compile" },
	{ name = "HttpGet throws", body = nil, expect = "fail" },
	{ name = "happy path", body = bundleBody(), expect = "ok" },
}

local passed, failed = 0, 0
local function check(condition, label)
	if condition then
		passed = passed + 1
	else
		failed = failed + 1
		REALPRINT("FAIL " .. label)
	end
end

for _, case in ipairs(cases) do
	BODY = case.body
	LOGS = {}
	URLS = {}
	FETCH_COUNT = 0
	_G.FatCatHub = nil

	local ok, returned = pcall(runLoader)

	local log = table.concat(LOGS, "\n")

	check(ok, case.name .. ": loader did not raise")
	check(LAST_URL ~= nil and LAST_URL:find("FatCatHub.bundle.lua", 1, true) ~= nil,
		case.name .. ": fetched the bundle")
	check(URLS[1]:find("/main/", 1, true) ~= nil, case.name .. ": tried main first")

	if case.expect == "ok" or case.expect == "compile" then
		check(FETCH_COUNT == 1, case.name .. ": stopped at the first good response")
	else
		-- Nothing loaded, so the loader should have walked to the next branch.
		local sawFallback = false
		for _, url in ipairs(URLS) do
			if url:find("arena/292e8b51-fatcat-deco", 1, true) then
				sawFallback = true
			end
		end
		check(sawFallback, case.name .. ": fell back to the working branch")
		check(FETCH_COUNT >= 4, case.name .. ": retried per branch and per HttpGet form")
	end

	if case.expect == "ok" then
		check(type(returned) == "table", case.name .. ": returned the hub table")
		check(_G.FatCatHub ~= nil, case.name .. ": published _G.FatCatHub")
		check(log:find("ready", 1, true) ~= nil, case.name .. ": announced readiness")
	elseif case.expect == "compile" then
		check(returned == nil, case.name .. ": returned nothing")
		check(log:find("did not compile", 1, true) ~= nil, case.name .. ": reported the compile failure")
		check(log:find("unexpected symbol", 1, true) ~= nil, case.name .. ": kept the compiler message")
		check(log:find(">   37", 1, true) ~= nil, case.name .. ": printed the offending line")
		check(_G.FatCatHub == nil, case.name .. ": did not publish a broken hub")
	else
		check(returned == nil, case.name .. ": returned nothing")
		check(log:find("could not download", 1, true) ~= nil, case.name .. ": said the download failed")
		check(_G.FatCatHub == nil, case.name .. ": did not publish a broken hub")
	end
end

-- The real bundle, byte for byte, has to survive the same path: markers,
-- size check, compile, and execution. A body built to satisfy the checks can
-- drift from the artifact that actually ships, and this is the case that
-- notices. REAL_BUNDLE is filled in by tools/test_fatchub_loader.sh.
if REAL_BUNDLE and #REAL_BUNDLE > 0 then
	BODY = REAL_BUNDLE
	URLS = {}
	LOGS = {}
	FETCH_COUNT = 0
	_G.FatCatHub = nil
	for key in pairs(_G) do
		if key == "FatCatProject" then
			_G.FatCatProject = nil
		end
	end

	local ok, returned = pcall(runLoader)
	local log = table.concat(LOGS, "\n")

	check(ok, "real bundle: loader did not raise")
	check(FETCH_COUNT == 1, "real bundle: one fetch was enough")
	check(returned ~= nil and type(returned) == "table", "real bundle: returned the hub")
	check(_G.FatCatHub ~= nil, "real bundle: published _G.FatCatHub")
	check(log:find("ready", 1, true) ~= nil, "real bundle: announced readiness")
	if _G.FatCatHub then
		check(type(_G.FatCatHub.Destroy) == "function", "real bundle: hub is usable")
		_G.FatCatHub = nil
	end
end

-- An explicit branch overrides the list.
BODY = nil
URLS = {}
LOGS = {}
_G.FatCatHubBranch = "some/other-branch"
pcall(runLoader)
check(#URLS == 4, "honoured _G.FatCatHubBranch: one branch, two URLs, two forms")
check(URLS[1] ~= nil and URLS[1]:find("some/other%-branch") ~= nil, "used the branch it was told to")
_G.FatCatHubBranch = nil

-- The unload key is registered before the download, so an executor that dies
-- mid-fetch still leaves the user a working unload.
check(type(getgenv().FatCatProjectUnload) == "function", "registered FatCatProjectUnload")

REALPRINT(("PASS %d loader checks"):format(passed))
if failed > 0 then
	error(("%d loader check(s) failed"):format(failed), 0)
end
