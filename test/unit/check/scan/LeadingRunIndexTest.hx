package unit.check.scan;

import anyparse.check.scan.CheckScan;
import anyparse.query.GrammarPlugin;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;

/**
 * `CheckScan.leadingRuns` reports where a run sits among its parent's children: `from` is the child index of the
 * run's first entry and `to` the index of the declaration it prefixes, so a reader slices the siblings before the run
 * without walking them. A run that no declaration follows is not reported.
 */
class LeadingRunIndexTest extends Test {

	private static final PREFIXED: String = 'package p;\nimport a.B;\n@:keep\nprivate\nclass C {}\n';

	@:pin('control')
	@:killer('M-LEADING-RUN-FROM-ZERO')
	public function testFromIsTheIndexOfTheFirstEntry(): Void {
		final runs: Array<LeadingRun> = runsOf(PREFIXED);
		Assert.equals(1, runs.length);
		Assert.equals(2, runs[0].from);
	}

	@:pin('control')
	@:killer('M-LEADING-RUN-TO-FIRST-ENTRY')
	public function testToIsTheIndexOfThePrefixedDeclaration(): Void {
		final runs: Array<LeadingRun> = runsOf(PREFIXED);
		Assert.equals(1, runs.length);
		Assert.equals(runs[0].from + runs[0].entries.length, runs[0].to);
		Assert.equals(4, runs[0].to);
	}

	public function testBareDeclarationHasNoRun(): Void {
		Assert.equals(0, runsOf('package p;\nimport a.B;\nclass C {}\n').length);
	}

	private static function runsOf(source: String): Array<LeadingRun> {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		return tree == null ? [] : CheckScan.leadingRuns(tree, [], CheckScan.leadingRunEntry(plugin));
	}

}
