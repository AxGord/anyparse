package unit.dev;

import dev.BaseLint;
import dev.BaseSuite;
import dev.SliceGate;
import devkit.Branches;
import devkit.Command;
import devkit.Lease.LeaseMode;

/** The threads the pool lends the two lint branches of a slice gate: what a lint run uses, no more. */
@:nullSafety(Strict)
final class GateLintLeaseTest extends Test {

	private static final FACTS: GateDemand = {
		recording: false,
		infra: 0,
		touchedHx: true,
		jvmMoved: false,
		kitsMoved: false,
		typerMoved: false,
		ruleInfra: 0
	};

	@:pin('control')
	@:killer('M-GATE-BASE-LINT-TWO-THREADS')
	public function testTheBaseLintBranchLeasesOneThread(): Void {
		Assert.equals('1', threadsOf([BaseLint.ROW]));
	}

	@:pin('control')
	@:killer('M-GATE-LINT-ROW-FOUR-THREADS')
	public function testTheLintRowLeasesThreeThreads(): Void {
		Assert.equals('3', threadsOf(['lint']));
	}

	/** The `--threads` value the pool lease of the branch running `rows` asks for in a gate of `FACTS`. */
	private static function threadsOf(rows: Array<String>): String {
		final branches: Array<Array<String>> = SliceGate.GATE_BRANCHES.concat([[BaseSuite.ROW], [BaseLint.ROW]]);
		final pool: LeaseMode = Own('/p/scripts/wf-run', 14);
		final argv: Array<String> = Branches.leased(
			pool, branches, r -> SliceGate.demandOf(FACTS, r), r -> Command.of(['node', r[0]]), 'gate'
		)(rows).argv;
		return argv[argv.indexOf('--threads') + 1];
	}

}
