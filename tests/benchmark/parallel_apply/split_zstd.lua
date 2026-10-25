-- Independent standard-frame boundary reader for native CLI verification only.
-- Production decoding uses libzstd's own validated frame scanner.
local bit = require('bit')
local input = assert(io.open(assert(arg[1]), 'rb'))
local data = assert(input:read('*a'))
assert(input:close())
local output = assert(arg[2])
local position, count = 1, 0
while position <= #data do
	local first = position
	assert(data:sub(position, position + 3) == '\x28\xb5\x2f\xfd', 'frame magic')
	position = position + 4
	local descriptor = assert(data:byte(position), 'frame descriptor')
	assert(bit.band(descriptor, 24) == 0, 'reserved descriptor bits')
	position = position + 1
	local single = bit.band(descriptor, 32) ~= 0
	if not single then position = position + 1 end
	local dictionary_bytes = ({0, 1, 2, 4})[bit.band(descriptor, 3) + 1]
	local size_flag = bit.rshift(descriptor, 6)
	local size_bytes = ({single and 1 or 0, 2, 4, 8})[size_flag + 1]
	position = position + dictionary_bytes + size_bytes
	local last
	repeat
		local a, b, c = data:byte(position, position + 2)
		assert(c, 'truncated block header')
		local header = a + 256 * b + 65536 * c
		last = bit.band(header, 1) ~= 0
		local kind = bit.band(bit.rshift(header, 1), 3)
		assert(kind ~= 3, 'reserved block type')
		local stored = kind == 1 and 1 or bit.rshift(header, 3)
		position = position + 3 + stored
		assert(position <= #data + 1, 'truncated block')
	until last
	if bit.band(descriptor, 4) ~= 0 then position = position + 4 end
	assert(position <= #data + 1, 'truncated checksum')
	count = count + 1
	local name = 'frame-'..count..'.zst'
	local file = assert(io.open(output..'/'..name, 'wb'))
	assert(file:write(data:sub(first, position - 1)))
	assert(file:close())
	io.write(name, '\n')
end
assert(count > 0, 'empty stream')
