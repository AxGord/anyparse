package anyparse.grammar.haxe;

/**
 * `sameLine` section of `hxformat.json` — three enum-abstract-string
 * knobs driving whether `else` / `catch` / `while` sit on the same
 * line as their preceding block.
 */
@:peg typedef HxFormatSameLineSection = {

	@:optional var ifElse:HxFormatSameLinePolicy;

	@:optional var tryCatch:HxFormatSameLinePolicy;

	@:optional var doWhile:HxFormatSameLinePolicy;
};
