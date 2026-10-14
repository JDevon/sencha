local RunService = game:GetService("RunService")

-- The error is raised on its own thread so the caller carries on (e.g. applying the rest of a snapshot)
return function(message: string)
	if RunService:IsStudio() then
		task.spawn(error, message, 0)
	else
		warn(message)
	end
end
