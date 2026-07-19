package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnnecessaryNullCheck;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * The `unnecessary-null-check` check: a comparison against `null` whose operand
 * is provably non-null — a value type (`Int` / `Float` / `Bool` / `UInt`) or a
 * non-`Null<…>` nominal type while the enclosing type is `@:nullSafety`. An
 * optional parameter, a `Null<…>` / `Dynamic` operand, a non-null-safe class, or
 * a non-identifier operand keep the conservative default and are not flagged.
 */
class UnnecessaryNullCheckCheckTest extends Test {

	public function testValueTypeParamFlagged(): Void {
		// `Int` is non-null on static targets regardless of null-safety.
		Assert.equals(1, violations('class C { function f(x:Int) { if (x != null) trace(x); } }').length);
	}

	public function testValueTypeLocalFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { final i:Int = 0; if (i != null) trace(i); } }').length);
	}

	public function testEitherOperandOrder(): Void {
		Assert.equals(1, violations('class C { function f(x:Int) { if (null == x) trace(x); } }').length);
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
		// `x:Int = 0` is a required (non-null) parameter — the null check is redundant.
		Assert.equals(1, violations('class C { function f(x:Int = 0) { if (x != null) trace(x); } }').length);
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
				'@:nullSafety(Strict) class C { function f() { var v = make(); if (v != null) trace(v); } function make():Null<String> return null; }'
			).length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(x:Int) { if (x != null) trace(x); } }');
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
