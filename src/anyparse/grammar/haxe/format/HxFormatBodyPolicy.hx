package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `sameLine.*Body` fields accept. Mapped by
 * `HaxeFormatConfigLoader` to `anyparse.format.BodyPolicy`: `"same"` → `Same`, `"next"` →
 * `Next`, `"fitLine"` → `FitLine`. `"keep"` (reproduce the source form) parses so that
 * `HaxeFormatConfigDiagnostics` can name it; the knob keeps its default.
 */
enum abstract HxFormatBodyPolicy(String) to String {
	final Same = 'same';
	final Next = 'next';
	final Keep = 'keep';
	final FitLine = 'fitLine';
}
