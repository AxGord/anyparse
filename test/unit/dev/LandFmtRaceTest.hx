package unit.dev;

import dev.LandFmtRace;
import devkit.Summary;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `fmt-race` verdict of `dev land`: a battery red only on the `fmt` row, whose listed files the branch did not change and
 * main did since the merge base, is named a race with its fix; every other red battery, and a green one, has no verdict. The
 * logs are made by the battery's own `Summary` table.
 */
@:nullSafety(Strict)
final class LandFmtRaceTest extends Test {

	private static final LISTED: String = '${LandFmtRace.LISTED} (or exited 0 — a non-zero exit with an EMPTY list is the one-pass gate)';

	@:pin('control')
	@:killer('M-LAND-FMT-RACE-OWN-FILE')
	public function testAListedFileTheBranchChangedIsNoRace(): Void {
		final run: Null<String> = LandFmtRace.verdict(
			log([red('fmt', LISTED)], ['src/A.hx', 'src/B.hx']), ['src/B.hx'], ['src/A.hx', 'src/B.hx']
		);
		Assert.isNull(run);
	}

	@:pin('control')
	@:killer('M-LAND-FMT-RACE-UNMOVED-FILE')
	public function testAListedFileMainDidNotChangeIsNoRace(): Void {
		Assert.isNull(LandFmtRace.verdict(log([red('fmt', LISTED)], ['src/A.hx', 'src/B.hx']), [], ['src/A.hx']));
	}

	public function testFilesOnlyMainChangedAreARaceNamedWithItsFix(): Void {
		final run: Null<String> = LandFmtRace.verdict(
			log([red('fmt', LISTED)], ['src/A.hx', 'test/unit/BTest.hx']), ['docs/x.md'], ['src/A.hx', 'test/unit/BTest.hx', 'src/C.hx']
		);
		Assert.notNull(run);
		final text: String = run ?? '';
		Assert.isTrue(text.startsWith('fmt-race src/A.hx test/unit/BTest.hx\n'), text);
		Assert.stringContains('sync; `hxq fmt --write src/A.hx test/unit/BTest.hx` with your engine', text);
		Assert.stringContains('`hxq changed <base>..HEAD` must class every file `layout`; amend', text);
	}

	@:pin('control')
	@:killer('M-LAND-FMT-RACE-OTHER-RED-ROW')
	public function testAnotherRedRowBesideFmtIsNoRace(): Void {
		final table: Array<Row> = [red('fmt', LISTED), red('suite', 'the suite is not green')];
		Assert.isNull(LandFmtRace.verdict(log(table, ['src/A.hx']), [], ['src/A.hx']));
	}

	@:pin('control')
	@:killer('M-LAND-FMT-RACE-OTHER-FMT-ROW')
	public function testARedFmtRowOfAnotherNameAloneIsNoRace(): Void {
		for (name in ['fmt xconfig', 'fmt squash'])
			Assert.isNull(LandFmtRace.verdict(log([red(name, LISTED)], ['src/A.hx']), [], ['src/A.hx']), name);
	}

	@:pin('control')
	@:killer('M-LAND-FMT-RACE-FORK-REASON')
	public function testAForkVerifyFailingBesideTheListIsNoRace(): Void {
		final why: String = '$LISTED; fmt --verify found a non-whitespace divergence in /fork/src';
		Assert.isNull(LandFmtRace.verdict(log([red('fmt', why)], ['src/A.hx']), [], ['src/A.hx']));
	}

	@:pin('control')
	@:killer('M-LAND-FMT-RACE-NO-FILES')
	public function testAFmtRowRedWithNoListedFileIsNoRace(): Void {
		Assert.isNull(LandFmtRace.verdict(log([red('fmt', LISTED)], []), [], ['src/A.hx']));
	}

	public function testOnlyTheTreeFilesOfTheFmtSectionAreListed(): Void {
		final text: String = [
			'=== suite ===',
			'src/NotListed.hx',
			'=== fmt ===',
			'apq fmt --list: 2 of 9 file(s) would be rewritten',
			'src/A.hx',
			'docs/readme.md',
			'/fork/src/F.hx',
			'src/A.hx',
			'tools/src/T.hx',
			'=== fmt xconfig ===',
			'src/Other.hx'
		].join('\n');
		Assert.same(['src/A.hx', 'tools/src/T.hx'], LandFmtRace.listed(text));
	}

	public function testAGreenBatteryHasNoVerdictAndNoRedRow(): Void {
		final text: String = log([pass('suite'), pass('fmt'), pass('fmt xconfig')], []);
		Assert.isNull(LandFmtRace.verdict(text, [], ['src/A.hx']));
		Assert.equals(0, LandFmtRace.red(text).length);
	}

	public function testTheRedRowsAreNamedWithTheirReason(): Void {
		final text: String = log([pass('suite'), red('fmt', LISTED), red('fmt xconfig', 'x')], []);
		Assert.same(['fmt', 'fmt xconfig'], LandFmtRace.red(text).map(row -> row.name));
		Assert.equals(LISTED, LandFmtRace.red(text)[0].why);
	}

	/** A battery log: the `fmt` section listing `files`, then the table of `rows`. */
	private static function log(rows: Array<Row>, files: Array<String>): String {
		final summary: Summary = new Summary();
		summary.add('build (parallel)', Passed, 49500);
		for (row in rows) summary.add(row.name, row.outcome, 15800);
		return [
			'=== suite ===',
			'ok',
			'',
			'=== fmt ===',
			'apq fmt --list: ${files.length} of 99 file(s) would be rewritten'
		].concat(files)
			.concat([
				'apq fmt --verify: 0 of 20 reformatted file(s) changed more than whitespace',
				'',
				'=== fmt xconfig ===',
				'src/Z.hx',
				''
			])
			.concat([summary.table(), '', '--- battery: FAIL ---'])
			.join('\n');
	}

	private static function red(name: String, why: String): Row {
		return { name: name, outcome: Failed(why) };
	}

	private static function pass(name: String): Row {
		return { name: name, outcome: Passed };
	}

}

private typedef Row = { var name: String; var outcome: Outcome; }
