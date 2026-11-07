package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `sameLine` keyword fields accept.
 * `"keep"` parses so that `HaxeFormatConfigDiagnostics` can name it; the
 * knob keeps its default, and `"fitLine"` reads as `Same`.
 */
enum abstract HxFormatSameLinePolicy(String) to String {
	final Same = 'same';
	final Next = 'next';
	final Keep = 'keep';
	final FitLine = 'fitLine';
}
