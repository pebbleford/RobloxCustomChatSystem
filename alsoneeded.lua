-- Chat Server Script
-- Handles all server-side chat functionality: messages, filtering, commands, moderation

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")

-- DataStore for muted players
local MutedPlayersStore = DataStoreService:GetDataStore("MutedPlayers_v1")

-- Get remotes
local ChatRemotes = ReplicatedStorage:WaitForChild("ChatRemotes")
local SendMessage = ChatRemotes:WaitForChild("SendMessage")
local ReceiveMessage = ChatRemotes:WaitForChild("ReceiveMessage")
local DeleteMessage = ChatRemotes:WaitForChild("DeleteMessage")
local MutePlayer = ChatRemotes:WaitForChild("MutePlayer")
local GetMutedPlayers = ChatRemotes:WaitForChild("GetMutedPlayers")
local GetChatHistory = ChatRemotes:WaitForChild("GetChatHistory")
local ExecuteCommand = ChatRemotes:WaitForChild("ExecuteCommand")

-- Get admin remotes for permission checking
local AdminRemotes = ReplicatedStorage:WaitForChild("AdminRemotes")
local IsAdminFunc = AdminRemotes:WaitForChild("IsAdmin")
local IsOwnerFunc = AdminRemotes:WaitForChild("IsOwner")
local IsFounderFunc = AdminRemotes:WaitForChild("IsFounder")

-- Default chat is disabled on client side (in ChatUIScript)

-- Message history (circular buffer)
local MessageHistory = {}
local MAX_HISTORY = 100

-- Muted players (loaded from DataStore)
local MutedPlayers = {}

-- Rate limiting
local RateLimits = {} -- {[userId] = {timestamps = {}}}
local MAX_MESSAGES = 5
local RATE_WINDOW = 10 -- seconds

-- Load muted players from DataStore
local function loadMutedPlayers()
	local success, data = pcall(function()
		return MutedPlayersStore:GetAsync("MutedList")
	end)
	
	if success and data then
		MutedPlayers = data
		print("[ChatServer] Loaded muted players from DataStore")
	else
		print("[ChatServer] No muted players found or failed to load")
	end
end

-- Save muted players to DataStore
local function saveMutedPlayers()
	local success, err = pcall(function()
		MutedPlayersStore:SetAsync("MutedList", MutedPlayers)
	end)
	
	if success then
		print("[ChatServer] Muted players saved to DataStore")
	else
		warn("[ChatServer] Failed to save muted players: " .. tostring(err))
	end
end

-- Load muted players on startup
loadMutedPlayers()

-- Helper function to find player by name
local function findPlayer(name)
	for _, player in pairs(Players:GetPlayers()) do
		if player.Name:lower() == name:lower() then
			return player
		end
	end
	return nil
end

-- Check if player is muted
local function isMuted(player)
	return MutedPlayers[player.Name:lower()] ~= nil
end

-- Check rate limit
local function checkRateLimit(player)
	local userId = player.UserId
	local currentTime = os.time()
	
	if not RateLimits[userId] then
		RateLimits[userId] = {timestamps = {}}
	end
	
	local timestamps = RateLimits[userId].timestamps
	
	-- Remove old timestamps
	local newTimestamps = {}
	for _, timestamp in ipairs(timestamps) do
		if currentTime - timestamp < RATE_WINDOW then
			table.insert(newTimestamps, timestamp)
		end
	end
	timestamps = newTimestamps
	RateLimits[userId].timestamps = timestamps
	
	-- Check if exceeded
	if #timestamps >= MAX_MESSAGES then
		return false
	end
	
	-- Add current timestamp
	table.insert(timestamps, currentTime)
	return true
end

-- Add message to history
local function addToHistory(messageData)
	table.insert(MessageHistory, messageData)
	if #MessageHistory > MAX_HISTORY then
		table.remove(MessageHistory, 1)
	end
end

-- Filter message using TextService
local function filterMessage(player, text, targetPlayer)
	local success, result = pcall(function()
		local textObject = TextService:FilterStringAsync(text, player.UserId)
		if targetPlayer then
			-- Private message filtering
			return textObject:GetNonChatStringForUserAsync(targetPlayer.UserId)
		else
			-- Public message filtering
			return textObject:GetNonChatStringForBroadcastAsync()
		end
	end)
	
	if success then
		return result
	else
		warn("[ChatServer] Failed to filter message: " .. tostring(result))
		return "[Message failed to filter]"
	end
end

-- Create message data structure
local function createMessageData(sender, text, messageType, targetPlayer)
	-- Check admin status directly on server
	local isAdmin = false
	local isOwner = false
	local isFounder = false
	
	if sender and sender.UserId then
		pcall(function()
			isAdmin = IsAdminFunc.OnServerInvoke(sender)
			isOwner = IsOwnerFunc.OnServerInvoke(sender)
			isFounder = IsFounderFunc.OnServerInvoke(sender)
		end)
	end
	
	return {
		MessageId = tostring(os.time()) .. "_" .. (sender.UserId or 0),
		Sender = sender.Name,
		SenderId = sender.UserId or 0,
		Text = text,
		Timestamp = os.time(),
		MessageType = messageType or "Normal",
		IsAdmin = isAdmin,
		IsOwner = isOwner,
		IsFounder = isFounder,
		TargetPlayer = targetPlayer and targetPlayer.Name or nil
	}
end
-- Send message handler
SendMessage.OnServerEvent:Connect(function(sender, text)
	-- Validate player is not muted
	if isMuted(sender) then
		local muteData = MutedPlayers[sender.Name:lower()]
		local reason = muteData.reason or "No reason given"
		ReceiveMessage:FireClient(sender, createMessageData(
			{Name = "System", UserId = 0},
			"You are muted. Reason: " .. reason,
			"System"
		))
		return
	end
	
	-- Check rate limit
	if not checkRateLimit(sender) then
		ReceiveMessage:FireClient(sender, createMessageData(
			{Name = "System", UserId = 0},
			"You are sending messages too quickly. Please slow down.",
			"System"
		))
		return
	end
	
	-- Validate message length
	if not text or text == "" or #text > 200 then
		return
	end
	
	-- Filter message
	local filteredText = filterMessage(sender, text)
	
	-- Create message data
	local messageData = createMessageData(sender, filteredText, "Normal")
	
	-- Add to history
	addToHistory(messageData)
	
	-- Broadcast to all clients
	ReceiveMessage:FireAllClients(messageData)
	
	print("[ChatServer] Message from " .. sender.Name .. ": " .. filteredText)
end)

-- Execute command handler
ExecuteCommand.OnServerEvent:Connect(function(sender, command, args)
	-- Check admin status directly on server
	local isAdmin = false
	local isOwner = false
	local isFounder = false
	
	pcall(function()
		isAdmin = IsAdminFunc.OnServerInvoke(sender)
		isOwner = IsOwnerFunc.OnServerInvoke(sender)
		isFounder = IsFounderFunc.OnServerInvoke(sender)
	end)
	
	command = command:lower()
	
	-- Whisper command (all players)
	if command == "w" or command == "whisper" then
		if #args < 2 then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Usage: /w [player] [message]",
				"System"
			))
			return
		end
		
		local targetName = args[1]
		local target = findPlayer(targetName)
		
		if not target then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Player not found: " .. targetName,
				"System"
			))
			return
		end
		
		-- Get message (everything after player name)
		table.remove(args, 1)
		local message = table.concat(args, " ")
		
		-- Filter message
		local filteredText = filterMessage(sender, message, target)
		
		-- Send to both players
		local whisperData = createMessageData(sender, filteredText, "Whisper", target)
		ReceiveMessage:FireClient(sender, whisperData)
		ReceiveMessage:FireClient(target, whisperData)
		
		print("[ChatServer] Whisper from " .. sender.Name .. " to " .. target.Name)
		
	-- Mute command (admin only)
	elseif command == "mute" and isAdmin then
		if #args < 1 then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Usage: /mute [player] [reason]",
				"System"
			))
			return
		end
		
		local targetName = args[1]
		local target = findPlayer(targetName)
		
		if not target then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Player not found: " .. targetName,
				"System"
			))
			return
		end
		
		-- Get reason
		table.remove(args, 1)
		local reason = table.concat(args, " ")
		if reason == "" then reason = "No reason given" end
		
		-- Add to muted players
		MutedPlayers[target.Name:lower()] = {
			mutedBy = sender.Name,
			reason = reason,
			timestamp = os.time(),
			permanent = true
		}
		saveMutedPlayers()
		
		-- Notify
		ReceiveMessage:FireClient(sender, createMessageData(
			{Name = "System", UserId = 0},
			"Muted " .. target.Name .. ". Reason: " .. reason,
			"System"
		))
		ReceiveMessage:FireClient(target, createMessageData(
			{Name = "System", UserId = 0},
			"You have been muted. Reason: " .. reason,
			"System"
		))
		
		print("[ChatServer] " .. sender.Name .. " muted " .. target.Name)
		
	-- Unmute command (admin only)
	elseif command == "unmute" and isAdmin then
		if #args < 1 then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Usage: /unmute [player]",
				"System"
			))
			return
		end
		
		local targetName = args[1]
		local targetLower = targetName:lower()
		
		if not MutedPlayers[targetLower] then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Player is not muted: " .. targetName,
				"System"
			))
			return
		end
		
		MutedPlayers[targetLower] = nil
		saveMutedPlayers()
		
		ReceiveMessage:FireClient(sender, createMessageData(
			{Name = "System", UserId = 0},
			"Unmuted " .. targetName,
			"System"
		))
		
		local target = findPlayer(targetName)
		if target then
			ReceiveMessage:FireClient(target, createMessageData(
				{Name = "System", UserId = 0},
				"You have been unmuted",
				"System"
			))
		end
		
		print("[ChatServer] " .. sender.Name .. " unmuted " .. targetName)
		
	-- Mutedlist command (admin only)
	elseif command == "mutedlist" and isAdmin then
		local list = {}
		for name, data in pairs(MutedPlayers) do
			table.insert(list, name .. " (by " .. data.mutedBy .. ": " .. data.reason .. ")")
		end
		
		if #list == 0 then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"No muted players",
				"System"
			))
		else
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Muted players: " .. table.concat(list, ", "),
				"System"
			))
		end
		
	-- Warn command (admin only)
	elseif command == "warn" and isAdmin then
		if #args < 2 then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Usage: /warn [player] [message]",
				"System"
			))
			return
		end
		
		local targetName = args[1]
		local target = findPlayer(targetName)
		
		if not target then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Player not found: " .. targetName,
				"System"
			))
			return
		end
		
		table.remove(args, 1)
		local message = table.concat(args, " ")
		
		ReceiveMessage:FireClient(target, createMessageData(
			{Name = "System", UserId = 0},
			"[WARNING from " .. sender.Name .. "] " .. message,
			"System"
		))
		ReceiveMessage:FireClient(sender, createMessageData(
			{Name = "System", UserId = 0},
			"Warning sent to " .. target.Name,
			"System"
		))
		
		print("[ChatServer] " .. sender.Name .. " warned " .. target.Name)
		
	-- Announce command (owner only)
	elseif command == "announce" and isOwner then
		if #args < 1 then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Usage: /announce [message]",
				"System"
			))
			return
		end
		
		local message = table.concat(args, " ")
		
		-- Publish to all servers
		local success, err = pcall(function()
			MessagingService:PublishAsync("ChatAnnouncements", {
				Sender = sender.Name,
				Message = message,
				Timestamp = os.time()
			})
		end)
		
		if success then
			print("[ChatServer] Announcement published: " .. message)
		else
			warn("[ChatServer] Failed to publish announcement: " .. tostring(err))
			-- Fallback: send to current server only
			local announceData = createMessageData(
				{Name = "Announcement", UserId = 0},
				"[" .. sender.Name .. "] " .. message,
				"Announcement"
			)
			ReceiveMessage:FireAllClients(announceData)
		end
	
	-- Bring command (admin only)
	elseif command == "bring" and isAdmin then
		if #args < 1 then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Usage: /bring [player]",
				"System"
			))
			return
		end
		
		local targetName = args[1]
		local BringPlayerEvent = AdminRemotes:WaitForChild("BringPlayer")
		BringPlayerEvent:FireServer(targetName)
		
		ReceiveMessage:FireClient(sender, createMessageData(
			{Name = "System", UserId = 0},
			"Bringing " .. targetName .. " to you",
			"System"
		))
		
		print("[ChatServer] " .. sender.Name .. " used /bring on " .. targetName)
		
	-- Kick command (admin only)
	elseif command == "kick" and isAdmin then
		if #args < 1 then
			ReceiveMessage:FireClient(sender, createMessageData(
				{Name = "System", UserId = 0},
				"Usage: /kick [player] [reason]",
				"System"
			))
			return
		end
		
		local targetName = args[1]
		table.remove(args, 1)
		local reason = table.concat(args, " ")
		if reason == "" then reason = "Kicked by " .. sender.Name end
		
		local KickPlayerEvent = AdminRemotes:WaitForChild("KickPlayer")
		KickPlayerEvent:FireServer(targetName, reason)
		
		ReceiveMessage:FireClient(sender, createMessageData(
			{Name = "System", UserId = 0},
			"Kicked " .. targetName .. ": " .. reason,
			"System"
		))
		
		print("[ChatServer] " .. sender.Name .. " kicked " .. targetName)
		
		
	else
		-- Unknown command or no permission
		ReceiveMessage:FireClient(sender, createMessageData(
			{Name = "System", UserId = 0},
			"Unknown command or insufficient permissions",
			"System"
		))
	end
end)

-- Delete message handler (admin only)
DeleteMessage.OnServerEvent:Connect(function(admin, messageId)
	local isAdmin = false
	pcall(function()
		isAdmin = IsAdminFunc.OnServerInvoke(admin)
	end)
	if not isAdmin then return end
	
	-- Broadcast deletion to all clients
	DeleteMessage:FireAllClients(messageId)
	
	print("[ChatServer] " .. admin.Name .. " deleted message " .. messageId)
end)

-- Get chat history
GetChatHistory.OnServerInvoke = function(player)
	-- Return last 50 messages
	local startIndex = math.max(1, #MessageHistory - 49)
	local history = {}
	
	for i = startIndex, #MessageHistory do
		table.insert(history, MessageHistory[i])
	end
	
	return history
end

-- Get muted players list
GetMutedPlayers.OnServerInvoke = function(player)
	local isAdmin = false
	pcall(function()
		isAdmin = IsAdminFunc.OnServerInvoke(player)
	end)
	if not isAdmin then return {} end
	
	return MutedPlayers
end

-- Subscribe to cross-server announcements
pcall(function()
	MessagingService:SubscribeAsync("ChatAnnouncements", function(message)
		local data = message.Data
		if data and data.Sender and data.Message then
			local announceData = createMessageData(
				{Name = "Announcement", UserId = 0},
				"[" .. data.Sender .. "] " .. data.Message,
				"Announcement"
			)
			ReceiveMessage:FireAllClients(announceData)
		end
	end)
	print("[ChatServer] Subscribed to announcements")
end)

print("[ChatServer] Chat server loaded!")
