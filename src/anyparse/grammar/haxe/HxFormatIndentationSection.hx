package anyparse.grammar.haxe;

/**
 * `indentation` section of `hxformat.json` — `character` is either
 * `"tab"` or an all-spaces string whose length becomes `indentSize`;
 * `tabWidth` controls the visual column width of a tab character
 * when the renderer supports tab emission. `trailingWhitespace` opts
 * the renderer into emitting the surrounding indent on blank rows
 * (see `WriteOptions.trailingWhitespace`).
 */
@:peg typedef HxFormatIndentationSection = {

	@:optional var character:String;

	@:optional var tabWidth:Int;

	@:optional var trailingWhitespace:Bool;
};
