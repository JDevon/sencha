export type Listener = { callback: (Player, ...any) -> (), connected: boolean }

return function(player: Player, listeners: { Listener }, packed: { n: number, [number]: any }, onFinished: (() -> ())?)
	if #listeners == 0 then
		if onFinished then
			onFinished()
		end
		return
	end

	local running = table.clone(listeners)
	local remaining = #running
	for _, listener in running do
		task.spawn(function()
			if listener.connected then
				local ok, trace = xpcall(
					listener.callback :: (Player, ...any) -> ...any,
					debug.traceback,
					player,
					table.unpack(packed, 1, packed.n)
				)
				if not ok then
					task.spawn(error, trace, 0)
				end
			end

			remaining -= 1
			if remaining == 0 and onFinished then
				onFinished()
			end
		end)
	end
end
