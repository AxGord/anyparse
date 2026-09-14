package unit.runtime;

import anyparse.runtime.CommonPrefix;
import utest.Assert;
import utest.Test;

/** `CommonPrefix.of` — the longest shared prefix, character for character, and the empty string when the first characters differ. */
class CommonPrefixTest extends Test {

	public function testSharedLeadingRun(): Void {
		Assert.equals('\t\t', CommonPrefix.of('\t\t\tdeep', '\t\tshallow'));
		Assert.equals('ab', CommonPrefix.of('abc', 'abd'));
	}

	public function testOneIsAPrefixOfTheOther(): Void {
		Assert.equals('ab', CommonPrefix.of('ab', 'abc'));
		Assert.equals('ab', CommonPrefix.of('abc', 'ab'));
		Assert.equals('same', CommonPrefix.of('same', 'same'));
	}

	public function testNothingShared(): Void {
		Assert.equals('', CommonPrefix.of('x', 'y'));
		Assert.equals('', CommonPrefix.of('', 'anything'));
		Assert.equals('', CommonPrefix.of('anything', ''));
	}

}
