package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferSwitchExpression;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `prefer-switch-expression` check: a VALUE-position ternary / if-expression
 * chain testing one or more expressions against constants is flagged `Info` and
 * rewritten to a switch expression by `--fix`.
 *
 * The negative cases pin one gate each — a non-whitelisted host, a missing trailing
 * else, a `!=` / `||` / extra-conjunct rung, a non-uniform discriminant tuple, a
 * call-bearing discriminant, and each way a qualified static constant fails to be
 * provably constant (a plain `static var`, a non-inline `static final`, a
 * `#if`-guarded declaration, an unresolvable receiver). The cross-file fixture is
 * derived from a real project site with every identifier and string anonymized.
 */
class PreferSwitchExpressionCheckTest extends Test {

	/** The trigger shape written INSIDE a `macro …` quotation, where the chain is AST the macro builds. */
	private static inline final QUOTED: String = 'class C {\n\tfunction f(x:Int):Int {\n\t\tfinal e = macro {\n'
		+ '\t\t\tfinal q = if (x == 1) 1; else if (x == 2) 2; else if (x == 3) 3; else 0;\n\t\t};\n\t\treturn 0;\n\t}\n}\n';

	/** The same shape quoted AND then written as real code — exactly one of the two is a finding. */
	private static inline final QUOTED_THEN_RUNTIME: String = 'class C {\n\tfunction f(x:Int):Int {\n\t\tfinal e = macro {\n'
		+ '\t\t\tfinal q = if (x == 1) 1; else if (x == 2) 2; else if (x == 3) 3; else 0;\n\t\t};\n'
		+ '\t\treturn if (x == 1) 1; else if (x == 2) 2; else if (x == 3) 3; else 0;\n\t}\n}\n';


	/** The anonymized constants module the cross-file fixtures resolve against. */
	private static final CONSTANTS: String = 'class NodeMeta {\n\tpublic static inline final KIND_RECTANGLE_SOLID:String = \'rs\';\n'
		+ "\tpublic static inline final KIND_RECTANGLE_STROKE:String = 'rk';\n\tpublic static inline final KIND_OVAL_SOLID:String = 'os';\n"
		+ "\tpublic static inline final KIND_OVAL_STROKE:String = 'ok';\n"
		+ "\tpublic static inline final KIND_TEXT_NODE_BUBBLE:String = 'tb';\n"
		+ "\tpublic static inline final KIND_TEXT_NODE_BUBBLE_STROKE:String = 'tk';\n"
		+ '\tpublic static inline final KIND_TEXT_NODE_BUBBLE_FILL_SHADE:String = \'tf\';\n}';

	/**
	 * The cross-file fixture, anonymized from a real ternary chain: two discriminants,
	 * four rungs of `static inline final` string constants declared in another module,
	 * and a trailing else value.
	 */
	private static final TUPLE_CHAIN: String = 'class BoardView {\n\tprivate static function resolveShadeProp(\n'
		+ '\t\tobj:BoardObject<RecordData>, targetType:String, readCurrent:Bool, newShade:Int = 0\n\t):MoveProperty {\n'
		+ '\t\treturn obj.boardNodeRecord.kind == NodeMeta.KIND_RECTANGLE_SOLID && targetType == NodeMeta.KIND_RECTANGLE_STROKE\n'
		+ '\t\t\t? EdgeShade(readCurrent ? cast(obj, RectangleNode).edgeShade : newShade)\n'
		+ '\t\t\t: obj.boardNodeRecord.kind == NodeMeta.KIND_OVAL_SOLID && targetType == NodeMeta.KIND_OVAL_STROKE\n'
		+ '\t\t\t\t? EdgeShade(readCurrent ? cast(obj, OvalNode).edgeShade : newShade)\n'
		+ '\t\t\t\t: obj.boardNodeRecord.kind == NodeMeta.KIND_TEXT_NODE_BUBBLE && targetType == NodeMeta.KIND_TEXT_NODE_BUBBLE_STROKE\n'
		+ '\t\t\t\t\t? EdgeShade(readCurrent ? cast(obj, TextNodeBubble).edgeShade : newShade)\n'
		+ '\t\t\t\t\t: obj.boardNodeRecord.kind == NodeMeta.KIND_TEXT_NODE_BUBBLE\n'
		+ '\t\t\t\t\t\t&& targetType == NodeMeta.KIND_TEXT_NODE_BUBBLE_FILL_SHADE\n'
		+ '\t\t\t\t\t\t? AreaShade(readCurrent ? cast(obj, TextNodeBubble).areaShade : newShade)\n'
		+ '\t\t\t\t\t\t: Shade(readCurrent ? obj.shade : newShade);\n\t}\n}';

	/** Rewriting a chain inside a REIFICATION subtree changes the `EIf` tree the macro emits into an `ESwitch`. */
	public function testMacroQuotationNotFlagged(): Void {
		Assert.equals(0, linted(QUOTED).length);
	}

	/** …and the skip is the quotation's SUBTREE, not everything that follows it. */
	public function testChainAfterMacroQuotationStillFlagged(): Void {
		CheckFixture.assertOnlyAfterQuotation(linted(QUOTED_THEN_RUNTIME), QUOTED_THEN_RUNTIME, 'chain');
	}

	public function testTernaryChainInReturnFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('return x == 1 ? a() : x == 2 ? b() : c();'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-switch-expression', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testStringTernaryChainFlagged(): Void {
		Assert.equals(1, violations(wrap("return x == 'a' ? p : x == 'b' ? q : r;")).length);
	}

	public function testThreeRungChainSingleFinding(): Void {
		Assert.equals(1, violations(wrap('return x == 1 ? p : x == 2 ? q : x == 3 ? r : s;')).length);
	}

	public function testIfExpressionInitializerFlagged(): Void {
		Assert.equals(1, violations(wrap('final v:Int = if (n == 1) 10 else if (n == 2) 20 else 30;')).length);
	}

	public function testAssignmentHostFlagged(): Void {
		Assert.equals(1, violations(wrap('q = x == 1 ? p : x == 2 ? r : s;')).length);
	}

	public function testMemberInitializerFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tvar m:Int = n == 1 ? 10 : n == 2 ? 20 : 30;\n}').length);
	}

	/** A call argument is not a whitelisted host: a switch parses there but reads worse. */
	public function testCallArgumentHostNotFlagged(): Void {
		Assert.equals(0, violations(wrap('g(x == 1 ? p : x == 2 ? q : r);')).length);
	}

	/**
	 * An if-expression chain with no final `else` is skipped. `SwitchChain` gate 7 requires the
	 * else-slot of EVERY chain, statement or value, so this rule contributes no policy of its
	 * own here — but value position would demand it regardless:
	 * `var v = switch (n) { case 1: 10; case 2: 20; }` over an `Int` is `Unmatched patterns: _`
	 * (verified on 4.3.7) where the same wildcard-less switch in STATEMENT position compiles.
	 */
	public function testNoTrailingElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final v:Int = if (n == 1) 10 else if (n == 2) 20;')).length);
	}

	/** A local `var` initializer is a host too — the commonest value-position shape after `return`. */
	public function testVarInitializerHostFlagged(): Void {
		Assert.equals(1, violations(wrap('var v:Int = x == 1 ? p : x == 2 ? q : r;')).length);
	}

	/**
	 * The two switch rules match DISJOINT node kinds, so a STATEMENT-position `if` chain —
	 * `prefer-switch`'s subject — draws nothing here. The mirror assertion lives in
	 * `PreferSwitchCheckTest`.
	 */
	public function testStatementChainNotFlagged(): Void {
		Assert.equals(0, violations(wrap("if (x == 'a') a(); else if (x == 'b') b(); else c();")).length);
	}

	public function testSingleTernaryNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return x == 1 ? p : q;')).length);
	}

	public function testNotEqRungNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return x == 1 ? p : x != 2 ? q : r;')).length);
	}

	/**
	 * A `||` is not `andKind`, so a disjunctive rung is not a conjunction of equalities and
	 * the chain is skipped. BOTH rungs are disjunctions and both discriminant sets are
	 * uniform, so nothing but the conjunction gate can reject this fixture.
	 */
	public function testOrRungNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return (a == 1 || b == 2) ? p : (a == 3 || b == 4) ? q : r;')).length);
	}

	/**
	 * A conjunct that is not an EQUALITY rejects the whole chain. `n > 0` is a two-operand
	 * comparison with exactly one constant operand, so neither the operand-arity check nor
	 * the one-constant-per-equality gate can reject it first — the `eqKind` test is the one
	 * under test.
	 */
	public function testExtraConjunctNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return a == 1 && n > 0 ? p : a == 2 && n > 0 ? q : r;')).length);
	}

	public function testDifferentDiscriminantsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return x == 1 ? p : y == 2 ? q : r;')).length);
	}

	/** Rung 2 tests a DIFFERENT second discriminant — the tuple is not uniform. */
	public function testNonUniformTupleNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return a == 1 && b == 2 ? p : a == 3 && c == 4 ? q : r;')).length);
	}

	/** Rung 2 tests a SUBSET of the tuple — wildcard padding is a documented follow-up, not v1. */
	public function testSubsetTupleNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return a == 1 && b == 2 ? p : a == 3 ? q : r;')).length);
	}

	public function testCallDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return get() == 1 ? p : get() == 2 ? q : r;')).length);
	}

	public function testInterpolatedStringNotFlagged(): Void {
		Assert.equals(0, violations(wrap("return x == '$y' ? p : x == '$z' ? q : r;")).length);
	}

	public function testFixToSwitchExpression(): Void {
		final fixed: String = fixedSource(wrap("return x == 'a' ? p : x == 'b' ? q : r;"));
		Assert.isTrue(fixed.indexOf('switch (x)') >= 0);
		Assert.isTrue(fixed.indexOf("case 'a': p;") >= 0);
		Assert.isTrue(fixed.indexOf("case 'b': q;") >= 0);
		Assert.isTrue(fixed.indexOf('case _: r;') >= 0);
	}

	public function testTupleChainFlaggedAndFixed(): Void {
		final src: String = wrap('return a == 1 && b == 2 ? p : a == 3 && b == 4 ? q : r;');
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('switch [a, b] {') >= 0);
		Assert.isTrue(fixed.indexOf('case [1, 2]: p;') >= 0);
		Assert.isTrue(fixed.indexOf('case [3, 4]: q;') >= 0);
		Assert.isTrue(fixed.indexOf('case _: r;') >= 0);
	}

	/** A `static inline final` constant declared in ANOTHER module is a valid case pattern. */
	public function testCrossFileConstantChainFlagged(): Void {
		final vs: Array<Violation> = violations(TUPLE_CHAIN, CONSTANTS);
		Assert.equals(1, vs.length);
		Assert.equals('BoardView.hx', vs[0].file);
	}

	/** The full cross-file fixture converts to the expected tuple switch. */
	public function testCrossFileConstantChainFixed(): Void {
		final fixed: String = fixedSource(TUPLE_CHAIN, CONSTANTS);
		Assert.isTrue(fixed.indexOf('switch [obj.boardNodeRecord.kind, targetType] {') >= 0);
		Assert.isTrue(fixed.indexOf(
			'case [NodeMeta.KIND_RECTANGLE_SOLID, NodeMeta.KIND_RECTANGLE_STROKE]: '
			+ 'EdgeShade(readCurrent ? cast(obj, RectangleNode).edgeShade : newShade);'
		) >= 0);
		Assert.isTrue(fixed.indexOf(
			'case [NodeMeta.KIND_TEXT_NODE_BUBBLE, NodeMeta.KIND_TEXT_NODE_BUBBLE_FILL_SHADE]: '
			+ 'AreaShade(readCurrent ? cast(obj, TextNodeBubble).areaShade : newShade);'
		) >= 0);
		Assert.isTrue(fixed.indexOf('case _: Shade(readCurrent ? obj.shade : newShade);') >= 0);
	}

	/** An enum-abstract value is always a compile-time constant, with no `static` modifier written. */
	public function testEnumAbstractConstantFlagged(): Void {
		final consts: String = 'enum abstract NodeMeta(Int) {\n\tfinal ALPHA = 0;\n\tvar BETA = 1;\n}';
		Assert.equals(1, violations(wrap('return k == NodeMeta.ALPHA ? p : k == NodeMeta.BETA ? q : r;'), consts).length);
	}

	/** A plain `static var` is a compile error in a pattern — the chain must stay untouched. */
	public function testStaticVarConstantNotFlagged(): Void {
		final consts: String = "class NodeMeta {\n\tpublic static var ALPHA:String = 'a';\n\tpublic static var BETA:String = 'b';\n}";
		Assert.equals(0, violations(wrap('return k == NodeMeta.ALPHA ? p : k == NodeMeta.BETA ? q : r;'), consts).length);
	}

	/** A constant declared inside `#if` is branch-dependent while the index is branch-blind. */
	public function testGuardedConstantNotFlagged(): Void {
		final consts: String = 'class NodeMeta {\n\t#if js\n\tpublic static inline final ALPHA:String = \'a\';\n'
			+ '\tpublic static inline final BETA:String = \'b\';\n\t#end\n}';
		Assert.equals(0, violations(wrap('return k == NodeMeta.ALPHA ? p : k == NodeMeta.BETA ? q : r;'), consts).length);
	}

	/** With no module declaring the receiver, the reference is unresolvable — skip, never guess. */
	public function testUnresolvedReceiverNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return k == NodeMeta.ALPHA ? p : k == NodeMeta.BETA ? q : r;')).length);
	}

	/** A chain carrying a comment is still flagged but not auto-converted (the comment would be lost). */
	public function testCommentChainReportedNotFixed(): Void {
		final src: String = wrap('return x == 1 // one\n\t\t\t? p : x == 2 ? q : r;');
		Assert.equals(1, violations(src).length);
		Assert.equals(-1, fixedSource(src).indexOf('switch'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-switch-expression'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-switch-expression'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/**
	 * The positive twin of the three negative constant cases below: the SAME chain over
	 * the SAME receiver, differing only in that the constants are provably constant. Without
	 * it a negative case would pass even if the qualified-static arm never fired at all.
	 */
	public function testStaticInlineFinalConstantFlagged(): Void {
		final consts: String =
			'class NodeMeta {\n\tpublic static inline final ALPHA:String = \'a\';\n\tpublic static inline final BETA:String = \'b\';\n}';
		Assert.equals(1, violations(wrap('return k == NodeMeta.ALPHA ? p : k == NodeMeta.BETA ? q : r;'), consts).length);
	}

	/**
	 * A non-inline `static final` is NOT accepted. It may hold a non-constant value of a
	 * type the language refuses in a pattern — `public static final A:Array<Int> = [1];`
	 * written as `case NodeMeta.A` is `Incompatible pattern` — and the index cannot see the
	 * initializer. Only `inline` proves constness: the compiler refuses it on a non-constant
	 * initializer, so `testStaticInlineFinalConstantFlagged` above is the accepted twin.
	 */
	public function testStaticFinalConstantNotFlagged(): Void {
		final consts: String = "class NodeMeta {\n\tpublic static final ALPHA:String = 'a';\n\tpublic static final BETA:String = 'b';\n}";
		Assert.equals(0, violations(wrap('return k == NodeMeta.ALPHA ? p : k == NodeMeta.BETA ? q : r;'), consts).length);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	/** The fixture file set: the chain-bearing module, plus the constants module when one is given. */
	private function entries(src: String, ?constants: String): Array<{ file: String, source: String }> {
		final all: Array<{ file: String, source: String }> = [{ file: mainFileOf(src), source: src }];
		if (constants != null) all.push({ file: 'NodeMeta.hx', source: constants });
		return all;
	}

	/** The chain fixture's file name — the cross-file fixture declares `BoardView`, every other one `C`. */
	private function mainFileOf(src: String): String {
		return src.indexOf('class BoardView') >= 0 ? 'BoardView.hx' : 'C.hx';
	}


	private function violations(src: String, ?constants: String): Array<Violation> {
		return new PreferSwitchExpression().run(entries(src, constants), new HaxeQueryPlugin());
	}

	/**
	 * The same findings THROUGH THE LINTER — the altitude the central reification gate lives at
	 * (`Linter.run`), so a quoted finding is dropped here and not by the check itself.
	 */
	private function linted(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new PreferSwitchExpression()]);
	}

	private function fixedSource(src: String, ?constants: String): String {
		final check: PreferSwitchExpression = new PreferSwitchExpression();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = entries(src, constants);
		final file: String = mainFileOf(src);
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == file);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, own, plugin, SymbolIndex.build(files, plugin));
		return CheckFixture.applyEdits(src, edits);
	}

}
