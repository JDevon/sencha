local PredictionsShared = require(script.Parent.PredictionsShared)

local PredictionsServer = {}

function PredictionsServer.validatePredictionId(id: any): (boolean, any)
	return PredictionsShared.predictionId:matches(id)
end

return PredictionsServer
