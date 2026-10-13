return function<A..., R...>(callback: (A...) -> R..., ...: A...): R...
	local thread = coroutine.create(callback)
	local results: any = table.pack(coroutine.resume(thread, ...))

	local ok = results[1]
	if not ok then
		error(debug.traceback(thread, `Thread errored: {results[2]}`))
	end

	if coroutine.status(thread) ~= "dead" then
		local trace = debug.traceback(thread, "Thread yielded. Yielding is not allowed in this context.")
		coroutine.close(thread)
		error(trace)
	end

	return table.unpack(results, 2, results.n)
end
