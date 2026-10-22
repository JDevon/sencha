local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Parent.Parent.Parent.Signal)
local DefineHooks = require(script.Parent.Parent.Parent.Parent.Util.DefineHooks)
local ReplicationServer = require(script.Parent.Parent.Parent.ReplicationServer)
local ReplicationShared = require(script.Parent.Parent.Parent.ReplicationShared)
local ObservableValue = require(script.Parent.Parent.Parent.Parent.Parent.ObservableValue)
local ClientReplicator = require(script.Parent.Parent.Parent.ReplicationClient.ClientReplicator)
local PredictionsClient = require(script.Parent.Parent.Parent.Parent.Predictions.PredictionsClient)
local ReplicatorChannel = require(script.Parent.Parent.Parent.ReplicationShared.ChannelRegistry.ReplicatorChannel)

local noYielding = require(script.Parent.Parent.Parent.Parent.Util.noYielding)
local toDisconnect = require(script.Parent.Parent.Parent.Parent.Util.toDisconnect)
local openChannel = require(script.Parent.Parent.Parent.ReplicationShared.openChannel)

local KIND = "temporaryGlobal"

--[=[
	@class TemporaryGlobalReplicator

	One value the server keeps in memory and sends to every player, created with
	`Sencha.temporaryReplicator.global`. Per-player data never goes through a global replicator unless you put it
	there, so the server always chooses what becomes public.
]=]
local TemporaryGlobalReplicator = {}
TemporaryGlobalReplicator.__index = TemporaryGlobalReplicator

local function getClientReplicator<T, P>(self: TemporaryGlobalReplicator<T, P>): ClientReplicator.ClientReplicator<T, P>
	assert(RunService:IsClient(), "TemporaryGlobalReplicator client methods can only be called on the client")
	return assert(self.clientReplicator, "TemporaryGlobalReplicator clientReplicator has not been initialized")
end

local function setPrepared(self: any, preparedValue: any)
	local oldValue = self.value
	if preparedValue == oldValue then
		return
	end

	-- clients are sent the change before server listeners run,
	-- so anything a listener changes in response reaches clients after it
	self.value = preparedValue
	local payload = ReplicationServer.createPayload(self.channel, preparedValue, "value")
	ReplicationServer.publishToReadyPlayers(self.channel, payload)
	assert(self.serverChangedSignal, "TemporaryGlobalReplicator serverChangedSignal has not been initialized"):Fire(
		preparedValue,
		oldValue
	)
end

export type TemporaryGlobalReplicator<T, P> = typeof(setmetatable(
	{} :: {
		channel: ReplicatorChannel.ReplicatorChannel<T, P>,
		value: T,
		clientReplicator: ClientReplicator.ClientReplicator<T, P>?,
		serverChangedSignal: Signal.Signal<T, T>?,
	},
	{} :: {
		__index: {
			get: (self: TemporaryGlobalReplicator<T, P>) -> T,
			getAsync: (self: TemporaryGlobalReplicator<T, P>) -> T,
			set: (self: TemporaryGlobalReplicator<T, P>, value: T) -> (),
			tryUpdate: (self: TemporaryGlobalReplicator<T, P>, callback: (value: T) -> (boolean, T?)) -> boolean,
			applyIncrementalUpdate: (self: TemporaryGlobalReplicator<T, P>, update: P) -> (),
			observe: (
				self: TemporaryGlobalReplicator<T, P>,
				callback: (newValue: T, oldValue: T?) -> ()
			) -> toDisconnect.Disconnect,
			onUpdateReceived: (
				self: TemporaryGlobalReplicator<T, P>,
				callback: (newValue: T, oldValue: T, patch: P) -> ()
			) -> toDisconnect.Disconnect,
			onChanged: (
				self: TemporaryGlobalReplicator<T, P>,
				callback: (newValue: T, oldValue: T) -> ()
			) -> toDisconnect.Disconnect,
			getObservable: (self: TemporaryGlobalReplicator<T, P>) -> ObservableValue.ObservableValue<T>,
			getConfirmed: (self: TemporaryGlobalReplicator<T, P>) -> T,
			onConfirmedChanged: (
				self: TemporaryGlobalReplicator<T, P>,
				callback: (newValue: T, oldValue: T) -> ()
			) -> toDisconnect.Disconnect,
			prediction: (
				self: TemporaryGlobalReplicator<T, P>,
				predict: ((value: T) -> T) | P
			) -> PredictionsClient.PredictionRequest,
			isLoaded: (self: TemporaryGlobalReplicator<T, P>) -> boolean,
		},
	}
))

function TemporaryGlobalReplicator.new<T, P>(
	valueType: T,
	initialValue: T,
	incrementalConfig: ReplicationShared.TemporaryIncrementalConfig<T, P>?
): TemporaryGlobalReplicator<T, P>
	if incrementalConfig and (incrementalConfig :: any).diff ~= nil then
		error("Temporary replicators don't use diff; send patches with applyIncrementalUpdate", 2)
	end

	local self = setmetatable({}, TemporaryGlobalReplicator) :: any
	self.channel = ReplicatorChannel.new({
		kind = KIND,
		valueType = valueType,
		read = function()
			return self.value
		end,
		incrementalConfig = incrementalConfig,
	})
	self.value = self.channel:prepareValue(initialValue)

	if RunService:IsClient() then
		self.clientReplicator = ClientReplicator.new(self.channel)
	else
		self.serverChangedSignal = Signal.new()
	end

	DefineHooks.set(self, function(name, parent)
		openChannel(self.channel, name, parent)
	end)

	return self
end

--[=[
	@method get
	@within TemporaryGlobalReplicator

	Returns the current value without yielding.

	On the client, errors if the value hasn't arrived yet. Call [Sencha.waitForReplicators] while loading, or use
	[TemporaryGlobalReplicator:getAsync] or [TemporaryGlobalReplicator:observe] in code that may run earlier.

	On the client, this includes pending predictions. [TemporaryGlobalReplicator:getConfirmed] returns the server's value
	without them.

	@return T
]=]
function TemporaryGlobalReplicator.get<T, P>(self: TemporaryGlobalReplicator<T, P>): T
	if RunService:IsServer() then
		return self.value
	else
		return getClientReplicator(self):get()
	end
end

--[=[
	@method getAsync
	@within TemporaryGlobalReplicator
	@yields

	Returns the current value, yielding until it's available. The server value always exists, so this only yields on the
	client.

	On the client, this includes pending predictions. [TemporaryGlobalReplicator:getConfirmed] returns the server's value
	without them.

	@return T
]=]
function TemporaryGlobalReplicator.getAsync<T, P>(self: TemporaryGlobalReplicator<T, P>): T
	if RunService:IsServer() then
		return self.value
	else
		return getClientReplicator(self):getAsync()
	end
end

--[=[
	@method set
	@within TemporaryGlobalReplicator
	@server

	Sets the value and sends it to every player. Errors if the value doesn't match the replicator's type. Setting a
	primitive to the value it already has does nothing; setting a table always counts as a change.

	@param value T
]=]
function TemporaryGlobalReplicator.set<T, P>(self: TemporaryGlobalReplicator<T, P>, value: T)
	assert(RunService:IsServer(), `TemporaryGlobalReplicator:set can only be called on the server`)
	setPrepared(self, self.channel:prepareValue(value))
end

--[=[
	@method tryUpdate
	@within TemporaryGlobalReplicator
	@server

	Calls `callback` with the current value. If it returns `true` and a new value, the value is set as with
	[TemporaryGlobalReplicator:set]; if it returns `false`, nothing changes. Returns what `callback` returned first.

	`callback` must not yield, so nothing else can change the value between reading and setting it.

	```lua
	local didStart = EventsNetwork.meteorShowerReplicator:tryUpdate(function(isActive)
		if isActive then
			return false
		end
		return true, true
	end)
	```

	@param callback (value: T) -> (boolean, T?)
	@return boolean
]=]
function TemporaryGlobalReplicator.tryUpdate<T, P>(
	self: TemporaryGlobalReplicator<T, P>,
	callback: (value: T) -> (boolean, T?)
): boolean
	assert(RunService:IsServer(), `TemporaryGlobalReplicator:tryUpdate can only be called on the server`)
	local shouldSet, newValue = noYielding(callback, self.value)
	if not shouldSet then
		return false
	end

	setPrepared(self, self.channel:prepareValue(newValue :: T))
	return true
end

--[=[
	@method applyIncrementalUpdate
	@within TemporaryGlobalReplicator
	@server

	Applies `patch` to the value with the incremental config's `apply`, then sends only the patch to every player.
	Errors if the patch or the new value doesn't match its type, or if the replicator has no incremental config. An
	empty table patch does nothing.

	@param patch P
]=]
function TemporaryGlobalReplicator.applyIncrementalUpdate<T, P>(self: TemporaryGlobalReplicator<T, P>, update: P)
	assert(RunService:IsServer(), `TemporaryGlobalReplicator:applyIncrementalUpdate can only be called on the server`)
	assert(
		self.channel.incrementalConfig,
		`TemporaryGlobalReplicator {self.channel.key} does not have an incremental config`
	)

	if type(update) == "table" and next(update :: any) == nil then
		return
	end

	local oldValue = self.value
	local newValue, patchFailure = self.channel:applyPatch(oldValue, update)
	if not newValue then
		error(patchFailure, 2)
	end

	if newValue == oldValue then
		return
	end

	self.value = newValue
	local payload = ReplicationServer.createPayload(self.channel, update, "patch")
	ReplicationServer.publishToReadyPlayers(self.channel, payload)
	assert(self.serverChangedSignal, "TemporaryGlobalReplicator serverChangedSignal has not been initialized"):Fire(
		newValue,
		oldValue
	)
end

--[=[
	@method onChanged
	@within TemporaryGlobalReplicator

	Calls `callback` when the value changes, not for the initial value.

	On the server, the change is sent to clients before `callback` runs, so anything it changes in response reaches
	clients after the change that caused it.

	On the client, this also fires when a prediction is made, and again if it's rolled back. Use
	[TemporaryGlobalReplicator:onConfirmedChanged] to only hear about the server's changes.

	@param callback (newValue: T, oldValue: T) -> ()
	@return Disconnect
]=]
function TemporaryGlobalReplicator.onChanged<T, P>(
	self: TemporaryGlobalReplicator<T, P>,
	callback: (newValue: T, oldValue: T) -> ()
)
	if RunService:IsServer() then
		return toDisconnect(
			assert(self.serverChangedSignal, "TemporaryGlobalReplicator serverChangedSignal has not been initialized"):Connect(
				callback
			)
		)
	else
		return getClientReplicator(self):onChanged(callback)
	end
end

--[=[
	@method observe
	@within TemporaryGlobalReplicator
	@client

	Calls `callback` with the current value right away if it has arrived (otherwise when it arrives), then on
	every change. `oldValue` is the value before the change, or `nil` for the first call.

	```lua
	EventsNetwork.meteorShowerReplicator:observe(function(isActive, wasActive)
		if isActive and wasActive ~= true then
			print("a meteor shower started")
		end
	end)
	```

	This includes predictions: it fires when a prediction is made, and again if it's rolled back.

	@param callback (newValue: T, oldValue: T?) -> ()
	@return Disconnect
]=]
function TemporaryGlobalReplicator.observe<T, P>(
	self: TemporaryGlobalReplicator<T, P>,
	callback: (newValue: T, oldValue: T?) -> ()
)
	assert(RunService:IsClient(), `TemporaryGlobalReplicator:observe can only be called on the client`)
	return getClientReplicator(self):observe(callback)
end

--[=[
	@method onUpdateReceived
	@within TemporaryGlobalReplicator
	@client

	Calls `callback` for each patch received, after the value is updated. Only replicators with an incremental
	config receive patches; calling this on one without errors.

	Whole values (the first value, or a `set`) don't fire this; use
	[TemporaryGlobalReplicator:onChanged] to see every change.

	Patches always come from the server: predictions don't fire this, and `newValue` and `oldValue` are the
	server's values.

	@param callback (newValue: T, oldValue: T, patch: P) -> ()
	@return Disconnect
]=]
function TemporaryGlobalReplicator.onUpdateReceived<T, P>(
	self: TemporaryGlobalReplicator<T, P>,
	callback: (newValue: T, oldValue: T, patch: P) -> ()
)
	assert(RunService:IsClient(), `TemporaryGlobalReplicator:onUpdateReceived can only be called on the client`)
	return getClientReplicator(self):onUpdateReceived(callback)
end

--[=[
	@method getObservable
	@within TemporaryGlobalReplicator
	@client

	Returns an [ObservableValue](https://jdevon.github.io/observable-value/) that follows the replicated value,
	for code that works with ObservableValues, like the
	[ReactObservableValue](https://github.com/JDevon/react-observable-value) hooks. Calling this again returns the same
	one. Setting it doesn't change the replicated value. Errors if the value hasn't arrived yet.

	```lua
	local isMeteorShower = ReactObservableValue.useObservableValue(EventsNetwork.meteorShowerReplicator:getObservable())
	```

	The observable includes pending predictions, like [TemporaryGlobalReplicator:get].

	@return ObservableValue<T>
]=]
function TemporaryGlobalReplicator.getObservable<T, P>(
	self: TemporaryGlobalReplicator<T, P>
): ObservableValue.ObservableValue<T>
	assert(RunService:IsClient(), `TemporaryGlobalReplicator:getObservable can only be called on the client`)
	return getClientReplicator(self):getObservable()
end

--[=[
	@method getConfirmed
	@within TemporaryGlobalReplicator
	@client

	Returns the value the server sent, without any pending predictions. [TemporaryGlobalReplicator:get] returns the
	predicted value while a prediction is pending; use this when code must only act on what the server has confirmed.
	Errors if the value hasn't arrived yet.

	@return T
]=]
function TemporaryGlobalReplicator.getConfirmed<T, P>(self: TemporaryGlobalReplicator<T, P>): T
	assert(RunService:IsClient(), `TemporaryGlobalReplicator:getConfirmed can only be called on the client`)
	return getClientReplicator(self):getConfirmed()
end

--[=[
	@method onConfirmedChanged
	@within TemporaryGlobalReplicator
	@client

	Calls `callback` when the server's value changes, not for predictions or the initial value.

	[TemporaryGlobalReplicator:onChanged] also fires for predictions, and again if a wrong prediction is rolled back.
	Use this instead for effects that should only change for confirmed values:

	```lua
	EventsNetwork.meteorShowerReplicator:onConfirmedChanged(function(isActive, wasActive)
		if isActive and not wasActive then
			announceMeteorShower()
		end
	end)
	```

	@param callback (newValue: T, oldValue: T) -> ()
	@return Disconnect
]=]
function TemporaryGlobalReplicator.onConfirmedChanged<T, P>(
	self: TemporaryGlobalReplicator<T, P>,
	callback: (newValue: T, oldValue: T) -> ()
): toDisconnect.Disconnect
	assert(RunService:IsClient(), `TemporaryGlobalReplicator:onConfirmedChanged can only be called on the client`)
	return getClientReplicator(self):onConfirmedChanged(function(newValue, oldValue)
		callback(newValue, oldValue)
	end)
end

--[=[
	@method prediction
	@within TemporaryGlobalReplicator
	@client

	Builds a prediction for this replicator. The returned prediction can be used with a predicted remote call such as
	`invokeServerPredicted` or `fireServerPredicted`. While the call is pending, [TemporaryGlobalReplicator:get],
	[TemporaryGlobalReplicator:observe] and [TemporaryGlobalReplicator:onChanged] show the value with the prediction
	applied; it's removed when the server confirms the call.

	`predict` is either a function that returns the predicted value, or a patch on a replicator with an incremental
	config. A patch is applied with the config's `apply`, the same way the server's patches are.

	```lua
	EventsNetwork.startMeteorShowerRemote:fireServerPredicted({
		EventsNetwork.meteorShowerReplicator:prediction(function()
			return true
		end),
	})
	```

	@param predict ((value: T) -> T) | P
	@return Prediction
]=]
function TemporaryGlobalReplicator.prediction<T, P>(
	self: TemporaryGlobalReplicator<T, P>,
	predict: ((value: T) -> T) | P
): PredictionsClient.PredictionRequest
	assert(RunService:IsClient(), `TemporaryGlobalReplicator:prediction can only be called on the client`)
	return getClientReplicator(self):prediction(predict)
end

--[=[
	@method isLoaded
	@within TemporaryGlobalReplicator
	@client

	Returns whether the value has arrived from the server.

	@return boolean
]=]
function TemporaryGlobalReplicator.isLoaded<T, P>(self: TemporaryGlobalReplicator<T, P>): boolean
	assert(RunService:IsClient(), `TemporaryGlobalReplicator:isLoaded can only be called on the client`)
	return getClientReplicator(self):isLoaded()
end

return table.freeze({
	new = TemporaryGlobalReplicator.new,
})
