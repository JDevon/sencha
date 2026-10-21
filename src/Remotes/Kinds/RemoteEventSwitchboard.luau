local RunService = game:GetService("RunService")

local RemoteEvent = require(script.Parent.RemoteEvent)
local RateLimiter = require(script.Parent.Parent.RateLimiter)
local Cleanup = require(script.Parent.Parent.Parent.Util.Cleanup)
local DefineHooks = require(script.Parent.Parent.Parent.Util.DefineHooks)
local PredictionsServer = require(script.Parent.Parent.Parent.Predictions.PredictionsServer)

--[=[
	@class EventSwitchboard

	One `RemoteEvent` that routes calls from clients to a server callback chosen by port name, created with
	[Sencha.eventSwitchboard]. Every port shares the same argument types.

	Each port has its own rate limit budget per player, so unrelated actions don't share one. Calls to a port with
	no callback are rejected.

	```lua
	-- server
	toolSwitchboard:connect("drop", function(player, slot)
		...
	end)

	-- client
	toolSwitchboard:fireServer("drop", 3)
	```
]=]
local RemoteEventSwitchboard = {}
RemoteEventSwitchboard.__index = RemoteEventSwitchboard

export type RemoteEventSwitchboard<T...> = typeof(setmetatable(
	{} :: {
		cleanup: Cleanup.Cleanup,
		connectionMap: { [string]: (Player, T...) -> () },
		remote: RemoteEvent.Event<T...>,
	},
	{} :: {
		__index: {
			connect: (self: RemoteEventSwitchboard<T...>, port: string, callback: (Player, T...) -> ()) -> () -> (),
			fireServer: (self: RemoteEventSwitchboard<T...>, port: string, T...) -> (),
			rateLimit: (self: RemoteEventSwitchboard<T...>, limit: RateLimiter.Limit) -> RemoteEventSwitchboard<T...>,
			destroy: (self: RemoteEventSwitchboard<T...>) -> (),
		},
	}
))

function RemoteEventSwitchboard.new<T...>(...: T...): RemoteEventSwitchboard<T...>
	local self = setmetatable({}, RemoteEventSwitchboard)
	self.cleanup = Cleanup.new()
	self.connectionMap = {}
	self.remote = RemoteEvent.new(...)

	if RunService:IsServer() then
		local remoteInstance = self.remote.loader:assertInstance()
		local rateLimiter = assert(self.remote.rateLimiter, "RateLimiter should exist on the server.")
		local rejections = assert(self.remote.rejections, "RemoteRejections should exist on the server.")

		self.cleanup:add(remoteInstance.OnServerEvent:Connect(function(player, predictionId, port, ...)
			local ok, cause = PredictionsServer.validatePredictionId(predictionId)
			if not ok then
				rejections:reject(player, "invalid prediction id", nil, cause:formatErr())
				return
			end

			local callback = if type(port) == "string" then self.connectionMap[port] else nil
			if not callback then
				rejections:reject(player, "unknown port")
				return
			end

			if not rateLimiter:tryConsume(player, port) then
				rejections:reject(player, "rate limited", port)
				return
			end

			ok, cause = self.remote.typechecker:matches(...)
			if not ok then
				rejections:reject(player, "invalid arguments", port, cause:formatErr())
				return
			end

			callback(player, ...)
		end))
	end

	DefineHooks.set(self, function(name, parent)
		DefineHooks.run(self.remote, name, parent)
	end)

	return self :: any
end

--[=[
	@method connect
	@within EventSwitchboard
	@server

	Sets the callback for `port`. Errors if the port already has one. Returns a function that removes it.

	@param port string
	@param callback (player: Player, T...) -> ()
	@return () -> ()
]=]
function RemoteEventSwitchboard.connect<T...>(
	self: RemoteEventSwitchboard<T...>,
	port: string,
	callback: (Player, T...) -> ()
)
	assert(RunService:IsServer(), "RemoteEventSwitchboard.connect can only be called from the server")
	if self.connectionMap[port] then
		error(`Port {port} is already connected`)
	end

	self.connectionMap[port] = callback
	return function()
		self.connectionMap[port] = nil
	end
end

--[=[
	@method fireServer
	@within EventSwitchboard
	@client

	Sends the arguments to the server callback for `port`.

	@param port string
	@param ... T...
]=]
function RemoteEventSwitchboard.fireServer<T...>(self: RemoteEventSwitchboard<T...>, port: string, ...: T...)
	assert(RunService:IsClient(), "RemoteEventSwitchboard.fireServer can only be called from the client")
	return self.remote.loader:assertInstance():FireServer(false, port, self.remote.typechecker:check(...))
end

--[=[
	@method rateLimit
	@within EventSwitchboard
	@server

	Sets the rate limit for calls to each port from each player, replacing the default of 60 at once and 30 per second.
	Returns the same switchboard, so it can be chained where it's created. Errors if the limit is invalid.

	```lua
	shopSwitchboard = Sencha.eventSwitchboard(gt.number()):rateLimit({ burst = 5, perSecond = 2 }),
	```

	@param limit Limit
	@return EventSwitchboard
]=]
function RemoteEventSwitchboard.rateLimit<T...>(
	self: RemoteEventSwitchboard<T...>,
	limit: RateLimiter.Limit
): RemoteEventSwitchboard<T...>
	RateLimiter.validateLimit(limit)
	if RunService:IsServer() then
		assert(self.remote.rateLimiter, "RateLimiter should exist on the server."):setLimit(limit)
	end
	return self
end

--[=[
	@method destroy
	@within EventSwitchboard

	Destroys the remote instance on the server.
]=]
function RemoteEventSwitchboard.destroy<T...>(self: RemoteEventSwitchboard<T...>)
	self.remote:destroy()
	self.cleanup:destroy()
end

return table.freeze({
	new = RemoteEventSwitchboard.new,
})
