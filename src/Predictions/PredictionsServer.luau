local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Failures = require(script.Parent.Parent.Util.Failures)

type HeldMessage = { id: number, payload: any, key: string? }
type ActivePrediction = { id: number, held: { HeldMessage }, isHolding: boolean, escapeThread: thread }

local MAX_PREDICTION_WAIT = 2

local activePredictions: { [Player]: ActivePrediction } = {}
local waitingThreads: { [Player]: { thread } } = {}
local sendStream: ((player: Player, id: number, payload: any) -> ())? = nil

local PredictionsServer = {}

function PredictionsServer.setStreamSender(send: (player: Player, id: number, payload: any) -> ())
	sendStream = send
end

function PredictionsServer.waitForTurnAsync(player: Player, id: number, remoteName: string)
	local activePlayerPrediction = activePredictions[player]
	if activePlayerPrediction then
		local waitingPlayerThreads = waitingThreads[player]
		if not waitingPlayerThreads then
			waitingPlayerThreads = {}
			waitingThreads[player] = waitingPlayerThreads
		end

		table.insert(waitingThreads[player], coroutine.running())
		coroutine.yield()
	end

	local nextActivePrediction: ActivePrediction
	nextActivePrediction = {
		id = id,
		held = {},
		isHolding = true,
		escapeThread = task.delay(MAX_PREDICTION_WAIT, function()
			PredictionsServer._sendBatch(player, nextActivePrediction.held, nil, id)
			nextActivePrediction.held = {}
			nextActivePrediction.isHolding = false
			Failures.reportOnce(
				`prediction:{remoteName}`,
				`{remoteName}'s handler was still running after {MAX_PREDICTION_WAIT}s. The prediction waiting on it was cancelled.`
			)
		end),
	}
	activePredictions[player] = nextActivePrediction
end

function PredictionsServer.finishPrediction(player: Player, id: number)
	local activePlayerPrediction = activePredictions[player]
	if not (activePlayerPrediction and activePlayerPrediction.id == id) then
		return
	end

	task.cancel(activePlayerPrediction.escapeThread)
	PredictionsServer._sendBatch(player, activePlayerPrediction.held, id)
	activePredictions[player] = nil

	local waitingPlayerThreads = waitingThreads[player]
	local poppedWaitingThread = waitingPlayerThreads and table.remove(waitingPlayerThreads, 1)
	if poppedWaitingThread then
		-- runs the next request inside this call, so back-to-back requests that never yield nest. This should
		-- not be an issue given rate limits. If it does, look into reserving the next slot and executing deferred.
		task.spawn(poppedWaitingThread)
	end
end

function PredictionsServer.holdMessage(player: Player, message: HeldMessage)
	local activePlayerPrediction = activePredictions[player]
	if not (activePlayerPrediction and activePlayerPrediction.isHolding) then
		return false
	end

	table.insert(activePlayerPrediction.held, message)
	return true
end

function PredictionsServer.acknowledgeRejected(player: Player, id: number)
	PredictionsServer._sendBatch(player, {}, id)
end

-- private
function PredictionsServer._sendBatch(player: Player, messages: { HeldMessage }, ack: number?, cancel: number?)
	assert(sendStream, "PredictionsServer has no stream sender yet")(player, 0, {
		kind = "batch",
		messages = messages,
		ack = ack,
		cancel = cancel,
	})
end

-- start
if RunService:IsServer() and RunService:IsRunning() then
	Players.PlayerRemoving:Connect(function(player)
		local activePlayerPrediction = activePredictions[player]
		if activePlayerPrediction then
			task.cancel(activePlayerPrediction.escapeThread)
			activePredictions[player] = nil
		end
		waitingThreads[player] = nil
	end)
end

return PredictionsServer
