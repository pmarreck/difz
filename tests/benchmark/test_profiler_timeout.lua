-- Drive the timeout callback directly, without clocks or live child processes.
local module_path=assert(arg[1], 'process module path required')
local function check(timeout, environment, expected)
	local recorded={}
	local uv={}
	function uv.new_pipe()
		return {close=function() end}
	end
	function uv.new_timer()
		return {
			start=function(_,ms,_,callback) recorded.timeout=ms; recorded.expire=callback end,
			stop=function() end, close=function() end,
		}
	end
	function uv.spawn(_,options,callback)
		recorded.options=options; recorded.exit=callback
		return {close=function() end,kill=function(_,signal) recorded.single=signal end},31415
	end
	function uv.read_start() end
	function uv.shutdown(_,callback) callback() end
	function uv.hrtime() return 0 end
	function uv.kill(pid,signal) recorded.pid=pid; recorded.signal=signal end
	function uv.run() recorded.expire(); recorded.exit(0,9) end
	package.loaded.luv=uv
	local getenv=os.getenv
	os.getenv=function(name) if name=='PERFORMANCE_TIMEOUT_MS' then return environment end; return getenv(name) end
	local process=dofile(module_path)
	local result=process.run({'workload'},{timeout_ms=timeout})
	os.getenv=getenv
	assert(recorded.timeout==expected, 'configured timeout was ignored')
	assert(recorded.options.detached==true, 'workload must own its process group')
	assert(recorded.pid==-31415 and recorded.signal=='sigkill', 'timeout must kill the entire workload group')
	assert(result.timed_out and result.signal==9, 'timeout must remain an invalid observation')
end
check(nil,nil,30000)
check(nil,'600000',600000)
check(1234,'600000',1234)
