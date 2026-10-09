--[[
"!craft <item>": lets members without the addon ask who can craft something.
The answer is a whisper to the asker, so guild chat only shows the question.

Asked in guild chat: all addon users see the question at the same time.
They rank themselves with the same deterministic hash ranking as the sync
partner election (Protocol.ElectionRank): rank 0 answers after a short
delay, rank 1 a few seconds later only if nobody answered, and so on. The
answering client first sends a tiny addon message (X) so the others cancel
their pending answer.

Whispered to an addon user: only that user sees it and answers right away -
if the asker is in the guild. Guild recipes are not told to strangers.
]]
local _, ns = ...

local L, Index, Util, Store, Roster = ns.L, ns.Index, ns.Util, ns.Store, ns.Roster
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
		-- Same person, online on another character: "Bobalt (Bob*)". For the
		-- asker, your own offline alts are reachable through you.
		local via = c.via and c.via.name or (c.isAlt and not c.online and Util.PlayerName())
		if c.online then
			name = name .. "*"
			anyOnline = true
		elseif via then
			name = name .. " (" .. Util.ShortName(via) .. "*)"
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

-- The answer is a real chat message: impossible during a chat lockdown;
-- another client further down the ranking answers instead.
-- (AreOutgoingAddonChatMessagesRestricted is true on the Forever beta realm,
-- yet chat messages from addons go out there, so it is not checked.)
local function lockedDown()
	return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

ChatResponder.sent = {}   -- [answer text] = GetTime(): our own whisper echo is hidden

-- Whisper target as Blizzard builds it: "First Last" on your own realm.
-- Errors are logged instead of raised: script errors are often hidden, and
-- a failing answer must not go unnoticed in "/gtb log".
local function whisper(text, asker)
	local target = Util.ShortName(Util.NormalizeName(asker))
	ChatResponder.sent[text] = GetTime()
	local send = C_ChatInfo.SendChatMessage or SendChatMessage
	local ok, err = pcall(send, text, "WHISPER", nil, target)
	if not ok then
		ns.Debug("!craft: whispering the answer to", target, "failed:", tostring(err))
	end
end

-- "To Anna: [Guild Tradebook] ..." would clutter the answering player's
-- chat; the answer is in "/gtb log" instead.
local function hideOwnAnswer(_, _, text)
	local at = ChatResponder.sent[text]
	return at ~= nil and GetTime() - at < 10
end

local function recentlyAnswered(key)
	local at = ChatResponder.answered[key]
	return at and GetTime() - at < ChatResponder.REPEAT_WINDOW
end

-- asker: name to whisper. private: whispered to us, nobody else saw it, so
-- there is nobody to tell that it was answered.
function ChatResponder.Answer(key, query, asker, private)
	if recentlyAnswered(key) then
		ns.Debug("!craft:", query, "- answered meanwhile")
		return
	end
	if lockedDown() then
		ns.Debug("!craft:", query, "- chat lockdown, not answering")
		return
	end
	local wait = ChatResponder.MIN_GAP - (GetTime() - ChatResponder.lastAnswer)
	if wait > 0 then
		ns.Debounce("craftq" .. key, wait, function() ChatResponder.Answer(key, query, asker, private) end)
		return
	end
	ChatResponder.answered[key] = GetTime()
	ChatResponder.lastAnswer = GetTime()
	if not private then
		ns.Protocol.Send({ t = "X", k = key }, "GUILD", nil, "ALERT")
	end
	local answer = ChatResponder.BuildAnswer(query, Index.Search(query, 0), Index.Crafters)
	ns.Debug("!craft:", query, "- whispering", tostring(asker) .. ":", answer)
	whisper(answer, asker)
end

-- The key names one question on every client: the query and the asker's
-- GUID (12th event value). Not the name: clients see it in different forms
-- (with or without realm), and the "answered" signal (X) must match.
function ChatResponder.QueryKey(query, askerGUID, playerName)
	return Util.Hash(query:lower() .. "|" .. (askerGUID or Util.NormalizeName(playerName) or ""))
end

-- Whom to whisper: the roster's name for the asker's GUID (one reliable
-- form), else the name from the chat event.
local function askerName(askerGUID, playerName)
	return (askerGUID and Roster.NameOf(askerGUID)) or playerName
end

function ChatResponder.OnGuildChat(_, text, playerName, _, _, _, _, _, _, _, _, _, askerGUID)
	local ok, query = pcall(ChatResponder.ParseQuery, text)
	if not ok or not query then return end
	if not ns.db or not ns.GetGuildData() then return end
	if not ns.db.options.chatResponder then
		ns.Debug("!craft:", query, "- answering is turned off (/gtb chatbot)")
		return
	end
	if type(askerGUID) ~= "string" or askerGUID == "" then askerGUID = nil end
	local key = ChatResponder.QueryKey(query, askerGUID, playerName)
	if recentlyAnswered(key) then
		ns.Debug("!craft:", query, "- already answered within a minute")
		return
	end
	local rank = ns.Protocol.ElectionRank("craft:" .. key, UnitGUID("player"))
	if not rank or rank >= ChatResponder.RANKS then
		ns.Debug("!craft:", query, "- rank", tostring(rank), ", others answer first")
		return
	end
	local delay = rank * ChatResponder.SLOT + ns.RandomDelay(0.3, 0.8)
	ns.Debug("!craft:", query, "from", tostring(playerName), "- rank", rank, ", answering in", ("%.1f s"):format(delay),
		"(key " .. Store.FormatInt(key) .. ")")
	local asker = askerName(askerGUID, playerName)
	ns.Debounce("craftq" .. key, delay, function() ChatResponder.Answer(key, query, asker) end)
end

-- "!craft <item>" whispered to us: nobody else saw it, answer right away.
-- Only guild members get an answer.
function ChatResponder.OnWhisper(_, text, playerName, _, _, _, _, _, _, _, _, _, askerGUID)
	local ok, query = pcall(ChatResponder.ParseQuery, text)
	if not ok or not query then return end
	if not ns.db or not ns.GetGuildData() then return end
	if type(askerGUID) ~= "string" or askerGUID == "" then
		askerGUID = Roster.GuidByName(playerName or "")
	end
	if not (askerGUID and Roster.IsMember(askerGUID)) then
		ns.Debug("!craft:", query, "whispered by", tostring(playerName), "- not in the guild, no answer")
		return
	end
	if not ns.db.options.chatResponder then
		ns.Debug("!craft:", query, "(whisper) - answering is turned off (/gtb chatbot)")
		return
	end
	local key = ChatResponder.QueryKey(query, askerGUID, playerName)
	if recentlyAnswered(key) then
		ns.Debug("!craft:", query, "(whisper) - already answered within a minute")
		return
	end
	ns.Debug("!craft:", query, "whispered by", tostring(playerName))
	ChatResponder.Answer(key, query, askerName(askerGUID, playerName), true)
end

-- Another addon user answered this question.
function ChatResponder.OnAnswered(key)
	ChatResponder.answered[key] = GetTime()
	if ns.IsPending("craftq" .. key) then
		ns.Debug("!craft: another client answered first")
	else
		ns.Debug("!craft: answered by another client (key " .. Store.FormatInt(key) .. ")")
	end
	ns.Cancel("craftq" .. key)
end

function ChatResponder.Start()
	ns.RegisterEvent("CHAT_MSG_GUILD", ChatResponder.OnGuildChat)
	ns.RegisterEvent("CHAT_MSG_WHISPER", ChatResponder.OnWhisper)
	ns.On("CraftQueryAnswered", ChatResponder.OnAnswered)
	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then
		addFilter("CHAT_MSG_WHISPER_INFORM", hideOwnAnswer)
	end
end
