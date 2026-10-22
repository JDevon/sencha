local RunService = game:GetService("RunService")

local ChannelUtil = require(script.Parent.ChannelUtil)
local ReplicationShared = require(script.Parent.Parent)
local ChannelBatch = require(script.Parent.ChannelBatch)
local gt = require(script.Parent.Parent.Parent.Parent.Parent.GreenTea)
local Signal = require(script.Parent.Parent.Parent.Parent.Parent.Signal)
local Failures = require(script.Parent.Parent.Parent.Parent.Util.Failures)
local ObservableValue = require(script.Parent.Parent.Parent.Parent.Parent.ObservableValue)

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
		confirmed: ObservableValue.ObservableValue<T>,
		shown: ObservableValue.ObservableValue<T>,
		predictions: { ChannelUtil.Prediction },
		hadPredictions: boolean,
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

	self.confirmed = ObservableValue.new(nil :: any)
	self.shown = ObservableValue.new(nil :: any)
	self.predictions = {}
	self.hadPredictions = false

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
		Failures.report(`Replicator {self.key} received a value that does not match its type:\n{cause:formatErr()}`)
		return false
	end

	ChannelUtil.freezeInPlace(value)
	self.confirmed:set(value)
	self:reconcilePredictions()
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
		Failures.report(`Replicator {self.key} received a patch before its value; the patch was dropped`)
		return false
	end

	local oldValue = self.confirmed:get()
	local newValue, patchFailure = self:applyPatch(oldValue, update)
	if not newValue then
		-- a bad patch here means the server and client disagree. Failures.report doesn't stop this thread, so the
		-- rest of the snapshot and buffered messages still apply
		Failures.report(`{patchFailure}\nFurther patches are ignored until the server sends a whole value.`)
		return false
	end

	ChannelUtil.freezeInPlace(update)
	self.confirmed:set(newValue)
	self:reconcilePredictions()
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

function ReplicatorChannel.addPrediction<T, P>(self: ReplicatorChannel<T, P>, prediction: ChannelUtil.Prediction)
	table.insert(self.predictions, prediction)
end

function ReplicatorChannel.removePrediction<T, P>(self: ReplicatorChannel<T, P>, id: number)
	for index = #self.predictions, 1, -1 do
		if self.predictions[index].id == id then
			table.remove(self.predictions, index)
			-- no early return/break since multiple predictions with this id are allowed
		end
	end
end

function ReplicatorChannel.reconcilePredictions<T, P>(self: ReplicatorChannel<T, P>): { number }
	local dropped = {}

	-- the batch reconciles once at the end. A first value isn't deferred: nothing can be predicted before it, and
	-- shown must be set before anything waiting on loaded reads it
	if ChannelBatch.isBatching() and self.loaded:get() then
		ChannelBatch.defer(self)
		return dropped
	end

	local confirmed = self.confirmed:get()

	if #self.predictions == 0 and not self.hadPredictions then
		self.shown:set(confirmed)
		return dropped
	end

	local shownValue = confirmed
	local kept = {}
	for _, prediction in self.predictions do
		local ok, result = ChannelUtil.applyPrediction(self.incrementalConfig, shownValue, prediction)
		if ok and RunService:IsStudio() then
			local matches, cause = self.typechecker:matches(result)
			if not matches then
				Failures.report(
					`A prediction on replicator {self.key} produced a value that doesn't match its type:\n{cause:formatErr()}`
				)
				ok = false
			end
		end

		if ok then
			ChannelUtil.freezeInPlace(result)
			shownValue = result
			table.insert(kept, prediction)
		else
			table.insert(dropped, prediction.id)
		end
	end

	self.predictions = kept
	self.hadPredictions = #kept > 0

	if not ChannelUtil.deepEqual(shownValue, self.shown:get()) then
		self.shown:set(shownValue)
	end

	return dropped
end

return table.freeze({
	new = ReplicatorChannel.new,
})
