package dev;

/**
 * One lesson as a slice's worker or reviewer writes it into the logs dir: `kind` is the class (`class` is a Haxe keyword),
 * `touches` the files a queue line would edit, `repro` the one line that shows it. Every field may be absent; `LessonsFile` says which one.
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef LessonRecordJson = {

	@:optional
	var id: String;

	@:optional
	var kind: String;

	@:optional
	var touches: Array<String>;

	@:optional
	var repro: String;

	@:optional
	var text: String;

};
