package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * omega-case-body-controlflow-glue — a non-flat case body whose single
 * statement is a CONTROL-FLOW statement must not glue to its label.
 *
 * `BodyFit.fitLineLayout` places a body that cannot render flat
 * (`WrapList.flatLength == -1`) on the label line, because no budget makes
 * it fit and its FIRST line is a real line that does. For a `{`-opening
 * VALUE — a block, an object literal, a lambda — that reads right: the
 * brace ends the label line and the interior is plainly the body's.
 *
 * For a keyword-led STATEMENT it does not. The construct's own
 * continuation lines (`else if`, `} while`, `catch`, a region's `#else` /
 * `#end`) are siblings of its head, so glued they render at the HEAD's
 * indent — the case LABEL's own column under
 * `indentation.alignInlineSwitchCaseBody`, one level under it at the
 * default. In neither case do they sit under the body they continue, so
 * the statement reads as if it had escaped the branch (shown here at the
 * aligned setting, where it is starkest):
 *
 * ```
 * case PAIR(a, b): if (p(k))
 *     a[k] = v;
 * else if (q(k))
 *     b[k] = v;
 * ```
 *
 * This slice sends such a body below its label instead, where the head and
 * its arms share one indent one level under `case`. The refusal is by STATEMENT KIND (`caseBodyControlFlowRoot`), not by
 * shape: a `{`-opening value keeps the glue it was given deliberately, and
 * a control-flow body that DOES render flat (`case X: if (c) x();`) is
 * untouched — it never reaches the glue branch at all. A `@:meta` prefix is
 * transparent to the question, so the predicate recurses through it on both
 * routes the parser takes (`MetaExpr` for `if` / `for` / `while` / `switch`
 * / `try`, `MetaStmt` for `do … while`) and answers about the statement
 * underneath: `@:meta if (c) { … }` is refused, `@:meta { … }` still glues.
 *
 * SIBLING SYMMETRY. A refused body is below its label, so the per-switch
 * rule of omega-case-sibling-symmetry applies and every sibling follows it
 * down. The verdict cannot be taken by the structural pre-pass, which
 * measures nothing: `case X: if (c) x();` and `case X: if (c) { x(); }`
 * have the SAME statement kind and only the width measure tells them
 * apart. It is taken in the WIDTH loop instead — a unit that measures `-1` AND has
 * a control-flow body root forces the break, exactly as a multi-statement
 * body does structurally. Both halves hang off ONE meta
 * (`@:fmt(refuseGlueOnControlFlowRoot)` on the case-body Star, which the
 * case-LIST Star reads back at macro time), so a grammar can never get the
 * spread without the placement that justifies it.
 *
 * GUARDS vs DISCRIMINATORS. Stash-verified against the pre-slice engine:
 * every test here FAILS there except
 * `testAFlatControlFlowBodyStaysInline`,
 * `testGluedValueBodiesStayGluedAndDoNotTrigger`,
 * `testAMetadataWrappedBlockStaysGlued` and `testKnobOffIsInert`, which are
 * the guards against over-firing.
 *
 * Per `feedback_unit_test_trivia_writer.md`: the knobs are visible only
 * through `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxCaseBodyControlFlowGlueTest extends Test {

	/** A braced `if` body beside a one-liner — nothing here is over-wide, the trigger is the body's KIND. */
	private static final BLOCK_IF_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase A: if (c) {\n'
		+ '\t\t\t\taa();\n\t\t\t}\n\t\t\tcase _: bb();\n\t\t}\n\t}\n}\n';

	/** The owner-reported shape: an `if` / `else if` chain whose arms rendered at LABEL indent. */
	private static final CHAIN_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n'
		+ '\t\t\tcase A(pp, qq): if (isAlpha(pp)) {\n\t\t\t\talpha[pp] = qq;\n\t\t\t} else if (isBeta(pp)) {\n'
		+ '\t\t\t\tbeta[pp] = qq;\n\t\t\t}\n\t\t\tcase _: throw new E();\n\t\t}\n\t}\n}\n';

	/** Every other control-flow ctor of `HxStatement`, one per case. */
	private static final LOOPS_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase A: for (i in list) {\n'
		+ '\t\t\t\taa(i);\n\t\t\t}\n\t\t\tcase B: while (c) {\n\t\t\t\tbb();\n\t\t\t}\n\t\t\tcase C: try {\n\t\t\t\tcc();\n'
		+ '\t\t\t} catch (e:E) {\n\t\t\t\tdd();\n\t\t\t}\n\t\t\tcase D: do {\n\t\t\t\tee();\n\t\t\t} while (c);\n'
		+ '\t\t\tcase E: switch (y) {\n\t\t\t\tcase 1: ff();\n\t\t\t\tcase _: gg();\n\t\t\t}\n\t\t\tcase _: hh();\n\t\t}\n\t}\n}\n';

	/** A control-flow body that renders FLAT — the measured outcome, which the kind refusal must not reach. */
	private static final SHORT_IF_SRC: String =
		'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase A: if (c) aa();\n\t\t\tcase _: bb();\n\t\t}\n\t}\n}\n';

	/** A comparator-table shape: `{`-opening VALUES whose glue is deliberate. */
	private static final GLUED_VALUES_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n'
		+ '\t\t\tcase A: (a, b) -> {\n\t\t\t\tfinal t:Int = k(a, b);\n\t\t\t\tt;\n\t\t\t}\n\t\t\tcase B: {\n\t\t\t\tcc();\n'
		+ '\t\t\t\tdd();\n\t\t\t}\n\t\t\tcase _: ee();\n\t\t}\n\t}\n}\n';

	/**
	 * A BRACE-LESS control-flow body. Nothing about the refusal is about
	 * braces: `whileBody: next` alone gives the body its hardline, and the
	 * `while` head then carries a continuation line exactly as a braced one
	 * carries its `}`.
	 */
	private static final BRACELESS_WHILE_SRC: String =
		'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase A: while (c) bb();\n\t\t\tcase _: cc();\n\t\t}\n\t}\n}\n';

	/**
	 * A `#if` REGION as the sole case body. Its `#else` / `#end` markers are
	 * the same kind of continuation line an `else if` is, and glued they land
	 * the same way.
	 */
	private static final COND_REGION_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase A: #if debug\n'
		+ '\t\t\t\taa();\n\t\t\t#else\n\t\t\t\tbb();\n\t\t\t#end\n\t\t\tcase _: cc();\n\t\t}\n\t}\n}\n';

	/**
	 * `@:meta`-prefixed control flow, on BOTH routes the parser takes for it:
	 * `if` goes to the expression route (`ExprStmt(MetaExpr(…, IfExpr))`),
	 * `do … while` has no expression form and stays a statement
	 * (`MetaStmt(…, DoWhileStmt)`).
	 */
	private static final META_CONTROL_FLOW_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n'
		+ '\t\t\tcase A: @:privateAccess if (c) {\n\t\t\t\taa();\n\t\t\t}\n\t\t\tcase B: @:privateAccess do {\n\t\t\t\tbb();\n'
		+ '\t\t\t} while (c);\n\t\t\tcase _: cc();\n\t\t}\n\t}\n}\n';

	/** The recursion control: `@:meta` over a `{`-opening VALUE must reach the value's answer, which is glue. */
	private static final META_BLOCK_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n'
		+ '\t\t\tcase A: @:privateAccess {\n\t\t\t\taa();\n\t\t\t\tbb();\n\t\t\t}\n\t\t\tcase _: cc();\n\t\t}\n\t}\n}\n';

	/** ONE case — no sibling to coordinate with, so only the per-construct decision can place this body. */
	private static final SOLE_CASE_SRC: String =
		'class M {\n\tfunction f():Void {\n\t\tswitch (x) {\n\t\t\tcase A: if (c) {\n\t\t\t\taa();\n\t\t\t}\n\t\t}\n\t}\n}\n';

	public function new(): Void {
		super();
	}

	/**
	 * The head of the refused body lands one level below its label, and the
	 * budget plays no part — 140 columns against a longest line of 20.
	 */
	public function testAControlFlowBodyGoesBelowItsLabel(): Void {
		final out: String = write(BLOCK_IF_SRC, json(140));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\tif (c) {') != -1, 'a braced `if` body must not glue to its label: <$out>');
		Assert.isTrue(out.indexOf('case A: if (c)') == -1, 'and nothing of it may stay on the label line: <$out>');
	}

	/** Below its label is a below-label placement, so the per-switch rule takes the one-liner sibling down too. */
	public function testAControlFlowBodySpreadsItsSiblings(): Void {
		final out: String = write(BLOCK_IF_SRC, json(140));
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\tbb();') != -1, 'a fitting sibling must follow a control-flow body down: <$out>');
	}

	/**
	 * The defect as reported: the chain's `else if` arm rendered at LABEL
	 * indent (3 tabs), reading as if it had escaped the branch. It must sit
	 * at the body's own indent (4 tabs), under the `if` it continues.
	 */
	public function testElseIfArmsIndentUnderTheBodyHead(): Void {
		final out: String = write(CHAIN_SRC, jsonAligned(140));
		Assert.isTrue(out.indexOf('case A(pp, qq):\n\t\t\t\tif (isAlpha(pp)) {') != -1, 'the chain head goes below its label: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t\t} else if (isBeta(pp)) {') != -1, 'and its `else if` arm indents with it: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t} else if (isBeta(pp)) {') == -1, 'never at label indent: <$out>');
	}

	/** `for` / `while` / `try` / `do while` / `switch` are the same kind of body and take the same placement. */
	public function testEveryControlFlowCtorGoesBelowItsLabel(): Void {
		final out: String = write(LOOPS_SRC, json(140));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\tfor (i in list) {') != -1, 'for: <$out>');
		Assert.isTrue(out.indexOf('case B:\n\t\t\t\twhile (c) {') != -1, 'while: <$out>');
		Assert.isTrue(out.indexOf('case C:\n\t\t\t\ttry {') != -1, 'try: <$out>');
		Assert.isTrue(out.indexOf('case D:\n\t\t\t\tdo {') != -1, 'do while: <$out>');
		Assert.isTrue(out.indexOf('case E:\n\t\t\t\tswitch (y) {') != -1, 'switch: <$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\thh();') != -1, 'and the plain sibling follows them: <$out>');
	}

	/**
	 * The refusal is on the GLUE outcome only. A control-flow body that
	 * renders flat never reaches it — it is measured like any other body and
	 * stays on the label line, taking its sibling with it.
	 */
	public function testAFlatControlFlowBodyStaysInline(): Void {
		final out: String = write(SHORT_IF_SRC, json(140));
		Assert.isTrue(out.indexOf('case A: if (c) aa();') != -1, 'a flat `if` body is measured, not refused: <$out>');
		Assert.isTrue(out.indexOf('case _: bb();') != -1, 'so its sibling stays inline as well: <$out>');
	}

	/**
	 * A `{`-opening VALUE keeps its glue: the brace ends the label line and
	 * the interior is unambiguously the body's. It is also not a trigger, so
	 * the plain sibling stays inline — the pin that this slice widened the
	 * refusal by STATEMENT KIND and not by `flatLength == -1`.
	 */
	public function testGluedValueBodiesStayGluedAndDoNotTrigger(): Void {
		final out: String = write(GLUED_VALUES_SRC, json(140));
		Assert.isTrue(out.indexOf('case A: (a, b) -> {') != -1, 'a block-lambda body stays glued: <$out>');
		Assert.isTrue(out.indexOf('case B: {') != -1, 'and so does a plain block body: <$out>');
		Assert.isTrue(out.indexOf('case _: ee();') != -1, 'neither is a trigger, so the plain sibling stays inline: <$out>');
	}

	/**
	 * The sibling pre-pass short-circuits on a one-unit case list, so a lone
	 * case gets no coordination at all. Its placement can only come from the
	 * per-construct decision inside `BodyFit.fitLineLayout` — which is the
	 * half of this slice the symmetry channel cannot stand in for.
	 * Braces have nothing to do with it. `whileBody: next` gives a brace-less
	 * `while` body its hardline, the case body then cannot render flat, and the
	 * same refusal applies — head below the label, sibling spread with it.
	 */
	public function testABracelessControlFlowBodyGoesBelowAndSpreads(): Void {
		final out: String = write(BRACELESS_WHILE_SRC, jsonNextWhileBody(140));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\twhile (c)\n\t\t\t\t\tbb();') != -1, 'the brace-less head goes below its label: <$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\tcc();') != -1, 'and its sibling follows it down: <$out>');
	}

	/**
	 * A `#if` region body is a control-flow body: glued, its `#else` / `#end`
	 * markers render at the head's indent, above the branch content they
	 * delimit. It goes below its label and takes its sibling with it.
	 */
	public function testAConditionalRegionBodyGoesBelowItsLabel(): Void {
		final out: String = write(COND_REGION_SRC, json(140));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\t#if debug') != -1, 'the region head goes below its label: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t\t#else\n') != -1, 'and its `#else` marker indents with it: <$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\tcc();') != -1, 'and the sibling follows it down: <$out>');
	}

	/**
	 * `@:meta` is transparent to the placement question, so what decides is the
	 * statement underneath. Both parse routes are covered: the expression one
	 * (`if`, via `MetaExpr`) and the statement one (`do … while`, via
	 * `MetaStmt`).
	 */
	public function testAMetadataWrappedControlFlowBodyGoesBelowItsLabel(): Void {
		final out: String = write(META_CONTROL_FLOW_SRC, json(140));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\t@:privateAccess if (c) {') != -1, 'the expression route: <$out>');
		Assert.isTrue(out.indexOf('case B:\n\t\t\t\t@:privateAccess do {') != -1, 'the statement route: <$out>');
		Assert.isTrue(out.indexOf('case _:\n\t\t\t\tcc();') != -1, 'and the sibling follows them down: <$out>');
	}

	/**
	 * The other half of the recursion, and the reason it is a recursion rather
	 * than a widened ctor table: an annotated `{`-opening VALUE keeps the glue
	 * the bare value gets, and is no trigger.
	 */
	public function testAMetadataWrappedBlockStaysGlued(): Void {
		final out: String = write(META_BLOCK_SRC, json(140));
		Assert.isTrue(out.indexOf('case A: @:privateAccess {') != -1, 'an annotated block body stays glued: <$out>');
		Assert.isTrue(out.indexOf('case _: cc();') != -1, 'and its sibling stays inline: <$out>');
	}

	public function testASoleCaseIsPlacedWithoutAnySiblingCoordination(): Void {
		final out: String = write(SOLE_CASE_SRC, json(140));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\tif (c) {') != -1, 'a lone control-flow case body still goes below: <$out>');
	}

	/** The new placement must reach its fixed point in ONE pass, like every other case-body verdict. */
	public function testIsIdempotent(): Void {
		final j: String = json(140);
		final fixtures: Array<{ name: String, src: String }> = [
			{ name: 'BLOCK_IF_SRC', src: BLOCK_IF_SRC },
			{ name: 'CHAIN_SRC', src: CHAIN_SRC },
			{ name: 'LOOPS_SRC', src: LOOPS_SRC },
			{ name: 'SOLE_CASE_SRC', src: SOLE_CASE_SRC },
			{ name: 'COND_REGION_SRC', src: COND_REGION_SRC },
			{ name: 'META_CONTROL_FLOW_SRC', src: META_CONTROL_FLOW_SRC }
		];
		for (f in fixtures) {
			final pass1: String = write(f.src, j);
			Assert.isTrue(
				pass1.indexOf('):\n\t\t\t\t') != -1 || pass1.indexOf('case A:\n\t\t\t\t') != -1,
				'${f.name} must really have moved its body below the label: <$pass1>'
			);
			final pass2: String = write(pass1, j);
			Assert.equals(pass1, pass2, '${f.name}: the placement must reach its fixed point in one pass');
			Assert.equals(pass2, write(pass2, j), '${f.name}: the fixed point must hold on a third pass');
		}
	}

	/** Under a non-`FitLine` policy the whole path is unreachable, so the source shape survives untouched. */
	public function testKnobOffIsInert(): Void {
		final keep: String = write(BLOCK_IF_SRC, '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "keep"}}');
		Assert.isTrue(keep.indexOf('case A: if (c) {') != -1, 'Keep preserves the source shape: <$keep>');
		Assert.isTrue(keep.indexOf('case _: bb();') != -1, '<$keep>');
	}

	private inline function json(maxLineLength: Int): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}}';
	}

	/**
	 * `json` plus `alignInlineSwitchCaseBody`. Under that knob a glued body's
	 * inner lines take NO continuation indent, so its continuation lines land
	 * on the case label's own column — which is what makes the arms of a glued
	 * `if` chain read as if they had left the branch, and the only config where
	 * a test about arm indentation can discriminate.
	 */
	private inline function jsonAligned(maxLineLength: Int): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "indentation": {"alignInlineSwitchCaseBody": true}, '
			+ '"sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}}';
	}

	/** `json` plus `whileBody: next`, which breaks a brace-less `while` body regardless of width. */
	private inline function jsonNextWhileBody(maxLineLength: Int): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine", '
			+ '"whileBody": "next"}}';
	}

	private inline function write(src: String, cfg: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(cfg));
	}

}
