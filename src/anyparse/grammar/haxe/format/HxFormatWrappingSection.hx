package anyparse.grammar.haxe.format;

/**
 * `wrapping` section of `hxformat.json` — `maxLineLength` maps to
 * `lineWidth` in `HxModuleWriteOptions`.
 */
@:peg typedef HxFormatWrappingSection = {

	@:optional var maxLineLength:Int;
};
