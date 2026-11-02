package unit.format;

import anyparse.format.WhitespacePolicy;

/**
 * `WhitespacePolicy.add`: switching one side's space on keeps whatever the policy already
 * spaces, so a site that always spaces one side lets the configured policy decide the other.
 */
@:nullSafety(Strict)
final class WhitespacePolicyTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-WSP-ADD-NOOP')
	public function testAddBeforeKeepsTheAfterSide(): Void {
		Assert.equals(WhitespacePolicy.Before, WhitespacePolicy.None.add(WhitespacePolicy.Before));
		Assert.equals(WhitespacePolicy.Before, WhitespacePolicy.Before.add(WhitespacePolicy.Before));
		Assert.equals(WhitespacePolicy.Both, WhitespacePolicy.After.add(WhitespacePolicy.Before));
		Assert.equals(WhitespacePolicy.Both, WhitespacePolicy.Both.add(WhitespacePolicy.Before));
	}

	public function testAddAfterKeepsTheBeforeSide(): Void {
		Assert.equals(WhitespacePolicy.After, WhitespacePolicy.None.add(WhitespacePolicy.After));
		Assert.equals(WhitespacePolicy.Both, WhitespacePolicy.Before.add(WhitespacePolicy.After));
	}

	public function testAddNoneChangesNothing(): Void {
		for (p in [
			WhitespacePolicy.None,
			WhitespacePolicy.Before,
			WhitespacePolicy.After,
			WhitespacePolicy.Both
		]) Assert.equals(p, p.add(WhitespacePolicy.None));
	}

}
