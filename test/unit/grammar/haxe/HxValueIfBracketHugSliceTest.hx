package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-bracket-body-glue + strict `comprehensionFor: fitLine`, together: the
 * exact layout the user asked for three times, pinned as bytes.
 *
 * The two halves are independent knobs and this class holds the ONE input
 * where both fire — the reported `Matrix.hor`. `expressionIfWithBrackets`
 * decides whether the value-`if` branch's `[` hugs the branch head, and
 * `comprehensionFor: fitLine` decides where each `for` body lands under its
 * own cuddled head. The `CFG_OFF` arm differs from `CFG_ON` in that one key, so an arm that hard-wires the hug on fails against it.
 *
 * Two fixtures here are GREEN on the base binary and are the vacuity guards:
 * `testAnArrayLiteralBranchWithoutTheKeyKeepsItsOwnLine` (an arm that hugs
 * unconditionally fails it) and `testTheFlatComprehensionStaysOnOneLine` (an
 * arm that breaks every comprehension body fails it).
 *
 * The expected strings are NOT derived from the grammar that generates the
 * writer — they were typed from the user's own statement of the rule and then
 * confirmed byte-for-byte, which is what makes them able to kill an arm (the
 * S66 lesson about a pin built from the declaration it tests).
 *
 * `testTheFlatComprehensionStaysOnOneLine` is the flat clause of the rule and
 * answers the same under both configs: a comprehension that renders flat keeps
 * its body on the head line, so a one-liner is never exploded. That is what separates the strict `fitLine` from `next`, which breaks it.
 *
 * The CLOSE side is pinned below it: the knob also drops the branch `;` before an `else` and
 * pulls the `else` up to the `]`, so the target bytes come out of the source shape the swept tree
 * actually holds (`];` alone on its line) and not only out of a flat one. A flat source leaves the
 * pre-`else` `Keep` gap slot inline, which is why the fixtures above could be green while the real
 * file was not.
 */
@:nullSafety(Strict)
final class HxValueIfBracketHugSliceTest extends Test {

	/** Pony-shaped config: cuddled-open on, padded comprehension brackets, strict `fitLine`, bracket hug ON. */
	private static final CFG_ON: String = cfg(true);

	/** The same config with `sameLine.expressionIfWithBrackets` absent — the base binary's layout. */
	private static final CFG_OFF: String = cfg(false);

	/** The reported `Matrix.hor`, written flat on one source line so no arm can pass by preserving the input. */
	private static final HOR_FLAT: String = 'class C {\n\tpublic function hor(d: Int): Matrix<T> {\n\t\treturn if (d > 0) '
		+ '[ for (e in this) [ for (i in 0...e.length) if (i + d < e.length) e[i + d] else e[i + d - e.length] ] ] '
		+ 'else if (d < 0) [ for (e in this) [ for (i in 0...e.length) if (i + d >= 0) e[i + d] else e[i + d + e.length] ] ] '
		+ 'else this;\n\t}\n}';

	/**
	 * The target bytes: every `[` hugs the head that owns it (the `if` branch for the outer one, its own `for`
	 * for both), every body sits one level below its head, and every `]` is alone on the line at the indent of
	 * the line its `[` opened on.
	 */
	private static final HOR_HUGGED: String = 'class C {\n\tpublic function hor(d: Int): Matrix<T> {\n\t\treturn if (d > 0) '
		+ '[ for (e in this)\n\t\t\t[ for (i in 0...e.length)\n\t\t\t\tif (i + d < e.length)\n\t\t\t\t\te[i + d]\n\t\t\t\telse\n'
		+ '\t\t\t\t\te[i + d - e.length]\n\t\t\t]\n\t\t] else if (d < 0) [ for (e in this)\n\t\t\t[ for (i in 0...e.length)\n'
		+ '\t\t\t\tif (i + d >= 0)\n\t\t\t\t\te[i + d]\n\t\t\t\telse\n\t\t\t\t\te[i + d + e.length]\n\t\t\t]\n\t\t] else\n'
		+ '\t\t\tthis;\n\t}\n}';

	/** Without the key the outer `[` drops to its own line and every level below it shifts one step in. */
	private static final HOR_UNHUGGED: String = 'class C {\n\tpublic function hor(d: Int): Matrix<T> {\n\t\treturn if (d > 0)\n'
		+ '\t\t\t[ for (e in this)\n\t\t\t\t[ for (i in 0...e.length)\n\t\t\t\t\tif (i + d < e.length)\n\t\t\t\t\t\te[i + d]\n'
		+ '\t\t\t\t\telse\n\t\t\t\t\t\te[i + d - e.length]\n\t\t\t\t]\n\t\t\t] else if (d < 0)\n\t\t\t[ for (e in this)\n'
		+ '\t\t\t\t[ for (i in 0...e.length)\n\t\t\t\t\tif (i + d >= 0)\n\t\t\t\t\t\te[i + d]\n\t\t\t\t\telse\n'
		+ '\t\t\t\t\t\te[i + d + e.length]\n\t\t\t\t]\n\t\t\t] else\n\t\t\tthis;\n\t}\n}';

	/** The reported `Matrix.cut` — two nested comprehensions that fit one line. */
	private static final CUT_FLAT: String =
		'class C {\n\tpublic function cut(x: Int, y: Int): Matrix<T> return [ for (i in 0...x) [ for (j in 0...y) this[i][j] ] ];\n}';

	/** An array LITERAL in a value-`if` branch, flat in source and over the wrap rule once it lands. */
	private static final ARRAY_FLAT: String = 'class C {\n\tpublic function b(c: Bool): Array<String> {\n\t\treturn if (c) '
		+ '[firstLongElementNameHereThatIsQuiteLongIndeed, secondLongElementNameHereThatIsAlsoLongIndeed] else [];\n\t}\n}';

	/** …hugged: `[` on the `if` line, items one level in, `] else [];` closing the chain. */
	private static final ARRAY_HUGGED: String = 'class C {\n\tpublic function b(c: Bool): Array<String> {\n\t\treturn if (c) [\n'
		+ '\t\t\tfirstLongElementNameHereThatIsQuiteLongIndeed,\n\t\t\tsecondLongElementNameHereThatIsAlsoLongIndeed\n'
		+ '\t\t] else [];\n\t}\n}';

	/** …and unhugged: the `[` and the `]` each take a line of their own and the `else` trails the closer. */
	private static final ARRAY_UNHUGGED: String = 'class C {\n\tpublic function b(c: Bool): Array<String> {\n\t\treturn if (c)\n'
		+ '\t\t\t[\n\t\t\t\tfirstLongElementNameHereThatIsQuiteLongIndeed,\n'
		+ '\t\t\t\tsecondLongElementNameHereThatIsAlsoLongIndeed\n\t\t\t] else\n\t\t\t[];\n\t}\n}';

	/** The reported `Matrix.hor` AS THE SWEPT TREE HOLDS IT: each branch closed by `];` with `else` on the next line. */
	private static final HOR_SEMI: String = 'class C {\n\tpublic function hor(d: Int): Matrix<T> {\n'
		+ '\t\treturn if (d > 0) [ for (e in this)\n\t\t\t[ for (i in 0...e.length)\n\t\t\t\tif (i + d '
		+ '< e.length)\n\t\t\t\t\te[i + d]\n\t\t\t\telse\n\t\t\t\t\te[i + d - e.length]\n\t\t\t]\n\t'
		+ '\t];\n\t\telse if (d < 0) [ for (e in this)\n\t\t\t[ for (i in 0...e.length)\n\t\t\t\tif (i + d >= 0)\n\t\t\t\t\te[i +'
		+ ' d]\n\t\t\t\telse\n\t\t\t\t\te[i + d + e.length]\n\t\t\t]\n\t\t];\n\t\telse\n\t\t\tthis;\n\t}\n}';

	/** The same shape with NO `;` — the break before `else` is the only thing left to close. */
	private static final HOR_SPLIT: String = 'class C {\n\tpublic function hor(d: Int): Matrix<T> {\n'
		+ '\t\treturn if (d > 0) [ for (e in this)\n\t\t\t[ for (i in 0...e.length)\n\t\t\t\tif (i + '
		+ 'd < e.length)\n\t\t\t\t\te[i + d]\n\t\t\t\telse\n\t\t\t\t\te[i + d - e.length]\n\t\t\t]\n\t'
		+ '\t]\n\t\telse if (d < 0) [ for (e in this)\n\t\t\t[ for (i in 0...e.length)\n\t\t\t\tif (i + d >= 0)\n\t\t\t\t\te[i + '
		+ 'd]\n\t\t\t\telse\n\t\t\t\t\te[i + d + e.length]\n\t\t\t]\n\t\t]\n\t\telse\n\t\t\tthis;\n\t}\n}';

	/** Base-binary answer for `HOR_SEMI` without the key: the `;` stays and so does the break. */
	private static final HOR_SEMI_KEPT: String = 'class C {\n\tpublic function hor(d: Int): Matrix<T> {\n\t\treturn if (d > 0)\n'
		+ '\t\t\t[ for (e in this)\n\t\t\t\t[ for (i in 0...e.length)\n\t\t\t\t\tif (i + d < '
		+ 'e.length)\n\t\t\t\t\t\te[i + d]\n\t\t\t\t\telse\n\t\t\t\t\t\te[i + d - e.length]\n'
		+ '\t\t\t\t]\n\t\t\t];\n\t\telse if (d < 0)\n\t\t\t[ for (e in this)\n\t\t\t\t[ for ('
		+ 'i in 0...e.length)\n\t\t\t\t\tif (i + d >= 0)\n\t\t\t\t\t\te[i + d]\n\t\t\t\t\telse\n'
		+ '\t\t\t\t\t\te[i + d + e.length]\n\t\t\t\t]\n\t\t\t];\n\t\telse\n\t\t\tthis;\n\t}\n}';

	/** Base-binary answer for `HOR_SPLIT` without the key: the break survives on its own. */
	private static final HOR_SPLIT_KEPT: String = 'class C {\n\tpublic function hor(d: Int): Matrix<T> {\n\t\treturn if (d > 0)\n'
		+ '\t\t\t[ for (e in this)\n\t\t\t\t[ for (i in 0...e.length)\n\t\t\t\t\tif (i + d < '
		+ 'e.length)\n\t\t\t\t\t\te[i + d]\n\t\t\t\t\telse\n\t\t\t\t\t\te[i + d - e.length]\n'
		+ '\t\t\t\t]\n\t\t\t]\n\t\telse if (d < 0)\n\t\t\t[ for (e in this)\n\t\t\t\t[ for ('
		+ 'i in 0...e.length)\n\t\t\t\t\tif (i + d >= 0)\n\t\t\t\t\t\te[i + d]\n\t\t\t\t\telse\n'
		+ '\t\t\t\t\t\te[i + d + e.length]\n\t\t\t\t]\n\t\t\t]\n\t\telse\n\t\t\tthis;\n\t}\n}';

	/** A BLOCK-valued value-`if` closed by `};` — the knob is about `[`, so this one is a fixed point under it. */
	private static final BLOCK_SEMI: String = 'class C {\n\tpublic function f(d: Int): Int {\n\t\treturn if (d > 0) {\n'
		+ '\t\t\ttraceSomethingHere(1);\n\t\t\t1;\n\t\t};\n\t\telse {\n\t\t\ttraceSomethingHere(2);\n\t\t\t2;\n' + '\t\t}\n\t}\n}';

	/** A STATEMENT-`if` whose then-body owns the `;` — valid idiomatic Haxe the knob must never reach. */
	private static final STMT_SEMI: String = 'class C {\n\tpublic function f(d: Int): Void {\n\t\tif (d > 0)\n'
		+ '\t\t\ttraceSomethingHere(1);\n\t\telse\n\t\t\ttraceSomethingHere(2);\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** The whole rule on the reported input, from a FLAT source: nothing here is the input read back. */
	public function testTheReportedComprehensionReachesTheTargetLayout(): Void {
		Assert.equals(HOR_HUGGED, HxWriteFixture.triviaWrite(HOR_FLAT, CFG_ON));
	}

	/**
	 * KEY DISCRIMINATOR: the two config arms differ in exactly `expressionIfWithBrackets`, and with it absent the
	 * outer `[` keeps a line of its own. This one is NOT green on the base binary — the comprehension cuddle below
	 * it moved too; the base-green guards are `testAnArrayLiteralBranchWithoutTheKeyKeepsItsOwnLine` and
	 * `testTheFlatComprehensionStaysOnOneLine`.
	 */
	public function testWithoutTheKeyTheBracketKeepsItsOwnLine(): Void {
		Assert.equals(HOR_UNHUGGED, HxWriteFixture.triviaWrite(HOR_FLAT, CFG_OFF));
	}

	/** The target layout is a fixed point — a second write changes nothing. */
	public function testTheTargetLayoutIsIdempotent(): Void {
		Assert.equals(HOR_HUGGED, HxWriteFixture.triviaWrite(HOR_HUGGED, CFG_ON));
	}

	/** The flat clause: a comprehension that renders flat keeps its body on the head line, under BOTH configs. */
	public function testTheFlatComprehensionStaysOnOneLine(): Void {
		Assert.equals(CUT_FLAT, HxWriteFixture.triviaWrite(CUT_FLAT, CFG_ON));
		Assert.equals(CUT_FLAT, HxWriteFixture.triviaWrite(CUT_FLAT, CFG_OFF));
	}

	/** An array LITERAL branch hugs too — the rule is about the `[`, not about the comprehension inside it. */
	public function testAnArrayLiteralBranchHugsTheHead(): Void {
		Assert.equals(ARRAY_HUGGED, HxWriteFixture.triviaWrite(ARRAY_FLAT, CFG_ON));
	}

	/** VACUITY GUARD for the literal arm: without the key it keeps the base `[` / `] else` / `[];` shape. */
	public function testAnArrayLiteralBranchWithoutTheKeyKeepsItsOwnLine(): Void {
		Assert.equals(ARRAY_UNHUGGED, HxWriteFixture.triviaWrite(ARRAY_FLAT, CFG_OFF));
	}

	/**
	 * CLOSE side, on the source the swept tree actually holds: `];` on its own line, `else` on the next. The
	 * `;` goes and the `else` comes up to the `]`, reaching the SAME target bytes as the flat input above —
	 * which is what the flat input could not prove, since a flat source leaves the `Keep` gap slot inline.
	 */
	public function testTheSemicolonClosedSourceReachesTheTargetLayout(): Void {
		Assert.equals(HOR_HUGGED, HxWriteFixture.triviaWrite(HOR_SEMI, CFG_ON));
	}

	/** The gap half on its own: no `;` to drop, only the source break before `else`, and it still closes. */
	public function testTheSplitCloserCuddlesTheElseWithNoSemicolonToDrop(): Void {
		Assert.equals(HOR_HUGGED, HxWriteFixture.triviaWrite(HOR_SPLIT, CFG_ON));
	}

	/** VACUITY GUARD: without the key both halves survive — the `;` and the break. Green on the base binary. */
	public function testWithoutTheKeyTheSemicolonAndTheBreakBothSurvive(): Void {
		Assert.equals(HOR_SEMI_KEPT, HxWriteFixture.triviaWrite(HOR_SEMI, CFG_OFF));
		Assert.equals(HOR_SPLIT_KEPT, HxWriteFixture.triviaWrite(HOR_SPLIT, CFG_OFF));
	}

	/**
	 * The knob is keyed on the `[` ctor, so a BLOCK-valued branch keeps its `};` and its break under BOTH
	 * configs. `expressionIfWithBlocks` collapses a block body's CONTENTS and has never hugged anything, so
	 * the curly twin of this close side would be a new behaviour with no corpus consumer.
	 */
	public function testABlockValuedBranchIsUntouchedByTheBracketKnob(): Void {
		Assert.equals(BLOCK_SEMI, HxWriteFixture.triviaWrite(BLOCK_SEMI, CFG_ON));
		Assert.equals(BLOCK_SEMI, HxWriteFixture.triviaWrite(BLOCK_SEMI, CFG_OFF));
	}

	/** A statement-`if`'s `foo();` / `else` is valid idiomatic Haxe and stays byte-identical under the key. */
	public function testAStatementIfKeepsItsOwnTerminatorAndBreak(): Void {
		Assert.equals(STMT_SEMI, HxWriteFixture.triviaWrite(STMT_SEMI, CFG_ON));
		Assert.equals(STMT_SEMI, HxWriteFixture.triviaWrite(STMT_SEMI, CFG_OFF));
	}

	/** Pony-shaped config text with `sameLine.expressionIfWithBrackets` as the only variable. */
	private static function cfg(brackets: Bool): String {
		final hug: String = brackets ? ', "expressionIfWithBrackets": true' : '';
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
			+ '"maxLineLength": 140, "comprehensionCuddledOpen": true, "arrayWrap": {"defaultWrap": "ignore", "rules": [{"conditions":'
			+ ' [{"cond": "anyItemLength >= n", "value": 30}], "type": "onePerLine"}]}}, "whitespace": {"typeHintColonPolicy": "after", '
			+ '"bracketConfig": {"comprehensionBrackets": {"openingPolicy": "onlyAfter", "closingPolicy": "before"}}}, "sameLine": {'
			+ '"ifBody": "fitLine", "functionBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"$hug}}';
	}

}
