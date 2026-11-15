package unit.dev;

import dev.ExecLedgerCli;
import dev.GateRecord;
import dev.GateReuse;
import devkit.ExecLedger;
import devkit.Summary.Step;
import devkit.TempDir;
import utest.Assert;
import utest.Test;

/**
 * `dev exec-ledger`: rows are summed per phase and branch, a branch's cpu sits on its first row and counts once, a branch
 * no cpu reached is unmetered rather than zero, `--since` keeps the rows recorded from that day, and a gate record carries
 * its rows as ledger lines through a write and a read.
 */
@:nullSafety(Strict)
final class ExecLedgerCliTest extends Test {

	@:pin('control')
	@:killer('M-EXECLEDGERCLI-BRANCH-KEY')
	public function testABranchCpuCountsOnceOverItsWall(): Void {
		final totals: Array<LedgerTotal> = ExecLedgerCli.summarize([
			{
				row: 'suite',
				phase: 'gate',
				wallMs: 60000,
				waitMs: 2000,
				cpuS: 120,
				threads: 4
			},
			{
				row: 'corpus',
				phase: 'gate',
				wallMs: 30000,
				threads: 4,
				branch: 'suite'
			}
		], null);
		Assert.equals(2, totals.length);
		Assert.equals(2, totals[0].rows);
		Assert.equals(120.0, totals[0].cpuS);
		Assert.floatEquals(120 / 90, ExecLedgerCli.cores(totals[0]) ?? 0);
		Assert.floatEquals(6, totals[0].threadMinutes);
		Assert.equals(ExecLedgerCli.TOTAL, totals[1].branch);
	}

	@:pin('control')
	@:killer('M-EXECLEDGERCLI-UNMETERED-ZERO')
	public function testAnUnmeteredBranchIsNotZeroCpu(): Void {
		final totals: Array<LedgerTotal> = ExecLedgerCli.summarize([
			{
				row: 'suite',
				phase: 'gate',
				wallMs: 10000,
				cpuS: 20
			},
			{ row: 'lint', phase: 'gate', wallMs: 10000 }
		], null);
		Assert.isNull(totals[1].cpuS);
		Assert.isNull(ExecLedgerCli.cores(totals[1]));
		final phase: LedgerTotal = totals[2];
		Assert.equals(1, phase.unmetered);
		Assert.floatEquals(2, ExecLedgerCli.cores(phase) ?? 0);
	}

	@:pin('control')
	@:killer('M-EXECLEDGERCLI-SINCE-IGNORED')
	public function testSinceKeepsOnlyRowsRecordedFromThatDay(): Void {
		final from: Float = ExecLedgerCli.dayStart('2026-11-10');
		final totals: Array<LedgerTotal> = ExecLedgerCli.summarize([
			{
				row: 'old',
				phase: 'land',
				wallMs: 1,
				at: from - 1
			},
			{ row: 'undated', phase: 'land', wallMs: 1 },
			{
				row: 'new',
				phase: 'land',
				wallMs: 1,
				at: from
			}
		], from);
		Assert.same(['new', ExecLedgerCli.TOTAL], totals.map(total -> total.branch));
	}

	@:pin('control')
	@:killer('M-EXECLEDGER-OFSTEPS-BRANCH')
	public function testAGateRecordCarriesItsRowsAsLedgerLines(): Void {
		final steps: Array<Step> = [
			step('suite', 500, 30, 4),
			step('corpus', null, null, 4),
			step('lint', null, null, null)
		];
		TempDir.with(dir -> {
			final file: String = dir.file('gate-record.json');
			GateReuse.write(file, {
				tree: 't',
				passed: true,
				toolchain: 'h',
				fork: '',
				allow: [],
				rows: [],
				tests: 0,
				assertions: 0,
				timings: GateReuse.timingsOf(steps, 7)
			});
			final record: Null<GateRecord> = GateReuse.read(file);
			final rows: Array<LedgerRow> = [];
			for (line in record?.timings ?? []) {
				final row: Null<LedgerRow> = ExecLedger.decode(line);
				if (row != null) rows.push(row);
			}
			Assert.same(['', 'suite', ''], rows.map(row -> row.branch ?? ''));
			Assert.same([30.0, null, null], rows.map(row -> row.cpuS));
			Assert.same([7.0, 7.0, 7.0], rows.map(row -> row.at));
		});
	}

	@:pin('control')
	@:killer('M-EXECLEDGERCLI-RUN-PER-LAND')
	public function testAnUnmeteredRunOfAMeasuredBranchStaysUnmetered(): Void {
		final totals: Array<LedgerTotal> = ExecLedgerCli.summarize([
			{
				row: 'suite',
				phase: 'gate',
				wallMs: 10000,
				cpuS: 40,
				at: 1
			},
			{
				row: 'suite',
				phase: 'gate',
				wallMs: 30000,
				at: 2
			}
		], null);
		Assert.equals(2, totals[0].rows);
		Assert.equals(1, totals[0].unmetered);
		Assert.floatEquals(4, ExecLedgerCli.cores(totals[0]) ?? 0);
		Assert.equals(1, totals[1].unmetered);
	}

	private static function step(name: String, wait: Null<Float>, cpu: Null<Float>, threads: Null<Int>): Step {
		final out: Step = {
			name: name,
			outcome: Passed,
			ms: 1000,
			note: '',
			excerpt: []
		};
		if (wait != null) out.wait = wait;
		if (cpu != null) out.cpu = cpu;
		if (threads != null) out.threads = threads;
		return out;
	}

}
