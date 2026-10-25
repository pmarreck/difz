local root = assert(arg[1])
local workload = assert(arg[2])
assert(workload == 'mixed' or workload == 'repeated-new')
local input = assert(io.open(root..'/random', 'rb'))
local edits = assert(io.open(root..'/edits', 'rb'))
local source = assert(io.open(root..'/source', 'wb'))
local target = assert(io.open(root..'/target', 'wb'))
local zeros = string.rep('\0', 2048)
local replacement = {}
if workload == 'repeated-new' then
	for index = 1, 1024 do
		replacement[index] = assert(edits:read(2048))
		assert(#replacement[index] == 2048)
	end
end
for block = 0, 32767 do
	local data = assert(input:read(2048))
	assert(#data == 2048)
	assert(source:write(data, zeros))
	if workload == 'mixed' then
		if block % 8 == 0 then data = assert(edits:read(2048)); assert(#data == 2048) end
	elseif math.floor(block / 1024) % 2 == 0 then
		data = replacement[block % 1024 + 1]
	end
	assert(target:write(data, zeros))
end
assert(input:read(1) == nil and edits:read(1) == nil)
assert(source:close()); assert(target:close())
