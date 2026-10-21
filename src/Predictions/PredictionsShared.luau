local gt = require(script.Parent.Parent.Parent.GreenTea)

local predictionId = gt.build(gt.union(gt.literal(false), gt.number({ integer = true, range = "[1, ]" })))

export type PredictionId = typeof(predictionId:type())

local PredictionsShared = {}
PredictionsShared.predictionId = predictionId

function PredictionsShared.validatePredictionId(id: any): (boolean, any)
	return PredictionsShared.predictionId:matches(id)
end

return PredictionsShared
