package anyparse.grammar.haxe.format;

/**
 * `indentation` section of `hxformat.json` — `character` is either
 * `"tab"` or an all-spaces string whose length becomes `indentSize`;
 * `tabWidth` controls the visual column width of a tab character
 * when the renderer supports tab emission. `trailingWhitespace` opts
 * the renderer into emitting the surrounding indent on blank rows
 * (see `WriteOptions.trailingWhitespace`). `indentCaseLabels` toggles
 * whether `case` / `default` labels inside a `switch` body are nested
 * one level (`true`, default) or kept flush with the `switch` keyword
 * (`false`, matching haxe-formatter's `indentation.indentCaseLabels:
 * @:default(true)`).
 */
@:peg typedef HxFormatIndentationSection = {

	@:optional var character:String;

	@:optional var tabWidth:Int;

	@:optional var trailingWhitespace:Bool;

	@:optional var indentCaseLabels:Bool;
};
