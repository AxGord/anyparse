package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `sameLine.*Body` fields accept. Mapped by
 * `HaxeFormatConfigLoader` to `anyparse.format.BodyPolicy`: `"same"` → `Same`, `"next"` →
 * `Next`, `"fitLine"` → `FitLine`, `"keep"` → `Keep` — the writer reads the source form and
 * reproduces it (`HxLoopBodyIfElseSliceTest` pins a `keep` body that reproduces a source
 * break).
 */
enum abstract HxFormatBodyPolicy(String) to String {

	final Same = 'same';

	final Next = 'next';

	final Keep = 'keep';

	final FitLine = 'fitLine';

}
