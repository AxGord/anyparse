package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferSwitch;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-switch` check: a STATEMENT-position `if` / `else if` chain testing one
 * or more expressions against constant values is flagged `Info` and rewritten to a
 * `switch` by `--fix`. A chain over different discriminants, a non-equality or `!=`
 * condition, a non-constant or interpolated operand, an extra conjunct that is not an
 * equality, a non-uniform discriminant tuple, a discriminant carrying a call / construction
 * / write (gate 5's `CheckScan.mutationKinds` set), or a lone `if`
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

	/** The trigger shape written INSIDE a `macro …` quotation, where the chain is AST the macro builds. */
	private static inline final QUOTED: String = 'class C {\n\tfunction f(x:Int):Void {\n\t\tfinal e = macro {\n\t\t\tif (x == 1) f();\n'
		+ '\t\t\telse if (x == 2) g();\n\t\t\telse if (x == 3) i();\n\t\t\telse h();\n\t\t};\n\t}\n}\n';

	/** The same shape quoted AND then written as real code — exactly one of the two is a finding. */
	private static inline final QUOTED_THEN_RUNTIME: String = 'class C {\n\tfunction f(x:Int):Void {\n\t\tfinal e = macro {\n'
		+ '\t\t\tif (x == 1) f();\n\t\t\telse if (x == 2) g();\n\t\t\telse if (x == 3) i();\n\t\t\telse h();\n\t\t};\n'
		+ '\t\tif (x == 1) f();\n\t\telse if (x == 2) g();\n\t\telse if (x == 3) i();\n\t\telse h();\n\t}\n}\n';


	/**
	 * An enum-abstract module: its values are exhaustiveness-checked by the compiler, and
	 * two fixtures below need the SAME module to differ only in the trailing `else`.
	 */
	private static final ENUM_ABSTRACT: String = 'enum abstract NodeMeta(Int) {\n\tfinal ALPHA = 0;\n\tvar BETA = 1;\n\tvar GAMMA = 2;\n}';

	/** Two values sharing one underlying value, beside a distinct one — gate 9's fixture. */
	private static final MODES: String = 'enum abstract Mode(Int) {\n\tfinal DEFAULT = 0;\n\tfinal AUTO = 0;\n\tfinal LINES = 1;\n}';

	/** An enum abstract overloading `==` — gate 10's fixture. */
	private static final OVERLOADING: String = 'enum abstract Mode(Int) from Int to Int {\n\tvar A = 1;\n\tvar B = 2;\n\n'
		+ '\t@:op(A == B) static function eq(a:Mode, b:Mode):Bool {\n\t\treturn true;\n\t}\n}';

	/** Rewriting a chain inside a REIFICATION subtree changes the `EIf` tree the macro emits into an `ESwitch`. */
	public function testMacroQuotationNotFlagged(): Void {
		Assert.equals(0, linted(QUOTED).length);
	}

	/** …and the skip is the quotation's SUBTREE, not everything that follows it. */
	public function testChainAfterMacroQuotationStillFlagged(): Void {
		CheckFixture.assertOnlyAfterQuotation(linted(QUOTED_THEN_RUNTIME), QUOTED_THEN_RUNTIME, 'chain');
	}

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

	/**
	 * Gate 5 covers every `CheckScan.mutationKinds` node, not just a call. A chain reads its
	 * discriminant per rung and the switch reads it ONCE, so an increment there is the same
	 * behaviour change a call is: `arr[i++]` over `[9, 2]` answers the SECOND rung as an
	 * `if` chain and the catch-all as a `switch`. On the shipped binary before the gate was
	 * widened it converted, and the two programs printed `two` and `other`.
	 */
	public function testIncrementDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (arr[i++] == 1) a(); else if (arr[i++] == 2) b(); else c();')).length);
	}

	/** The assignment half of the same gate — `arr[i = i + 1]` is read once by the switch. */
	public function testAssignmentDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (arr[i = i + 1] == 1) a(); else if (arr[i = i + 1] == 2) b(); else c();')).length);
	}

	/** The construction half — `new B()` runs a constructor per rung, once after the rewrite. */
	public function testNewDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (new B().v == 1) a(); else if (new B().v == 2) b(); else c();')).length);
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
	 * The `;` before an `else` is elided, so a then-branch arrives BARE (`return 1`, `throw 'b'`)
	 * and the `;` after the last branch belonged to the whole chain. Every `case` body must end
	 * terminated, or the switch does not compile (`Missing ;`).
	 */
	@:pin('control')
	@:killer('M-SWITCH-BARE-BODY-VERBATIM')
	public function testBareBranchBodiesGainATerminator(): Void {
		final fixed: String = fixedSource(wrap("if (x == 1) return 1 else if (x == 2) throw 'b' else trace(3);"));
		Assert.isTrue(fixed.indexOf('return 1;') >= 0, fixed);
		Assert.isTrue(fixed.indexOf("throw 'b';") >= 0, fixed);
		Assert.isTrue(fixed.indexOf('trace(3);') >= 0, fixed);
		Assert.equals(-1, fixed.indexOf(';;'), fixed);
	}

	/**
	 * The chain from a value-returning lambda block, `x -> { if (…) a else if (…) b else c; }`:
	 * every branch is a bare VALUE, and the switch stays the block's last expression, so each
	 * `case` yields its value with a `;` of its own.
	 */
	@:pin('control')
	@:killer('M-SWITCH-BARE-BODY-VERBATIM')
	public function testValueChainInALambdaBlockGainsTerminators(): Void {
		final fixed: String = fixedSource(
			wrap("final g = file -> {\n\t\t\tif (file == 'A') one else if (file == 'B') two else null;\n\t\t};")
		);
		Assert.isTrue(fixed.indexOf("case 'A': one;") >= 0, fixed);
		Assert.isTrue(fixed.indexOf("case 'B': two;") >= 0, fixed);
		Assert.isTrue(fixed.indexOf('case _: null;') >= 0, fixed);
	}

	/** A body that already ends in its own `;` or in a closing `}` is taken verbatim — never `;;`, never `};`. */
	@:pin('control')
	@:killer('M-SWITCH-TERMINATED-BODY-DOUBLED')
	public function testTerminatedBranchBodiesAreNotDoubled(): Void {
		final fixed: String = fixedSource(wrap('if (x == 1) { a(); } else if (x == 2) b(); else c();'));
		Assert.isTrue(fixed.indexOf('switch (x)') >= 0, fixed);
		Assert.equals(-1, fixed.indexOf(';;'), fixed);
		Assert.equals(-1, fixed.indexOf('};'), fixed);
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

	/**
	 * The bare-identifier constant arm reaches the STATEMENT rule too, and not by a second
	 * implementation: `prefer-switch` and `prefer-switch-expression` share ONE scanner
	 * (`SwitchChain`), so gate 6 is a single body of code and the two rules cannot drift apart
	 * on what counts as a `case` pattern. This is that shared gate seen from the statement side.
	 */
	public function testBareStaticInlineConstantChainFlagged(): Void {
		final src: String = "class C {\n\tstatic inline final alpha:String = 'a';\n\tstatic inline final beta:String = 'b';\n"
			+ '\tstatic function f(text:String):Void {\n\t\tif (text == alpha) p(); else if (text == beta) q(); else r();\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-switch', vs[0].rule);
		Assert.isTrue(fixedSource(src).indexOf('case alpha: p();') >= 0);
	}

	/**
	 * …and so does the refusal. A local operand is a CAPTURE in a pattern, which would make the
	 * first arm swallow every value; the statement rule inherits the binding proof unchanged.
	 */
	public function testBareLocalOperandChainNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tstatic function f(text:String):Void {\n\t\tfinal target = 'a';\n\t\tfinal other = 'b';\n"
				+ '\t\tif (text == target) p(); else if (text == other) q(); else r();\n\t}\n}'
			).length
		);
	}

	/**
	 * Gate 9: two enum-abstract values written with different NAMES can be one value
	 * (`DEFAULT = 0; AUTO = 0`). The chain is dead past its first match and so would the switch
	 * be, but the switch carries a `case` the compiler reports unused. The distinct twin over the
	 * SAME module converts, so the refusal cannot pass on a dead enum-abstract arm.
	 */
	@:pin('control')
	@:killer('M-SWITCH-VALUES-NOT-DISTINCT')
	public function testEnumAbstractDuplicateValueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (k == Mode.DEFAULT) p(); else if (k == Mode.AUTO) q(); else r();'), MODES).length);
		Assert.equals(1, violations(wrap('if (k == Mode.DEFAULT) p(); else if (k == Mode.LINES) q(); else r();'), MODES).length);
	}

	/**
	 * The duplicate is decided by VALUE across spellings: a hexadecimal and a decimal literal, and
	 * a literal against the enum-abstract value it equals (`LINES = 1`).
	 */
	@:pin('control')
	@:killer('M-SWITCH-VALUES-NOT-DISTINCT')
	public function testDuplicateValueAcrossSpellingsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x == 16) a(); else if (x == 0x10) b(); else c();')).length);
		Assert.equals(0, violations(wrap('if (k == Mode.LINES) p(); else if (k == 1) q(); else r();'), MODES).length);
	}

	/**
	 * A constant whose value cannot be PROVED refuses the chain — here a `static inline` field
	 * initialized from another one. A rung against a known literal sits beside it, so the two
	 * value keys can only collide if the unknown one is wrongly given one.
	 */
	@:pin('control')
	@:killer('M-SWITCH-UNKNOWN-VALUE-ACCEPTED')
	public function testUnknownConstantValueNotFlagged(): Void {
		final consts: String =
			'class NodeMeta {\n\tpublic static inline final ALPHA:Int = 1;\n\tpublic static inline final BETA:Int = ALPHA;\n}';
		Assert.equals(0, violations(wrap('if (k == NodeMeta.BETA) p(); else if (k == 5) q(); else r();'), consts).length);
	}

	/**
	 * An enum-abstract value written WITHOUT an initializer has the value the language fills in:
	 * the previous value plus one over `Int` (`var I0; var I1 = 5; var I2;` counts 0, 5, 6),
	 * its own name over `String`. `I0` / `I2` are distinct and convert; `I2` against `6` is the
	 * same value and is refused, which pins the count to the previous value rather than to the
	 * member's position.
	 */
	@:pin('control')
	@:killer('M-CASEVALUE-IMPLICIT-NOT-COUNTED')
	@:killer('M-CASEVALUE-NAMING-UNKNOWN')
	public function testImplicitEnumAbstractValues(): Void {
		final counted: String = 'enum abstract Mode(Int) {\n\tvar I0;\n\tvar I1 = 5;\n\tvar I2;\n}';
		final named: String = "enum abstract Mode(String) {\n\tvar X;\n\tvar Y;\n\tvar Z = 'X';\n}";
		Assert.equals(1, violations(wrap('if (k == Mode.I0) p(); else if (k == Mode.I2) q(); else r();'), counted).length);
		Assert.equals(0, violations(wrap('if (k == Mode.I2) p(); else if (k == 6) q(); else r();'), counted).length);
		Assert.equals(1, violations(wrap('if (k == Mode.X) p(); else if (k == Mode.Y) q(); else r();'), named).length);
		Assert.equals(0, violations(wrap('if (k == Mode.X) p(); else if (k == Mode.Z) q(); else r();'), named).length);
	}

	/**
	 * Gate 10's PATTERN half: a switch compares by the built-in equality, so an abstract
	 * overloading `==` is bypassed — `m = Op.B` takes the `A` rung as a chain and the `B` case
	 * as a switch (`--interp` and `-js`). The discriminant is an `Int` parameter, so only the
	 * pattern's own declaration can refuse it.
	 */
	@:pin('control')
	@:killer('M-SWITCH-PATTERN-EQ-OVERLOAD-IGNORED')
	public function testOverloadedEqualityPatternNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapWithParams('k:Int', 'if (k == Mode.A) p(); else if (k == Mode.B) q(); else r();'), OVERLOADING).length
		);
	}

	/**
	 * Gate 10's DISCRIMINANT half: literal patterns, a discriminant DECLARED as the overloading
	 * abstract — only its type can refuse the chain.
	 */
	@:pin('control')
	@:killer('M-SWITCH-DISC-EQ-OVERLOAD-IGNORED')
	public function testOverloadedEqualityDiscriminantNotFlagged(): Void {
		Assert.equals(0, violations(wrapWithParams('k:Mode', 'if (k == 1) p(); else if (k == 2) q(); else r();'), OVERLOADING).length);
	}

	/**
	 * An `==` overload ELSEWHERE in scope is not a reason to refuse: the pattern half is proved
	 * from the constant's own declaration, so an enum-abstract value of a type overloading
	 * nothing still converts beside an unrelated overloading type — the shape every scope holding
	 * the std `UInt` (which declares `@:op(A == B)`) is in.
	 */
	public function testUnrelatedOverloadDoesNotRefuse(): Void {
		final both: String = '$OVERLOADING\n\nenum abstract Plain(Int) {\n\tvar P = 1;\n\tvar Q = 2;\n}';
		Assert.equals(
			1, violations(wrapWithParams('k:Plain', 'if (k == Plain.P) p(); else if (k == Plain.Q) q(); else r();'), both).length
		);
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

	/**
	 * The same findings THROUGH THE LINTER — the altitude the central reification gate lives at
	 * (`Linter.run`), so a quoted finding is dropped here and not by the check itself.
	 */
	private function linted(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new PreferSwitch()]);
	}

	private function fixedSource(src: String, ?constants: String): String {
		final check: PreferSwitch = new PreferSwitch();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = entries(src, constants);
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'C.hx');
		final edits: Array<{ span: Span, text: String }> = check.fix(src, own, plugin, SymbolIndex.build(files, plugin));
		return CheckFixture.applyEdits(src, edits);
	}

}
