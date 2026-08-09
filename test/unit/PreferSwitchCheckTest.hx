package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferSwitch;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;

/**
 * The `prefer-switch` check: a STATEMENT-position `if` / `else if` chain testing one
 * or more expressions against constant values is flagged `Info` and rewritten to a
 * `switch` by `--fix`. A chain over different discriminants, a non-equality or `!=`
 * condition, a non-constant or interpolated operand, an extra conjunct that is not an
 * equality, a non-uniform discriminant tuple, a call-bearing discriminant, or a lone `if`
 * is not flagged; neither is a qualified static the `SymbolIndex` cannot prove constant (a
 * plain `static var`, a `#if`-guarded declaration).
 *
 * A chain with NO trailing `else` is not flagged either, whatever its subject: gate 7 is
 * unconditional, so every converted chain carries `case _`. `testNoTrailingElseNotFlagged`
 * pins that across the shapes an earlier subject-type waiver did and did not convert, and
 * `testGuardedTrailingElseNotFlagged` pins the `#if`-guarded `else`, which never reaches
 * the `if`'s else-slot at all.
 *
 * Value-position chains belong to `prefer-switch-expression` and are not matched here.
 */
class PreferSwitchCheckTest extends Test {

	/**
	 * An enum-abstract module: its values are exhaustiveness-checked by the compiler, and
	 * two fixtures below need the SAME module to differ only in the trailing `else`.
	 */
	private static final ENUM_ABSTRACT: String = 'enum abstract NodeMeta(Int) {\n\tfinal ALPHA = 0;\n\tvar BETA = 1;\n\tvar GAMMA = 2;\n}';

	public function testStringChainFlagged(): Void {
		final vs: Array<Violation> = violations(wrap("if (x == 'a') a(); else if (x == 'b') b(); else c();"));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-switch', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testIntChainFlagged(): Void {
		Assert.equals(1, violations(wrap('if (n == 1) a(); else if (n == 2) b(); else c();')).length);
	}

	public function testFieldAccessDiscriminantFlagged(): Void {
		Assert.equals(1, violations(wrap("if (child.nodeName == 'f') a(); else if (child.nodeName == 'g') b(); else c();")).length);
	}

	public function testLiteralLeftOperandFlagged(): Void {
		Assert.equals(1, violations(wrap('if (1 == n) a(); else if (2 == n) b(); else c();')).length);
	}

	public function testThreeRungChainSingleFinding(): Void {
		Assert.equals(1, violations(wrap("if (x == 'a') a(); else if (x == 'b') b(); else if (x == 'c') c(); else d();")).length);
	}

	public function testDifferentDiscriminantsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 1) a(); else if (y == 2) b(); else c();')).length);
	}

	public function testNonEqualityNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 1) a(); else if (x > 2) b(); else c();')).length);
	}

	public function testNonLiteralOperandNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == y) a(); else if (x == z) b(); else c();')).length);
	}

	public function testInterpolatedStringNotFlagged(): Void {
		Assert.equals(0, violations(wrap("if (x == '$y') a(); else if (x == '$z') b(); else c();")).length);
	}

	public function testCallDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (get() == 1) a(); else if (get() == 2) b(); else c();')).length);
	}

	public function testLoneIfNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 1) a();')).length);
	}

	public function testSingleIfElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 1) a(); else b();')).length);
	}

	public function testNotEqChainNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x != 1) a(); else if (x != 2) b(); else c();')).length);
	}

	public function testFixToSwitch(): Void {
		final fixed: String = fixedSource(wrap("if (x == 'a') a(); else if (x == 'b') b(); else c();"));
		Assert.isTrue(fixed.indexOf('switch (x)') >= 0);
		Assert.isTrue(fixed.indexOf("case 'a':") >= 0);
		Assert.isTrue(fixed.indexOf("case 'b':") >= 0);
		Assert.isTrue(fixed.indexOf('case _:') >= 0);
	}

	/**
	 * Gate 7 is UNCONDITIONAL: a chain with no trailing `else` is never flagged, whatever its
	 * subject, so every converted chain carries `case _`. The fixtures cover both sides of the
	 * waiver this replaced — an `Int` local and an `Int` PARAMETER over cross-file constants,
	 * which the waiver did convert, and a `Bool`, an enum-abstract subject and a tuple, which
	 * it never did. Each shape has a with-`else` positive twin elsewhere in this class showing
	 * it converts once the `else` is there, so none of these can pass on a dead scanner.
	 * Restoring the else-less conversion needs the COMPILER's answer about the subject's type,
	 * not a resolver's — its home is the `OracleAssisted` / `RiskyFix` machinery; gate 7 on
	 * `SwitchChain` carries the reproduced miscompiles a structural guard leaked.
	 */
	public function testNoTrailingElseNotFlagged(): Void {
		final consts: String = 'class NodeMeta {\n\tpublic static inline final ALPHA:Int = 0;\n\tpublic static inline final BETA:Int = 1;\n'
			+ '\tpublic static inline final GAMMA:Int = 2;\n}';
		final params: String = wrapWithParams(
			'stripes:Int',
			'if (stripes == NodeMeta.ALPHA) p(); else if (stripes == NodeMeta.BETA) q(); else if (stripes == NodeMeta.GAMMA) r();'
		);
		final tuple: String = wrap('var a:Int = 1;\n\t\tvar b:Int = 2;\n\t\tif (a == 1 && b == 2) p(); else if (a == 3 && b == 4) q();');
		Assert.equals(0, violations(wrap('var r:Int = 1;\n\t\tif (r == 1) a(); else if (r == 2) b();')).length);
		Assert.equals(0, violations(params, consts).length);
		Assert.equals(0, violations(wrap('var b:Bool = true;\n\t\tif (b == true) p(); else if (b == null) q();')).length);
		Assert.equals(
			0, violations(wrap('var k:NodeMeta = NodeMeta.ALPHA;\n\t\tif (k == 1) p(); else if (k == 2) q();'), ENUM_ABSTRACT).length
		);
		Assert.equals(0, violations(tuple).length);
	}

	/**
	 * A `#if`-guarded trailing `else` does NOT reach the `if`'s else-slot: it projects as a
	 * SIBLING `Conditional` wrapping an `OrphanElseStmt` —
	 * `(IfStmt cond then (IfStmt …)) (Conditional (OrphanElseStmt …))` — so the chain reads as
	 * else-less. The old waiver converted it for an open-typed subject and the stranded `#if`
	 * block no longer parsed (`Expected }`); the unconditional gate 7 refuses the chain, which
	 * closes the shape by construction rather than by a check that knows about `#if`.
	 */
	public function testGuardedTrailingElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var n:Int = 1;\n\t\tif (n == 1) a(); else if (n == 2) b(); #if js else c(); #end')).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-switch'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-switch'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** A chain carrying a comment is still flagged but not auto-converted (the comment would be lost). */
	public function testCommentChainReportedNotFixed(): Void {
		final src: String = wrap('if (x == 1) a(); // one\n\t\telse if (x == 2) b(); else c();');
		Assert.equals(1, violations(src).length);
		Assert.equals(-1, fixedSource(src).indexOf('switch'));
	}

	/**
	 * Axis 2 on the statement path: a rung condition may be a `&&`-conjunction of
	 * equalities over a consistent tuple of discriminants.
	 */
	public function testTupleChainFlaggedAndFixed(): Void {
		final src: String = wrap('if (a == 1 && b == 2) p(); else if (a == 3 && b == 4) q(); else r();');
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('switch [a, b] {') >= 0);
		Assert.isTrue(fixed.indexOf('case [1, 2]: p();') >= 0);
		Assert.isTrue(fixed.indexOf('case [3, 4]: q();') >= 0);
		Assert.isTrue(fixed.indexOf('case _: r();') >= 0);
	}

	/**
	 * A rung testing a different second discriminant is not a uniform tuple. The
	 * trailing `else` is load-bearing: without it gate 7 would reject the chain first and
	 * this fixture would pass on a dead uniform-tuple gate.
	 */
	public function testNonUniformTupleNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a == 1 && b == 2) p(); else if (a == 3 && c == 4) q(); else r();')).length);
	}

	/**
	 * A conjunct that is not an EQUALITY rejects the whole chain. `n > 0` is a two-operand
	 * comparison with exactly one constant operand, so neither the operand-arity check nor
	 * the one-constant-per-equality gate can reject it first — the `eqKind` test is the one
	 * under test. The trailing `else` keeps gate 7 out of the way too.
	 */
	public function testExtraConjunctNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a == 1 && n > 0) p(); else if (a == 2 && n > 0) q(); else r();')).length);
	}

	/**
	 * Axis 3 on the statement path: a `static inline final` constant declared in ANOTHER
	 * module is a valid case pattern, so the chain converts to a switch over it.
	 */
	public function testCrossFileConstantChainFlaggedAndFixed(): Void {
		final consts: String =
			'class NodeMeta {\n\tpublic static inline final ALPHA:String = \'a\';\n\tpublic static inline final BETA:String = \'b\';\n}';
		final src: String = wrap('if (k == NodeMeta.ALPHA) p(); else if (k == NodeMeta.BETA) q(); else r();');
		Assert.equals(1, violations(src, consts).length);
		final fixed: String = fixedSource(src, consts);
		Assert.isTrue(fixed.indexOf('switch (k)') >= 0);
		Assert.isTrue(fixed.indexOf('case NodeMeta.ALPHA: p();') >= 0);
		Assert.isTrue(fixed.indexOf('case NodeMeta.BETA: q();') >= 0);
	}

	/** A plain `static var` is a compile error in a pattern — the same chain must stay untouched. */
	public function testCrossFileStaticVarNotFlagged(): Void {
		final consts: String = "class NodeMeta {\n\tpublic static var ALPHA:String = 'a';\n\tpublic static var BETA:String = 'b';\n}";
		Assert.equals(0, violations(wrap('if (k == NodeMeta.ALPHA) p(); else if (k == NodeMeta.BETA) q(); else r();'), consts).length);
	}

	/** A constant declared inside `#if` is branch-dependent while the index is branch-blind. */
	public function testCrossFileGuardedConstantNotFlagged(): Void {
		final consts: String = 'class NodeMeta {\n\t#if js\n\tpublic static inline final ALPHA:String = \'a\';\n'
			+ '\tpublic static inline final BETA:String = \'b\';\n\t#end\n}';
		Assert.equals(0, violations(wrap('if (k == NodeMeta.ALPHA) p(); else if (k == NodeMeta.BETA) q(); else r();'), consts).length);
	}

	/**
	 * A `null` operand is a literal like any other and converts to `case null:` — which is
	 * also what keeps the `nullable-switch-missing-null` exposure the docs discuss visible
	 * on the result rather than silently dropped.
	 */
	public function testNullPatternChainFlaggedAndFixed(): Void {
		final src: String = wrap('if (x == null) a(); else if (x == 1) b(); else c();');
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('switch (x)') >= 0);
		Assert.isTrue(fixed.indexOf('case null: a();') >= 0);
		Assert.isTrue(fixed.indexOf('case 1: b();') >= 0);
		Assert.isTrue(fixed.indexOf('case _: c();') >= 0);
	}

	/**
	 * The two switch rules match DISJOINT node kinds, so a VALUE-position ternary chain —
	 * `prefer-switch-expression`'s subject — draws nothing here. The mirror assertion lives
	 * in `PreferSwitchExpressionCheckTest`.
	 */
	public function testTernaryChainNotFlagged(): Void {
		Assert.equals(0, violations(wrap("return x == 'a' ? p : x == 'b' ? q : r;")).length);
	}

	/**
	 * An enum-abstract chain WITH a trailing `else` converts — the qualified-static arm
	 * resolves the values and the wildcard makes the result compile. The negative twin in
	 * `testNoTrailingElseNotFlagged` uses the SAME module and chain, differing only in the
	 * `else`, so neither can pass on a dead qualified-static arm.
	 */
	public function testEnumAbstractChainWithElseFlagged(): Void {
		final src: String = wrap('if (k == NodeMeta.ALPHA) p(); else if (k == NodeMeta.BETA) q(); else r();');
		Assert.equals(1, violations(src, ENUM_ABSTRACT).length);
	}

	private inline function wrap(body: String): String {
		return wrapWithParams('', body);
	}

	/** The chain-bearing fixture with `params` on the enclosing function — the shape a PARAMETER subject needs. */
	private function wrapWithParams(params: String, body: String): String {
		return 'class C {\n\tfunction f($params):Void {\n\t\t$body\n\t}\n}';
	}

	/** The fixture file set: the chain-bearing module, plus a constants module when one is given. */
	private function entries(src: String, ?constants: String): Array<{ file: String, source: String }> {
		final all: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		if (constants != null) all.push({ file: 'NodeMeta.hx', source: constants });
		return all;
	}

	private function violations(src: String, ?constants: String): Array<Violation> {
		return new PreferSwitch().run(entries(src, constants), new HaxeQueryPlugin());
	}

	private function fixedSource(src: String, ?constants: String): String {
		final check: PreferSwitch = new PreferSwitch();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = entries(src, constants);
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'C.hx');
		final edits: Array<{ span: Span, text: String }> = check.fix(src, own, plugin, SymbolIndex.build(files, plugin));
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
