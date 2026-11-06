package anyparse.grammar.haxe.format;

/**
 * Closed set of values `sameLine.caseSiblings` accepts. Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.SiblingPolicy`: `"off"` → `Off`, `"anyBreak"` → `AnyBreak`.
 */
enum abstract HxFormatSiblingPolicy(String) to String {
	final Off = 'off';
	final AnyBreak = 'anyBreak';
}
