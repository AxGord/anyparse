package unit.check;

/**
 * The registry order `Linter.builtins()` takes from the rules' own `@:lintAfter` / `@:lintBefore`: every pair a rule's fix
 * depends on runs in the declared order, whatever the class names would sort to.
 */
@:nullSafety(Strict)
class BuiltinOrderTest extends Test {

	/** Each earlier rule of a declared pair precedes the later one in the registry. */
	@:killer('M-RULE-ORDER-BEFORE-IGNORED')
	@:pin('control')
	public function testEveryDeclaredPairRunsInItsOrder(): Void {
		final ids: Array<String> = CheckFixture.builtinIds();
		for (pair in [
			['misplaced-type-doc', 'duplicate-import'],
			['unused-import', 'import-outside-guard'],
			['unused-import', 'import-order'],
			['simplify-boolean-return-chain', 'prefer-ternary-return'],
			['prefer-ternary-expression', 'join-branch-call'],
			['hoist-branch-string-affix', 'cond-assign-merge'],
			['prefer-lpad', 'prefer-comprehension'],
			['double-negation', 'simplify-negated-compound'],
			['unused-case-binder', 'unnecessary-switch'],
			['redundant-else-after-return', 'collapsible-else-if'],
			['redundant-else-after-return', 'hoist-common-branch-head'],
			['redundant-else-after-return', 'prefer-switch'],
			['prefer-ternary-return', 'guard-return']
		]) {
			final earlier: Int = ids.indexOf(pair[0]);
			final later: Int = ids.indexOf(pair[1]);
			Assert.isTrue(earlier >= 0 && later >= 0, 'both `${pair[0]}` and `${pair[1]}` are registered');
			Assert.isTrue(earlier < later, '`${pair[0]}` runs before `${pair[1]}`');
		}
	}

}
