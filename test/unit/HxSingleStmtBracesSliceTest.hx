package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-single-stmt-braces — `whitespace.bracesConfig.
 * singleStatementBraces: "remove"` drops the curly braces around a
 * single-statement `if` / `else` / `for` / `while` body
 * (`if (c) { return x; }` → `if (c) return x;`).
 *
 * Engine wiring: `@:fmt(dropSingleStmtBraces)` on `HxIfStmt.thenBody`
 * / `HxIfStmt.elseBody` / `HxForStmt.body` / `HxWhileStmt.body`
 * splices `SingleStmtBraces.unwrapStmt` around the body value in
 * `WriterLowering` (trivia mode only); the loader maps the JSON key
 * onto `HxModuleWriteOptions.dropSingleStmtBraces` (default `false` —
 * byte-inert, corpus flip-0).
 *
 * The battery locks every safety gate: multi-statement, dangling-else
 * (direct AND through a nested loop body via the `_ssbSuppress`
 * frame), comments, missing terminator, declaration scoping — each
 * fails closed (braces kept) — plus the else-if collapse, layout
 * parity, idempotence and default-off inertness.
 */
@:nullSafety(Strict)
class HxSingleStmtBracesSliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;
	private static final removeConfig: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "remove" } },'
		+ ' "sameLine": { "ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "doWhileBody": "same" } }';

	public function testDefaultOptionsKeepBraces(): Void {
		Assert.isFalse(HaxeFormat.instance.defaultWriteOptions.dropSingleStmtBraces);
	}

	public function testLoaderMapsRemove(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		Assert.isTrue(opts.dropSingleStmtBraces);
	}

	public function testLoaderExplicitKeepStaysOff(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{ "whitespace": { "bracesConfig": { "singleStatementBraces": "keep" } } }'
		);
		Assert.isFalse(opts.dropSingleStmtBraces);
	}

	public function testLoaderOmittedStaysOff(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.isFalse(opts.dropSingleStmtBraces);
	}

	public function testSingleStmtIfUnbraced(): Void {
		assertFmt(
			'class F {\n\tfunction f(a:Bool):Bool {\n\t\tif (a) {\n\t\t\treturn true;\n\t\t}\n\t\treturn false;\n\t}\n}',
			'class F {\n\tfunction f(a:Bool):Bool {\n\t\tif (a) return true;\n\t\treturn false;\n\t}\n}'
		);
	}

	public function testMultiStmtKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tone();\n\t\t\ttwo();\n\t\t}\n\t}\n}');
	}

	public function testDanglingElseKeepsBraces(): Void {
		// KEY safety gate: dropping the outer braces would rebind `else`
		// to the inner else-less `if`.
		roundTrip('class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tif (b) x();\n\t\t} else\n\t\t\ty();\n\t}\n}');
	}

	public function testDanglingElseThroughLoopBodyKeepsBraces(): Void {
		// KEY safety gate (suppress frame): the loop body itself sees no
		// `else`, but unwrapping `{ if (b) x(); }` inside the then-body of
		// an if-with-else would rebind the outer `else` to `if (b)`.
		assertFmt(
			'class F {\n\tfunction f(a:Bool, b:Bool, c:Bool):Void {\n\t\tif (a) while (c) {\n\t\t\tif (b) x();\n\t\t} else y();\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, b:Bool, c:Bool):Void {\n\t\tif (a)\n\t\t\twhile (c) {\n\t\t\t\tif (b) x();\n\t\t\t}\n\t\telse\n\t\t\ty();\n\t}\n}'
		);
	}

	public function testElseIfChainStaysValid(): Void {
		assertFmt(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tx();\n\t\t} else if (b) {\n\t\t\ty();\n\t\t} else {\n\t\t\tz();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a)\n\t\t\tx();\n\t\telse if (b)\n\t\t\ty();\n\t\telse\n\t\t\tz();\n\t}\n}'
		);
	}

	public function testIfElseAsymmetryKeepsBothBraced(): Void {
		// A single-statement then-branch must NOT de-brace while its else-branch keeps braces —
		// `if (b) return true; else { … }` is an asymmetric-brace violation. Keep both braced.
		roundTrip(
			'class F {\n\tfunction f(b:Bool):Bool {\n\t\tif (b) {\n\t\t\treturn true;\n\t\t} else {\n\t\t\tg();\n\t\t\treturn false;\n\t\t}\n\t}\n}'
		);
	}

	public function testIfElseIfChainKeepsBracesWhenAnyBranchMulti(): Void {
		// if/else-if CHAIN symmetry: `if (a) { multi } else if (b) { single }` — the else-if
		// body must NOT de-brace while a sibling chain branch keeps braces (asymmetry violation).
		roundTrip(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tone();\n\t\t\ttwo();\n\t\t} else if (b) {\n\t\t\tthree();\n\t\t}\n\t}\n}'
		);
	}

	public function testAllSingleElseIfChainDeBracesEveryBranch(): Void {
		// An else-if chain whose EVERY branch is a single-statement block de-braces
		// them all — symmetric-unbraced is allowed; only MIXED chains force braces.
		assertFmt(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tone();\n\t\t} else if (b) {\n\t\t\ttwo();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a)\n\t\t\tone();\n\t\telse if (b)\n\t\t\ttwo();\n\t}\n}'
		);
	}

	public function testElseIfChainLaterBranchForcesEarlierBraces(): Void {
		// The chain-root scan (not the immediate-pair gate 7): a LATER multi branch
		// forces an EARLIER single-block branch to keep its braces. The outer `if`'s
		// then-body probes only its immediate else sibling (the nested `else if`,
		// which is not a brace-bearing block), so only a full-spine OR keeps it braced.
		roundTrip(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tx();\n\t\t} else if (b) {\n\t\t\tm1();\n\t\t\tm2();\n\t\t}\n\t}\n}'
		);
	}

	public function testDeepMixedElseIfChainKeepsAllBraced(): Void {
		// Deep (4-branch) chain with the multi branch in the MIDDLE: the keeper
		// propagates BOTH backward (root scan) and forward (`_ssbChainSuppress` down
		// the else-if spine), so every branch keeps its braces.
		roundTrip(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tp();\n\t\t} else if (b) {\n\t\t\tq();\n\t\t} else if (a) {\n\t\t\tm1();\n\t\t\tm2();\n\t\t} else {\n\t\t\tr();\n\t\t}\n\t}\n}'
		);
	}

	public function testElseIfBranchNestedIndependentChainStillDeBraces(): Void {
		// The chain-suppress signal is CLEARED when descending into a branch's own
		// content: an independent single-statement `if` nested inside an else-if
		// branch de-braces on its own merits even though the OUTER chain keeps braces.
		assertFmt(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tone();\n\t\t\ttwo();\n\t\t} else if (b) {\n\t\t\tif (a) {\n\t\t\t\tp();\n\t\t\t}\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tone();\n\t\t\ttwo();\n\t\t} else if (b) {\n\t\t\tif (a) p();\n\t\t}\n\t}\n}'
		);
	}

	public function testTrailingSemiTerminalElseIfKeepsChainBraced(): Void {
		// The TERMINAL else-if then-body carries the enclosing statement's redundant
		// trailing `;`, so gate 6 keeps its braces at the real splice. The chain scan
		// must read that then-body's own trail slot (not assume false) or the earlier
		// branch de-braces asymmetrically. Fully braced round-trips (the `;` stays).
		roundTrip(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tA();\n\t\t} else if (b) {\n\t\t\tB();\n\t\t};\n\t}\n}'
		);
	}

	public function testIfMultiElseSingleKeepsBothBraced(): Void {
		// Reverse direction: a multi-statement then keeps its braces, so the single-statement
		// else must keep its own too (gate 7 reaches the then value from the else splice).
		roundTrip(
			'class F {\n\tfunction f(b:Bool):Void {\n\t\tif (b) {\n\t\t\tone();\n\t\t\ttwo();\n\t\t} else {\n\t\t\tg();\n\t\t}\n\t}\n}'
		);
	}

	public function testIfSingleElseSingleDeBracesBoth(): Void {
		// Symmetric-unbraced is allowed: when BOTH branches are single-statement, de-brace both.
		assertFmt(
			'class F {\n\tfunction f(b:Bool):Void {\n\t\tif (b) {\n\t\t\tone();\n\t\t} else {\n\t\t\ttwo();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(b:Bool):Void {\n\t\tif (b)\n\t\t\tone();\n\t\telse\n\t\t\ttwo();\n\t}\n}'
		);
	}

	public function testElseBlockSingleIfCollapsesToElseIf(): Void {
		assertFmt(
			'class F {\n\tfunction f(a:Bool, c:Bool):Void {\n\t\tif (a) y(); else {\n\t\t\tif (c) x();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, c:Bool):Void {\n\t\tif (a)\n\t\t\ty();\n\t\telse if (c)\n\t\t\tx();\n\t}\n}'
		);
	}

	public function testLeadingCommentKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\t// keep me\n\t\t\tx();\n\t\t}\n\t}\n}');
	}

	public function testTrailingCommentKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tx(); // trailing\n\t\t}\n\t}\n}');
	}

	public function testCommentBeforeCloseKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tx();\n\t\t\t// before close\n\t\t}\n\t}\n}');
	}

	public function testMissingSemicolonKeepsBraces(): Void {
		// `{ return true }` — the braceless form would not re-parse
		// before a `}` (Slice-V statement boundary), so braces stay.
		roundTrip('class F {\n\tfunction f(a:Bool):Bool {\n\t\tif (a) {\n\t\t\treturn true\n\t\t}\n\t\treturn false;\n\t}\n}');
	}

	public function testTrailingEmptyStmtAfterForKeepsBraces(): Void {
		// `for (...) { stmt; };` — a block FOLLOWED by a redundant empty statement.
		// De-bracing yields `for (...) stmt;;`, which anyparse parses but the Haxe
		// compiler rejects ("Expected }"). The gate must fail closed and keep braces.
		roundTrip('class F {\n\tfunction f(m:Map<Int, Int>):Void {\n\t\tfor (k => v in m) {\n\t\t\ttrace(v);\n\t\t};\n\t}\n}');
	}

	public function testTrailingEmptyStmtAfterIfKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tg();\n\t\t};\n\t}\n}');
	}

	public function testTrailingEmptyStmtAfterElseDropsSemiKeepsBraces(): Void {
		// The else-body's writer path drops the redundant trailing `;` (`else { h(); };` ->
		// no `;;`), so that stray `;` is gone. But the sibling then-body is multi-statement
		// and keeps its braces, so the if/else symmetry gate (gate 7) keeps the else braced
		// too - a single-vs-multi if/else de-braces NEITHER branch.
		assertFmt(
			'class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tg();\n\t\t\tg2();\n\t\t} else {\n\t\t\th();\n\t\t};\n\t}\n}',
			'class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tg();\n\t\t\tg2();\n\t\t} else {\n\t\t\th();\n\t\t}\n\t}\n}'
		);
	}

	public function testVarDeclKeepsBraces(): Void {
		// The braces scope the binding — dropping them would widen it.
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tvar t = 1;\n\t\t}\n\t}\n}');
	}

	public function testForBodyUnbraced(): Void {
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\tfor (i in 0...3) {\n\t\t\ttrace(i);\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\tfor (i in 0...3) trace(i);\n\t}\n}'
		);
	}

	public function testWhileBodyUnbraced(): Void {
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\twhile (cond()) {\n\t\t\tstep();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\twhile (cond()) step();\n\t}\n}'
		);
	}

	public function testIdempotentAndReparses(): Void {
		final source: String = 'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tif (b) x();\n\t\t} else\n\t\t\ty();\n\t\tif (a) {\n\t\t\treturn;\n\t\t}\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final pass1: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		final pass2: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(pass1), opts);
		Assert.equals(pass1, pass2);
	}

	public function testDefaultConfigKeepsBracesByteIdentical(): Void {
		final source: String = 'class F {\n\tfunction f(a:Bool):Bool {\n\t\tif (a) {\n\t\t\treturn true;\n\t\t}\n\t\treturn false;\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals('$source\n', out);
	}

	public function testDoWhileBodyUnbraced(): Void {
		// The mapped ExprBody drops the `;` — modern Haxe rejects
		// `do i++; while (…)` ("Expected while"); `do i++ while (…);` is
		// the valid braceless form.
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\tvar i = 0;\n\t\tdo {\n\t\t\ti++;\n\t\t} while (i < 3);\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\tvar i = 0;\n\t\tdo i++ while (i < 3);\n\t}\n}'
		);
	}

	public function testDoWhileMultiStmtKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f():Void {\n\t\tdo {\n\t\t\tone();\n\t\t\ttwo();\n\t\t} while (cond());\n\t}\n}');
	}

	public function testDoWhileNonExprStmtKeepsBraces(): Void {
		// Only an ExprStmt has an `HxDoWhileBody.ExprBody` counterpart —
		// any other statement kind keeps its braces.
		roundTrip('class F {\n\tfunction f():Void {\n\t\tdo {\n\t\t\treturn;\n\t\t} while (cond());\n\t}\n}');
	}

	public function testThenBranchInnerIfElseKeepsBraces(): Void {
		// Gate 8 (readability): a then-branch whose sole statement is an if/else
		// keeps its braces even though every removal gate would pass —
		// `if (r) if (b) {…} else {…}` reads as a dangling-else puzzle.
		roundTrip(
			'class F {\n\tfunction f(r:Bool, b:Bool):Void {\n\t\tif (r) {\n\t\t\tif (b) {\n\t\t\t\tone();\n\t\t\t\ttwo();\n\t\t\t} else {\n\t\t\t\tthree();\n\t\t\t\tfour();\n\t\t\t}\n\t\t}\n\t}\n}'
		);
	}

	public function testThenBranchLoneInnerIfKeepsBraces(): Void {
		// Gate 8 applies to ANY if in then-position, else-less included: the
		// no-else case belongs to collapsible-if (`if (a && b)`), not to a
		// chained `if (a) if (b)` header.
		roundTrip('class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tif (b) x();\n\t\t}\n\t}\n}');
	}

	public function testBareThenIfGetsBracesAdded(): Void {
		// Repair direction (ω-ssb-wrap): a BARE if in then-position gains
		// braces — fmt self-heals sources unwrapped by the pre-gate-8 writer.
		assertFmt(
			'class F {\n\tfunction f(r:Bool, b:Bool):Void {\n\t\tif (r) if (b) {\n\t\t\tone();\n\t\t\ttwo();\n\t\t} else {\n\t\t\tthree();\n\t\t\tfour();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(r:Bool, b:Bool):Void {\n\t\tif (r) {\n\t\t\tif (b) {\n\t\t\t\tone();\n\t\t\t\ttwo();\n\t\t\t} else {\n\t\t\t\tthree();\n\t\t\t\tfour();\n\t\t\t}\n\t\t}\n\t}\n}'
		);
	}

	public function testLoopBodyLoneIfStillUnbraces(): Void {
		// Loop bodies are exempt from gate 8 — `for (…) if (…)` guard headers
		// are the preferred style and keep de-bracing.
		assertFmt(
			'class F {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) {\n\t\t\tif (x > 0) y();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) if (x > 0) y();\n\t}\n}'
		);
	}

	private static function assertFmt(source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals('$expected\n', out);
	}

	private static function roundTrip(source: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals('$source\n', out);
	}

}
