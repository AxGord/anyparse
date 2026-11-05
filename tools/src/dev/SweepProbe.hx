package dev;

/** One probe of a trap catalog: the file it probes, its text, and the position the resolution traps ask at. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef SweepProbe = {
	var file: String;
	@:optional var text: Array<String>;

	/** The resolution traps' position: the first `at` in the file moved by `offset`; the sweep reads none of these. */
	@:optional var at: String;
	@:optional var offset: Int;

	/** The declaration the compiler names at the position, as `<file>#<Type>`, null for none. */
	@:optional var expect: Null<String>;

	/** True when the resolver must name `expect` rather than answer `Unknown`. */
	@:optional var answered: Bool;
};
