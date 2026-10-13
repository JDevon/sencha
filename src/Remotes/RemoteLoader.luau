local RunService = game:GetService("RunService")

local RemoteLoader = {}
RemoteLoader.__index = RemoteLoader

export type RemoteLoader<Inst> = typeof(setmetatable(
	{} :: {
		instance: Inst?,
	},
	{} :: {
		__index: {
			load: (self: RemoteLoader<Inst>, name: string, parent: Instance) -> Inst,
			assertInstance: (self: RemoteLoader<Inst>) -> Inst,
		},
	}
))

function RemoteLoader.new<Inst>(instance: Inst?): RemoteLoader<Inst>
	local self = setmetatable({}, RemoteLoader)
	self.instance = instance
	return self :: any
end

function RemoteLoader.load<Inst>(self: RemoteLoader<Inst>, name: string, parent: Instance): Inst
	if not RunService:IsRunning() then
		return Instance.new("RemoteEvent") :: any
	end

	local instance
	do
		if RunService:IsServer() then
			instance = assert(self.instance, `RemoteLoader {name} has no instance to load on the server`) :: any
			instance.Name = name
			instance.Parent = parent
		else
			instance = assert(
				parent:WaitForChild(name),
				`RemoteLoader {name} could not find instance in parent {parent:GetFullName()}`
			) :: any
			self.instance = instance
		end
	end

	return instance
end

function RemoteLoader.assertInstance<Inst>(self: RemoteLoader<Inst>): Inst
	return assert(self.instance, "RemoteLoader has no instance")
end

return table.freeze({
	new = RemoteLoader.new,
})
