package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * ω-same-on-block: under `sameLine.expressionIf: next` a value-`if` whose
 * branch is a `{ … }` block JOINS its `else` to the close (`} else {`), the
 * same layout the STATEMENT twin of that construct has always produced.
 *
 * The reported source is `pony.magic.builder.DIVerifier.recordResolution`,
 * read by eye out of a swept Pony tree: `}` on its own line, `else {` on the
 * next. Measured on `f8ba0a46` under Pony's own `hxformat.json`, three probes
 * on the same construct gave three answers — an already-cuddled value-`if`
 * stayed cuddled, the reported broken one KEPT its break, and the statement
 * twin of the identical break JOINED. One construct, two layouts, decided by
 * value-vs-statement position alone.
 *
 * The cause was the `expressionIf` fanout, and the pre-slice comment on it
 * said so: `next` mapped the else-gap onto `SameLinePolicy.Keep`, i.e. onto
 * the synth `elseBranchBeforeKwNewline` slot — the source's own break, which
 * outlives everything — and the comment called true shape-aware dispatch
 * "deferred until a fixture surfaces that the source-preserving mapping
 * mishits". This is that fixture. `next` now maps to `SameOnBlock`, which the
 * shape-aware separator answers per DELIMITER: a curly close cuddles, a
 * bracket close keeps its source shape (its glue is
 * `expressionIfWithBrackets`, S79), and a non-block branch keeps the forced
 * break it already had.
 *
 * The cheaper-looking fix is refuted by measurement, not by argument: mapping
 * `next` onto a plain `Same` moved 3 anyparse files instead of 1 and made 2 of
 * them WORSE — `[] else {` and `['--code', staged]; else if (…)`, an `else`
 * glued onto a list literal the source had left alone.
 *
 * Every config here is Pony-shaped and states `expressionIfWithBrackets`
 * nowhere, so the bracket fixture measures the `SameOnBlock` bracket arm and
 * not S79's knob.
 */
@:nullSafety(Strict)
final class HxValueIfCurlyElseJoinSliceTest extends Test {

	/** Pony-shaped config with `sameLine.expressionIf: next` — what both real trees set. */
	private static final CFG_NEXT: String = cfg('next');

	/** The same config with `expressionIf: keep`, which must still mean keep. */
	private static final CFG_KEEP: String = cfg('keep');

	/** The reported source, reduced: the value-`if` with a `{ … }` branch and the break the sweep left before `else`. */
	private static final BROKEN: String = 'class DIVerifier {\n'
		+ '\tprivate static function recordResolution(className: String, fieldName: String, ref: Null<ResolvedRef>): Void {\n\t\tfinal '
		+ 'existing: Null<Map<String, Null<ResolvedRef>>> = resolutions[className];\n\t\tfinal classMap: Map<String, Null<ResolvedRef>> = '
		+ 'if (existing != null) {\n\t\t\texisting;\n\t\t}\n\t\telse {\n\t\t\tfinal fresh: Map<String, Null<ResolvedRef>> = [];\n'
		+ '\t\t\tresolutions[className] = fresh;\n\t\t\tfresh;\n\t\t};\n\t\trecordFieldResolution(classMap, fieldName, ref);\n\t}\n}';

	/** The user's target bytes, quoted from his report verbatim and verified byte-for-byte against his real file. */
	private static final JOINED: String = 'class DIVerifier {\n\tprivate static function recordResolution(className: String, fieldName: '
		+ 'String, ref: Null<ResolvedRef>): Void {\n'
		+ '\t\tfinal existing: Null<Map<String, Null<ResolvedRef>>> = resolutions[className];\n\t\tfinal '
		+ 'classMap: Map<String, Null<ResolvedRef>> = if (existing != null) {\n\t\t\texisting;\n\t\t} else {'
		+ '\n\t\t\tfinal fresh: Map<String, Null<ResolvedRef>> = [];\n\t\t\tresolutions[className] = fresh;\n'
		+ '\t\t\tfresh;\n\t\t};\n\t\trecordFieldResolution(classMap, fieldName, ref);\n\t}\n}';

	/** The same source with the optional `;` the grammar parks on `thenBranch` — `};` cannot be a join either. */
	private static final SEMI: String = 'class DIVerifier {\n'
		+ '\tprivate static function recordResolution(className: String, fieldName: String, ref: Null<ResolvedRef>): Void {\n\t\tfinal '
		+ 'existing: Null<Map<String, Null<ResolvedRef>>> = resolutions[className];\n\t\tfinal classMap: Map<String, Null<ResolvedRef>> = '
		+ 'if (existing != null) {\n\t\t\texisting;\n\t\t};\n\t\telse {\n\t\t\tfinal fresh: Map<String, Null<ResolvedRef>> = [];\n'
		+ '\t\t\tresolutions[className] = fresh;\n\t\t\tfresh;\n\t\t};\n\t\trecordFieldResolution(classMap, fieldName, ref);\n\t}\n}';

	/** The STATEMENT twin of the identical break: same braces, same gap, statement position. */
	private static final STMT_BROKEN: String = 'class DIVerifier {\n'
		+ '\tprivate static function recordResolution(className: String, fieldName: String, ref: Null<ResolvedRef>): Void {\n'
		+ '\t\tif (ref != null) {\n\t\t\trecordFieldResolution(className, fieldName, ref);\n\t\t}\n'
		+ '\t\telse {\n\t\t\trecordFieldResolution(className, fieldName, null);\n\t\t}\n\t}\n}';

	/** What the statement twin has ALWAYS produced — the layout that made the value-side answer read as a defect. */
	private static final STMT_JOINED: String = 'class DIVerifier {\n'
		+ '\tprivate static function recordResolution(className: String, fieldName: String, ref: Null<ResolvedRef>): Void {\n'
		+ '\t\tif (ref != null) {\n\t\t\trecordFieldResolution(className, fieldName, ref);\n'
		+ '\t\t} else {\n\t\t\trecordFieldResolution(className, fieldName, null);\n\t\t}\n\t}\n}';

	/** A value-`if` whose branch is an object literal: not a block ctor, so the shape-aware switch forces the break. */
	private static final OBJ: String = 'class DIVerifier {\n\tprivate static function describe(existingResolvedReference: Null<Int>): '
		+ 'Dynamic {\n\t\treturn if (existingResolvedReference != null)\n\t\t\t{\n'
		+ '\t\t\t\townerClassNameValue: existingResolvedReference,\n' + '\t\t\t\tdeclaredFieldNameValue: existingResolvedReference,\n'
		+ '\t\t\t\tsourceModulePathValue: existingResolvedReference\n\t\t\t}\n\t\telse\n\t\t\tnull;\n' + '\t}\n}';

	/** A value-`if` whose branch is a `[ … ]` list: a block ctor, but not a curly one, so the source shape stands. */
	private static final BRACKET: String = 'class DIVerifier {\n\tprivate static function widths(declaredArgumentCount: Int): Array<Int> {'
		+ '\n\t\treturn if (declaredArgumentCount > 0)\n'
		+ '\t\t\t[declaredArgumentCount, declaredArgumentCount, declaredArgumentCount, declaredArgumentCount]\n'
		+ '\t\telse\n\t\t\t[];\n\t}\n}';

	/** An else-LESS value-`if`: its `;` is the enclosing statement's terminator and dropping it would not compile. */
	private static final ELSE_LESS: String = 'class DIVerifier {\n\tprivate static function only(existing: Null<Int>): Int {\n'
		+ '\t\tfinal classMap: Int = if (existing != null) {\n\t\t\texisting;\n\t\t};\n\t\treturn classMap;\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** The report itself: his source in, his target bytes out. RED on `f8ba0a46`. */
	@:pin('control')
	@:killer('M-EXPR-ELSE-KEEP')
	public function testTheReportedValueIfJoinsItsElseToTheCurlyClose(): Void {
		Assert.equals(JOINED, HxWriteFixture.triviaWrite(BROKEN, CFG_NEXT));
	}

	/**
	 * The joined layout is a fixed point — a layout slice that is not idempotent corrupts
	 * a corpus on the second sweep.
	 *
	 * It was declared a COST filter when this class was written, because it is green on
	 * `f8ba0a46` too (`Keep` reproduces an already-cuddled source) and the arm registry
	 * could not then address the macro-time code that decides the join. It can now:
	 * `M-CURLY-CTORS-NONE` empties the curly branch-ctor set the shape-aware separator
	 * switches on, every value-`if` branch falls to the hardline arm, and the fixed point
	 * is gone. Its evidence is that arm rather than base-redness.
	 */
	@:pin('control')
	@:killer('M-CURLY-CTORS-NONE')
	public function testTheJoinedLayoutIsIdempotent(): Void {
		Assert.equals(JOINED, HxWriteFixture.triviaWrite(JOINED, CFG_NEXT));
	}

	/**
	 * The statement twin, which needs no fix and gets none. Guards PRE-EXISTING behaviour:
	 * green on the base, and the reason the value-side answer was reportable at all. An arm
	 * that broke it would be cutting `sameLineElse`, which this slice does not touch.
	 */
	@:pin('guard')
	public function testTheStatementTwinKeepsTheLayoutItAlwaysHad(): Void {
		Assert.equals(STMT_JOINED, HxWriteFixture.triviaWrite(STMT_BROKEN, CFG_NEXT));
		Assert.equals(STMT_JOINED, HxWriteFixture.triviaWrite(STMT_JOINED, CFG_NEXT));
	}

	/** A non-block branch keeps its forced break — `SameOnBlock` promises a `}` join and nothing else. */
	@:pin('control')
	@:killer('M-ELSE-BODY-SAME')
	public function testAnObjectLiteralBranchKeepsItsOwnLine(): Void {
		Assert.equals(OBJ, HxWriteFixture.triviaWrite(OBJ, CFG_NEXT));
	}

	/** A `[ … ]` branch keeps the SOURCE shape: gluing a `]` is `expressionIfWithBrackets`, not this policy. */
	@:pin('control')
	@:killer('M-EXPR-ELSE-PLAIN-SAME')
	@:killer('M-NONCURLY-SAME-DROP')
	public function testABracketBranchKeepsTheSourceBreak(): Void {
		Assert.equals(BRACKET, HxWriteFixture.triviaWrite(BRACKET, CFG_NEXT));
	}

	/** `};` is not a join either, so the `;` goes with the break it used to justify. RED on `f8ba0a46`. */
	@:pin('control')
	@:killer('M-EXPR-ELSE-KEEP')
	@:killer('M-EXPR-ELSE-PLAIN-SAME')
	public function testTheSemicolonBeforeElseGoesWithTheJoin(): Void {
		Assert.equals(JOINED, HxWriteFixture.triviaWrite(SEMI, CFG_NEXT));
	}

	/**
	 * With no `else` the same slot holds the enclosing statement's terminator, and dropping it there
	 * emits code that does not compile — so the drop is gated on a following sibling.
	 *
	 * This was S100's declared COST filter, and the reason it gave has been removed rather than
	 * restated: the gate is MACRO-time, in `WriterLowering.semicolonBeforeSiblingWrap`, and
	 * `TestDiscovery.checkArms` used to resolve an arm's `type` with `Context.getModule` in the
	 * test build, where every `anyparse/macro/*` module sits behind `#if macro` and answers with
	 * no types at all — so a row naming `anyparse.macro.WriterLowering` failed the build with
	 * `resolves to no class`. S102 separated that answer from a module the classpath does not
	 * carry, and `M-SBE-UNGATED` now cuts the `_sbeSibling &&` out of the gate itself. Measured:
	 * it is the only fixture in this class the cut takes down.
	 */
	@:pin('control')
	@:killer('M-SBE-UNGATED')
	public function testAnElseLessValueIfKeepsItsTerminator(): Void {
		Assert.equals(ELSE_LESS, HxWriteFixture.triviaWrite(ELSE_LESS, CFG_NEXT));
	}

	/** `keep` still means keep: the same source, the same break, under the neighbouring config value. */
	@:pin('control')
	@:killer('M-KEEP-JOINS')
	public function testKeepStillPreservesTheSourceBreak(): Void {
		Assert.equals(BROKEN, HxWriteFixture.triviaWrite(BROKEN, CFG_KEEP));
	}

	/**
	 * Pony-shaped config: tab indent, 140 columns, source-preserving array wrap, the two
	 * `fitLine` body keys both real trees set, and `sameLine.expressionIf` as the one
	 * variable. `expressionIfWithBrackets` is deliberately absent.
	 */
	private static function cfg(expressionIf: String): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
			+ '"arrayWrap": {"defaultWrap": "ignore", "rules": []}}, "whitespace": {"typeHintColonPolicy": "after"}, '
			+ '"sameLine": {"ifBody": "fitLine", "functionBody": "fitLine", "expressionIf": "$expressionIf"}}';
	}

}
