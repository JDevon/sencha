local RunService = game:GetService("RunService")

local Failures = require(script.Parent.Parent.Util.Failures)

export type PredictionRequest = { channel: any, predict: any }
type Pending = { channels: { any }, timeoutThread: thread }

local TIMEOUT_SECONDS = 10

local predictionId = 0
local pending: { [number]: Pending } = {}

local PredictionsClient = {}

function PredictionsClient.beginPrediction(requests: { PredictionRequest }): number
	assert(RunService:IsClient(), "PredictionsClient can only be used on the client")

	for _, request in requests do
		local channel = request.channel
		if not channel.loaded:get() then
			error(`Replicator {channel.key} can't be predicted before its value has arrived`, 3)
		end
		if type(request.predict) ~= "function" and not channel.incrementalConfig then
			error(`Replicator {channel.key} has no incremental config, so it can only be predicted with a function`, 3)
		end
	end

	local id = PredictionsClient._getNextPredictionId()
	local predictedChannels = {}
	for _, request in requests do
		request.channel:addPrediction({ id = id, predict = request.predict })
		table.insert(predictedChannels, request.channel)
	end

	for _, channel in predictedChannels do
		local dropped = channel:reconcilePredictions()
		if table.find(dropped, id) then
			Failures.report(`A prediction on replicator {channel.key} errored the first time it was applied`)
		end
	end

	pending[id] = {
		channels = predictedChannels,
		timeoutThread = task.delay(TIMEOUT_SECONDS, function()
			if RunService:IsStudio() then
				local keys = {}
				for _, channel in predictedChannels do
					if not table.find(keys, channel.key) then
						table.insert(keys, channel.key)
					end
				end
				warn(
					`A prediction was still waiting for the server after {TIMEOUT_SECONDS}s, so it was removed.`
						.. ` Replicators: {table.concat(keys, ", ")}`
				)
			end
			PredictionsClient.settle(id, true)
		end),
	}

	return id
end

function PredictionsClient.settle(id: number, reconcile: boolean)
	local entry = pending[id]
	if not entry then
		return
	end
	pending[id] = nil

	if coroutine.running() ~= entry.timeoutThread then
		task.cancel(entry.timeoutThread)
	end

	for _, channel in entry.channels do
		channel:removePrediction(id)
		if reconcile then
			channel:reconcilePredictions()
		end
	end
end

-- private
function PredictionsClient._getNextPredictionId()
	predictionId = predictionId + 1
	return predictionId
end

return PredictionsClient
