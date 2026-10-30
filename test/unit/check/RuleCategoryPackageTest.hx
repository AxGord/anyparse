package unit.check;

import anyparse.check.Check.LanguageBound;

/**
 * Where a builtin rule lives says what it is about: its package is `anyparse.check.<axis>.<category>`, the last segment
 * its own `category()` and the axis the one segment between — `common` for a rule every grammar answers, the one
 * language a `LanguageBound` rule names otherwise. `category()` and `languages()` stay the declarations; this holds the
 * tree to them, so a rule filed under another subject or another grammar fails here.
 */
class RuleCategoryPackageTest extends Test {

	@:pin('guard')
	public function testEveryBuiltinLivesInItsCategoryPackage(): Void {
		final misplaced: Array<String> = [];
		for (check in Linter.builtins()) {
			final path: Array<String> = Type.getClassName(Type.getClass(check)).split('.');
			final category: String = check.category();
			final axis: String = check is LanguageBound ? (cast check: LanguageBound).languages().join('+') : 'common';
			if (path.length != 5 || path[0] != 'anyparse' || path[1] != 'check' || path[2] != axis || path[3] != category)
				misplaced.push('${path.join('.')} ($axis.$category)');
		}
		Assert.same([], misplaced);
	}

}
