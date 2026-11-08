package unit.query;

import anyparse.query.ImportBindings;

/**
 * A wildcard import `p.*` names `p` (a package or a type); a path that is no wildcard is unchanged.
 */
class ImportBindingsWildcardBaseTest extends Test {

	@:pin('guard')
	public function testWildcardNamesItsPrefix(): Void {
		Assert.equals('a.b', ImportBindings.wildcardBase('a.b.*'));
		Assert.equals('a.B', ImportBindings.wildcardBase('a.B.*'));
	}

	@:pin('guard')
	public function testPlainPathIsUnchanged(): Void {
		Assert.equals('a.b.C', ImportBindings.wildcardBase('a.b.C'));
		Assert.isFalse(ImportBindings.isWildcard('a.b.C'));
	}

}
