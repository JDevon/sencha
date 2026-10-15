local ReplicationClient = require(script.Parent)
local ObservableValue = require(script.Parent.Parent.Parent.Parent.ObservableValue)
local ReplicatorChannel = require(script.Parent.Parent.ReplicationShared.ChannelRegistry.ReplicatorChannel)

local toDisconnect = require(script.Parent.Parent.Parent.Util.toDisconnect)

export type ClientReplicator<T, P> = typeof(setmetatable(
	{} :: {
		channel: ReplicatorChannel.ReplicatorChannel<T, P>,
		observable: ObservableValue.ObservableValue<T>?,
	},
	{} :: {
		__index: {
			get: (ClientReplicator<T, P>) -> T,
			getAsync: (ClientReplicator<T, P>) -> T,
			observe: (ClientReplicator<T, P>, callback: (newValue: T, oldValue: T?) -> ()) -> toDisconnect.Disconnect,
			onChanged: (ClientReplicator<T, P>, callback: (newValue: T, oldValue: T) -> ()) -> toDisconnect.Disconnect,
			onUpdateReceived: (
				ClientReplicator<T, P>,
				callback: (newValue: T, oldValue: T, patch: P) -> ()
			) -> toDisconnect.Disconnect,
			getObservable: (ClientReplicator<T, P>) -> ObservableValue.ObservableValue<T>,
			isLoaded: (ClientReplicator<T, P>) -> boolean,
		},
	}
))

local ClientReplicator = {}
ClientReplicator.__index = ClientReplicator

function ClientReplicator.new<T, P>(channel: ReplicatorChannel.ReplicatorChannel<T, P>)
	local self = setmetatable({}, ClientReplicator)
	self.channel = channel
	return self
end

local function assertLoaded<T, P>(self: ClientReplicator<T, P>, method: string)
	if self.channel.loaded:get() then
		return
	end

	if ReplicationClient.isInitialFetchComplete() then
		error(
			`Replicator {self.channel.key} has no value: the server did not send one.`
				.. ` Make sure the server requires the module that defines it.`,
			3
		)
	else
		error(
			`Replicator {self.channel.key}:{method} was called before its value arrived from the server.`
				.. ` Call Sencha.waitForReplicators() before starting client systems,`
				.. ` or use :observe() / :getAsync() instead.`,
			3
		)
	end
end

function ClientReplicator.get<T, P>(self: ClientReplicator<T, P>): T
	assertLoaded(self, "get")
	return self.channel.observable:get()
end

function ClientReplicator.getAsync<T, P>(self: ClientReplicator<T, P>): T
	if not self.channel.loaded:get() then
		local waitSeconds = ReplicationClient.SLOW_LOAD_WARNING_SECONDS
		local warnThread = task.delay(waitSeconds, function()
			local reason = if ReplicationClient.isInitialFetchComplete()
				then "The initial fetch finished without a value for it.\nEnsure the server requires the module that defines it."
				else "The initial fetch hasn't finished yet."
			warn(`Replicator {self.channel.key}:getAsync has waited {waitSeconds}s for its value. {reason}`)
		end)

		self.channel.loaded
			:promiseValue(function(loaded)
				return loaded, nil
			end)
			:expect()
		task.cancel(warnThread)
	end
	return self.channel.observable:get()
end

-- fires immediately if loaded (otherwise once loaded), then on every change. oldValue is nil for the first call
function ClientReplicator.observe<T, P>(self: ClientReplicator<T, P>, callback: (newValue: T, oldValue: T?) -> ())
	local isLoaded = self.channel.loaded:get()
	local lastValue: T? = if isLoaded then self.channel.observable:get() else nil

	-- onSet rather than onChanged.
	-- A first value of nil isn't a change from the nil starting value, but still needs a first call
	local disconnect = self.channel.observable:onSet(function(value)
		local oldValue = lastValue
		lastValue = value
		callback(value, oldValue)
	end)
	if isLoaded then
		task.spawn(callback, lastValue :: T, nil)
	end
	return disconnect
end

-- fires on changes after the initial value
function ClientReplicator.onChanged<T, P>(self: ClientReplicator<T, P>, callback: (newValue: T, oldValue: T) -> ())
	return self.channel.observable:onChanged(function(newValue, oldValue)
		-- the initial load sets the value while loaded is still false
		if self.channel.loaded:get() then
			callback(newValue, oldValue)
		end
	end)
end

-- fires for each received patch with the value before and after it; full values (the initial load, or a
-- late registration) only fire onChanged, so use that to see every change
function ClientReplicator.onUpdateReceived<T, P>(
	self: ClientReplicator<T, P>,
	callback: (newValue: T, oldValue: T, patch: P) -> ()
): toDisconnect.Disconnect
	assert(self.channel.incrementalConfig, `Replicator {self.channel.key} does not have an incremental config.`)
	return toDisconnect(self.channel.updateReceivedSignal:Connect(callback))
end

-- a separate ObservableValue that follows the replicated value, so setting it can't change what Sencha holds
function ClientReplicator.getObservable<T, P>(self: ClientReplicator<T, P>): ObservableValue.ObservableValue<T>
	assertLoaded(self, "getObservable")
	local observable = self.observable
	if observable then
		return observable
	end

	local newObservable = ObservableValue.new(self.channel.observable:get())
	self.channel.observable:onSet(function(value)
		newObservable:set(value)
	end)
	self.observable = newObservable
	return newObservable
end

function ClientReplicator.isLoaded<T, P>(self: ClientReplicator<T, P>): boolean
	return self.channel.loaded:get()
end

return table.freeze({
	new = ClientReplicator.new,
})
