package anyparse.grammar.haxe.format;

/**
 * Granularity policy for blank-line insertion between consecutive
 * same-kind imports / usings, modelled after haxe-formatter's
 * `BetweenImportsEmptyLinesLevel` (slice ω-imports-using-between).
 *
 * Drives the `@:fmt(blankLinesBetweenSameCtorByLevel(...))` cascade in
 * `WriterLowering.triviaEofStarExpr`: when two consecutive elements are
 * both imports or both usings, the writer emits
 * `opt.betweenImports` blank lines IFF
 * `pathDiffers(prevPath, currPath, opt.betweenImportsLevel)` returns
 * `true`. `All` always returns `true` (one blank between every pair);
 * the `*LevelPackage` cases compare the first N dot-separated segments
 * of each path; `FullPackage` compares the entire path.
 *
 * The path arguments are dotted-ident strings — the import / using
 * payload (`HxTypeName` / `HxWildPath`) round-trips through the writer
 * as-is. For wildcards (`foo.bar.*`) the trailing `.*` participates in
 * the `FullPackage` comparison just like fork's
 * `MarkEmptyLines.getImportInfo`, which uses the verbatim token stream.
 *
 * Note `pathDiffers` returns `true` when the prefixes are the same
 * length but mismatch, AND when one path is shorter than the other at
 * the configured level — both signal "different group, insert blank".
 * Equal prefixes return `false` so consecutive imports under one
 * package stay glued.
 */
enum abstract HxBetweenImportsLevel(Int) from Int to Int {

	final All = 0;

	final FirstLevelPackage = 1;

	final SecondLevelPackage = 2;

	final ThirdLevelPackage = 3;

	final FourthLevelPackage = 4;

	final FifthLevelPackage = 5;

	final FullPackage = 6;

	/**
	 * `true` if the two paths fall into different groups at the
	 * configured level — i.e. the writer should emit
	 * `opt.betweenImports` blank lines between them. Mirrors fork's
	 * `MarkEmptyLines.hx:128-155` per-level `prevInfo.<level> !=
	 * newInfo.<level>` comparison.
	 *
	 * Signature accepts `level:Int` to remain directly assignable to
	 * the format-neutral `WriteOptions.betweenImportsPathDiffers:
	 * Null<(String, String, Int) -> Bool>` adapter slot. The first-line
	 * cast lifts the Int back into the typed enum so the switch reads
	 * named cases.
	 */
	public static function pathDiffers(prev:String, curr:String, level:Int):Bool {
		final lvl:HxBetweenImportsLevel = level;
		switch lvl {
			case All: return true;
			case FullPackage: return prev != curr;
			case _:
		}
		final prevSegs:Array<String> = prev.split('.');
		final currSegs:Array<String> = curr.split('.');
		// fork's ImportPackageInfo zero-fills missing levels (default-empty
		// String fields). When prev/curr have fewer than `level` segments,
		// the missing slots compare as '' — same shape as fork's behaviour.
		for (i in 0...level) {
			final p:String = i < prevSegs.length ? prevSegs[i] : '';
			final c:String = i < currSegs.length ? currSegs[i] : '';
			if (p != c) return true;
		}
		return false;
	}
}
