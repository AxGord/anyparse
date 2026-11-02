package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * `caseBody` / `expressionCase: fitLine` is decided per branch: a body below its label, for any
 * reason, leaves every sibling that fits on its own label. Pinned for each way a body gets
 * there (several statements, a flat-refused or control-flow one, over-wide), for each way a
 * case list is spelled (a `#if` region, a label splice, a shared splice list), and for the
 * fixed point every one of them must reach in one pass.
 *
 * The knobs are visible only through `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxCaseBodyPerBranchTest extends Test {

	/** `case 2` is 12 + 28 = 40 columns at 3 tabs; the other two are far narrower. */
	private static final MIXED_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: aa(bb);\n'
		+ '\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** `MIXED_SRC` with its over-wide body inside a `#if` region. */
	private static final CONDITIONAL_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n#if js\n\t\t\tcase 2: cc(ddddddddddddddd);\n#end\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** The over-wide case sits in the `#else` branch, behind an `#elseif` that also holds one. */
	private static final BRANCHES_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: aa(bb);\n'
		+ '#if js\n\t\t\tcase 2: gg(h);\n#elseif cpp\n\t\t\tcase 3: ii(jj);\n#else\n\t\t\tcase 4: cc(ddddddddddddddd);\n#end\n'
		+ '\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** The over-wide case sits inside a `#if` nested in another `#if`. */
	private static final NESTED_REGION_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n#if js\n#if debug\n\t\t\tcase 2: cc(ddddddddddddddd);\n#end\n\t\t\tcase 3: gg(h);\n#end\n'
		+ '\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** `HxCondSpliceSwitchOpen`: the case list shared after `#end`, at 4 tabs, so the wide case is 16 + 28 = 44 columns. */
	private static final SPLICE_SWITCH_OPEN_SRC: String = 'class M {\n\tfunction f():Void {\n#if utf16\n\t\tfor (c in it(tmp)) {\n'
		+ '\t\t\tswitch (c) {\n#else\n\t\tfor (i in 0...tmp.length) {\n\t\t\tswitch (fast(tmp, i)) {\n#end\n'
		+ '\t\t\t\tcase 1: aa(bb);\n\t\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t\t\tcase _: ee(ff);\n\t\t\t}\n\t\t}\n\t}\n}\n';

	/** A switch whose ONLY element is a `#if` region. */
	private static final LONE_REGION_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n#if js\n'
		+ '\t\t\tcase 1: aa(bb);\n\t\t\tcase 2: cc(ddddddddddddddd);\n#end\n\t\t};\n\t}\n}\n';

	/** A pattern-scope conditional: the region sits inside the pattern list and the `:` is outside it. */
	private static final PATTERN_REGION_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase #if js "a" #else "b" #end: cc(dd);\n\t\t\tcase _: ee(ff);\n\t\t};\n\t}\n}\n';

	/** `HxSwitchCase.CondSpliceCase`: a region splitting a case's labels from the body they share after `#end`. */
	private static final SPLICE_CASE_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar w = switch ext(a) {\n#if hxbitmini\n'
		+ '\t\t\tcase ATLAS, BINATLAS:\n#else\n\t\t\tcase ATLAS:\n#end\n\t\t\t\tcc(ddddddddddddddd);\n\t\t\tcase PNG: tiles[a];\n'
		+ '\t\t};\n\t}\n}\n';

	private static final MULTI_STMT_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n\t\t\tcase 2:\n\t\t\t\tfinal t:Int = k();\n\t\t\t\tt;\n\t\t};\n\t}\n}\n';

	/** A single statement the flat-refusal gate rejects (outermost `&&`). */
	private static final REFUSED_FLAT_SRC: String =
		'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: a && b;\n\t\t\tcase 2: cc(d);\n\t\t};\n\t}\n}\n';

	private static final DEFAULT_MULTI_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n\t\t\tdefault:\n\t\t\t\tfinal t:Int = k();\n\t\t\t\tt;\n\t\t};\n\t}\n}\n';
	private static final GLUED_BESIDE_MULTI_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: (a, b) -> {\n\t\t\t\tfinal t:Int = k(a, b);\n\t\t\t\tt;\n\t\t\t}\n\t\t\tcase 2:\n'
		+ '\t\t\t\tfinal u:Int = m();\n\t\t\t\tu;\n\t\t};\n\t}\n}\n';
	private static final GLUED_BESIDE_WIDE_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: (a, b) -> {\n\t\t\t\tfinal t:Int = k(a, b);\n\t\t\t\tt;\n\t\t\t}\n'
		+ '\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t};\n\t}\n}\n';
	private static final COND_MULTI_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n'
		+ '\t\t\tcase 1: aa(bb);\n#if js\n\t\t\tcase 2:\n\t\t\t\tfinal t:Int = k();\n\t\t\t\tt;\n#end\n\t\t};\n\t}\n}\n';

	/** Statement position, and the shape that decided the rule: a two-statement branch beside a one-liner. */
	private static final STATEMENT_MULTI_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch type {\n\t\t\tcase Neko:\n'
		+ '\t\t\t\ta();\n\t\t\t\tb();\n\t\t\tcase Air:\n\t\t\t\tc(p, v);\n\t\t}\n\t}\n}\n';

	public function new(): Void {
		super();
	}

	public function testAMultiStatementStatementBranchLeavesItsSiblingOnItsLabel(): Void {
		final out: String = write(STATEMENT_MULTI_SRC, jsonCaseBody(140));
		has(out, 'case Air: c(p, v);');
		has(out, 'case Neko:\n\t\t\t\ta();\n\t\t\t\tb();');
	}

	public function testAMultiStatementValueBranchLeavesItsSiblingOnItsLabel(): Void {
		final out: String = write(MULTI_STMT_SRC, json(140));
		has(out, 'case 1: aa(bb);');
		has(out, 'case 2:\n\t\t\t\tfinal t:Int = k();');
	}

	public function testAMultiStatementDefaultLeavesItsSiblingOnItsLabel(): Void {
		final out: String = write(DEFAULT_MULTI_SRC, json(140));
		has(out, 'case 1: aa(bb);');
		has(out, 'default:\n\t\t\t\tfinal t:Int = k();');
	}

	public function testAGuardedMultiStatementBranchLeavesItsSiblingOnItsLabel(): Void {
		final out: String = write(COND_MULTI_SRC, json(140));
		has(out, 'case 1: aa(bb);');
		has(out, 'case 2:\n\t\t\t\tfinal t:Int = k();');
	}

	public function testAFlatRefusedBranchLeavesItsSiblingOnItsLabel(): Void {
		final out: String = write(REFUSED_FLAT_SRC, json(140));
		has(out, 'case 2: cc(d);');
		has(out, 'case 1:\n\t\t\t\ta && b;');
	}

	/** Width coordinates nothing either: `fitLine` is read literally, per branch. */
	public function testAnOverWideBranchLeavesItsSiblingsOnTheirLabels(): Void {
		final out: String = write(MIXED_SRC, json(39));
		has(out, 'case 1: aa(bb);');
		has(out, 'case 2:\n\t\t\t\tcc(ddddddddddddddd);');
		has(out, 'case _: ee(ff);');
	}

	public function testEveryBranchStaysOnItsLabelWhenItFits(): Void {
		final out: String = write(MIXED_SRC, json(40));
		has(out, 'case 1: aa(bb);');
		has(out, 'case 2: cc(ddddddddddddddd);');
		has(out, 'case _: ee(ff);');
	}

	public function testAGluedBranchStaysGluedBesideABranchBelowItsLabel(): Void {
		has(write(GLUED_BESIDE_MULTI_SRC, json(140)), 'case 1: (a, b) -> {');
		has(write(GLUED_BESIDE_WIDE_SRC, json(39)), 'case 1: (a, b) -> {');
	}

	public function testAGuardedOverWideBranchLeavesItsSiblingsOnTheirLabels(): Void {
		final out: String = write(CONDITIONAL_SRC, json(39));
		has(out, 'case 1: aa(bb);');
		has(out, 'case 2:\n\t\t\t\tcc(ddddddddddddddd);');
		has(out, 'case _: ee(ff);');
	}

	public function testEachConditionalBranchAnswersForItself(): Void {
		final out: String = write(BRANCHES_SRC, json(39));
		has(out, 'case 1: aa(bb);');
		has(out, 'case 2: gg(h);');
		has(out, 'case 3: ii(jj);');
		has(out, 'case 4:\n\t\t\t\tcc(ddddddddddddddd);');
		has(out, 'case _: ee(ff);');
	}

	public function testANestedRegionAnswersForItself(): Void {
		final out: String = write(NESTED_REGION_SRC, json(39));
		has(out, 'case 1: aa(bb);');
		has(out, 'case 2:\n\t\t\t\tcc(ddddddddddddddd);');
		has(out, 'case 3: gg(h);');
		has(out, 'case _: ee(ff);');
	}

	public function testALoneRegionsCasesAnswerForThemselves(): Void {
		final out: String = write(LONE_REGION_SRC, json(39));
		has(out, 'case 1: aa(bb);');
		has(out, 'case 2:\n\t\t\t\tcc(ddddddddddddddd);');
	}

	public function testASharedSpliceCaseListAnswersPerBranch(): Void {
		final over: String = write(SPLICE_SWITCH_OPEN_SRC, jsonCaseBody(43));
		has(over, 'case 1: aa(bb);');
		has(over, 'case 2:\n\t\t\t\t\tcc(ddddddddddddddd);');
		has(over, 'case _: ee(ff);');
		has(write(SPLICE_SWITCH_OPEN_SRC, jsonCaseBody(44)), 'case 2: cc(ddddddddddddddd);');
	}

	/** The shared body renders below the labels it was split from, which says nothing about the plain case beside it. */
	public function testALabelSpliceLeavesItsSiblingOnItsLabel(): Void {
		has(write(SPLICE_CASE_SRC, json(39)), 'case PNG: tiles[a];');
	}

	public function testAPatternScopeConditionalAnswersByItsOwnWidth(): Void {
		final fits: String = write(PATTERN_REGION_SRC, json(51));
		has(fits, '#end: cc(dd);');
		has(fits, 'case _: ee(ff);');
		final over: String = write(PATTERN_REGION_SRC, json(50));
		has(over, '#end:\n\t\t\t\tcc(dd);');
		has(over, 'case _: ee(ff);');
	}

	public function testANestedSwitchAnswersIndependently(): Void {
		final src: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1: switch (y) {\n'
			+ '\t\t\t\tcase 3: pp(q);\n\t\t\t\tcase _: rr(s);\n\t\t\t}\n\t\t\tcase 2: cc(ddddddddddddddd);\n\t\t};\n\t}\n}\n';
		final out: String = write(src, json(39));
		has(out, 'case 3: pp(q);');
		has(out, 'case _: rr(s);');
		has(out, 'case 2:\n\t\t\t\tcc(ddddddddddddddd);');
	}

	/** Every fixture at a budget that fits and one that does not. A per-branch verdict must not need a second pass. */
	public function testEveryShapeReachesItsFixedPointInOnePass(): Void {
		final fixtures: Array<String> = [
			MIXED_SRC,
			CONDITIONAL_SRC,
			BRANCHES_SRC,
			NESTED_REGION_SRC,
			SPLICE_SWITCH_OPEN_SRC,
			LONE_REGION_SRC,
			PATTERN_REGION_SRC,
			SPLICE_CASE_SRC,
			MULTI_STMT_SRC,
			REFUSED_FLAT_SRC,
			DEFAULT_MULTI_SRC,
			GLUED_BESIDE_MULTI_SRC,
			GLUED_BESIDE_WIDE_SRC,
			COND_MULTI_SRC,
			STATEMENT_MULTI_SRC
		];
		for (src in fixtures) for (width in [39, 140]) {
			final j: String = '{"wrapping": {"maxLineLength": $width}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}}';
			final once: String = write(src, j);
			Assert.equals(once, write(once, j), 'width $width must settle in one pass on <$src>');
		}
	}

	/** The same AST from inline and from already-broken source: each branch's verdict must not read the source's line shape. */
	public function testOutputIsIndependentOfSourceLineShape(): Void {
		final broken: String = 'class M {\n\tfunction f():Void {\n\t\tvar v = switch (x) {\n\t\t\tcase 1:\n\t\t\t\taa(bb);\n'
			+ '\t\t\tcase 2:\n\t\t\t\tcc(ddddddddddddddd);\n\t\t\tcase _:\n\t\t\t\tee(ff);\n\t\t};\n\t}\n}\n';
		Assert.equals(write(MIXED_SRC, json(39)), write(broken, json(39)));
		Assert.equals(write(MIXED_SRC, json(80)), write(broken, json(80)));
	}

	public function testAlignInlineSwitchCaseBodyComposesWithBothOutcomes(): Void {
		final onFit: String = write(MIXED_SRC, json(80, true));
		Assert.equals(write(MIXED_SRC, json(80, false)), onFit);
		has(onFit, 'case 1: aa(bb);');
		final onBreak: String = write(MIXED_SRC, json(39, true));
		Assert.equals(write(MIXED_SRC, json(39, false)), onBreak);
		has(onBreak, 'case 2:\n');
	}

	public function testKeepPreservesTheSourceShape(): Void {
		final keep: String = write(CONDITIONAL_SRC, '{"wrapping": {"maxLineLength": 39}, "sameLine": {"expressionCase": "keep"}}');
		has(keep, 'case 1: aa(bb);');
		has(keep, 'case 2: cc(ddddddddddddddd);');
		has(keep, 'case _: ee(ff);');
	}

	/** `d` switches nested through each other's first case body. A canary: a placement pre-pass per level would cost 2^d here. */
	public function testDeeplyNestedSwitchesSettleInOnePass(): Void {
		var body: String = 'aa(bb);';
		for (i in 0...15) body = 'switch (y$i) {\n\t\t\tcase 3: $body\n\t\t\tcase _: cc(dd);\n\t\t}';
		final src: String = 'class D {\n\tfunction f():Void {\n\t\t$body\n\t}\n}\n';
		final j: String = '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}}';
		final once: String = write(src, j);
		Assert.equals(once, write(once, j));
		has(once, 'case 3: aa(bb);');
	}

	private inline function has(out: String, fragment: String): Void {
		Assert.isTrue(out.indexOf(fragment) != -1, 'expected <$fragment> in <$out>');
	}

	private inline function jsonCaseBody(maxLineLength: Int): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "sameLine": {"caseBody": "fitLine"}}';
	}

	private inline function json(maxLineLength: Int, alignInline: Bool = false): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "indentation": {"alignInlineSwitchCaseBody": $alignInline'
			+ '}, "sameLine": {"expressionCase": "fitLine"}}';
	}

	private inline function write(src: String, cfg: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(cfg));
	}

}
