package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnnecessaryNullCheck;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import utest.Assert;
import utest.Test;

/**
 * The `unnecessary-null-check` check: a comparison against `null` whose operand
 * is provably non-null — a value type (`Int` / `Float` / `Bool` / `UInt`) or a
 * non-`Null<…>` nominal type while the enclosing type is `@:nullSafety`. An
 * optional parameter, a `Null<…>` / `Dynamic` operand, a non-null-safe class, or
 * a non-identifier operand keep the conservative default and are not flagged.
 */
class UnnecessaryNullCheckCheckTest extends Test {

	public function testValueTypeParamNotFlaggedWithoutNullSafety(): Void {
		// `Int` is non-null on STATIC targets only, and this comparison does not compile on one
		// ("On static platforms, null can't be used as basic type Int", 4.3.7) — so the file it
		// sits in is a dynamic-target file, where `Int` IS nullable and the guard is load-bearing.
		Assert.equals(0, violations('class C { function f(x:Int) { if (x != null) trace(x); } }').length);
	}

	public function testValueTypeParamFlaggedUnderNullSafety(): Void {
		// Null safety normalises a non-`Null<…>` type to non-nullable on EVERY target and rejects
		// a null flowing into it, so the same operand IS proven — by the compiler, not the target.
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(x:Int) { if (x != null) trace(x); } }').length);
	}

	public function testValueTypeLocalNotFlaggedWithoutNullSafety(): Void {
		Assert.equals(0, violations('class C { function f() { final i:Int = 0; if (i != null) trace(i); } }').length);
	}

	public function testValueTypeLocalFlaggedUnderNullSafety(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f() { final i:Int = 0; if (i != null) trace(i); } }').length);
	}

	public function testEitherOperandOrder(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(x:Int) { if (null == x) trace(x); } }').length);
	}

	public function testNullSafeNominalFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(s:String) { if (s != null) trace(s); } }').length);
	}

	public function testNonNullSafeNominalNotFlagged(): Void {
		// No null-safety meta: a class-typed `s` may be null at runtime.
		Assert.equals(0, violations('class C { function f(s:String) { if (s != null) trace(s); } }').length);
	}

	public function testNullSafetyOffNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Off) class C { function f(s:String) { if (s != null) trace(s); } }').length);
	}

	public function testNullableWrapperNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(n:Null<String>) { if (n != null) trace(n); } }').length);
	}

	public function testDynamicNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(d:Dynamic) { if (d != null) trace(d); } }').length);
	}

	public function testOptionalParamNotFlagged(): Void {
		// `?x:Int` is nullable despite the nominal `Int` annotation.
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(?x:Int) { if (x != null) trace(x); } }').length);
	}

	public function testDefaultedParamFlagged(): Void {
		// `x:Int = 0` is a required (non-null) parameter — the null check is redundant. A NON-null
		// default is not the `= null` exemption, and null safety carries the value type's proof.
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(x:Int = 0) { if (x != null) trace(x); } }').length);
	}

	public function testCallOperandNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f() { if (foo() != null) trace(1); } function foo():Null<String> return null; }').length
		);
	}

	public function testUnannotatedLocalNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'@:nullSafety(Strict) class C { function f() { var v = make(); if (v != null) trace(v); } '
				+ 'function make():Null<String> return null; }'
			).length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('@:nullSafety(Strict) class C { function f(x:Int) { if (x != null) trace(x); } }');
		Assert.equals(1, vs.length);
		Assert.equals('unnecessary-null-check', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixUnwrapBody(): Void {
		assertFixContains(wrap('if (x != null) trace(x);'), 'trace(x)', 'if (x != null)');
	}

	public function testFixDeleteAlwaysFalse(): Void {
		assertFixContains(wrap('if (x == null) trace(0);\n\t\ttrace("keep");'), 'trace("keep")', 'trace(0)');
	}

	public function testFixDropConjunct(): Void {
		assertFixContains(wrap('if (x != null && cond()) trace(x);'), 'if (cond())', 'x != null');
	}

	public function testFixRefusesElse(): Void {
		assertFixRefused(wrap('if (x != null) trace(x); else cond();'));
	}

	public function testFixRefusesTernary(): Void {
		assertFixRefused(wrap('final b:Int = x != null ? 1 : 2;\n\t\ttrace(b);'));
	}

	public function testFixRefusesCommentInDeletedBody(): Void {
		assertFixRefused(wrap('if (x == null) {\n\t\t\t// note\n\t\t\ttrace(0);\n\t\t}'));
	}

	public function testDefaultNullParamNotFlagged(): Void {
		// A `p: T = null` default-null parameter is nullable per Haxe null-safety ("an
		// argument with a default value of null is nullable") — the null check is
		// load-bearing and must NOT be flagged, even under strict null-safety and even
		// for a value-typed default (`x:Int = null` compiles with `x == null` reachable).
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(p:String = null) { if (p != null) trace(p); } }').length);
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(x:Int = null) { if (x != null) trace(x); } }').length);
	}

	/**
	 * The reported defect, verbatim: `pony`'s `create.section.Build` declares
	 * `public var esVersion: Int = null;` and guards its use with `if (esVersion != null)`.
	 * The rule read `Int` off `declaredTypes`, called the operand non-null, and `--fix`
	 * DELETED the guard — the emitted hxml then always carried `js-esnull`. The declaration's
	 * own `= null` is local, syntactic, target-independent proof that the binding is nullable
	 * and must outrank its written type.
	 */
	public function testNullInitialisedValueFieldNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { public var esVersion: Int = null; function f() { if (esVersion != null) trace(esVersion); } }').length
		);
	}

	/** The same declaration as a LOCAL, and as a `final` — one predicate covers every binder. */
	public function testNullInitialisedLocalNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var x: Int = null; if (x != null) trace(x); } }').length);
		Assert.equals(0, violations('class C { function f() { final x: Float = null; if (x != null) trace(x); } }').length);
	}

	/**
	 * The exemption sits BEFORE the null-safety arm, so it also covers a nominal type whose
	 * declaration contradicts it — `@:nullSafety` would otherwise prove `s` non-null.
	 */
	public function testNullInitialisedNominalNotFlaggedUnderNullSafety(): Void {
		Assert.equals(
			0, violations('@:nullSafety(Strict) class C { var s: String = null; function f() { if (s != null) trace(s); } }').length
		);
	}

	/**
	 * A multi-declarator list nests its continuation inside the first declarator's node, so an
	 * outermost-first walk would exempt BOTH names off the first one's `= null`. Only the name
	 * that owns the binding decides: `a` is exempt, `b` is still proven.
	 */
	public function testMultiDeclaratorExemptsOnlyTheNullOne(): Void {
		final vs: Array<Violation> = violations(
			'@:nullSafety(Strict) class C { function f() { var a: String = null, b: String = "x"; '
			+ 'if (a != null) trace(a); if (b != null) trace(b); } }'
		);
		Assert.equals(1, vs.length);
	}

	/** The null literal must be the initialiser ITSELF; buried in a call it proves nothing. */
	public function testNullDeepInInitialiserStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'@:nullSafety(Strict) class C { function f() { final x: Int = g(null); if (x != null) trace(x); } '
				+ 'function g(v: Null<Int>): Int return 0; }'
			).length
		);
	}

	/**
	 * `pony.pixi.ui.slices.SliceSprite`: a value-typed property with NO initialiser is `null`
	 * on a dynamic target until its setter runs, and the guard picks the image's natural size.
	 * The value-type arm called it non-null; the null-comparison variant declines.
	 */
	public function testUninitialisedValueFieldNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { public var sliceWidth: Float; function f() { if (sliceWidth != null) trace(sliceWidth); } }').length
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new UnnecessaryNullCheck().run([{ file: 'Bad.hx', source: 'class Bad { function f() { if (x != ' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unnecessary-null-check'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unnecessary-null-check'));
	}

	public function testReshadowedNullableParamGuardNotFlagged(): Void {
		// Exact TM `renameItem` shape: a nullable param whose guard has a SIDE EFFECT
		// before `return`, followed by a later same-name non-null capture
		// (`final p:String = p;`). The first-wins scope resolver binds the guard's `p`
		// to the LATER non-null shadow, so `isProvablyNonNull` wrongly affirms and the
		// load-bearing guard is deleted (dropping the side effect and leaving a
		// nullable-into-non-null assignment). The re-shadowed name must not be proven.
		Assert.equals(
			0,
			violations(
				'@:nullSafety(Strict) class C { function f(p:Null<String>) { if (p == null) { g(); return; } '
				+ 'final p:String = p; trace(p); } function g():Void {} }'
			).length
		);
	}

	/**
	 * The always-true unwrap used to splice the body block WHOLE, leaving a bare `{ … }` behind that only a
	 * later `unnecessary-block` pass could clear. With no collision the braces go too, so the body's local
	 * lands beside the statement that followed the `if`.
	 */
	public function testFixUnwrapBlockBodyDropsBraces(): Void {
		assertFixContains(
			wrap('if (x != null) {\n\t\t\tfinal t:Int = x;\n\t\t\ttrace(t);\n\t\t}\n\t\ttrace(9);'),
			'\t\tfinal t:Int = x;\n\t\ttrace(t);\n\t\ttrace(9);', '\t\t\tfinal t:Int = x;'
		);
	}

	/** A body local shadowing an enclosing one keeps its braces — the `if` still goes, the scope stays. */
	public function testFixKeepsBracesWhenBodyLocalCollides(): Void {
		assertFixContains(
			wrap('final t:Int = 1;\n\t\tif (x != null) {\n\t\t\tfinal t:Int = x;\n\t\t\ttrace(t);\n\t\t}\n\t\ttrace(t);'),
			'{\n\t\t\tfinal t:Int = x;', 'if (x != null)'
		);
	}

	/** Past `CheckScan.BARE_BLOCK_MAX_STATEMENTS` the body reads as a section — the `if` goes, the block stays. */
	public function testFixKeepsBracesOnOverWeightBody(): Void {
		final body: String = 'if (x != null) {\n\t\t\tfinal t:Int = x;\n\t\t\ttrace(1);\n\t\t\ttrace(2);\n\t\t\ttrace(3);\n'
			+ '\t\t\ttrace(4);\n\t\t\ttrace(t);\n\t\t}';
		assertFixContains(wrap(body), '{\n\t\t\tfinal t:Int = x;', 'if (x != null)');
	}

	/** A module whose `f` takes a provably-non-null `x:Int`, wrapping `body`. */
	private function wrap(body: String): String {
		return
			'@:nullSafety(Strict)\nclass C {\n\tfunction cond():Bool\n\t\treturn true;\n\n\tfunction f(x:Int):Void {\n\t\t$body\n\t}\n}\n';
	}

	/** Run + fix + canonicalise (whole-file reformat) `src`, returning the emitted text. */
	private function fixText(src: String): String {
		final check: UnnecessaryNullCheck = new UnnecessaryNullCheck();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
				src;
		};
	}

	/** The fixed text of `src` contains `present` and no longer contains `absent`. */
	private function assertFixContains(src: String, present: String, absent: String): Void {
		final out: String = fixText(src);
		Assert.isTrue(out.indexOf(present) >= 0, 'expected "$present" in: $out');
		Assert.isTrue(out.indexOf(absent) == -1, 'expected NOT "$absent" in: $out');
	}

	/** `src` is flagged by `run` but produces no fix edit — a conservative refusal. */
	private function assertFixRefused(src: String): Void {
		final check: UnnecessaryNullCheck = new UnnecessaryNullCheck();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length > 0, 'expected a finding to exist');
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	private function violations(src: String): Array<Violation> {
		return new UnnecessaryNullCheck().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
