package unit.check.haxe.loops;

import anyparse.check.haxe.loops.IdentityMap;

/** `identity-map` over an element type no indexed declaration names: an abstract from an unindexed library is unresolved, so no finding. */
class IdentityMapUnindexedElementTest extends Test {

	@:pin('control')
	@:killer('M-IM-UNRESOLVED-ELEMENT')
	public function testUnindexedElementNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final ys = us.map(u -> u);')).length);
		Assert.equals(0, violations(wrap('final ys = us.map(u -> (u : Null<U>));')).length);
		Assert.equals(0, violations(wrap('final ys = [for (u in us) u];')).length);
	}

	@:pin('control')
	@:killer('M-IM-BUILTIN-REFERENCE')
	public function testStringAndIndexedClassElementStillFlagged(): Void {
		Assert.equals(1, violations(wrap('final ys = strs.map(s -> s);')).length);
		Assert.equals(1, violations(wrap('final ys = ps.map(p -> p);')).length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new IdentityMap(), src);
	}

	private static function wrap(statement: String): String {
		return 'class P {}\n\nclass C {\n\tfunction run(us: Array<U>, strs: Array<String>, ps: Array<P>): Void {\n\t\t$statement\n\t}\n}';
	}

}
