package unit.check.common.unused;

import anyparse.check.Check;
import anyparse.check.Linter;

/**
 * A finding `unused-public-member` reports must either be deleted by `--fix` or carry the reason
 * it was not: an array-literal static field was reported and then skipped without a line.
 */
@:nullSafety(Strict)
class UnusedPublicMemberSilentSkipTest extends Test {

	private static final SHAPE: String = 'class C {\n\t// Last section\n\tpublic static inline final A:Int = 1;\n\n\t/** Players */\n'
		+ '\tpublic static final TONES:Array<UInt> = [0xff9966, 0xfadebe];\n\n\t// @formatter:off\n'
		+ '\tpublic static final PALETTE:Array<Int> = [0x000000, 0x333333];\n\tpublic static function main():Void trace(A);\n}';

	/** A pure array-literal initializer is deletable: the field leaves with its doc. */
	@:pin('control')
	@:killer('M-UPM-SITE-PURITY-ARRAY')
	public function testArrayLiteralFieldDeletedWithItsDoc(): Void {
		final fixed: String = fixed(SHAPE);
		Assert.isFalse(fixed.indexOf('TONES') >= 0);
		Assert.isFalse(fixed.indexOf('Players') >= 0);
		Assert.isTrue(fixed.indexOf('Last section') >= 0);
	}

	/** A member under `@formatter:off` is left alone and says why. */
	@:pin('control')
	@:killer('M-UPM-SITE-FENCE')
	public function testFormatterOffMemberKeptAndNamed(): Void {
		Assert.isTrue(fixed(SHAPE).indexOf('PALETTE') >= 0);
		final kept: Array<Violation> = violations(SHAPE).filter(v -> v.message.indexOf('PALETTE') >= 0);
		Assert.equals(1, kept.length);
		Assert.notNull(kept[0].declineReason);
	}

	/** An initializer that may do something at class load keeps the field, and the finding says so. */
	@:pin('control')
	@:killer('M-UPM-FIELD-INITIALIZER-PURITY')
	public function testEffectfulInitializerKeptAndNamed(): Void {
		final src: String = 'class C {\n\tpublic static var zqxwvN:Array<Int> = [Std.random(3)];\n}';
		Assert.equals(src, fixed(src));
		assertAllNamed(violations(src), 1);
	}

	/** The sole member of a `#if` region is kept, and the finding names the region as the reason. */
	@:pin('control')
	@:killer('M-UPM-REGION-DECLINE')
	public function testEmptiedRegionKeptAndNamed(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tpublic static final zqxwvGone:Array<Int> = [1];\n\t#end\n}';
		Assert.equals(src, fixed(src));
		assertAllNamed(violations(src), 1);
	}

	/** A name an interpolated string may spell at runtime keeps the member, and the finding says so. */
	@:pin('control')
	@:killer('M-UPM-FRAGMENT-DECLINE')
	public function testRuntimeNameFragmentKeptAndNamed(): Void {
		final owner: String = 'class C {\n\tpublic static final orphaned:Array<Int> = [1];\n}';
		final user: String =
			'class U {\n\tpublic static function main(c:C, suffix:String):Dynamic return Reflect.field(c, \'orphan$$suffix\');\n}';
		assertAllNamed(violationsOf([{ file: 'C.hx', source: owner }, { file: 'U.hx', source: user }]), 1);
	}

	/** Every finding the fix keeps carries a reason: none is reported and then skipped without a line. */
	private function assertAllNamed(found: Array<Violation>, count: Int): Void {
		Assert.equals(count, found.length);
		for (violation in found) Assert.notNull(violation.declineReason);
	}

	private function violations(src: String): Array<Violation> {
		return violationsOf([{ file: 'C.hx', source: src }]);
	}

	private function violationsOf(files: Array<{ file: String, source: String }>): Array<Violation> {
		final check: Null<Check> = Linter.byId('unused-public-member');
		return check == null ? [] : CheckFixture.violationsIn(check, files);
	}

	private function fixed(src: String): String {
		final check: Null<Check> = Linter.byId('unused-public-member');
		return check == null ? src : CheckFixture.fixedSource(check, src);
	}

}
