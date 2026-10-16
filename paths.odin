package engine

import "core:strings"

// The engine's own path join ("a" + "b" -> "a/b"): `core:path/filepath` needs `core:os`, which the
// web build doesn't have. Paths in project files always use "/". Temp allocated
JoinPath :: proc(parts: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for part, i in parts {
		if part == "" do continue
		if strings.builder_len(b) > 0 && !strings.has_suffix(strings.to_string(b), "/") do strings.write_byte(&b, '/')
		strings.write_string(&b, i > 0 ? strings.trim_left(part, "/") : part)
	}
	return strings.to_string(b)
}
