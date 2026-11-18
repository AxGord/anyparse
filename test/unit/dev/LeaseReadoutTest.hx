package unit.dev;

import dev.ExecLedgerCli;
import dev.LeaseReadout;
import devkit.Args.UsageError;
import devkit.ExecLedger;
import devkit.TempDir;
import utest.Assert;
import utest.Test;

/** `LeaseReadout`: held and used per metered branch run, gate rows regrouped by their real branches, shared battery leases left out. */
@:nullSafety(Strict)
final class LeaseReadoutTest extends Test {

	private static inline final MINUTE: Float = 60000;

	@:pin('control')
	@:killer('M-LEASEREADOUT-GAP-ABS')
	public function testHeldAndUsedGiveTheGapIdleOverAndShare(): Void {
		final lines: Array<LeaseBranch> = LeaseReadout.read([run('shard', 4, 120, 1), run('shard', 1, 120, 2)], null);
		Assert.equals(3, lines.length);
		final all: LeaseBranch = lines[2];
		Assert.equals(LeaseReadout.ALL, all.branch);
		Assert.equals(2, all.runs);
		Assert.floatEquals(1.5, LeaseReadout.meanGap(all));
		Assert.floatEquals(2, all.idle);
		Assert.floatEquals(1, all.over);
		Assert.floatEquals(5, all.heldMin);
		Assert.floatEquals(60, LeaseReadout.mismatch(all));
	}

	@:pin('control')
	@:killer('M-LEASEREADOUT-GATE-REGROUP')
	public function testGateRowsReadUnderTheirRealBranches(): Void {
		final rows: Array<LedgerRow> = [
			{
				row: 'suite',
				phase: 'gate',
				wallMs: MINUTE,
				cpuS: 180,
				threads: 3,
				at: 1
			},
			{
				row: 'lists',
				phase: 'gate',
				wallMs: MINUTE,
				cpuS: 60,
				threads: 1,
				at: 1
			},
			{
				row: 'corpus',
				phase: 'gate',
				wallMs: MINUTE,
				threads: 3,
				branch: 'lists',
				at: 1
			}
		];
		final lines: Array<LeaseBranch> = LeaseReadout.read(rows, null);
		Assert.same(['suite', 'lists', LeaseReadout.PHASE, LeaseReadout.ALL], lines.map(line -> line.branch));
		Assert.floatEquals(3, lines[0].held);
		Assert.floatEquals(1.5, lines[0].used);
		Assert.floatEquals(1, lines[1].held);
	}

	@:pin('control')
	@:killer('M-LEASEREADOUT-SHARED-LEASE')
	public function testABatteryThatSharedOneLeaseIsLeftOut(): Void {
		final rows: Array<LedgerRow> = [
			{
				row: 'suite',
				phase: 'battery',
				wallMs: MINUTE,
				cpuS: 60,
				threads: 8,
				at: 100
			},
			{
				row: 'span',
				phase: 'battery',
				wallMs: MINUTE,
				at: 101
			},
			{
				row: 'suite',
				phase: 'battery',
				wallMs: MINUTE,
				cpuS: 60,
				threads: 1,
				at: 5000
			},
			{
				row: 'span',
				phase: 'battery',
				wallMs: MINUTE,
				cpuS: 60,
				at: 5001
			}
		];
		final lines: Array<LeaseBranch> = LeaseReadout.read(rows, null);
		Assert.same(['suite', LeaseReadout.PHASE, LeaseReadout.ALL], lines.map(line -> line.branch));
		Assert.equals(1, lines[0].runs);
		Assert.floatEquals(1, lines[0].held);
	}

	@:pin('control')
	@:killer('M-LEASEREADOUT-UNMETERED-READ')
	public function testARunWithoutLeaseOrCpuIsNotRead(): Void {
		final lines: Array<LeaseBranch> = LeaseReadout.read([
			{
				row: 'a',
				phase: 'gate',
				wallMs: MINUTE,
				threads: 2,
				at: 1
			},
			{
				row: 'b',
				phase: 'gate',
				wallMs: MINUTE,
				cpuS: 30,
				at: 1
			}
		], null);
		Assert.same([LeaseReadout.ALL], lines.map(line -> line.branch));
		Assert.equals(0, lines[0].runs);
	}

	@:pin('control')
	@:killer('M-LEASEREADOUT-SINCE-TIME')
	public function testSinceTakesATimeOfDay(): Void {
		final day: Float = ExecLedgerCli.sinceStart('2026-11-10');
		Assert.floatEquals(12.5 * 60 * MINUTE, ExecLedgerCli.sinceStart('2026-11-10 12:30') - day);
		Assert.floatEquals(0, ExecLedgerCli.sinceStart('2026-11-10T00:00:00') - day);
		final offset: Float = Date.fromString('2026-11-10 00:00:00').getTimezoneOffset();
		Assert.floatEquals(offset * MINUTE, day - ExecLedgerCli.sinceStart('2026-11-10T00:00:00Z'));
	}

	@:pin('control')
	@:killer('M-LEASEREADOUT-UNTIL-EXCLUSIVE')
	public function testUntilKeepsTheRowsBeforeTheEnd(): Void {
		final rows: Array<LedgerRow> = [run('a', 1, 1, 1), run('b', 1, 1, 2), run('c', 1, 1, 3)];
		Assert.same(['a', 'b'], ExecLedgerCli.before(rows, 3).map(row -> row.row));
		Assert.equals(3, ExecLedgerCli.before(rows, null).length);
	}

	@:pin('control')
	@:killer('M-LEASEREADOUT-PHASE-LINE')
	public function testEachPhaseClosesItsBranchesWithItsOwnMean(): Void {
		final lines: Array<LeaseBranch> = LeaseReadout.read([
			run('x', 4, 120, 1),
			phased('gate', 'y', 1, 120, 2),
			run('z', 1, 60, 3),
			phased('gate', 'w', 2, 60, 4)
		], null);
		Assert.same(['x', 'z', LeaseReadout.PHASE, 'y', 'w', LeaseReadout.PHASE, LeaseReadout.ALL], lines.map(line -> line.branch));
		Assert.same(['post-land', 'post-land', 'post-land', 'gate', 'gate', 'gate', ''], lines.map(line -> line.phase));
		Assert.floatEquals(1, LeaseReadout.meanGap(lines[2]));
		Assert.floatEquals(1, LeaseReadout.meanGap(lines[5]));
		Assert.equals(2, lines[2].runs);
		Assert.equals(4, lines[6].runs);
	}

	@:pin('control')
	@:killer('M-LEASEREADOUT-MAIN-WINDOW')
	public function testTheCommandReadsItsWindowFromItsOptions(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('ledger.tsv');
			final ledger: ExecLedger = new ExecLedger(file);
			final at: Float -> Float = hour -> ExecLedgerCli.sinceStart('2026-11-10 $hour:30');
			for (entry in [
				run('early', 1, 60, at(11)),
				run('inside', 1, 60, at(12)),
				run('late', 1, 60, at(13))
			]) ledger.record(entry);
			final printed: Array<String> = [];
			final status: Int = ExecLedgerCli.run(
				['--file', file, '--since', '2026-11-10 12:00', '--until', '2026-11-10 13:00'], printed.push
			);
			final text: String = printed.join('\n');
			Assert.equals(0, status);
			Assert.isTrue(text.indexOf('inside') >= 0);
			Assert.isFalse(text.indexOf('early') >= 0);
			Assert.isFalse(text.indexOf('late') >= 0);
			Assert.raises(() -> ExecLedgerCli.run(['--file', file, '--until', 'soon'], printed.push), UsageError);
		});
	}

	private static function phased(phase: String, branch: String, threads: Int, cpu: Float, at: Float): LedgerRow {
		final row: LedgerRow = run(branch, threads, cpu, at);
		row.phase = phase;
		return row;
	}

	private static function run(branch: String, threads: Int, cpu: Float, at: Float): LedgerRow {
		return {
			row: branch,
			phase: 'post-land',
			wallMs: MINUTE,
			cpuS: cpu,
			threads: threads,
			at: at
		};
	}

}
