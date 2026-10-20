package engine

import "core:encoding/csv"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"

/*
Localization: a game's text in several languages, from CSV tables like Godot's.

A table's first row names the languages (the first column, the keys, is named anything); each
row after it is a key and its text in each language. Rows with an empty key or one starting
with `#` are comments. Quotes allow commas and line breaks (standard CSV):

	key,en,fr,de
	menu.play,Play,Jouer,Spielen
	menu.quit,Quit,Quitter,Beenden
	# The HUD
	hud.coins,"Coins: %d","Pièces : %d","Münzen: %d"

A project's tables are its assets of kind "Translation" (`<asset path="i18n/strings.csv"
kind="Translation"/>`, format 13), loaded in their order, and it may pick the language
(`locale="fr"`); without it the player's system language is used when
a table has it, else the first column's. `Tr(key)` gives a key's text in the current language
(falling back to the first column's, then the key itself), and **Labels and Menu items whose
text starts with `@` are keys** ("@menu.play"), translated as they draw, so switching the
language (`Locale_Set`, from an options menu) changes them at once. "@@" starts text with a
literal "@".

Example:
	// Given: coinCount: int, item: ^e.MenuItem
	coins := fmt.tprintf(e.Tr("hud.coins"), coinCount)
	_ = coins
	// An options menu's language select
	e.Locale_Set(game, e.Locale_List(game)[item.selectedOption])
*/

// The asset kind of translation tables in project.xml
TRANSLATION_ASSET_KIND :: "Translation"

// A game's translation tables, merged (Game.localization; in the game's arena)
Localization :: struct {
	// Languages, in the order the tables named them (the first is the fallback)
	locales: [dynamic]string,
	// Each key's text, one per language ("" where a table has none); shorter when a later table
	// added languages
	texts: map[string][]string,
	// The language in use: an index into `locales`
	current: int,
}

/*
Reads a translation table (CSV, as above) into the game's, adding its keys and languages to
those already loaded (a key loaded again takes the new text).

Inputs:
- game: The game
- text: The CSV
- source: Its name, for messages

Returns:
- false (logged) when the table can't be parsed

Example:
	e.Locale_LoadCSV(game, "key,en,fr\nmenu.play,Play,Jouer\n", "builtin")
*/
Locale_LoadCSV :: proc(game: ^Game, text: string, source := "translations") -> bool {
	reader: csv.Reader
	csv.reader_init_with_string(&reader, text, context.temp_allocator)
	// Comment rows and rows without every language have fewer fields
	reader.fields_per_record = -1
	records, err := csv.read_all(&reader, context.temp_allocator)
	if err != nil {
		log.errorf("%s: not a CSV table (%v)", source, err)
		return false
	}
	if len(records) == 0 || len(records[0]) < 2 {
		log.errorf("%s: the first row must name the languages (key,en,fr...)", source)
		return false
	}
	l := &game.localization
	allocator := Game_GetAllocator(game)
	if l.locales == nil do l.locales = make([dynamic]string, allocator)
	if l.texts == nil do l.texts = make(map[string][]string, allocator)
	// Each column's language index
	columns := make([]int, len(records[0]), context.temp_allocator)
	for name, column in records[0][1:] {
		name := strings.trim_space(name)
		index := -1
		for known, i in l.locales do if known == name do index = i
		if index < 0 {
			append(&l.locales, strings.clone(name, allocator))
			index = len(l.locales) - 1
		}
		columns[column + 1] = index
	}
	for row in records[1:] {
		if len(row) == 0 do continue
		key := strings.trim_space(row[0])
		if key == "" || strings.has_prefix(key, "#") do continue
		values: []string
		if existing, known := &l.texts[key]; known {
			// A table before this one may have had fewer languages
			if len(existing) < len(l.locales) {
				grown := make([]string, len(l.locales), allocator)
				copy(grown, existing^)
				existing^ = grown
			}
			values = existing^
		} else {
			values = make([]string, len(l.locales), allocator)
			l.texts[strings.clone(key, allocator)] = values
		}
		for value, column in row[1:] {
			if column + 1 >= len(columns) do break
			values[columns[column + 1]] = strings.clone(value, allocator)
		}
	}
	return true
}

/*
Reads a translation table from a file (the data pack first: platform layer), as `Locale_LoadCSV`.

Inputs:
- game: The game
- path: The file

Returns:
- false (logged) when it can't be read or parsed

Example:
	e.Locale_LoadFile(game, "i18n/extra.csv")
*/
Locale_LoadFile :: proc(game: ^Game, path: string) -> bool {
	bytes, ok := Platform_ReadFile(path)
	if !ok {
		log.errorf("Couldn't read translations: %s", path)
		return false
	}
	// Temp allocated (or the pack's): not freed here
	return Locale_LoadCSV(game, string(bytes), path)
}

/*
Switches the language: an exact name ("pt_BR"), else one of the same language ("fr" for
"fr_CA", or "fr_FR" for "fr").

Inputs:
- game: The game (nil: the one playing)
- locale: The language's name, as the tables' first row has it

Returns:
- false when no table has it (the language stays)

Example:
	if !e.Locale_Set(game, "fr") do log.warn("no French text")
*/
Locale_Set :: proc(game: ^Game, locale: string) -> bool {
	game := game != nil ? game : currentGame
	if game == nil do return false
	l := &game.localization
	for known, i in l.locales do if strings.equal_fold(known, locale) {
		l.current = i
		return true
	}
	language := localeLanguage(locale)
	for known, i in l.locales do if strings.equal_fold(localeLanguage(known), language) {
		l.current = i
		return true
	}
	return false
}

/*
The language in use.

Inputs:
- game: The game (nil: the one playing)

Returns:
- Its name as the tables' first row has it ("" when no table is loaded); the game's memory
*/
Locale_Get :: proc(game: ^Game = nil) -> string {
	game := game != nil ? game : currentGame
	if game == nil || len(game.localization.locales) == 0 do return ""
	return game.localization.locales[game.localization.current]
}

/*
The languages the tables have, in their order (the first is the fallback).

Inputs:
- game: The game (nil: the one playing)

Returns:
- The names (the game's: don't keep the slice past it, or past loading another table); nil without a game
*/
Locale_List :: proc(game: ^Game = nil) -> []string {
	game := game != nil ? game : currentGame
	if game == nil do return nil
	return game.localization.locales[:]
}

/*
The player's preferred language, as SDL reports it ("fr_CA", or "fr"), temp allocated; "" when
unknown.
*/
Locale_System :: proc() -> string {
	count: i32
	locales := sdl.GetPreferredLocales(&count)
	if locales == nil do return ""
	defer sdl.free(locales)
	if count == 0 || locales[0] == nil || locales[0].language == nil do return ""
	if locales[0].country == nil do return strings.clone(string(locales[0].language), context.temp_allocator)
	return strings.concatenate({string(locales[0].language), "_", string(locales[0].country)}, context.temp_allocator)
}

/*
A key's text in the current language; the first language's when it has none there, and the key
itself when no table has it (so missing text shows up as its key).

Inputs:
- key: The key, as the tables' first column has it
- game: The game (nil: the one playing)

Returns:
- The text (the game's memory: valid while it runs)

Example:
	e.CreateLabel(scene, e.Tr("title.press_start"), {640, 500}, 24, {255, 255, 255, 255})
*/
Tr :: proc(key: string, game: ^Game = nil) -> string {
	game := game != nil ? game : currentGame
	if game == nil do return key
	l := &game.localization
	values, ok := l.texts[key]
	if !ok do return key
	if l.current < len(values) && values[l.current] != "" do return values[l.current]
	if len(values) > 0 && values[0] != "" do return values[0]
	return key
}

/*
Text as Labels and Menu items show it: "@key" is `Tr(key)`, "@@..." is the text from its second
character (a literal "@"), anything else is itself.

Inputs:
- text: The text
- game: The game (nil: the one playing)

Returns:
- The text to show (a translation, or part of `text`: nothing is allocated)
*/
Tr_Text :: proc(text: string, game: ^Game = nil) -> string {
	if len(text) < 2 || text[0] != '@' do return text
	if text[1] == '@' do return text[1:]
	return Tr(text[1:], game)
}

@(private="file")
localeLanguage :: proc(locale: string) -> string {
	end := strings.index_any(locale, "_-")
	return end < 0 ? locale : locale[:end]
}

// Game_LoadProject: the project's tables and language
@(private)
loadProjectTranslations :: proc(game: ^Game, project: ^ProjectData, projectDir: string) {
	for asset in project.assets do if asset.kind == TRANSLATION_ASSET_KIND {
		Locale_LoadFile(game, JoinPath(projectDir, asset.path))
	}
	if len(game.localization.locales) == 0 do return
	if project.locale != "" {
		if !Locale_Set(game, project.locale) do log.warnf("No translations for the project's locale '%s'", project.locale)
	} else if system := Locale_System(); system != "" {
		Locale_Set(game, system)
	}
}
