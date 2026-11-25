-- Project adapter: shared engine owns timing validation, bounds and retry policy.
local directory=assert(os.getenv('PERFORMANCE_PROCESS_MODULE')):match('^(.*)/[^/]+$')
package.path=directory..'/?.lua;'..package.path
local json,config,core,process,cpus=require('json'),require('config'),require('core'),require('process'),require('cpus')
local probe=assert(arg[1],'prepared probe required')
local file=assert(io.open('profiling-rust-structure.json','rb'))
local cfg=config.validate(json.decode(file:read('*a'))); file:close()
local declarations=json.decode(process.checked({probe,'--structure-declarations'}))
local expected,seen={},{}
for _,d in ipairs(declarations) do
	assert(not expected[d.operation],'duplicate declaration'); expected[d.operation]=d
end
assert(#declarations>0,'empty declarations')
for _,case in ipairs(cfg.cases) do
	local d=assert(expected[case.operation],'unregistered operation')
	assert(case.model==d.model and case.axis==d.axis,'stale model or input dimension')
	assert(case.cores==1 or case.cores==2 or case.cores==12,'unsupported core scope')
	assert(case.mode==(case.cores==12 and 'bm' or 'cg'),'incorrect required/extended scope')
	assert(case.metric=='cpu_ns','process CPU metric required')
	local key=case.operation..'/'..case.cores; assert(not seen[key],'duplicate measurement'); seen[key]=true
	assert(#case.sizes==4,'four-point sweep required')
	local sizes=d.sizes; assert(type(sizes)=='table' and #sizes==4,'compiled size declaration required')
	for i,size in ipairs(sizes) do assert(case.sizes[i]==size,'input sweep changed') end
end
for operation in pairs(expected) do
	for _,cores in ipairs({1,2,12}) do assert(seen[operation..'/'..cores],'unmeasured declaration') end
end
if arg[2]=='--coverage-only' then print('PASS compiled metadata/directory declarations have complete measurement coverage'); return end
local allowed=assert(cpus.allowed(),'Linux CPU affinity required')
local pool=os.getenv('PERFORMANCE_CPUS')
if pool then
	local permitted={}; for _,cpu in ipairs(allowed) do permitted[cpu]=true end
	allowed=cpus.parse(pool); for _,cpu in ipairs(allowed) do assert(permitted[cpu],'CPU pool outside allowed affinity') end
end
local results={}
for _,case in ipairs(cfg.cases) do
	if case.mode=='cg' then
		local selected=cpus.select(allowed,case.cores)
		local result=core.run(case,{count=0},function()
			local argv=cpus.pin({probe,'--measure-structure',case.operation,table.concat(case.sizes,','),'41'},selected)
			local run=process.run(argv,{timeout_ms=30000,env={PERFORMANCE_CORES=tostring(case.cores)}})
			assert(run.rc==0 and run.signal==0 and not run.timed_out,'probe failed: '..run.stderr)
			local measurement=json.decode(run.stdout)
			assert(measurement.operation==case.operation and measurement.axis==case.axis and measurement.seed=='41','workload identity mismatch')
			assert(#measurement.sample_order==5,'five interleaved rounds required')
			for _,round in ipairs(measurement.sample_order) do
				assert(#round==4,'incomplete size round'); local visited={}
				for _,size in ipairs(round) do assert(not visited[size],'duplicate size'); visited[size]=true end
				for _,size in ipairs(case.sizes) do assert(visited[size],'missing size') end
			end
			return measurement
		end)
		results[#results+1]={case=case.name,cpus=selected,result=result}
		if result.verdict~='UNBASELINED' or not result.candidate or result.candidate.approvable~=true then
			io.stderr:write(json.encode(results),'\n'); error('structure growth or measurement validation failed')
		end
	end
end
print(json.encode({scope='declared-growth-only',historical_comparison='not evaluated',cases=results}))
print('PASS declared metadata/directory growth: all compiled operations, 1/2 cores and all adjacent ratios')
