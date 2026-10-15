local RunService = game:GetService("RunService")

local reportedKeys: { [string]: true } = {}

local Failures = {}

-- errors in Studio, so the bug is noticed while testing, and warns in live games, where the player keeps playing.
-- The error is raised on its own thread so the caller carries on (e.g. applying the rest of a snapshot)
function Failures.report(message: string)
	if RunService:IsStudio() then
		task.spawn(error, message, 0)
	else
		warn(message)
	end
end

-- like report, but live games only report each key once, so a bug that repeats on every save won't flood the server
-- log. Studio reports every time
function Failures.reportOnce(key: string, message: string)
	if not RunService:IsStudio() then
		if reportedKeys[key] then
			return
		end
		reportedKeys[key] = true
		message ..= "\nFurther reports of this won't be shown."
	end
	Failures.report(message)
end

return table.freeze(Failures)
