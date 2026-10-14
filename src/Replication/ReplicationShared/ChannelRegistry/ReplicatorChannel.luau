local RunService = game:GetService("RunService")

local ChannelUtil = require(script.Parent.ChannelUtil)
local ReplicationShared = require(script.Parent.Parent)
local gt = require(script.Parent.Parent.Parent.Parent.Parent.GreenTea)
local Signal = require(script.Parent.Parent.Parent.Parent.Parent.Signal)
local ObservableValue = require(script.Parent.Parent.Parent.Parent.Parent.ObservableValue)

local reportFailure = require(script.Parent.Parent.Parent.Parent.Util.reportFailure)

export type ReplicatorChannelConfig<T, P> = {
	kind: string,
	valueType: T,
	read: ChannelUtil.ChannelRead<T>,
	incrementalConfig: ReplicationShared.IncrementalConfig<T, P>?,
}

local ReplicatorChannel = {}
ReplicatorChannel.__index = ReplicatorChannel

export type ReplicatorChannel<T, P> = typeof(setmetatable(
	{} :: {
		config: ReplicatorChannelConfig<T, P>,
		key: string,
		kind: string,
		typechecker: gt.Type,
		patchTypechecker: gt.Type?,
		incrementalConfig: ReplicationShared.IncrementalConfig<T, P>?,
		read: ChannelUtil.ChannelRead<T>,
		loaded: ObservableValue.ObservableValue<boolean>,
		observable: ObservableValue.ObservableValue<T>,
		updateReceivedSignal: Signal.Signal<T, T, P>,
	},
	ReplicatorChannel
))

function ReplicatorChannel.new<T, P>(config: ReplicatorChannelConfig<T, P>): ReplicatorChannel<T, P>
	local self = setmetatable({}, ReplicatorChannel)
	self.config = config
	self.kind = config.kind
	self.incrementalConfig = ChannelUtil.guardIncrementalConfig(config.incrementalConfig)
	self.key = ""

	self.typechecker = gt.build(config.valueType)
	self.patchTypechecker = if config.incrementalConfig then gt.build(config.incrementalConfig.patchType) else nil

	self.read = ChannelUtil.guardConfiguredRead(config.read)

	self.loaded = ObservableValue.new(false)
	self.observable = ObservableValue.new(nil :: any)
	self.updateReceivedSignal = Signal.new()
	return self :: any
end

function ReplicatorChannel.setKey<T, P>(self: ReplicatorChannel<T, P>, key: string)
	assert(self.key == "", `Replicator {self.key} was defined twice; it cannot also be defined as {key}`)
	self.key = key
end

function ReplicatorChannel.prepareValue<T, P>(self: ReplicatorChannel<T, P>, value: T): T
	local ok, cause = self.typechecker:matches(value)
	if not ok then
		local name = if self.key ~= "" then self.key else "(not yet defined)"
		error(`Replicator {name} was given a value that does not match its type:\n{cause:formatErr()}`, 3)
	end

	if type(value) == "table" then
		return ChannelUtil.copyAndFreeze(value)
	end
	return value
end

function ReplicatorChannel.receive<T, P>(self: ReplicatorChannel<T, P>, value: any): boolean
	assert(RunService:IsClient(), "Replicators can only receive values on the client.")
	local ok, cause = self.typechecker:matches(value)
	if not ok then
		reportFailure(`Replicator {self.key} received a value that does not match its type:\n{cause:formatErr()}`)
		return false
	end

	ChannelUtil.freezeInPlace(value)
	self.observable:set(value)
	self.loaded:set(true)
	return true
end

function ReplicatorChannel.receiveUpdate<T, P>(self: ReplicatorChannel<T, P>, update: any): boolean
	assert(RunService:IsClient(), "Replicators can only receive updates on the client.")
	assert(
		self.incrementalConfig,
		`Replicator {self.key} received an incremental update but has no incremental config.`
	)

	if not self.loaded:get() then
		reportFailure(`Replicator {self.key} received a patch before its value; the patch was dropped`)
		return false
	end

	local oldValue = self.observable:get()
	local newValue, patchFailure = self:applyPatch(oldValue, update)
	if not newValue then
		-- a bad patch here means the server and client disagree, so it is dropped and the client resyncs.
		-- reportFailure doesn't stop this thread, so the rest of the snapshot and buffered messages still apply
		reportFailure(`{patchFailure}\nThe client will request the full value again.`)
		return false
	end

	ChannelUtil.freezeInPlace(update)
	self.observable:set(newValue)
	self.updateReceivedSignal:Fire(newValue, oldValue, update)
	return true
end

function ReplicatorChannel.applyPatch<T, P>(self: ReplicatorChannel<T, P>, oldValue: T, update: P): (T?, string?)
	local incrementalConfig = assert(
		self.incrementalConfig,
		`Replicator {self.key} received an incremental update but has no incremental config.`
	)
	local patchTypechecker = assert(self.patchTypechecker, `Replicator {self.key} has no patch type.`)

	local patchOk, patchCause = patchTypechecker:matches(update)
	if not patchOk then
		return nil,
			`Replicator {self.key} received a patch that does not match its patch type:\n{patchCause:formatErr()}`
	end

	local newValue = incrementalConfig.apply(oldValue, update)
	local ok, cause = self.typechecker:matches(newValue)
	if not ok then
		return nil,
			`Replicator {self.key} produced a value from a patch that does not match its type:\n{cause:formatErr()}`
	end

	ChannelUtil.freezeInPlace(newValue)
	return newValue
end

return table.freeze({
	new = ReplicatorChannel.new,
})
