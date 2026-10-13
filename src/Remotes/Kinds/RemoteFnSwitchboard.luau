local RunService = game:GetService("RunService")

local RemoteFunction = require(script.Parent.RemoteFunction)
local RateLimiter = require(script.Parent.Parent.RateLimiter)
local DefineHooks = require(script.Parent.Parent.Parent.DefineHooks)

--[=[
	@class FunctionSwitchboard

	One `RemoteFunction` that routes calls from clients to a server callback chosen by port name, created with
	[Sencha.funcSwitchboard]. Every port shares the same argument types.

	Each port has its own rate limit budget per player, so unrelated actions don't share one. Calls to a port with
	no callback are rejected.

	```lua
	-- server
	shopSwitchboard:connect("buy", function(player, itemId)
		return true
	end)

	-- client
	local bought = shopSwitchboard:invokeServer("buy", 12)
	```
]=]
local RemoteFnSwitchboard = {}
RemoteFnSwitchboard.__index = RemoteFnSwitchboard

export type RemoteFnSwitchboard<T..., R...> = typeof(setmetatable(
	{} :: {
		connectionMap: { [string]: (Player, T...) -> R... },
		remote: RemoteFunction.Function<T..., R...>,
	},
	{} :: {
		__index: {
			connect: (
				self: RemoteFnSwitchboard<T..., R...>,
				port: string,
				callback: (Player, T...) -> R...
			) -> () -> (),
			invokeServer: (self: RemoteFnSwitchboard<T..., R...>, port: string, T...) -> R...,
			rateLimit: (
				self: RemoteFnSwitchboard<T..., R...>,
				limit: RateLimiter.Limit
			) -> RemoteFnSwitchboard<T..., R...>,
			destroy: (self: RemoteFnSwitchboard<T..., R...>) -> (),
		},
	}
))

function RemoteFnSwitchboard.new<T..., R...>(args: (T...) -> (), ret: () -> R...): RemoteFnSwitchboard<T..., R...>
	local self = setmetatable({}, RemoteFnSwitchboard)
	self.connectionMap = {}
	self.remote = RemoteFunction.new(args, ret)

	if RunService:IsServer() then
		local remoteInstance = self.remote.loader:assertInstance()
		local rateLimiter = assert(self.remote.rateLimiter, "RateLimiter should exist on the server.")
		local rejections = assert(self.remote.rejections, "RemoteRejections should exist on the server.")

		remoteInstance.OnServerInvoke = function(player, port, ...)
			local callback = if type(port) == "string" then self.connectionMap[port] else nil
			if not callback then
				rejections:reject(player, "unknown port")
				error(`{rejections:getName()} has no such port`, 0)
			end

			if not rateLimiter:tryConsume(player, port) then
				rejections:reject(player, "rate limited", port)
				error(`{rejections:getName()} is rate limited; try again shortly`, 0)
			end

			local ok, cause = self.remote.argTypechecker:matches(...)
			if not ok then
				rejections:reject(player, "invalid arguments", port, cause:formatErr())
				error(`{rejections:getName()} received invalid arguments`, 0)
			end

			return self.remote.retTypechecker:check(callback(player, ...))
		end
	end

	DefineHooks.set(self, function(name, parent)
		DefineHooks.run(self.remote, name, parent)
	end)

	return self :: any
end

--[=[
	@method connect
	@within FunctionSwitchboard
	@server

	Sets the callback for `port`. Errors if the port already has one. Returns a function that removes it.

	@param port string
	@param callback (player: Player, T...) -> R...
	@return () -> ()
]=]
function RemoteFnSwitchboard.connect<T..., R...>(
	self: RemoteFnSwitchboard<T..., R...>,
	port: string,
	callback: (Player, T...) -> R...
)
	assert(RunService:IsServer(), "RemoteFnSwitchboard.connect can only be called from the server")
	if self.connectionMap[port] then
		error(`Port {port} is already connected`)
	end

	self.connectionMap[port] = callback
	return function()
		self.connectionMap[port] = nil
	end
end

--[=[
	@method invokeServer
	@within FunctionSwitchboard
	@client
	@yields

	Calls the server callback for `port` and returns what it returns.

	@param port string
	@param ... T...
	@return R...
]=]
function RemoteFnSwitchboard.invokeServer<T..., R...>(self: RemoteFnSwitchboard<T..., R...>, port: string, ...: T...): R...
	assert(RunService:IsClient(), "RemoteFnSwitchboard.invokeServer can only be called from the client")
	return self.remote.retTypechecker:check(
		self.remote.loader:assertInstance():InvokeServer(port, self.remote.argTypechecker:check(...))
	)
end

--[=[
	@method rateLimit
	@within FunctionSwitchboard
	@server

	Sets the rate limit for calls to each port from each player, replacing the default of 60 at once and 30 per second. Returns
	the same switchboard, so it can be chained where it's created. Errors if the limit is invalid.

	```lua
	shopSwitchboard = Sencha.funcSwitchboard(gt.args(gt.number()), gt.returns(gt.boolean())):rateLimit({ burst = 5, perSecond = 2 }),
	```

	@param limit Limit
	@return FunctionSwitchboard
]=]
function RemoteFnSwitchboard.rateLimit<T..., R...>(
	self: RemoteFnSwitchboard<T..., R...>,
	limit: RateLimiter.Limit
): RemoteFnSwitchboard<T..., R...>
	RateLimiter.validateLimit(limit)
	if RunService:IsServer() then
		assert(self.remote.rateLimiter, "RateLimiter should exist on the server."):setLimit(limit)
	end
	return self
end

--[=[
	@method destroy
	@within FunctionSwitchboard

	Destroys the remote instance on the server.
]=]
function RemoteFnSwitchboard.destroy<T..., R...>(self: RemoteFnSwitchboard<T..., R...>)
	self.remote:destroy()
end

return table.freeze({
	new = RemoteFnSwitchboard.new,
})
