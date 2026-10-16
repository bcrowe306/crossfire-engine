// Emscripten --pre-js for web exports. The wasm imports Odin's runtime functions (odin_env.js)
// from the module "odin_env", which Emscripten doesn't know: it only fills "env". Give the
// instance "env" under that name too.
(function () {
	function withOdinEnv(imports) {
		if (imports && imports.env && !imports.odin_env) imports.odin_env = imports.env;
		return imports;
	}
	const instantiate = WebAssembly.instantiate;
	WebAssembly.instantiate = function (source, imports) {
		return instantiate.call(WebAssembly, source, withOdinEnv(imports));
	};
	const instantiateStreaming = WebAssembly.instantiateStreaming;
	if (instantiateStreaming) {
		WebAssembly.instantiateStreaming = function (source, imports) {
			return instantiateStreaming.call(WebAssembly, source, withOdinEnv(imports));
		};
	}
})();
