local ADDON, ns = ...

ns.name = ADDON
ns.PREFIX = "GuildTradebook"
-- Major protocol version: messages with a different value are ignored.
ns.PROTO = 1

-- Internal callbacks -----------------------------------------------------------

local listeners = {}

function ns.On(name, fn)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end

function ns.Emit(name, ...)
	local list = listeners[name]
	if not list then return end
	for i = 1, #list do
		list[i](...)
	end
end

-- Game events ------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = eventHandlers[event]
	if not list then return end
	for i = 1, #list do
		list[i](event, ...)
	end
end)

function ns.RegisterEvent(event, fn)
	if not eventHandlers[event] then
		eventHandlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(eventHandlers[event], fn)
end

-- Time and timers --------------------------------------------------------------

-- Server time is shared by every client, which is what makes it usable as a
-- record version (see Data/Store.lua).
function ns.Now()
	return GetServerTime()
end

-- Returns a handle with :Cancel().
function ns.After(seconds, fn)
	return C_Timer.NewTimer(seconds, fn)
end

function ns.RandomDelay(minSeconds, maxSeconds)
	return minSeconds + math.random() * (maxSeconds - minSeconds)
end

-- Keyed one-shot timers. At most one run per key is pending at any time.
local keyed = {}

local function startKeyed(key, seconds, fn)
	local entry = { due = GetTime() + seconds, fn = fn }
	entry.timer = ns.After(seconds, function()
		if keyed[key] ~= entry then return end
		keyed[key] = nil
		entry.fn()
	end)
	keyed[key] = entry
end

function ns.Cancel(key)
	local entry = keyed[key]
	if entry then
		entry.timer:Cancel()
		keyed[key] = nil
	end
end

function ns.IsPending(key)
	return keyed[key] ~= nil
end

-- Trailing debounce: runs `seconds` after the last call with this key.
function ns.Debounce(key, seconds, fn)
	ns.Cancel(key)
	startKeyed(key, seconds, fn)
end

-- Runs at the earliest requested time: a pending run is never postponed, but a
-- request with a shorter delay pulls it forward.
function ns.ScheduleEarliest(key, seconds, fn)
	local entry = keyed[key]
	if entry and entry.due <= GetTime() + seconds then
		entry.fn = fn
		return
	end
	ns.Cancel(key)
	startKeyed(key, seconds, fn)
end

-- Output -----------------------------------------------------------------------

local LOG_SIZE = 200
ns.log = {}

function ns.Print(...)
	print("|cff33ff99" .. ns.L.TITLE .. "|r:", ...)
end

function ns.Debug(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	local line = table.concat(parts, " ")
	table.insert(ns.log, line)
	if #ns.log > LOG_SIZE then
		table.remove(ns.log, 1)
	end
	if ns.db and ns.db.options.debug then
		print("|cff999999[GTB]|r " .. line)
	end
end
