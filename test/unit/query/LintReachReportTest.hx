package unit.query;

import unit.cli.CliFixture;

/**
 * `lint` reports a finding only where the builds that compile its file resolve the helper the finding advises.
 *
 * Driven through the command, since the property is its wiring: the declared builds are real, the helper lives under a root the
 * narrow build does not read, and the rules a withheld finding supersedes stay in the report.
 */
@:nullSafety(Strict)
final class LintReachReportTest extends Test {

	private static final CMP: String = 'package lib;\nclass Cmp {\n\tpublic static function strings(a:String, b:String):Int return 0;\n}';
	private static final SOURCE: String = '@:nullSafety(Strict)\nclass C {\n\n\tstatic function main() {}\n\n'
		+ '\tfunction wrapped(xs:Array<String>):Void {\n\t\txs.sort((a, b) -> Reflect.compare(a, b));\n\t}\n\n'
		+ '\tfunction ternary(xs:Array<String>):Void {\n\t\txs.sort((a:String, b:String) -> a < b ? -1 : a > b ? 1 : 0);\n\t}\n\n}\n';
	private static final RULES: String = '"rules":{"prefer-compare-function":{"enabled":true,"compare":{"String":"lib.Cmp.strings"}},'
		+ '"redundant-lambda-wrapper":{"enabled":true},"prefer-if-expression-chain":{"enabled":true}}';

	/** A build that cannot read the helper's root hears of neither site, the report-only one included. */
	@:pin('control')
	@:killer('M-LINTREACH-REPORT-UNWIRED')
	public function testASiteWhoseHelperTheBuildCannotSeeIsNotReported(): Void {
		#if (sys || nodejs)
		final report: String = reportOver('narrow.hxml');
		Assert.equals(-1, report.indexOf('(prefer-compare-function)'), 'the helper is out of the build\'s reach: $report');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The rules a withheld finding supersedes speak at its sites: one finding per site, never zero. */
	@:pin('control')
	@:killer('M-LINTREACH-AFTER-SUPERSESSION')
	public function testAWithheldFindingLeavesTheRulesItSupersedesStanding(): Void {
		#if (sys || nodejs)
		final report: String = reportOver('narrow.hxml');
		Assert.stringContains('(redundant-lambda-wrapper)', report);
		Assert.stringContains('(prefer-if-expression-chain)', report);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A build that reads the helper's root is told of both sites, and they still supersede. */
	@:pin('control')
	@:killer('M-LINTREACH-REPORT-DROPS-REMEDIED')
	public function testASiteWhoseHelperTheBuildSeesIsReported(): Void {
		#if (sys || nodejs)
		final report: String = reportOver('wide.hxml');
		Assert.stringContains('(prefer-compare-function)', report);
		Assert.equals(-1, report.indexOf('(redundant-lambda-wrapper)'), 'a reported finding still supersedes: $report');
		Assert.equals(-1, report.indexOf('(prefer-if-expression-chain)'), 'a reported finding still supersedes: $report');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The report of `lint --no-oracle --all` over a project whose one declared build is `hxml`. */
	private static function reportOver(hxml: String): String {
		final root: String = CliFixture.writeTree('lintreach', [
			{
				name: 'apq.json',
				source: '{"compilerOracle":[{"hxml":"leaf/$hxml","dir":"leaf"}],"resolutionRoots":["shared","leaf/src"],$RULES}'
			},
			{ name: 'leaf/narrow.hxml', source: '-cp src\n-main C\n' },
			{ name: 'leaf/wide.hxml', source: '-cp src\n-cp ../shared\n-main C\n' },
			{ name: 'leaf/src/C.hx', source: SOURCE },
			{ name: 'shared/lib/Cmp.hx', source: CMP }
		]);
		final report: String = CliFixture.inDir(root, ['lint', 'leaf/src/C.hx', '--no-oracle', '--all']);
		CliFixture.removeDir(root);
		return report;
	}
	#end

}
