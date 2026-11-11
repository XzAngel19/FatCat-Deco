-- Assertions for src/FatCatHub.loader.lua. Every case is a response body the
-- loader has to survive: an HTML error page, a truncated file, a file that is
-- not the library, a syntax error in the library, an HttpGet that throws, and
-- the happy path.

local cases = {
	{ name = "html error page", body = "<!DOCTYPE html><body>404 not found</body>", expect = "fail" },
	{ name = "truncated body", body = string.rep("-- filler\n", 10), expect = "fail" },
	{ name = "wrong file", body = string.rep("local a = 1\n", 400), expect = "fail" },
	{ name = "syntax error", body = string.rep("local broken = )(\n", 100) .. "_G.FatCatHub = 1\n", expect = "compile" },
	{ name = "HttpGet throws", body = nil, expect = "fail" },
	{ name = "happy path", body = string.rep("local a = 1\n", 100) .. "_G.FatCatHub = 1\n", expect = "ok" },
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
	check(LAST_URL ~= nil and LAST_URL:find("FatCatHub.lua", 1, true) ~= nil, case.name .. ": fetched FatCatHub.lua")
	check(URLS[1]:find("/main/", 1, true) ~= nil, case.name .. ": tried main first")

	if case.expect == "ok" or case.expect == "compile" then
		check(FETCH_COUNT == 1, case.name .. ": stopped at the first good response")
	else
		-- Nothing loaded, so the loader should have walked to the next branch.
		local sawFallback = false
		for _, url in ipairs(URLS) do
			if url:find("arena/4918f801-fatcat-deco", 1, true) then
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

-- An explicit branch overrides the list.
BODY = nil
URLS = {}
LOGS = {}
_G.FatCatHubBranch = "some/other-branch"
pcall(runLoader)
check(#URLS <= 2, "honoured _G.FatCatHubBranch")
check(URLS[1] ~= nil and URLS[1]:find("some/other%-branch") ~= nil, "used the branch it was told to")
_G.FatCatHubBranch = nil

-- Unload key is registered even when the download later fails.
check(type(getgenv().FatCatHubUnload) == "function", "registered FatCatHubUnload")

REALPRINT(("PASS %d loader checks"):format(passed))
if failed > 0 then
	error(("%d loader check(s) failed"):format(failed), 0)
end
