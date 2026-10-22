local RunService = game:GetService("RunService")

local RateLimiter = require(script.Parent.Parent.RateLimiter)
local gt = require(script.Parent.Parent.Parent.Parent.GreenTea)
local RemoteLoader = require(script.Parent.Parent.RemoteLoader)
local Cleanup = require(script.Parent.Parent.Parent.Util.Cleanup)
local RemoteRejections = require(script.Parent.Parent.RemoteRejections)
local DefineHooks = require(script.Parent.Parent.Parent.Util.DefineHooks)
local RemoteTypechecker = require(script.Parent.Parent.RemoteTypechecker)
local PredictionsShared = require(script.Parent.Parent.Parent.Predictions.PredictionsShared)
local PredictionsServer = require(script.Parent.Parent.Parent.Predictions.PredictionsServer)
local PredictionsClient = require(script.Parent.Parent.Parent.Predictions.PredictionsClient)

local runListeners = require(script.Parent.Parent.Parent.Util.runListeners)
local toDisconnect = require(script.Parent.Parent.Parent.Util.toDisconnect)

--[=[
	@class Event

	A typed `RemoteEvent`, created with [Sencha.event] or [Sencha.unreliableEvent]. Arguments are checked against
	its GreenTea types: calls from your own code error on bad types, and calls from clients with bad types are
	rejected on the server.

	Calls from clients are also rate limited. Rejected calls are dropped, and the server warns once per player,
	remote and reason, then stays quiet for that combination for 60 seconds.
]=]
local RemoteEvent = {}
RemoteEvent.__index = RemoteEvent

export type Event<T...> = typeof(setmetatable(
	{} :: {
		cleanup: Cleanup.Cleanup,
		loader: RemoteLoader.RemoteLoader<RemoteEvent>,
		typechecker: RemoteTypechecker.RemoteTypechecker<T...>,
		rateLimiter: RateLimiter.RateLimiter?,
		rejections: RemoteRejections.RemoteRejections?,
		listeners: { runListeners.Listener },
		isUnreliable: boolean,
		serverConnection: RBXScriptConnection?,
	},
	{} :: {
		__index: {
			fireServer: (Event<T...>, T...) -> (),
			fireServerPredicted: (Event<T...>, predictions: { PredictionsClient.PredictionRequest }, T...) -> (),
			fireClient: (Event<T...>, Player, T...) -> (),
			fireAllClients: (Event<T...>, T...) -> (),
			onClientEvent: (Event<T...>, (T...) -> ()) -> toDisconnect.Disconnect,
			onServerEvent: (Event<T...>, (Player, T...) -> ()) -> toDisconnect.Disconnect,
			rateLimit: (Event<T...>, RateLimiter.Limit) -> Event<T...>,
			destroy: (Event<T...>) -> (),
		},
	}
))

function RemoteEvent.new<T...>(isUnreliable: boolean, ...: T...): Event<T...>
	local self = setmetatable({}, RemoteEvent)
	self.cleanup = Cleanup.new()

	local remoteEventInstance: RemoteEvent?
	if RunService:IsServer() then
		local instance = if isUnreliable
			then Instance.new("UnreliableRemoteEvent")
			else Instance.new("RemoteEvent") :: any
		remoteEventInstance = instance
		self.cleanup:add(instance)

		self.rateLimiter = RateLimiter.new()
		self.cleanup:add(function()
			self.rateLimiter:destroy()
		end)

		self.rejections = RemoteRejections.new()
		local rejections = self.rejections
		self.cleanup:add(function()
			rejections:destroy()
		end)
	end

	self.loader = RemoteLoader.new(remoteEventInstance)
	self.typechecker = RemoteTypechecker.fromArgs(gt.args(...))

	self.listeners = {}
	self.isUnreliable = isUnreliable
	self.cleanup:add(function()
		table.clear(self.listeners)
	end)
	self.serverConnection = nil :: RBXScriptConnection?

	DefineHooks.set(self, function(name, parent)
		self.loader:load(name, parent)

		if self.rejections then
			self.rejections:setName(`{parent:GetFullName()}.{name}`)
		end
	end)

	return self :: any
end

--[=[
	@method fireServer
	@within Event
	@client

	Sends the arguments to the server.

	@param ... T...
]=]
function RemoteEvent.fireServer<T...>(self: Event<T...>, ...: T...)
	assert(RunService:IsClient(), "RemoteEvent.fireServer can only be called from the client")
	self.loader:assertInstance():FireServer(false, self.typechecker:check(...))
end

--[=[
	@method fireServerPredicted
	@within Event
	@client

	Sends the arguments to the server, and shows `predictions` on their replicators until the server has handled this
	call. Build each prediction with a replicator's `prediction` method. Unreliable events can't be predicted.

	@param predictions { Prediction }
	@param ... T...
]=]
function RemoteEvent.fireServerPredicted<T...>(
	self: Event<T...>,
	predictions: { PredictionsClient.PredictionRequest },
	...: T...
)
	assert(RunService:IsClient(), "RemoteEvent.fireServerPredicted can only be called from the client")
	if self.isUnreliable then
		error("Unreliable events can't be predicted: a dropped message would never be confirmed", 2)
	end
	if #predictions == 0 then
		error("fireServerPredicted needs at least one prediction", 2)
	end

	local args = table.pack(self.typechecker:check(...))
	local id = PredictionsClient.beginPrediction(predictions)
	self.loader:assertInstance():FireServer(id, table.unpack(args, 1, args.n))
end

--[=[
	@method fireClient
	@within Event
	@server

	Sends the arguments to one player.

	@param player Player
	@param ... T...
]=]
function RemoteEvent.fireClient<T...>(self: Event<T...>, player: Player, ...: T...)
	assert(RunService:IsServer(), "RemoteEvent.fireClient can only be called from the server")
	self.loader:assertInstance():FireClient(player, self.typechecker:check(...))
end

--[=[
	@method fireAllClients
	@within Event
	@server

	Sends the arguments to every player.

	@param ... T...
]=]
function RemoteEvent.fireAllClients<T...>(self: Event<T...>, ...: T...)
	assert(RunService:IsServer(), "RemoteEvent.fireAllClients can only be called from the server")
	self.loader:assertInstance():FireAllClients(self.typechecker:check(...))
end

--[=[
	@method onClientEvent
	@within Event
	@client

	Calls `callback` whenever the server fires this event to this client.

	@param callback (T...) -> ()
	@return Disconnect
]=]
function RemoteEvent.onClientEvent<T...>(self: Event<T...>, callback: (T...) -> ()): toDisconnect.Disconnect
	assert(RunService:IsClient(), "RemoteEvent.onClientEvent can only be called from the client")
	return toDisconnect(self.loader:assertInstance().OnClientEvent:Connect(function(...)
		callback(self.typechecker:check(...))
	end))
end

--[=[
	@method onServerEvent
	@within Event
	@server

	Calls `callback` whenever a client fires this event, after the call passes the rate limit and type check. Each
	call spends one token and is checked once, however many listeners there are.

	@param callback (player: Player, T...) -> ()
	@return Disconnect
]=]
function RemoteEvent.onServerEvent<T...>(self: Event<T...>, callback: (Player, T...) -> ()): toDisconnect.Disconnect
	assert(RunService:IsServer(), "RemoteEvent.onServerEvent can only be called from the server")

	local rateLimiter = assert(self.rateLimiter, "RateLimiter should exist on the server.")
	local rejections = assert(self.rejections, "RemoteRejections should exist on the server.")
	if not self.serverConnection then
		-- one connection per remote, so each call from a client spends one token and is type-checked once
		local connection = self.loader:assertInstance().OnServerEvent:Connect(function(player, predictionId, ...)
			local ok, cause = PredictionsShared.validatePredictionId(predictionId)
			if not ok then
				rejections:reject(player, "invalid prediction id", nil, cause:formatErr())
				return
			end

			if not rateLimiter:tryConsume(player) then
				rejections:reject(player, "rate limited")
				PredictionsServer.tryAcknowledgeRejected(player, predictionId)
				return
			end

			ok, cause = self.typechecker:matches(...)
			if not ok then
				rejections:reject(player, "invalid arguments", nil, cause:formatErr())
				PredictionsServer.tryAcknowledgeRejected(player, predictionId)
				return
			end

			if predictionId then
				PredictionsServer.waitForTurnAsync(player, predictionId, rejections:getName())
				runListeners(player, self.listeners, table.pack(...), function()
					PredictionsServer.finishPrediction(player, predictionId)
				end)
			else
				runListeners(player, self.listeners, table.pack(...))
			end
		end)
		self.serverConnection = connection
		self.cleanup:add(connection)
	end

	local listener = { callback = callback, connected = true }
	table.insert(self.listeners, listener)
	return function()
		if not listener.connected then
			return
		end

		listener.connected = false
		local index = table.find(self.listeners, listener)
		if index then
			table.remove(self.listeners, index)
		end
	end
end

--[=[
	@method rateLimit
	@within Event
	@server

	Sets the rate limit for calls from each player, replacing the default of 60 at once and 30 per second. Returns
	the same event, so it can be chained where it's created. Errors if the limit is invalid.

	```lua
	exportItemRemote = Sencha.event(gt.string()):rateLimit({ burst = 10, perSecond = 4 }),
	```

	@param limit Limit
	@return Event
]=]
function RemoteEvent.rateLimit<T...>(self: Event<T...>, limit: RateLimiter.Limit): Event<T...>
	RateLimiter.validateLimit(limit)
	if RunService:IsServer() then
		assert(self.rateLimiter, "RateLimiter should exist on the server."):setLimit(limit)
	end
	return self
end

--[=[
	@method destroy
	@within Event

	Disconnects every listener and, on the server, destroys the remote instance.
]=]
function RemoteEvent.destroy<T...>(self: Event<T...>)
	self.cleanup:destroy()
end

return table.freeze({
	new = function<T...>(...: T...): Event<T...>
		return RemoteEvent.new(false, ...)
	end,
	newUnreliable = function<T...>(...: T...): Event<T...>
		return RemoteEvent.new(true, ...)
	end,
})
