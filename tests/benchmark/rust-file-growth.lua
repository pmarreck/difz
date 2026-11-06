-- Reuse shared policy and process adapters; this gate checks declared bounds only.
local directory=assert(os.getenv('PERFORMANCE_PROCESS_MODULE')):match('^(.*)/[^/]+$')
package.path=directory..'/?.lua;'..package.path
local json,config,core,process,cpus=require('json'),require('config'),require('core'),require('process'),require('cpus')
local probe=assert(arg[1],'prepared probe required')
local file=assert(io.open('profiling-rust-file.json','rb')); local cfg=config.validate(json.decode(file:read('*a'))); file:close()
local declarations=json.decode(process.checked({probe,'--declarations'}))
local function search_profile(p)
	local fields={size=true,window=true,chain=true,hash=true,search=true,min_match=true,target=true,strategy=true,ldm=true,ldm_window=true,ldm_hash=true,ldm_rate=true,ldm_bucket=true,ldm_min_match=true,context_bytes=true,workers=true,block_bytes=true}
	for name in pairs(fields) do assert(type(p[name])=='number' and p[name]>=0 and p[name]==math.floor(p[name]),'missing or invalid native field: '..name) end
	for name in pairs(p) do assert(fields[name],'unknown native field: '..name) end
	assert(type(p.size)=='number' and p.size>0,'native size missing')
	local raw,span=0,p.size
	while span>0 do raw=raw+1; span=math.floor(span/2) end
	assert(p.window==math.max(10,math.min(31,raw)),'native window trajectory changed')
	assert(type(p.context_bytes)=='number' and p.context_bytes>0,'native context allocation missing')
	assert(p.workers==0 and p.block_bytes>0,'single-thread/block contract changed')
	if p.ldm==1 then
		assert(p.ldm_window==p.window and p.ldm_hash+p.ldm_rate==p.window,'native LDM trajectory changed')
	else
		assert(p.ldm==0 and p.ldm_window==0 and p.ldm_hash==0,'disabled LDM state changed')
	end
	return json.encode({chain=p.chain,hash=p.hash,search=p.search,min_match=p.min_match,target=p.target,strategy=p.strategy,ldm=p.ldm,ldm_rate=p.ldm_rate,ldm_bucket=p.ldm_bucket,ldm_min_match=p.ldm_min_match,workers=p.workers,block_bytes=p.block_bytes})
end
local native_parameters,native_records={},{}
for _,p in ipairs(json.decode(process.checked({probe,'--native-parameters'}))) do
	native_parameters[p.size]=search_profile(p); native_records[p.size]=json.encode(p)
end
local expected,seen={},{}
for _,d in ipairs(declarations) do assert(not expected[d.operation],'duplicate declaration'); expected[d.operation]=d.model end
assert(#declarations>0,'empty declarations')
for _,case in ipairs(cfg.cases) do
	assert(expected[case.operation]==case.model and case.model=='linear','unregistered or stale model')
	assert(case.cores==1 or case.cores==2 or case.cores==12,'unsupported core scope')
	assert(case.mode==(case.cores==12 and 'bm' or 'cg'),'incorrect required/extended scope')
	local key=case.operation..'/'..case.cores; assert(not seen[key],'duplicate measurement'); seen[key]=true
	assert(#case.sizes==4,'four-point sweep required')
	local parameters
	for _,size in ipairs(case.sizes) do
		local key=assert(native_parameters[size],'missing native SDK parameter record')
		assert(not parameters or key==parameters,'scaling case crosses native parameter regimes')
		parameters=key
	end
end
for operation in pairs(expected) do for _,cores in ipairs({1,2,12}) do assert(seen[operation..'/'..cores],'unmeasured declaration') end end
if arg[2]=='--coverage-only' then print('PASS compiled growth declarations have complete measurement coverage'); return end
local results={}
for _,case in ipairs(cfg.cases) do
	if case.mode=='cg' then
	local allowed=assert(cpus.allowed(),'Linux CPU affinity required')
	local pool=os.getenv('PERFORMANCE_CPUS')
	if pool then
		local permitted={}; for _,cpu in ipairs(allowed) do permitted[cpu]=true end
		allowed=cpus.parse(pool); for _,cpu in ipairs(allowed) do assert(permitted[cpu],'CPU pool outside allowed affinity') end
	end
	local selected=cpus.select(allowed,case.cores)
	local result=core.run(case,{count=0},function()
		local argv=cpus.pin({probe,'--measure',case.operation,table.concat(case.sizes,','),'41'},selected)
		local run=process.run(argv,{timeout_ms=30000,env={PERFORMANCE_CORES=tostring(case.cores)}})
		assert(run.rc==0 and run.signal==0 and not run.timed_out,'probe failed: '..run.stderr)
		local measurement=json.decode(run.stdout)
		assert(type(measurement.sample_order)=='table' and #measurement.sample_order==5,'five interleaved rounds required')
		for _,round in ipairs(measurement.sample_order) do
			assert(#round==#case.sizes,'incomplete sample round')
			local visited={}
			for _,size in ipairs(round) do assert(not visited[size],'duplicate size in sample round'); visited[size]=true end
			for _,size in ipairs(case.sizes) do assert(visited[size],'missing size in sample round') end
		end
		local first
		for _,row in ipairs(measurement.rows) do
			local parameters=row.native_parameters
			assert(parameters.size==row.size,'native parameter identity mismatch')
			assert(json.encode(parameters)==native_records[row.size],'native SDK record mismatch')
			local key=search_profile(parameters)
			assert(not first or key==first,'scaling case crosses native parameter regimes')
			first=key
		end
		return measurement
	end)
	results[#results+1]={case=case.name,cpus=selected,result=result}
	if result.verdict~='UNBASELINED' or not result.candidate or result.candidate.approvable~=true then
		io.stderr:write(json.encode(results),'\n'); error('declared growth or measurement validation failed')
	end
	end
end
print(json.encode({scope='declared-growth-only',historical_comparison='not evaluated',cases=results}))
print('PASS declared Rust file growth: both operations, 1/2 cores, all adjacent ratios; extended 12-core cases remain in ./big_o')
