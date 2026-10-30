package unit.check.haxe.nullsafety;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Severity;
import anyparse.check.haxe.nullsafety.NullSafetyStrict;

/**
 * The `null-safety-strict` check: a class with no `@:nullSafety` entry, a loose or an `Off` one is flagged `Warning` and
 * made strict; a `@:nullSafety(Off)` below type level is reported only. Strict classes, externs and the other type kinds
 * are left alone. Default-off, and its fix is risky (kept only where the compiler oracle accepts it).
 */
class NullSafetyStrictCheckTest extends Test {

	public function testMissingEntryFlagged(): Void {
		final vs: Array<Violation> = violations('class A {}');
		Assert.equals(1, vs.length);
		Assert.equals('null-safety-strict', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('A declares no @:nullSafety(Strict)', vs[0].message);
	}

	/** One finding per entry: a class-level `Off` is the class's finding, not also a below-type one. */
	@:pin('control')
	@:killer('M-NSSTRICT-TYPE-OFF-TWICE')
	public function testLooseAndOffFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety class A {}').length);
		Assert.equals(1, violations('@:nullSafety(Loose) class A {}').length);
		Assert.equals(1, violations('@:nullSafety(Off) final class A {}').length);
	}

	public function testMemberOffFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict) class A {\n\t@:nullSafety(Off) function f():Void {}\n}').length);
	}

	public function testStrictExternAndOtherKindsNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class A {}').length);
		Assert.equals(0, violations('@:nullSafety(StrictThreaded) class A {}').length);
		Assert.equals(0, violations('extern class A {}').length);
		Assert.equals(0, violations('interface I {}\nenum E { X; }\ntypedef T = Int;\nabstract B(Int) {}').length);
	}

	/** The new entry lands below the doc and the other metadata, above the modifiers. */
	public function testFixAddsEntry(): Void {
		Assert.equals(
			'/** d */\n@:keep\n@:nullSafety(Strict)\nprivate final class A {}', applyFix('/** d */\n@:keep\nprivate final class A {}')
		);
	}

	public function testFixRewritesLooseEntry(): Void {
		Assert.equals('@:nullSafety(Strict) class A {}', applyFix('@:nullSafety(Off) class A {}'));
		Assert.equals('@:nullSafety(Strict) class A {}', applyFix('@:nullSafety class A {}'));
	}

	public function testMemberOffGetsNoEdit(): Void {
		final src: String = '@:nullSafety(Strict) class A {\n\t@:nullSafety(Off) function f():Void {}\n}';
		Assert.equals(0, CheckFixture.edits(new NullSafetyStrict(), src).length);
	}

	public function testDefaultOffAndRisky(): Void {
		final check: NullSafetyStrict = new NullSafetyStrict();
		Assert.isTrue(Std.isOfType(check, DefaultOff));
		Assert.isTrue(Std.isOfType(check, RiskyFix));
		Assert.notNull(Linter.byId('null-safety-strict'));
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new NullSafetyStrict(), src);
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new NullSafetyStrict(), src);
	}

}
