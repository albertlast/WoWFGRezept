--[[
Load simulation for a busy launch phase. Not part of tests/run.lua (slow).

  lua tests/load.lua [addon users ...] [--minutes N] [--crafters 0.5]

Per size (default 50 100 200 addon users online):
  1. everyone logs in over 5 minutes and scans their professions
  2. 10 minutes of quiet so the pools settle
  3. measured window: a share of the users (crafters, default half) levels
     a profession, one skill point every 20 s, and learns a new recipe every
     5 minutes
     During the window members without the addon ask "!craft" in guild
     chat (one question every 15 s, every fifth one for something nobody
     crafts): answers per question and time to the first answer.
  4. a fresh install logs in; time until it holds 95% of the records

Messages queue up per sender at 800 bytes/s (ChatThrottleLib) by their
real wire size: CBOR, Deflate (LibDeflate, test-only), Base64, plus
AceComm's per-chunk overhead (H.WireSize). Records are realistic: two primary professions
with 40-120 recipes each, Cooking and First Aid, recipe and item IDs in the
ranges of the real game data.

Every client is the real addon code with its own pool, so memory grows with
users x records; 800 users do not fit. Message rates per user are measured
at several sizes; larger guilds are extrapolated by hand.
]]
local dir = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "tests"
local H = dofile(dir .. "/harness.lua")
-- Real sizes: CBOR -> Deflate -> Base64 per message (tests/vendor/LibDeflate).
H.realSizes = true

local sizes, minutes, crafterShare, off = {}, 10, 0.5, {}
local i = 1
while arg and arg[i] do
	if arg[i] == "--off" then
		-- Turn fixes off to measure each one: A (rank-up delay), B (no
		-- double requests, split), D (batches). E.g. --off B,D
		for f in arg[i + 1]:gmatch("%a") do off[f] = true end
		i = i + 1
	elseif arg[i] == "--minutes" then
		minutes, i = tonumber(arg[i + 1]), i + 1
	elseif arg[i] == "--crafters" then
		crafterShare, i = tonumber(arg[i + 1]), i + 1
	else
		sizes[#sizes + 1] = tonumber(arg[i])
	end
	i = i + 1
end
if #sizes == 0 then sizes = { 50, 100, 200 } end

local BANDWIDTH = 800
local PRIMARY = { 197, 171, 165, 164, 333, 202, 186, 182, 393 }
local COOKING, FIRST_AID = 185, 129

-- Recipe pools per profession: half classic IDs, half new Forever IDs (the
-- size of an ID matters for the wire size). Members of one profession share
-- the first recipes of its pool, like real players.
local pools = {}
local function pool(sl)
	if not pools[sl] then
		local list = {}
		for n = 1, 160 do
			local rid = n % 2 == 0 and (2000 + sl * 37 + n * 61) or (1229000 + sl * 311 + n * 97)
			local item = n % 2 == 0 and (2300 + sl * 13 + n * 29) or (247000 + sl * 211 + n * 83)
			list[n] = { rid, item }
		end
		pools[sl] = list
	end
	return pools[sl]
end

local function profession(sl, count, secondary)
	local recipes = {}
	for n = 1, count do
		local r = pool(sl)[n]
		recipes[r[1]] = r[2]
	end
	return { rank = 50 + count, maxRank = 300, name = "P" .. sl, recipes = recipes, secondary = secondary, known = count }
end

-- Applies --off to a client right after its login.
local function configure(client)
	local P = client.ns.Protocol
	if off.A then P.MinorDelay = function() return 60 end end
	if off.B then P.SPLIT_MIN, P.WANT_PATIENCE = math.huge, -1 end
	if off.D then P.batchPeers = setmetatable({}, { __newindex = function() end }) end
	return client
end

local function guid(n)
	return ("Player-1-%08X"):format(n)
end

local function kb(bytes) return bytes / 1024 end

local function run(n)
	math.randomseed(n)
	local world = H.NewWorld({ slowRoster = true, bandwidth = BANDWIDTH })
	local chars = {}
	for k = 1, n do
		local a = PRIMARY[(k - 1) % #PRIMARY + 1]
		local b = PRIMARY[(k + 3) % #PRIMARY + 1]
		chars[k] = world:AddChar({ guid = guid(k), name = "M" .. k, profs = {
			[a] = profession(a, math.random(40, 120)),
			[b] = profession(b, math.random(40, 120)),
			[COOKING] = profession(COOKING, math.random(10, 40), true),
			[FIRST_AID] = profession(FIRST_AID, math.random(5, 15), true),
		} })
	end

	local started = os.clock()
	-- 1. Logins over 5 minutes; a minute later everyone opens their
	-- professions one after the other.
	for k = 1, n do
		configure(world:Login(chars[k].guid))
		world:Run(300 / n)
	end
	world:Run(60)
	for slot = 1, 4 do
		for k = 1, n do
			local sls = {}
			for sl in pairs(chars[k].profs) do sls[#sls + 1] = sl end
			table.sort(sls)
			world.online[chars[k].guid]:OpenTradeSkill(sls[slot])
		end
		world:Run(3)
	end
	-- 2. Settle.
	world:Run(600)
	local recordCount, recipes = 0, 0
	for _, rec in pairs(world.online[chars[1].guid]:GuildData().chars) do
		recordCount = recordCount + 1
		for _, p in pairs(rec.profs) do
			for _ in pairs(p.recipes or {}) do recipes = recipes + 1 end
		end
	end

	-- 3. Measured window.
	world:ResetCounters()
	local crafters = {}
	for k = 1, n do
		if math.random() < crafterShare then crafters[#crafters + 1] = chars[k] end
	end
	local window = minutes * 60
	local step = 5
	-- !craft askers: guild members without the addon, one per question.
	local questions = {}
	local function ask(t)
		local q = #questions + 1
		local asker = world:AddChar({ guid = guid(100000 + q), name = "Asker" .. q })
		world:AddToGuild(asker.guid)
		local text
		if q % 5 == 0 then
			text = "!craft Thunderfury"
		else
			local c = chars[math.random(#chars)]
			local sl
			for s, p in pairs(c.profs) do if not p.secondary then sl = s break end end
			text = "!craft Recipe " .. pool(sl)[math.random(20)][1]
		end
		questions[q] = { asker = asker.name, at = world.clock.t, found = q % 5 ~= 0 }
		world:GuildChat(asker.name, text)
	end
	for t = step, window, step do
		if t % 15 == 0 then ask(t) end
		for idx, c in ipairs(crafters) do
			local client = world.online[c.guid]
			-- Spread the crafters over the 20 s rhythm.
			if (t + idx * step) % 20 == 0 then
				local sl = next(c.profs)
				for s, p in pairs(c.profs) do if not p.secondary then sl = s break end end
				local p = c.profs[sl]
				p.rank = math.min(p.maxRank, p.rank + 1)
				client:Fire("SKILL_LINES_CHANGED")
			end
			if (t + idx * 60) % 300 == 0 then
				for _, p in pairs(c.profs) do
					if not p.secondary and p.known < #pools[next(c.profs)] then
						p.known = p.known + 1
						break
					end
				end
				for sl, p in pairs(c.profs) do
					if not p.secondary then
						local r = pool(sl)[p.known]
						if r and not p.recipes[r[1]] then
							p.recipes[r[1]] = r[2]
							client:Fire("NEW_RECIPE_LEARNED", r[1])
						end
						break
					end
				end
			end
		end
		world:Run(step)
	end
	world:Run(30) -- the last questions get their answers
	local perMin = 60 / window
	local craft = { asked = #questions, double = 0, none = 0, found = { n = 0, sum = 0, max = 0 }, nobody = { n = 0, sum = 0, max = 0 } }
	for _, q in ipairs(questions) do
		local answers, first = 0, nil
		for _, w in ipairs(world.whispers) do
			if w.to == q.asker and w.text:find("[Guild Tradebook]", 1, true) then
				answers = answers + 1
				first = math.min(first or math.huge, w.at)
			end
		end
		if answers == 0 then craft.none = craft.none + 1 end
		if answers > 1 then craft.double = craft.double + 1 end
		if first then
			local s = q.found and craft.found or craft.nobody
			local latency = first - q.at
			s.n, s.sum, s.max = s.n + 1, s.sum + latency, math.max(s.max, latency)
		end
	end
	local recv, recvMax = 0, 0
	for g in pairs(world.online) do
		local b = world.recvBytes[g] or 0
		recv = recv + b
		if b > recvMax then recvMax = b end
	end
	local result = {
		n = n, records = recordCount, crafters = #crafters, recipesPerRecord = recipes / math.max(1, recordCount),
		msgsPerMin = world.messages * perMin,
		recPerMin = (world.records or 0) * perMin,
		bytesPerMin = world.bytes * perMin,
		recvPerClientPerSec = recv / n / window,
		recvMaxPerSec = recvMax / window,
		maxQueue = world.maxQueueDelay,
		queueByPrio = world.queueDelayByPrio,
		craft = craft,
		byType = H.Describe(world.byType),
		recBytes = ((world.bytesByType.R or 0) + (world.bytesByType.B or 0)) / math.max(1, world.records or 0),
	}

	-- 4. Fresh install.
	world:ResetCounters()
	local fresh = world:AddChar({ guid = guid(n + 1), name = "Fresh" })
	world:AddToGuild(fresh.guid)
	local cf = configure(world:Login(fresh.guid))
	local need = math.floor(recordCount * 0.95)
	local took
	for t = 10, 7200, 10 do
		world:Run(10)
		local have = 0
		for g, rec in pairs(cf:GuildData().chars) do
			if g ~= fresh.guid and rec.ver > 0 then have = have + 1 end
		end
		if have >= need then took = t break end
	end
	result.freshSeconds = took
	result.freshBytes = world.bytes
	result.freshRecords = world.records or 0
	result.cpu = os.clock() - started
	return result
end

local offList = {}
for f in pairs(off) do offList[#offList + 1] = f end
table.sort(offList)
print(("Load simulation: %d min window, %d%% crafting (1 skill point / 20 s, 1 recipe / 5 min), %d bytes/s per sender%s")
	:format(minutes, crafterShare * 100, BANDWIDTH, #offList > 0 and (", fixes off: " .. table.concat(offList, ",")) or ""))
local results = {}
for _, n in ipairs(sizes) do
	io.write(("  %d addon users ... "):format(n))
	io.flush()
	local r = run(n)
	results[#results + 1] = r
	print(("done (%.0f s CPU)"):format(r.cpu))
	print(("    records %d (%.0f recipes each), crafters %d"):format(r.records, r.recipesPerRecord, r.crafters))
	print(("    guild-wide: %.0f messages/min (%.0f records/min, %.0f B each), %.1f KB/min sent"):format(
		r.msgsPerMin, r.recPerMin, r.recBytes, kb(r.bytesPerMin)))
	print(("    received per client: %.2f KB/s average, %.2f KB/s max; longest send queue %.0f s"):format(
		kb(r.recvPerClientPerSec), kb(r.recvMaxPerSec), r.maxQueue))
	print(("    longest wait in the send queue by priority: ALERT %.1f s, NORMAL %.1f s, BULK %.1f s"):format(
		r.queueByPrio.ALERT or 0, r.queueByPrio.NORMAL or 0, r.queueByPrio.BULK or 0))
	print(("    messages: %s"):format(r.byType))
	local c = r.craft
	local function avg(s) return s.n > 0 and s.sum / s.n or 0 end
	print(("    !craft: %d questions, %d answered twice or more, %d unanswered; first answer after %.1f s on average (max %.1f s), \"nobody\" after %.1f s (max %.1f s)"):format(
		c.asked, c.double, c.none, avg(c.found), c.found.max, avg(c.nobody), c.nobody.max))
	print(("    fresh install: 95%% of %d records after %s (%.0f KB, %d records sent)"):format(
		r.records, r.freshSeconds and (r.freshSeconds .. " s") or "more than 2 h", kb(r.freshBytes), r.freshRecords))
end
