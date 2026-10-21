local predictionId = 0

local PredictionsClient = {}

function PredictionsClient.getNextPredictionId()
	predictionId = predictionId + 1
	return predictionId
end

return PredictionsClient
