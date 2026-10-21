package crossfire

/*
A strict zlib inflater (RFC 1950 / RFC 1951) for data the engine doesn't trust (Aseprite files'
images): it writes into a buffer of the size the caller expects and never past it, treats running
out of input as an error, and checks the Adler-32 sum. `core:compress/zlib` feeds zeros after the
end of its input and grows its output without bound, so a damaged file could make it allocate
gigabytes (seen: a minute per bad image, then a crash).
*/

/*
Inflates a zlib stream that must decompress to exactly `size` bytes.

Inputs:
- compressed: The zlib stream (header, deflate blocks, Adler-32)
- size: How many bytes it holds
- allocator: For the result

Returns:
- The bytes, and false (nil) if the stream is damaged, shorter or longer than `size`
*/
@(private)
Inflate_Exact :: proc(compressed: []u8, size: int, allocator := context.allocator) -> ([]u8, bool) {
	if size < 0 || len(compressed) < 6 do return nil, false
	// Deflate packs at most 258 bytes into about two bits: a larger size is a damaged stream (and
	// isn't allocated)
	if size > len(compressed) * 1032 + 1024 do return nil, false
	// The header: deflate, a 32 KB window at most, no preset dictionary, its check bits
	cmf, flg := compressed[0], compressed[1]
	if cmf & 0x0f != 8 || cmf >> 4 > 7 || flg & 0x20 != 0 || (u32(cmf) * 256 + u32(flg)) % 31 != 0 do return nil, false
	out := make([]u8, size, allocator)
	s := Inflater{input = compressed, pos = 2, out = out}
	for {
		last := bits(&s, 1)
		switch bits(&s, 2) {
		case 0: stored(&s)
		case 1: fixedBlock(&s)
		case 2: dynamicBlock(&s)
		case:   s.failed = true
		}
		if s.failed || last == 1 do break
	}
	// The Adler-32 of the output, big-endian, after the last block's byte
	if !s.failed && s.outPos == size && s.pos + 4 <= len(compressed) {
		a, b: u32 = 1, 0
		for v in out {
			a = (a + u32(v)) % 65521
			b = (b + a) % 65521
		}
		sum := u32(compressed[s.pos]) << 24 | u32(compressed[s.pos + 1]) << 16 | u32(compressed[s.pos + 2]) << 8 | u32(compressed[s.pos + 3])
		if sum == b << 16 | a do return out, true
	}
	delete(out, allocator)
	return nil, false
}

@(private="file")
Inflater :: struct {
	input: []u8,
	pos: int,
	bitBuffer: u32,
	bitCount: u32,
	out: []u8,
	outPos: int,
	failed: bool,
}

@(private="file")
MAX_BITS :: 15

// A canonical Huffman code: how many codes of each length, and the symbols in code order
@(private="file")
Huffman :: struct {
	count: [MAX_BITS + 1]u16,
	symbol: [288]u16,
}

@(private="file")
bits :: proc(s: ^Inflater, n: u32) -> u32 {
	for s.bitCount < n {
		if s.pos >= len(s.input) {
			s.failed = true
			return 0
		}
		s.bitBuffer |= u32(s.input[s.pos]) << s.bitCount
		s.pos += 1
		s.bitCount += 8
	}
	value := s.bitBuffer & ((1 << n) - 1)
	s.bitBuffer >>= n
	s.bitCount -= n
	return value
}

// A block stored as it is: its length, the length's complement, the bytes
@(private="file")
stored :: proc(s: ^Inflater) {
	s.bitBuffer, s.bitCount = 0, 0
	if s.pos + 4 > len(s.input) {
		s.failed = true
		return
	}
	length := int(s.input[s.pos]) | int(s.input[s.pos + 1]) << 8
	complement := int(s.input[s.pos + 2]) | int(s.input[s.pos + 3]) << 8
	s.pos += 4
	if length != ~complement & 0xffff || s.pos + length > len(s.input) || s.outPos + length > len(s.out) {
		s.failed = true
		return
	}
	copy(s.out[s.outPos:], s.input[s.pos:][:length])
	s.pos += length
	s.outPos += length
}

// Builds a code from each symbol's code length; false if the lengths are over-subscribed (or
// incomplete, unless only one code is used, as RFC 1951 allows for distances)
@(private="file")
build :: proc(h: ^Huffman, lengths: []u16) -> bool {
	h.count = {}
	for l in lengths do h.count[l] += 1
	if int(h.count[0]) == len(lengths) do return true
	left := 1
	for l in 1..=MAX_BITS {
		left <<= 1
		left -= int(h.count[l])
		if left < 0 do return false
	}
	offsets: [MAX_BITS + 1]u16
	for l in 1..<MAX_BITS do offsets[l + 1] = offsets[l] + h.count[l]
	for l, symbol in lengths do if l != 0 {
		h.symbol[offsets[l]] = u16(symbol)
		offsets[l] += 1
	}
	return left == 0 || len(lengths) - int(h.count[0]) == 1
}

@(private="file")
decode :: proc(s: ^Inflater, h: ^Huffman) -> int {
	code, first, index := 0, 0, 0
	for l in 1..=MAX_BITS {
		code |= int(bits(s, 1))
		if s.failed do return -1
		count := int(h.count[l])
		if code - count < first do return int(h.symbol[index + code - first])
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	s.failed = true
	return -1
}

@(private="file")
LENGTH_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private="file")
LENGTH_EXTRA := [29]u16{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private="file")
DISTANCE_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private="file")
DISTANCE_EXTRA := [30]u16{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

// A compressed block's symbols until its end code: literals, and copies from earlier output
@(private="file")
codes :: proc(s: ^Inflater, lengthCode, distanceCode: ^Huffman) {
	for !s.failed {
		symbol := decode(s, lengthCode)
		switch {
		case symbol < 0:
			return
		case symbol < 256:
			if s.outPos >= len(s.out) {
				s.failed = true
				return
			}
			s.out[s.outPos] = u8(symbol)
			s.outPos += 1
		case symbol == 256:
			return
		case:
			symbol -= 257
			if symbol >= 29 {
				s.failed = true
				return
			}
			length := int(LENGTH_BASE[symbol]) + int(bits(s, u32(LENGTH_EXTRA[symbol])))
			d := decode(s, distanceCode)
			if d < 0 || d >= 30 {
				s.failed = true
				return
			}
			distance := int(DISTANCE_BASE[d]) + int(bits(s, u32(DISTANCE_EXTRA[d])))
			if s.failed || distance > s.outPos || s.outPos + length > len(s.out) {
				s.failed = true
				return
			}
			// Byte by byte: a copy may overlap what it writes (a run)
			for _ in 0..<length {
				s.out[s.outPos] = s.out[s.outPos - distance]
				s.outPos += 1
			}
		}
	}
}

@(private="file")
fixedBlock :: proc(s: ^Inflater) {
	// Built each time (cheap), so threads share nothing
	lengthCode, distanceCode: Huffman
	lengths: [288]u16
	for i in 0..<144 do lengths[i] = 8
	for i in 144..<256 do lengths[i] = 9
	for i in 256..<280 do lengths[i] = 7
	for i in 280..<288 do lengths[i] = 8
	build(&lengthCode, lengths[:])
	distances: [30]u16
	for &d in distances do d = 5
	build(&distanceCode, distances[:])
	codes(s, &lengthCode, &distanceCode)
}

@(private="file")
dynamicBlock :: proc(s: ^Inflater) {
	ORDER :: [19]int{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}
	literals := int(bits(s, 5)) + 257
	distances := int(bits(s, 5)) + 1
	lengthCodes := int(bits(s, 4)) + 4
	if s.failed || literals > 286 || distances > 30 {
		s.failed = true
		return
	}
	lengths: [320]u16
	order := ORDER
	for i in 0..<lengthCodes do lengths[order[i]] = u16(bits(s, 3))
	lengthsCode: Huffman
	if !build(&lengthsCode, lengths[:19]) || s.failed {
		s.failed = true
		return
	}
	lengths = {}
	for i := 0; i < literals + distances; {
		symbol := decode(s, &lengthsCode)
		if symbol < 0 do return
		if symbol < 16 {
			lengths[i] = u16(symbol)
			i += 1
			continue
		}
		value: u16
		repeat: int
		switch symbol {
		case 16:
			if i == 0 {
				s.failed = true
				return
			}
			value = lengths[i - 1]
			repeat = 3 + int(bits(s, 2))
		case 17:
			repeat = 3 + int(bits(s, 3))
		case:
			repeat = 11 + int(bits(s, 7))
		}
		if s.failed || i + repeat > literals + distances {
			s.failed = true
			return
		}
		for _ in 0..<repeat {
			lengths[i] = value
			i += 1
		}
	}
	// The block must be able to end
	if lengths[256] == 0 {
		s.failed = true
		return
	}
	lengthCode, distanceCode: Huffman
	if !build(&lengthCode, lengths[:literals]) || !build(&distanceCode, lengths[literals:][:distances]) {
		s.failed = true
		return
	}
	codes(s, &lengthCode, &distanceCode)
}
