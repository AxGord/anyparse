package unit.macro;

import anyparse.macro.RuleDiscovery;
import unit.cli.CliFixture;

/**
 * `RuleDiscovery`: which files under the classpath roots are modules of the rule packages, and the registry order the
 * rule rows take with their anchors.
 */
@:nullSafety(Strict)
class RuleDiscoveryTest extends Test {

	/**
	 * Only a module file of the `anyparse.check` packages outside every dot-entry is walked, named by its path; a root
	 * given twice yields each module once, the result is sorted, and an empty root is skipped.
	 */
	@:killer('M-GRAMMAR-DISCOVERY-DOT-ENTRIES')
	@:pin('control')
	public function testOnlyAModuleFileOfTheCheckPackagesIsWalked(): Void {
		final root: String = CliFixture.writeTree('rule_discovery', [
			{ name: 'anyparse/check/a/X.hx', source: '' },
			{ name: 'anyparse/check/.hidden/Y.hx', source: '' },
			{ name: 'anyparse/check/import.hx', source: '' },
			{ name: 'anyparse/check/W.txt', source: '' },
			{ name: 'anyparse/check/V.hx', source: '' },
			{ name: 'anyparse/other/Z.hx', source: '' }
		]);
		CliFixture.always(
			CliFixture.removeDir.bind(root),
			() -> Assert.same(['anyparse.check.V', 'anyparse.check.a.X'], RuleDiscovery.ruleModules(['', root, root]))
		);
	}

	/** With no anchor the order is by class name, and two rules of one name go by class path. */
	@:killer('M-RULE-ORDER-UNSORTED')
	@:pin('control')
	public function testRulesWithoutAnchorsGoByClassNameThenPath(): Void {
		Assert.same({ paths: ['x.A', 'y.A', 'z.B'], problem: null }, RuleDiscovery.order([rule('z.B'), rule('y.A'), rule('x.A')]));
	}

	/** A rule declaring `@:lintAfter` moves behind its anchor, and the rules ahead of it keep their order. */
	@:killer('M-RULE-ORDER-AFTER-IGNORED')
	@:pin('control')
	public function testAfterMovesARuleBehindItsAnchor(): Void {
		Assert.same({ paths: ['p.B', 'p.C', 'p.A'], problem: null }, RuleDiscovery.order([rule('p.A', ['C']), rule('p.B'), rule('p.C')]));
	}

	/**
	 * The anchor of a rule declaring `@:lintBefore` waits behind it, and the rules ahead of the anchor keep their order.
	 */
	@:killer('M-RULE-ORDER-BEFORE-IGNORED')
	@:pin('control')
	public function testBeforeHoldsItsAnchorBack(): Void {
		Assert.same(
			{ paths: ['p.B', 'p.C', 'p.A'], problem: null }, RuleDiscovery.order([rule('p.A'), rule('p.B'), rule('p.C', [], ['A'])])
		);
	}

	/** An anchor naming no rule is the problem, naming the rule and its metadata. */
	@:killer('M-RULE-ANCHOR-UNKNOWN-SKIPPED')
	@:pin('control')
	public function testAnAnchorNamingNoRuleIsAProblem(): Void {
		Assert.same(
			{ paths: [], problem: 'p.A declares @:lintAfter(Q), but Q names no built-in lint rule' },
			RuleDiscovery.order([rule('p.A', ['Q']), rule('p.B')])
		);
	}

	/** A class name two rules share is an ambiguous anchor, and a class path picks one of them. */
	@:killer('M-RULE-ANCHOR-PATH-IGNORED')
	@:pin('control')
	public function testAClassPathSettlesAnAnchorTwoRulesShare(): Void {
		Assert.same(
			{ paths: [], problem: 'p.A declares @:lintAfter(B), but B names several built-in lint rules, so spell its class path' },
			RuleDiscovery.order([rule('p.A', ['B']), rule('q.B'), rule('r.B')])
		);
		Assert.same({ paths: ['q.B', 'r.B', 'p.A'], problem: null }, RuleDiscovery.order([rule('p.A', ['r.B']), rule('q.B'), rule('r.B')]));
	}

	/** Two rules that each run after the other are a cycle, the problem naming both. */
	@:killer('M-RULE-ORDER-ANCHORS-UNREAD')
	@:pin('control')
	public function testACycleOfAnchorsIsAProblem(): Void {
		Assert.same({
			paths: [],
			problem: 'the lint rules p.A, p.B order each other in a cycle of @:lintAfter / @:lintBefore, so no registry order honours '
			+ 'them all'
		}, RuleDiscovery.order([rule('p.A', ['B']), rule('p.B', ['A']), rule('p.C')]));
	}

	/** The row of the rule at the class path `path`, running after the rules `after` and before the rules `before`. */
	private static function rule(path: String, ?after: Array<String>, ?before: Array<String>): RuleRow {
		final segments: Array<String> = path.split('.');
		return {
			path: path,
			name: segments[segments.length - 1],
			after: after ?? [],
			before: before ?? []
		};
	}

}
