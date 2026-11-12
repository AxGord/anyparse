package unit.grammar.haxe;

import testkit.MutationArms;
import utest.Assert;
import utest.Test;

/**
 * The cut of each `M-DEFAULT-*-IGNORE` arm must change what its pin's source-broken list renders as: an arm whose
 * replacement default lays the list out exactly as `Ignore` does can never be killed.
 */
@:nullSafety(Strict)
final class HxListLayoutDefaultArmCutTest extends Test {

	public function new(): Void {
		super();
	}

	/** The object-literal default cut keeps a short source-broken literal open. */
	@:pin('control')
	@:killer('M-DEFAULT-OBJECT-IGNORE')
	public function testTheObjectLiteralCutChangesWhatItsPinRenders(): Void {
		assertCutChangesOutput(
			'M-DEFAULT-OBJECT-IGNORE', 'defaultMode: WrapMode.OnePerLine', 'OnePerLine', 'objectLiteral',
			'class C {\n\tstatic var o = {\n\t\ta: 1,\n\t\tb: 2\n\t};\n}'
		);
	}

	/** The array default cut keeps a short source-broken array open. */
	@:pin('control')
	@:killer('M-DEFAULT-ARRAY-IGNORE')
	public function testTheArrayLiteralCutChangesWhatItsPinRenders(): Void {
		assertCutChangesOutput(
			'M-DEFAULT-ARRAY-IGNORE', 'defaultMode: WrapMode.OnePerLine', 'OnePerLine', 'arrayWrap',
			'class C {\n\tstatic var a = [\n\t\t1,\n\t\t2\n\t];\n}'
		);
	}

	/** The anonymous-type default cut keeps a short source-broken anon type open. */
	@:pin('control')
	@:killer('M-DEFAULT-ANON-IGNORE')
	public function testTheAnonTypeCutChangesWhatItsPinRenders(): Void {
		assertCutChangesOutput(
			'M-DEFAULT-ANON-IGNORE', 'defaultMode: WrapMode.OnePerLine', 'OnePerLine', 'anonType',
			'class C {\n\tstatic var t:{\n\t\ta:Int,\n\t\tb:Int\n\t};\n}'
		);
	}

	private static function assertCutChangesOutput(arm: String, cut: String, mode: String, section: String, src: String): Void {
		#if (sys || nodejs)
		final record: Null<MutationArm> = MutationArms.find(MutationArms.parseDirectory('test/testkit/arms').arms, arm);
		final replace: Null<Array<String>> = record?.replace;
		Assert.notNull(replace, '$arm is a declared fragment arm');
		if (replace == null) return;
		Assert.equals(cut, replace[0], '$arm declares the cut this fixture renders; a re-aim updates both');
		final cutConfig: String = '{"wrapping": {"$section": {"defaultWrap": "$mode"}}}';
		Assert.notEquals(
			HxWriteFixture.triviaWrite(src, '{}'), HxWriteFixture.triviaWrite(src, cutConfig), '$arm: `$mode` renders as `Ignore` does'
		);
		#else
		Assert.pass('the arm table needs a filesystem');
		#end
	}

}
