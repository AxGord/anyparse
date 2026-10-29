package unit.check;

/**
 * Where a builtin rule lives says what it is about: its package is `anyparse.check.<axis>.<category>`, the last segment
 * its own `category()` and the axis the one segment between (`common` for a rule every grammar answers). `category()`
 * stays the declaration; this holds the tree to it, so a rule filed under another subject fails here.
 */
class RuleCategoryPackageTest extends Test {

	@:pin('guard')
	public function testEveryBuiltinLivesInItsCategoryPackage(): Void {
		final misplaced: Array<String> = [];
		for (check in Linter.builtins()) {
			final path: Array<String> = Type.getClassName(Type.getClass(check)).split('.');
			final category: String = check.category();
			if (path.length != 5 || path[0] != 'anyparse' || path[1] != 'check' || path[3] != category)
				misplaced.push('${path.join('.')} ($category)');
		}
		Assert.same([], misplaced);
	}

}
