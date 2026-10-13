export type Disconnect = () -> ()

return function(connection: any): Disconnect
	local connected = true
	return function()
		if connected then
			connected = false
			connection:Disconnect()
		end
	end
end
