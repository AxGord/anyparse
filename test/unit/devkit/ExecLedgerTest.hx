package unit.devkit;

import devkit.ExecLedger;
import devkit.Summary.Step;
import sys.FileSystem;
import sys.io.File;

/**
 * `devkit.ExecLedger`: a finished row is kept as one line and read back whole, a reading a row has none of stays absent, a
 * line an older tool wrote reads back with the newer readings absent, and the file keeps a bounded tail.
 */
@:nullSafety(Strict)
final class ExecLedgerTest extends Test {

	@:pin('control')
	@:killer('M-EXECLEDGER-READINGS-WRITTEN')
	public function testARowReadsBackWithEveryReading(): Void {
		TempDir.with(dir -> {
			final ledger: ExecLedger = new ExecLedger(dir.file('sub/ledger.tsv'));
			ledger.record({
				row: 'suite',
				phase: 'gate',
				wallMs: 1500,
				waitMs: 250,
				cpuS: 12.5,
				threads: 4
			});
			ledger.record({ row: 'lint', phase: 'gate', wallMs: 90 });
			Assert.same([
				{
					row: 'suite',
					phase: 'gate',
					wallMs: 1500.0,
					waitMs: 250.0,
					cpuS: 12.5,
					threads: 4
				},
				{
					row: 'lint',
					phase: 'gate',
					wallMs: 90.0,
					waitMs: null,
					cpuS: null,
					threads: null
				}
			], ledger.rows());
		});
	}

	@:pin('control')
	@:killer('M-EXECLEDGER-NO-WALL-SKIPPED')
	public function testALineThatIsNoRowIsSkippedAndAnOlderOneReadsShort(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('ledger.tsv');
			File.saveContent(file, 'old\tgate\t700\nnot a row\nbad\tgate\tmany\n\nfull\tland\t5\t6\t7\t8\n');
			final rows: Array<LedgerRow> = new ExecLedger(file).rows();
			Assert.equals(2, rows.length);
			Assert.equals('old', rows[0].row);
			Assert.equals(700.0, rows[0].wallMs);
			Assert.isNull(rows[0].waitMs);
			Assert.isNull(rows[0].threads);
			Assert.equals('full', rows[1].row);
			Assert.equals(8, rows[1].threads);
		});
	}

	@:pin('control')
	@:killer('M-EXECLEDGER-NO-NAME-RECORDED')
	public function testARowWithNoNameOrNoWallTimeIsNotRecorded(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('ledger.tsv');
			final ledger: ExecLedger = new ExecLedger(file);
			ledger.record({ row: '', phase: 'gate', wallMs: 5 });
			ledger.record({ row: 'a', phase: 'gate', wallMs: -1 });
			Assert.isFalse(FileSystem.exists(file));
		});
	}

	@:pin('control')
	@:killer('M-EXECLEDGER-TAB-IN-NAME')
	public function testATabInANameCannotShiftTheReadings(): Void {
		TempDir.with(dir -> {
			final ledger: ExecLedger = new ExecLedger(dir.file('ledger.tsv'));
			ledger.record({
				row: 'a\tb',
				phase: 'g\nh',
				wallMs: 10,
				threads: 2
			});
			final rows: Array<LedgerRow> = ledger.rows();
			Assert.equals(1, rows.length);
			Assert.equals('a b', rows[0].row);
			Assert.equals('g h', rows[0].phase);
			Assert.equals(2, rows[0].threads);
		});
	}

	@:pin('control')
	@:killer('M-EXECLEDGER-BOUND')
	public function testTheFileKeepsABoundedTail(): Void {
		TempDir.with(dir -> {
			final ledger: ExecLedger = new ExecLedger(dir.file('ledger.tsv'));
			for (i in 0...ExecLedger.MAX_LINES + 20) ledger.record({ row: 'row$i', phase: 'gate', wallMs: 1 });
			final rows: Array<LedgerRow> = ledger.rows();
			Assert.equals(ExecLedger.MAX_LINES, rows.length);
			Assert.equals('row20', rows[0].row, 'the oldest went');
			Assert.equals('row${ExecLedger.MAX_LINES + 19}', rows[rows.length - 1].row);
		});
	}

	@:pin('control')
	@:killer('M-EXECLEDGER-BATTERY-TWICE')
	public function testTheLandBatteryStepKeepsOnlyItsOverhead(): Void {
		final land: Array<LedgerRow> = [
			{ row: 'build', phase: 'land', wallMs: 10 },
			{ row: 'battery', phase: 'land', wallMs: 100 }
		];
		final inner: Array<LedgerRow> = [
			{ row: 'suite', phase: 'battery', wallMs: 70 },
			{ row: 'fmt', phase: 'battery', wallMs: 60 },
			{ row: 'span', phase: 'battery', wallMs: 80 }
		];
		final out: Array<LedgerRow> = ExecLedger.withoutDoubleCount(land, inner);
		Assert.equals('build', out[0].row);
		Assert.equals(10.0, out[0].wallMs);
		Assert.equals('battery-overhead', out[1].row);
		Assert.equals(20.0, out[1].wallMs, 'cut by the span, never by the overlapping rows');
		Assert.equals(0.0, ExecLedger.withoutDoubleCount(land, [{ row: 'span', phase: 'battery', wallMs: 120 }])[1].wallMs);
	}

	/** A land records its battery's rows from the file the battery wrote, so a shared ledger already at its cap still gets them. */
	@:pin('control')
	@:killer('M-EXECLEDGER-LAND-DROPS-BATTERY')
	public function testAFullLedgerStillGetsTheLandsBatteryRows(): Void {
		TempDir.with(dir -> {
			final shared: ExecLedger = new ExecLedger(dir.file('shared.tsv'));
			for (i in 0...ExecLedger.MAX_LINES) shared.record({ row: 'old$i', phase: 'gate', wallMs: 1 });
			final battery: ExecLedger = new ExecLedger(dir.file('battery.tsv'));
			battery.record({ row: 'suite', phase: 'battery', wallMs: 70 });
			battery.record({ row: 'span', phase: 'battery', wallMs: 80 });
			final land: Array<LedgerRow> = [{ row: 'battery', phase: 'land', wallMs: 100 }];
			for (row in ExecLedger.ofLand(land, battery.rows())) shared.record(row);
			final tail: Array<LedgerRow> = shared.rows().slice(-3);
			Assert.same(['battery-overhead', 'suite', 'span'], tail.map(row -> row.row));
			Assert.equals(20.0, tail[0].wallMs);
			Assert.equals(ExecLedger.MAX_LINES, shared.rows().length);
		});
	}

	/** The land's battery step is cut by the span's cpu as by its wall, and the span carries the cpu of everything the battery measured. */
	@:pin('control')
	@:killer('M-EXECLEDGER-OVERHEAD-CPU-TWICE')
	public function testTheLandBatteryStepKeepsOnlyItsOverheadCpu(): Void {
		final land: Array<LedgerRow> = [{
			row: 'battery',
			phase: 'land',
			wallMs: 100,
			cpuS: 30
		}];
		final span: Array<LedgerRow> = [{
			row: 'span',
			phase: 'battery',
			wallMs: 80,
			cpuS: 25
		}];
		Assert.equals(5.0, ExecLedger.withoutDoubleCount(land, span)[0].cpuS);
		Assert.equals(0.0, ExecLedger.withoutDoubleCount(land, [{
			row: 'span',
			phase: 'battery',
			wallMs: 80,
			cpuS: 40
		}])[0].cpuS);
		Assert.equals(
			30.0, ExecLedger.withoutDoubleCount(land, [{ row: 'span', phase: 'battery', wallMs: 80 }])[0].cpuS,
			'an unmeasured span cuts nothing'
		);
		Assert.isNull(ExecLedger.withoutDoubleCount([{ row: 'battery', phase: 'land', wallMs: 100 }], span)[0].cpuS);
	}

	@:pin('control')
	@:killer('M-EXECLEDGER-SPAN-CPU')
	public function testTheSpanRowSumsWhatItsStepsMeasured(): Void {
		final steps: Array<Step> = [
			{
				name: 'build (parallel)',
				outcome: Passed,
				ms: 1,
				note: '',
				excerpt: [],
				cpu: 10
			},
			{
				name: 'suite',
				outcome: Passed,
				ms: 1,
				note: '',
				excerpt: [],
				cpu: 20
			},
			{
				name: 'corpus',
				outcome: Passed,
				ms: 1,
				note: '',
				excerpt: []
			}
		];
		final span: LedgerRow = ExecLedger.spanRow(steps, 500, 7, 4);
		Assert.equals(30.0, span.cpuS);
		Assert.equals(4, span.threads, 'the lease the battery held is recorded on the span, once');
		Assert.equals(500.0, span.wallMs);
		Assert.equals('span', span.row);
		Assert.isNull(ExecLedger.spanRow([steps[2]], 500, 7, null).cpuS, 'nothing measured, nothing recorded');
	}

	/** A land that made the base's snapshot by a battery records that battery's rows and keeps only the overhead of its `base` step. */
	@:pin('control')
	@:killer('M-EXECLEDGER-BASE-TWICE')
	@:killer('M-EXECLEDGER-LAND-DROPS-SNAPSHOT')
	public function testTheLandBaseStepKeepsOnlyItsOverheadBesideTheSnapshotBattery(): Void {
		final land: Array<LedgerRow> = [
			{
				row: 'base',
				phase: 'land',
				wallMs: 100,
				cpuS: 30
			},
			{ row: 'battery', phase: 'land', wallMs: 50 }
		];
		final snapshot: Array<LedgerRow> = [
			{ row: 'suite', phase: 'battery', wallMs: 70 },
			{
				row: 'span',
				phase: 'battery',
				wallMs: 80,
				cpuS: 25
			}
		];
		final out: Array<LedgerRow> = ExecLedger.ofLand(land, [], snapshot);
		Assert.same(['base-overhead', 'battery-overhead', 'suite', 'span'], out.map(row -> row.row));
		Assert.equals(20.0, out[0].wallMs);
		Assert.equals(5.0, out[0].cpuS);

	}

}
