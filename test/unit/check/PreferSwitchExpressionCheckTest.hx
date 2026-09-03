package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferSwitchExpression;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-switch-expression` check: a VALUE-position ternary / if-expression
 * chain testing one or more expressions against constants is flagged `Info` and
 * rewritten to a switch expression by `--fix`.
 *
 * The negative cases pin one gate each — a non-whitelisted host, a missing trailing
 * else, a `!=` / `||` / extra-conjunct rung, a non-uniform discriminant tuple, a
 * discriminant carrying a call / construction / write (gate 5's
 * `CheckScan.mutationKinds` set), and each way a qualified static constant fails to be
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
		+ "\tpublic static inline final KIND_RECTANGLE_STROKE:String = 'rk';\n\tpublic static inline final KIND_OVAL_SOLID:String = "
		+ "'os';\n\tpublic static inline final KIND_OVAL_STROKE:String = 'ok';\n\tpublic static inline final KIND_TEXT_NODE_BUBBLE:String "
		+ "= 'tb';\n\tpublic static inline final KIND_TEXT_NODE_BUBBLE_STROKE:String = 'tk';\n"
		+ '\tpublic static inline final KIND_TEXT_NODE_BUBBLE_FILL_SHADE:String = \'tf\';\n}';

	/**
	 * The live bare-constant shape, reduced from `anyparse`'s own `BoolLoopScan.literalValue`:
	 * two `static inline final` constants declared in the SAME class and reached with no
	 * receiver.
	 */
	private static final BARE_CONSTANT_CHAIN: String = 'class C {\n\tstatic inline final TRUE_LITERAL:String = \'true\';\n'
		+ "\tstatic inline final FALSE_LITERAL:String = 'false';\n\tstatic function pick(text:String):Null<Bool> {\n"
		+ '\t\treturn if (text == TRUE_LITERAL)\n\t\t\ttrue\n\t\telse if (text == FALSE_LITERAL)\n\t\t\tfalse\n'
		+ '\t\telse\n\t\t\tnull;\n\t}\n}';

	/**
	 * The cross-file fixture, anonymized from a real ternary chain: two discriminants,
	 * four rungs of `static inline final` string constants declared in another module,
	 * and a trailing else value.
	 */
	private static final TUPLE_CHAIN: String = 'class BoardView {\n\tprivate static function resolveShadeProp(\n'
		+ '\t\tobj:BoardObject<RecordData>, targetType:String, readCurrent:Bool, newShade:Int = 0\n\t):MoveProperty {\n'
		+ '\t\treturn obj.boardNodeRecord.kind == NodeMeta.KIND_RECTANGLE_SOLID && targetType == NodeMeta.KIND_RECTANGLE_STROKE\n'
		+ '\t\t\t? EdgeShade(readCurrent ? cast(obj, RectangleNode).edgeShade : newShade)\n\t\t\t: obj.boardNodeRecord.kind == '
		+ 'NodeMeta.KIND_OVAL_SOLID && targetType == NodeMeta.KIND_OVAL_STROKE\n\t\t\t\t? EdgeShade(readCurrent ? cast(obj, '
		+ 'OvalNode).edgeShade : newShade)\n\t\t\t\t: obj.boardNodeRecord.kind == NodeMeta.KIND_TEXT_NODE_BUBBLE && targetType == '
		+ 'NodeMeta.KIND_TEXT_NODE_BUBBLE_STROKE\n\t\t\t\t\t? EdgeShade(readCurrent ? cast(obj, TextNodeBubble).edgeShade : newShade)\n'
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

	/**
	 * Gate 5's write half, in value position: the chain evaluates `arr[i++]` per rung and the
	 * switch subject once. The shipped binary converted this one, and the before / after pair
	 * printed `two` and `other` for `arr = [9, 2]`.
	 */
	public function testIncrementDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return arr[i++] == 1 ? p : arr[i++] == 2 ? q : r;')).length);
	}

	/** The assignment half of the same gate. */
	public function testAssignmentDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return arr[i = i + 1] == 1 ? p : arr[i = i + 1] == 2 ? q : r;')).length);
	}

	/** The construction half — one constructor call after the rewrite, one per rung before it. */
	public function testNewDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return new B().v == 1 ? p : new B().v == 2 ? q : r;')).length);
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

	/**
	 * The BARE spelling of a same-class `static inline final` constant — the live shape
	 * (`anyparse`'s own `BoolLoopScan.literalValue`, `text == TRUE_LITERAL`). Identical to
	 * `testStaticInlineFinalConstantFlagged` except that the constant is reached without a
	 * receiver, so this fixture pins ONLY the bare-identifier arm.
	 */
	public function testBareStaticInlineConstantFlagged(): Void {
		final vs: Array<Violation> = violations(BARE_CONSTANT_CHAIN);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-switch-expression', vs[0].rule);
	}

	/** The bare-constant chain converts, the patterns written exactly as the source spelled them. */
	public function testBareStaticInlineConstantFixed(): Void {
		final fixed: String = fixedSource(BARE_CONSTANT_CHAIN);
		Assert.isTrue(fixed.indexOf('switch (text) {') >= 0);
		Assert.isTrue(fixed.indexOf('case TRUE_LITERAL: true;') >= 0);
		Assert.isTrue(fixed.indexOf('case FALSE_LITERAL: false;') >= 0);
		Assert.isTrue(fixed.indexOf('case _: null;') >= 0);
	}

	/**
	 * THE refusal this widening exists for. A bare identifier bound to a LOCAL is the one
	 * operand class the compiler does not protect: `case target:` is a CAPTURE, so the
	 * emitted switch matches EVERYTHING and the chain's second and third arms become dead
	 * code. Measured on 4.3.7 — `pick('a', 'a')` and `pick('zzz', 'a')` both returned 1,
	 * with only a `WUnusedPattern` warning on the now-unreachable `case _`.
	 */
	public function testBareLocalOperandNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap("final target = 'a';\n\t\tfinal other = 'b';\n\t\tfinal v = text == target ? 1 : text == other ? 2 : 0;"))
				.length
		);
	}

	/** A PARAMETER is a local by another name, and captures in a pattern exactly the same way. */
	public function testBareParameterOperandNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f(text:String, target:String, other:String):Int {\n'
				+ '\t\treturn text == target ? 1 : text == other ? 2 : 0;\n\t}\n}'
			).length
		);
	}

	/**
	 * A MUTABLE instance field bare-referenced. The compiler rejects it outright — `Only
	 * inline or read-only (default, never) fields can be used as a pattern` — so this is a
	 * refusal the language would have caught; it is pinned because the gate must not lean on
	 * the compiler to catch it, `--fix` writing the file before anyone typechecks it.
	 */
	public function testBareMutableInstanceFieldNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tvar alpha:String = 'a';\n\tvar beta:String = 'b';\n"
				+ '\tfunction f(text:String):Int {\n\t\treturn text == alpha ? 1 : text == beta ? 2 : 0;\n\t}\n}'
			).length
		);
	}

	/**
	 * A non-inline `static final` reached BARE is refused for the same reason its qualified
	 * twin is (`testStaticFinalConstantNotFlagged`): the index cannot see the initializer, and
	 * a non-scalar one is `Incompatible pattern` at the case site. The two spellings share one
	 * proof, so they cannot disagree.
	 */
	public function testBareStaticFinalNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tstatic final ALPHA:String = 'a';\n\tstatic final BETA:String = 'b';\n"
				+ '\tstatic function f(text:String):Int {\n\t\treturn text == ALPHA ? 1 : text == BETA ? 2 : 0;\n\t}\n}'
			).length
		);
	}

	/**
	 * A local SHADOWING a same-class constant of the same name — the ONE refusal a name-keyed
	 * gate gets wrong, and the reason the proof asks the resolver. Measured on 4.3.7: a pattern
	 * identifier does not see locals at all, so `case alpha:` next to `final alpha = 'x';`
	 * resolves to NOTHING and becomes a capture — `f('x')`, `f('y')`, `f('zzz')` and `f('a')`
	 * ALL returned 1, with two `WUnusedPattern` warnings the only complaint. The names are
	 * lower-case deliberately: an UPPER-case one fails loudly instead (`Unknown identifier :
	 * ALPHA, pattern variables must be lower-case`), so the lower-case spelling is the silent
	 * half of the same bug. Substituting a name-keyed lookup for the binding proof makes this
	 * fixture — and only this fixture — report.
	 */
	public function testBareConstantShadowedByLocalNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tstatic inline final alpha:String = 'a';\n\tstatic inline final beta:String = 'b';\n"
				+ "\tstatic function f(text:String):Int {\n\t\tfinal alpha = 'x';\n\t\tfinal beta = 'y';\n"
				+ '\t\treturn text == alpha ? 1 : text == beta ? 2 : 0;\n\t}\n}'
			).length
		);
	}

	/**
	 * An enum-abstract VALUE reached bare from inside the abstract's own body — a compile-time
	 * constant carrying no `static` modifier, the same arm the qualified `T.M` proof accepts.
	 */
	public function testBareEnumAbstractValueFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'enum abstract Mode(String) {\n\tfinal ALPHA = \'a\';\n\tfinal BETA = \'b\';\n'
				+ '\tpublic function rank():Int {\n\t\treturn this == ALPHA ? 1 : this == BETA ? 2 : 0;\n\t}\n}'
			).length
		);
	}

	/**
	 * A bare identifier the file's own scopes do not bind — an import-static / inherited /
	 * cross-file constant. `Refs` is per-file and resolves nothing here, and an unresolved
	 * reference is refused rather than guessed: a miss costs a finding, a wrong yes costs a
	 * silently-capturing switch.
	 */
	public function testBareUnresolvedIdentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final v = text == ALPHA ? 1 : text == BETA ? 2 : 0;'), CONSTANTS).length);
	}

	/**
	 * A DOTTED receiver (`pkg.Mod.CONST`) stays refused. Such a path IS a legal pattern in
	 * Haxe, but the index resolves a member against a TYPE name and a dotted path is not one —
	 * accepting it would mean matching the whole module path, which is a separate piece of
	 * work. Refused, and pinned so the refusal is a decision rather than an accident.
	 */
	public function testDottedReceiverConstantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('return k == pkg.NodeMeta.ALPHA ? p : k == pkg.NodeMeta.BETA ? q : r;'), CONSTANTS).length);
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
