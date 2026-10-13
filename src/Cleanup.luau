export type Task = Instance | RBXScriptConnection | { Destroy: (any) -> () } | () -> ()

local Cleanup = {}
Cleanup.__index = Cleanup

export type Cleanup = typeof(setmetatable(
	{} :: {
		tasks: { Task },
	},
	Cleanup
))

function Cleanup.new(): Cleanup
	local self = setmetatable({}, Cleanup)
	self.tasks = {}
	return self
end

function Cleanup.add(self: Cleanup, cleanupTask: Task)
	table.insert(self.tasks, cleanupTask)
end

function Cleanup.destroy(self: Cleanup)
	local tasks = self.tasks
	self.tasks = {}
	for _, cleanupTask in tasks do
		if type(cleanupTask) == "function" then
			cleanupTask()
		elseif typeof(cleanupTask) == "RBXScriptConnection" then
			cleanupTask:Disconnect()
		else
			(cleanupTask :: any):Destroy()
		end
	end
end

return table.freeze({
	new = Cleanup.new,
})
