package unit.devkit;

import devkit.Branches;
import devkit.Command;
import devkit.Summary;
import devkit.TempDir;
import haxe.io.Path;
import utest.Assert;
import utest.Test;

/** `devkit.Branches`: a branch report survives its round trip, a lease is shared, and a branch that left no report fails its steps. */
@:nullSafety(Strict)
final class BranchesTest extends Test {

	public function testAReportRoundTripsEveryOutcome(): Void {
		final summary: Summary = new Summary();
		summary.add('a', Passed, 1, 'note');
		summary.add('b', Failed('why b'));
		summary.add('c', NotRun('why c'));
		summary.add('d', Skipped('why d'));
		final read: BranchReport = Branches.decode(Branches.encode('r1', summary.steps(), ['tests' => 3]));
		Assert.equals('r1', read.run);
		Assert.same(summary.steps(), read.steps);
		Assert.equals(3, read.readings['tests']);
	}

	@:pin('control')
	@:killer('M-BRANCHES-SHARE-WHOLE')
	public function testTheHeavyRowsShareWhatTheLeaseLeaves(): Void {
		Assert.equals(6, Branches.share(10, 4));
		Assert.equals(1, Branches.share(3, 5));
		Assert.isNull(Branches.share(null, 4));
	}

	@:pin('control')
	@:killer('M-BRANCHES-FOREIGN-REPORT')
	public function testAReportOfAnotherRunIsNone(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('a.json');
			sys.io.File.saveContent(file, Branches.encode('old', [], []));
			Assert.isNull(Branches.reportOf(file, 'new'));
			Assert.notNull(Branches.reportOf(file, 'old'));
			sys.io.File.saveContent(file, '{"steps": [], "readings": []}');
			Assert.isNull(Branches.reportOf(file, 'new'));
		});
	}

	public function testABranchWithoutAReportFailsItsSteps(): Void {
		TempDir.with(dir -> {
			final report: Array<String> -> String = names -> Path.join([dir.path, '${names[0]}.json']);
			final summary: Summary = new Summary();
			final left: String = Branches.encode('r1', [
				{
					name: 'a',
					outcome: Passed,
					ms: 0,
					note: ''
				}
			], ['n' => 1]);
			final readings: Map<String, Int> = Branches.run(
				'r1', [['a'], ['b']],
				['b', 'a'],
				names -> names[0] == 'a'
					? Command.of([
						'node',
						'-e',
						'require("fs").writeFileSync(process.argv[1], process.argv[2])',
						report(names),
						left
					])
					: Command.of(['node', '-e', 'process.exit(3)']),
				report, summary
			);
			Assert.equals(1, readings['n']);
			Assert.same(['b', 'a'], [for (step in summary.steps()) step.name]);
			Assert.isTrue(summary.steps()[0].outcome.match(NotRun(_)));
			Assert.isTrue(summary.steps()[1].outcome.match(Passed));
		});
	}

}
