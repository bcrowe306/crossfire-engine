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
	// Saves (the engine's save.odin): localStorage, text in UTF-8. A blocked or full storage
	// reports failure instead of throwing
	odin_storage_set__deps: ["$UTF8ToString"],
	odin_storage_set: function (key, keyLength, value, valueLength) {
		try {
			localStorage.setItem(UTF8ToString(key, keyLength), UTF8ToString(value, valueLength));
			return 1;
		} catch (e) {
			console.error("Couldn't save: " + e);
			return 0;
		}
	},
	odin_storage_size__deps: ["$UTF8ToString", "$lengthBytesUTF8"],
	odin_storage_size: function (key, keyLength) {
		try {
			const value = localStorage.getItem(UTF8ToString(key, keyLength));
			return value === null ? -1 : lengthBytesUTF8(value);
		} catch (e) {
			return -1;
		}
	},
	odin_storage_get__deps: ["$UTF8ToString", "$stringToUTF8Array"],
	odin_storage_get: function (key, keyLength, buffer, capacity) {
		try {
			const value = localStorage.getItem(UTF8ToString(key, keyLength));
			if (value === null) return -1;
			const bytes = [];
			stringToUTF8Array(value, bytes, 0, 0x7fffffff);
			const n = Math.min(capacity, bytes.length);
			for (let i = 0; i < n; i++) HEAPU8[buffer + i] = bytes[i];
			return n;
		} catch (e) {
			return -1;
		}
	},
	odin_storage_remove__deps: ["$UTF8ToString"],
	odin_storage_remove: function (key, keyLength) {
		try { localStorage.removeItem(UTF8ToString(key, keyLength)); } catch (e) {}
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
