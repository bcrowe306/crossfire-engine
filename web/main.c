// The C entry point of a web export: Emscripten starts programs at main. The engine exports
// odin_web_main (player_web.odin).
extern void odin_web_main(void);

int main(void) {
	odin_web_main();
	return 0;
}
