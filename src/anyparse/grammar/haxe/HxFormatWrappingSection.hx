package anyparse.grammar.haxe;

/**
 * `wrapping` section of `hxformat.json` — `maxLineLength` maps to
 * `lineWidth` in `HxModuleWriteOptions`.
 */
@:peg typedef HxFormatWrappingSection = {

	@:optional var maxLineLength:Int;
};
