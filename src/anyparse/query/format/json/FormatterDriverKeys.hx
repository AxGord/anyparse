package anyparse.query.format.json;

import anyparse.grammar.json.JValue;

/**
 * The two driver-level keys of a haxe-formatter fixture's config: neither maps to a write option. Each stays raw, so a key
 * of another type means nothing rather than refusing the whole config, whose other keys are skipped.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef FormatterDriverKeys = {
	@:optional var disableFormatting: JValue;
	@:optional var excludes: JValue;
};
