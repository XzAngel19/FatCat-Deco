-- Fat Cat | loader.
--
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/main/src/FatCatHub.loader.lua"))()
--
-- Steps:
--   1. fetch src/FatCatHub.lua from the branch (raw GitHub),
--   2. compile it and report the exact line if the download is broken,
--   3. run it, then return _G.FatCatHub,
--   4. register getgenv().FatCatHubUnload so a re-run cleans up first.
--
-- The menu never assumes it was loaded this way: pasting src/FatCatHub.lua
-- straight into an executor works too.
--
-- Diagnostics: set _G.FatCatHubVerbose = true to print every stage.

-- Raw GitHub 404s until the branch actually contains src/FatCatHub.lua, so the
-- list below is tried in order and the first one that looks like the library
-- wins. That makes the loader work before the work is merged into main, and
-- stop caring about the branch afterwards.
-- Set _G.FatCatHubBranch = "some/branch" to force one.
local BRANCHES = {
	"main",
	"arena/3f9165cb-fatcat-deco",
	"arena/4918f801-fatcat-deco",
}

local function branchList()
	if _G.FatCatHubBranch then
		return { _G.FatCatHubBranch }
	end
	return BRANCHES
end

-- Two URL shapes per branch: raw.githubusercontent, and github.com/.../raw,
-- which redirects to the same file. The second one exists because a branch name
-- with a slash in it can be mis-split by the raw host.
local function urlsFor(branch)
	return {
		("https://raw.githubusercontent.com/XzAngel19/FatCat-Deco/%s/src/FatCatHub.lua"):format(branch),
		("https://github.com/XzAngel19/FatCat-Deco/raw/%s/src/FatCatHub.lua"):format(branch),
	}
end

local function verbose(...)
	if _G.FatCatHubVerbose then
		print("[Fat Cat]", ...)
	end
end

local function report(message)
	warn("[Fat Cat] " .. message)
end

-- Reject anything that did not come back as the library: a 404 page, an
-- empty body, or an HTML error page served by a proxy.
local function looksLikeSource(body)
	if type(body) ~= "string" then
		return false, "the response was a " .. typeof(body) .. ", not a string"
	end
	if #body < 1000 then
		return false, ("the response was only %d bytes - probably an error page"):format(#body)
	end
	if body:find("^%s*<!DOCTYPE") or body:find("^%s*<html") then
		return false, "the server returned HTML instead of Lua"
	end
	if not body:find("_G.FatCatHub", 1, true) then
		return false, "the file did not look like the Fat Cat library"
	end
	return true
end

-- Walk the branches; inside one branch try the cached call first, then the
-- plain one, because a few executors only implement the single-argument form.
local function download()
	local lastError = "no branch was reachable"
	local tried = {}

	for _, branch in branchList() do
		tried[#tried + 1] = branch

		for _, url in urlsFor(branch) do
			local calls = {
				function()
					return game:HttpGet(url, true)
				end,
				function()
					return game:HttpGet(url)
				end,
			}

			for _, fetch in calls do
				local ok, body = pcall(fetch)
				if ok then
					local valid, why = looksLikeSource(body)
					if valid then
						verbose("loaded from branch", branch)
						return body, nil, branch
					end
					lastError = why
					verbose(url .. ": " .. why)
				else
					lastError = tostring(body)
					verbose(url .. ": HttpGet failed: " .. lastError)
				end
			end
		end
	end

	return nil, lastError, nil, tried
end

-- Compile, and on failure take one line either side of the reported line so
-- the error is actionable instead of "something is wrong".
local function compile(source)
	local chunk, compileError = loadstring(source, "FatCatHub")
	if chunk then
		return chunk
	end

	local message = tostring(compileError)
	verbose("compile error:", message)

	local foundLine = message:match(":(%d+):")
	if foundLine then
		local number = tonumber(foundLine)
		-- The trailing newline and the non-greedy capture matter: a pattern
		-- that can match the empty string makes gmatch loop forever.
		local lines = {}
		for line in (source .. "\n"):gmatch("(.-)\n") do
			lines[#lines + 1] = line
		end
		for index = math.max(1, number - 2), math.min(#lines, number + 2) do
			warn(("%s %4d | %s"):format(index == number and ">" or " ", index, lines[index]))
		end
	end

	return nil, message
end

if _G.FatCatHub then
	pcall(function()
		_G.FatCatHub:Destroy()
	end)
end

getgenv().FatCatHubUnload = function()
	if _G.FatCatHub then
		pcall(function()
			_G.FatCatHub:Destroy()
		end)
	end
end

local source, downloadError, usedBranch, tried = download()
if not source then
	report("could not download the library. Tried: " .. table.concat(tried or {}, ", "))
	report(tostring(downloadError))
	report("if the menu is in a branch that is not listed, run this first:")
	report('  _G.FatCatHubBranch = "your/branch"')
	return nil
end
verbose(("downloaded %d bytes from %s"):format(#source, usedBranch))

local chunk, compileError = compile(source)
if not chunk then
	report("the downloaded library did not compile: " .. tostring(compileError))
	return nil
end

local ran, runtimeError = pcall(chunk)
if not ran then
	report("the library failed at runtime: " .. tostring(runtimeError))
	return nil
end

local Hub = _G.FatCatHub
if not Hub or not Hub._window then
	report("the library ran but built no window.")
	return nil
end

pcall(function()
	print(("[Fat Cat] ready - %s, press %s"):format(
		Hub._window.selected or "Main",
		tostring(Hub.menuKey or "RightShift")
	))
end)

return Hub
