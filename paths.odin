package crossfire

import "core:strings"

/*
Joins path parts with "/" ("a" + "b" -> "a/b"). The engine's own: `core:path/filepath` needs
`core:os`, which the web build doesn't have. Paths in project files always use "/".

Empty parts are skipped; a later part's leading "/" is dropped once something is written (so
an absolute path after empty parts stays absolute), and no "/" is doubled after a part that ends
in one.

Inputs:
- parts: The parts, in order

Returns:
- The joined path (temp allocated)

Example:
	path := e.JoinPath(game.projectDir, "assets", "ship.png")
	_ = path
*/
JoinPath :: proc(parts: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for part in parts {
		if part == "" do continue
		if strings.builder_len(b) == 0 {
			strings.write_string(&b, part)
			continue
		}
		if !strings.has_suffix(strings.to_string(b), "/") do strings.write_byte(&b, '/')
		strings.write_string(&b, strings.trim_left(part, "/"))
	}
	return strings.to_string(b)
}
