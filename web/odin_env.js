// Emscripten JS library (emcc --js-library) with the functions Odin's js_wasm32 runtime imports
// from its "odin_env" module. Emscripten links them as ordinary imports. Odin passes a slice as
// two arguments, pointer and length.
addToLibrary({
	// Odin's stderr (panics, runtime.print), a piece at a time: to the browser console by line
	$odinPending: "''",
	write__deps: ["$UTF8ToString", "$odinPending"],
	write: function (fd, ptr, len) {
		odinPending += UTF8ToString(ptr, len);
		const lines = odinPending.split("\n");
		odinPending = lines.pop();
		for (const line of lines) (fd === 2 ? console.error : console.log)(line);
	},
	rand_bytes: function (ptr, len) {
		crypto.getRandomValues(HEAPU8.subarray(ptr, ptr + len));
	},
	// Written out: Emscripten copies each function's source into its output
	sin: function (x) { return Math.sin(x); },
	cos: function (x) { return Math.cos(x); },
	pow: function (x, y) { return Math.pow(x, y); },
	ln: function (x) { return Math.log(x); },
	exp: function (x) { return Math.exp(x); },
	fmuladd: function (a, b, c) { return a * b + c; },
});
