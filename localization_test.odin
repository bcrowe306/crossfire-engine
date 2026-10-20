#+build !js
package crossfire

import "core:log"
import os "core:os"
import "core:testing"

@(test)
translations_load_merge_and_fall_back :: proc(t: ^testing.T) {
	game: Game
	defer if game.arenaReady do MemoryArena_Destroy(&game.arena)

	ok := Locale_LoadCSV(&game, `key,en,fr
menu.play,Play,Jouer
# a comment row
,ignored too
hud.coins,"Coins: %d","Pièces : %d"
quote,"She said ""hi"", twice","Elle a dit ""salut"""
lines,"one
two",
`)
	testing.expect(t, ok, "parsed")
	testing.expect(t, len(Locale_List(&game)) == 2 && Locale_Get(&game) == "en", "the first language is the starting one")
	testing.expect_value(t, Tr("menu.play", &game), "Play")
	testing.expect_value(t, Tr("quote", &game), `She said "hi", twice`)
	testing.expect_value(t, Tr("lines", &game), "one\ntwo")
	testing.expect_value(t, Tr("missing.key", &game), "missing.key")
	testing.expect_value(t, Tr("# a comment row", &game), "# a comment row")

	testing.expect(t, Locale_Set(&game, "fr"), "French")
	testing.expect_value(t, Tr("menu.play", &game), "Jouer")
	testing.expect_value(t, Tr("hud.coins", &game), "Pièces : %d")
	// No French: the first language's
	testing.expect_value(t, Tr("lines", &game), "one\ntwo")
	// A region finds its language
	testing.expect(t, Locale_Set(&game, "en_GB") && Locale_Get(&game) == "en", "en_GB is en")
	testing.expect(t, Locale_Set(&game, "FR-ca") && Locale_Get(&game) == "fr", "FR-ca is fr")
	testing.expect(t, !Locale_Set(&game, "de") && Locale_Get(&game) == "fr", "unknown: unchanged")

	// Another table adds a language and keys, and replaces a text
	ok = Locale_LoadCSV(&game, "id,de,fr\nmenu.play,Spielen,Lancer\nmenu.quit,Beenden,Quitter\n")
	testing.expect(t, ok && len(Locale_List(&game)) == 3, "merged")
	testing.expect_value(t, Tr("menu.play", &game), "Lancer")
	testing.expect_value(t, Tr("menu.quit", &game), "Quitter")
	testing.expect(t, Locale_Set(&game, "de"), "German now")
	testing.expect_value(t, Tr("menu.play", &game), "Spielen")
	testing.expect_value(t, Tr("hud.coins", &game), "Coins: %d") // older key, no German: English
	// No English for a key only the second table has: the key itself (the first language is the fallback)
	testing.expect(t, Locale_Set(&game, "en"))
	testing.expect_value(t, Tr("menu.quit", &game), "menu.quit")
	_ = Locale_Set(&game, "fr")

	// Labels' and menu items' text
	testing.expect_value(t, Tr_Text("@menu.play", &game), "Lancer")
	testing.expect_value(t, Tr_Text("@@home", &game), "@home")
	testing.expect_value(t, Tr_Text("Plain", &game), "Plain")
	testing.expect_value(t, Tr_Text("@", &game), "@")

	// A table without languages is refused
	context.logger = log.nil_logger()
	testing.expect(t, !Locale_LoadCSV(&game, "key\nonly.keys\n"), "no languages")
	free_all(context.temp_allocator)
}

@(test)
projects_pick_a_locale :: proc(t: ^testing.T) {
	project, err := ParseProject(`<project formatVersion="13" name="P" locale="fr"/>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	testing.expect_value(t, project.locale, "fr")
	plain, _ := ParseProject(`<project formatVersion="13" name="P"/>`)
	defer ProjectData_Destroy(&plain)
	testing.expect_value(t, plain.locale, "")
}

@(test)
games_load_their_projects_translations :: proc(t: ^testing.T) {
	dir := tempFolder("engine_test_translations")
	defer os.remove_all(dir)
	_ = os.write_entire_file(JoinPath(dir, "menu.csv"), transmute([]u8)string("key,en,fr\nmenu.play,Play,Jouer\n"))
	_ = os.write_entire_file(JoinPath(dir, "hud.csv"), transmute([]u8)string("key,en,fr\nhud.score,Score,Points\n"))
	project, err := ParseProject(`<project formatVersion="13" name="T" locale="fr"><asset path="menu.csv" kind="Translation"/><asset path="hud.csv" kind="Translation"/><asset path="x.png" kind="Image"/></project>`)
	defer ProjectData_Destroy(&project)
	testing.expect_value(t, err, ProjectError.None)
	game := testGame(dir)
	defer { Game_Destroy(game); free(game) }
	testing.expect(t, Game_LoadProject(game, &project, dir), "loads")
	testing.expect_value(t, Locale_Get(game), "fr")
	testing.expect_value(t, Tr("menu.play", game), "Jouer")
	testing.expect_value(t, Tr("hud.score", game), "Points")
	free_all(context.temp_allocator)
}
