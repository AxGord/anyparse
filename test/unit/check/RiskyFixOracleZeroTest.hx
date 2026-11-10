package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.common.types.AvoidDynamic;
import anyparse.check.haxe.loops.PreferSinglePass;
import anyparse.query.Cli.RuleFixOutcome;
import anyparse.query.cli.command.LintFixLedger;
import anyparse.query.cli.command.LintFixVerify;
import unit.cli.CliFixture;

/**
 * What a `RiskyFix` run says under a real compiler oracle about each file a finding sits in: a file the oracle reads
 * takes the fix, a file it does not read is named as such, and a file the writer would reformat is named too rather
 * than ending in an unexplained zero.
 */
@:nullSafety(Strict)
final class RiskyFixOracleZeroTest extends Test {

	#if (sys || nodejs)
	private static final HXML: String = '-cp .\n-main Main\n';
	private static final MAIN: String = 'class Main {\n\n\tstatic function main() {\n\t\ttrace(run([1, 2]));\n\t}\n\n'
		+ '\tstatic function run(xs:Array<Int>):Array<Int> {\n\t\treturn xs.filter(x -> x > 1).map(x -> x * 2);\n\t}\n\n}\n';
	private static final DRIFTED_TWO_RULES: String = 'class Main {\n    public function new() {}\n    static function main() {\n'
		+ '        final a:Main = new Main();\n        var x:Dynamic = a;\n        var y:Main = x;\n'
		+ '        trace(y);\n        trace(run([1, 2]));\n    }\n    static function '
		+ 'run(xs:Array<Int>):Array<Int> {\n        return xs.filter(x -> x > 1).map(x -> x * 2);\n    }\n}\n';
	private static final OTHER: String = 'class Other {\n\n'
		+ '\tstatic function run(xs:Array<Int>):Array<Int> {\n\t\treturn xs.filter(x -> x > 1).map(x -> x * 2);\n\t}\n\n}\n';
	private static final DRIFTED: String = 'class Main {\n    static function main() {\n        trace(run([1, 2]));\n    }\n'
		+ '    static function run(xs:Array<Int>):Array<Int> {\n        return xs.filter(x -> x > 1).map(x -> x * 2);\n    }\n}\n';
	#end

	@:pin('control')
	@:killer('M-RISKY-ORACLE-READ-NOT-APPLIED')
	public function testAFileTheOracleReadsTakesTheRiskyFix(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(MAIN);
		final outcome: RiskyFixOutcome = run(dir, MAIN);
		Assert.equals(1, outcome.appliedCount, outcome.tail);
		Assert.notEquals(MAIN, File.getContent('$dir/Main.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-RISKY-ORACLE-UNREAD-NOT-NAMED')
	public function testAFileTheOracleDoesNotReadIsNamed(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(MAIN);
		final outcome: RiskyFixOutcome = run(dir, OTHER, 'Other.hx');
		Assert.equals(0, outcome.appliedCount, outcome.tail);
		Assert.stringContains('DECLINED', outcome.tail);
		Assert.equals(1, outcome.declines.length);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-RISKY-NOT-CANONICAL-SILENT')
	public function testADriftedFileIsNamedNotASilentZero(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(DRIFTED);
		final outcome: RiskyFixOutcome = run(dir, DRIFTED);
		Assert.equals(0, outcome.appliedCount, outcome.tail);
		Assert.stringContains('not writer-canonical', outcome.tail);
		Assert.equals(DRIFTED, File.getContent('$dir/Main.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-RISKY-NOT-CANONICAL-NOT-REPORTED')
	public function testADriftedFilesFindingsCountAsReportedNotDeclined(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(DRIFTED);
		final ledger: Map<String, RuleFixOutcome> = [];
		Assert.equals(0, run(dir, DRIFTED, 'Main.hx', null, ledger).appliedCount);
		final row: Null<RuleFixOutcome> = ledger['prefer-single-pass'];
		Assert.notNull(row, 'the rule has a ledger row');
		if (row != null) {
			Assert.equals(1, row.reported);
			Assert.equals(0, row.declined, 'the tree state is not charged to the rule');
		}
		Assert.stringContains(
			'0 produced an edit, 1 reported and got none', LintFixLedger.exerciseCensus(ledger, ['prefer-single-pass'], [])[0]
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-RISKY-NOT-CANONICAL-COUNTS-ROWS')
	public function testTwoRulesOnOneDriftedFileCountOneFile(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(DRIFTED_TWO_RULES);
		final outcome: RiskyFixOutcome = run(dir, DRIFTED_TWO_RULES, 'Main.hx', [new PreferSinglePass(), new AvoidDynamic()]);
		Assert.stringContains(', 1 file(s) not writer-canonical', outcome.tail);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function fixture(main: String): String {
		return CliFixture.writeDir('riskyzero', [
			{ name: 'Main.hx', source: main },
			{ name: 'Other.hx', source: OTHER },
			{ name: 'check.hxml', source: HXML }
		]);
	}

	private static function run(
		dir: String, source: String, name: String = 'Main.hx', ?checks: Array<Check>, ?ledger: Map<String, RuleFixOutcome>
	): RiskyFixOutcome {
		return LintFixVerify.verifyRiskyFixes(
			[{ file: '$dir/$name', source: source }],
			checks ?? [new PreferSinglePass()], new HaxeQueryPlugin(), [{ hxml: 'check.hxml', dir: dir, defines: [] }],
			[], [], ledger ?? [], _ -> new LintConfig([]), false
		);
	}
	#end

}
