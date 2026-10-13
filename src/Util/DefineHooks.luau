type Hook = (name: string, parent: Instance) -> ()

local hooks: { [any]: Hook } = setmetatable({}, { __mode = "k" }) :: any

local DefineHooks = {}

function DefineHooks.set(implementation: any, hook: Hook)
	hooks[implementation] = hook
end

function DefineHooks.run(implementation: any, name: string, parent: Instance)
	local hook = hooks[implementation]
	if not hook then
		error(`{name} cannot be defined: it is not a network implementation, or it was already defined`, 3)
	end

	hooks[implementation] = nil
	hook(name, parent)
end

return DefineHooks
