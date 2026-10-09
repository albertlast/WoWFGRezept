--[[
"!craft <item>" in guild chat: lets members without the addon ask who can
craft something. Exactly one addon user answers in guild chat.

All addon users see the question at the same time. They rank themselves with
the same deterministic hash ranking as the sync partner election
(Protocol.ElectionRank): rank 0 answers after a short delay, rank 1 a few
seconds later only if nobody answered, and so on. The answering client first
sends a tiny addon message (X) so the others cancel their pending answer.
]]
local _, ns = ...

local L, Index, Util = ns.L, ns.Index, ns.Util
local ChatResponder = { answered = {}, lastAnswer = 0 }
ns.ChatResponder = ChatResponder

ChatResponder.COMMANDS = { "!craft", "!herstellen" }
ChatResponder.RANKS = 4           -- only the first ranks ever answer
ChatResponder.SLOT = 2            -- seconds between ranks
ChatResponder.REPEAT_WINDOW = 60  -- the same question is answered once per minute
ChatResponder.MIN_GAP = 3         -- seconds between two answers of this client
ChatResponder.MAX_LENGTH = 255

-- "!craft Mooncloth Bag" -> "Mooncloth Bag", or nil.
function ChatResponder.ParseQuery(text)
	if type(text) ~= "string" then return nil end
	local lower = text:lower()
	for _, cmd in ipairs(ChatResponder.COMMANDS) do
		if lower:sub(1, #cmd + 1) == cmd .. " " then
			local query = text:sub(#cmd + 2):gsub("^%s+", ""):gsub("%s+$", "")
			if #query >= 3 then
				return query
			end
		end
	end
	return nil
end

local function crafterNames(crafters, max)
	local names, anyOnline = {}, false
	for i, c in ipairs(crafters) do
		if i > max then
			names[#names + 1] = "+" .. (#crafters - max)
			break
		end
		local name = Util.ShortName(c.name)
		if c.online then
			name = name .. "*"
			anyOnline = true
		end
		names[#names + 1] = name
	end
	return table.concat(names, ", "), anyOnline
end

--[[
Pure core: builds the chat answer.
  results        = Index.Search(query, 0) entries ({recipeID, name})
  craftersOf(id) = Index.Crafters(id)
]]
function ChatResponder.BuildAnswer(query, results, craftersOf)
	local q = query:lower()
	local picks = {}
	for _, r in ipairs(results) do
		if r.name:lower() == q then picks[#picks + 1] = r end
	end
	if #picks == 0 then picks = results end

	local text
	if #picks == 0 then
		text = L.CHAT_NONE:format(query)
	elseif #picks > 3 then
		local names = {}
		for i = 1, 3 do names[i] = picks[i].name end
		text = L.CHAT_MANY:format(#picks, query, table.concat(names, ", "))
	else
		local parts, anyOnline = {}, false
		for _, r in ipairs(picks) do
			local names, online = crafterNames(craftersOf(r.recipeID), 3)
			anyOnline = anyOnline or online
			parts[#parts + 1] = r.name .. ": " .. names
		end
		text = L.CHAT_PREFIX .. " " .. table.concat(parts, "; ")
		if anyOnline then
			text = text .. " " .. L.CHAT_ONLINE_HINT
		end
	end
	if #text > ChatResponder.MAX_LENGTH then
		text = text:sub(1, ChatResponder.MAX_LENGTH - 3) .. "..."
	end
	return text
end

local function lockedDown()
	return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

local function sendGuildChat(text)
	if C_ChatInfo.SendChatMessage then
		C_ChatInfo.SendChatMessage(text, "GUILD")
	else
		SendChatMessage(text, "GUILD")
	end
end

local function recentlyAnswered(key)
	local at = ChatResponder.answered[key]
	return at and GetTime() - at < ChatResponder.REPEAT_WINDOW
end

function ChatResponder.Answer(key, query)
	if recentlyAnswered(key) or lockedDown() then return end
	local wait = ChatResponder.MIN_GAP - (GetTime() - ChatResponder.lastAnswer)
	if wait > 0 then
		ns.Debounce("craftq" .. key, wait, function() ChatResponder.Answer(key, query) end)
		return
	end
	ChatResponder.answered[key] = GetTime()
	ChatResponder.lastAnswer = GetTime()
	ns.Protocol.Send({ t = "X", k = key }, "GUILD", nil, "ALERT")
	sendGuildChat(ChatResponder.BuildAnswer(query, Index.Search(query, 0), Index.Crafters))
end

function ChatResponder.OnGuildChat(_, text, playerName)
	if not ns.db or not ns.db.options.chatResponder or not ns.GetGuildData() then return end
	local query = ChatResponder.ParseQuery(text)
	if not query then return end
	local key = Util.Hash(query:lower() .. "|" .. (Util.NormalizeName(playerName) or ""))
	if recentlyAnswered(key) then return end
	local rank = ns.Protocol.ElectionRank("craft:" .. key, Util.NormalizeName(UnitName("player")))
	if not rank or rank >= ChatResponder.RANKS then return end
	local delay = rank * ChatResponder.SLOT + ns.RandomDelay(0.3, 0.8)
	ns.Debounce("craftq" .. key, delay, function() ChatResponder.Answer(key, query) end)
end

-- Another addon user answered this question.
function ChatResponder.OnAnswered(key)
	ChatResponder.answered[key] = GetTime()
	ns.Cancel("craftq" .. key)
end

function ChatResponder.Start()
	ns.RegisterEvent("CHAT_MSG_GUILD", ChatResponder.OnGuildChat)
	ns.On("CraftQueryAnswered", ChatResponder.OnAnswered)
end
