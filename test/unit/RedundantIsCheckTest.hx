package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantIsCheck;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * The `redundant-is-check` check: an `is` type-check `x is T` that is provably ALWAYS
 * TRUE — `x` is a plain identifier of declared type `T` AND provably non-null. Only the
 * always-true direction is detected (always-false needs a class hierarchy anyparse does
 * not model). A nullable operand (no `@:nullSafety`, `Null<…>`, optional param), a
 * different checked type, or a non-identifier operand keep the conservative default.
 */
class RedundantIsCheckTest extends Test {

	public function testValueTypeSameTypeFlagged(): Void {
		// `Int` is non-null on static targets regardless of null-safety; `i is Int` is constant.
		Assert.equals(1, violations('class C { function f(i:Int) { var b = i is Int; } }').length);
	}

	public function testNullSafeNominalSameTypeFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict) class C { function f(s:String) { var b = s is String; } }').length);
	}

	public function testNonNullSafeNominalNotFlagged(): Void {
		// No null-safety: `s` may be null, and `null is String` is false — not constant.
		Assert.equals(0, violations('class C { function f(s:String) { var b = s is String; } }').length);
	}

	public function testDifferentTypeNotFlagged(): Void {
		// `i:Int is String` — different types; always-false is intentionally not detected.
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(i:Int) { var b = i is String; } }').length);
	}

	public function testNullableWrapperNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(n:Null<String>) { var b = n is String; } }').length);
	}

	public function testOptionalParamNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(?s:String) { var b = s is String; } }').length);
	}

	public function testNonIdentifierOperandNotFlagged(): Void {
		Assert.equals(
			0,
			violations('@:nullSafety(Strict) class C { function f() { var b = make() is String; } function make():String return ""; }').length
		);
	}

	public function testQualifiedTypeReconciledFlagged(): Void {
		// `e:Eof` vs checked `haxe.io.Eof` reconcile via importMap → same FQN → flagged.
		Assert.equals(
			1, violations('import haxe.io.Eof;\n@:nullSafety(Strict) class C { function f(e:Eof) { var b = e is haxe.io.Eof; } }').length
		);
	}

	public function testQualifiedDifferentPackageNotFlagged(): Void {
		// `e:Eof` (haxe.io.Eof) vs `sys.io.Eof` — distinct FQNs, not flagged.
		Assert.equals(
			0, violations('import haxe.io.Eof;\n@:nullSafety(Strict) class C { function f(e:Eof) { var b = e is sys.io.Eof; } }').length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(i:Int) { var b = i is Int; } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-is-check', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixUnwrapBody(): Void {
		assertFixContains(wrap('if (x is Int) trace(x);'), 'trace(x)', 'if (x is Int)');
	}

	public function testFixDropConjunct(): Void {
		assertFixContains(wrap('if (x is Int && cond()) trace(x);'), 'if (cond())', 'x is Int');
	}

	public function testFixRefusesElse(): Void {
		assertFixRefused(wrap('if (x is Int) trace(x); else cond();'));
	}

	public function testFixRefusesTernary(): Void {
		assertFixRefused(wrap('final b:Int = x is Int ? 1 : 2;\n\t\ttrace(b);'));
	}

	public function testFixRefusesCommentInHeader(): Void {
		assertFixRefused(wrap('if (x is Int) /* keep */ trace(x);'));
	}

	public function testFixRefusesAssignmentPosition(): Void {
		// An `is`-check in a plain `var b = …` initializer has no condition/chain parent to
		// simplify — a conservative refusal, though the run still flags it.
		assertFixRefused(wrap('var b = x is Int;\n\t\ttrace(b);'));
	}

	public function testDefaultNullParamNotFlagged(): Void {
		// A `s: T = null` default-null parameter is nullable per Haxe null-safety ("an
		// argument with a default value of null is nullable"), so `s is T` is NOT always
		// true (`null is T` is false) and must not be flagged.
		Assert.equals(
			0, violations('@:nullSafety(Strict) class C { function f(s:String = null) { if (s is String) trace(s.length); } }').length
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new RedundantIsCheck().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var b = x is ' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-is-check'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-is-check'));
	}

	/** A module whose `f` takes a provably-non-null `x:Int`, wrapping `body`. */
	private function wrap(body: String): String {
		return
			'@:nullSafety(Strict)\nclass C {\n\tfunction cond():Bool\n\t\treturn true;\n\n\tfunction f(x:Int):Void {\n\t\t$body\n\t}\n}\n';
	}

	/** Run + fix + canonicalise (whole-file reformat) `src`, returning the emitted text. */
	private function fixText(src: String): String {
		final check: RedundantIsCheck = new RedundantIsCheck();
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
		final check: RedundantIsCheck = new RedundantIsCheck();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length > 0, 'expected a finding to exist');
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantIsCheck().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
