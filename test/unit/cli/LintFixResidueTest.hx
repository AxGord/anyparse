package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.check.common.control.PreferTernaryReturn;
import anyparse.check.common.nullsafety.PreferNullCoalescing;
import anyparse.check.oracle.CompilerOracle;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExitCode;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.cli.command.LintFixDriver;
import anyparse.runtime.Span;

using StringTools;

/**
 * What `lint --fix` says about a finding its own writes left behind: a safe fix can produce the shape another rule
 * reports, and that finding sits on a line the run changed — named on stderr and answered with `EXIT_RESIDUE`, apart
 * from a finding the original text already held.
 */
@:nullSafety(Strict)
class LintFixResidueTest extends Test {

	/** `pick` holds an `if`/`return` pair the safe fix folds into the guard ternary; `old` already is that ternary. */
	private static final SOURCE: String = 'class V {\n\n\tpublic static function pick(a:Null<Int>, b:Int):Int {\n'
		+ '\t\tif (a != null) return a;\n\t\treturn b;\n\t}\n\n\tpublic static function old(a:Null<Int>, b:Int):Int {'
		+ '\n\t\treturn a != null ? a : b;\n\t}\n\n}\n';

	/** The ternary a safe fix wrote is reported by a rule left report-only, on the line the run wrote, and the exit says so. */
	@:pin('control')
	@:killer('M-FIX-RESIDUE-IGNORED')
	public function testAFindingOnAWrittenLineIsReportedWithItsOwnExit(): Void {
		#if (sys || nodejs)
		final run: ResidueRun = fix(SOURCE, pair(), '{}');
		Assert.equals(ExitCode.EXIT_RESIDUE, run.code);
		Assert.notEquals(ExitCode.EXIT_RUNTIME, run.code);
		Assert.isTrue(run.stderr.contains('apq lint --fix: 1 finding(s) on lines this run changed\n'));
		Assert.isTrue(run.stderr.contains('V.hx:4:'));
		#else
		Assert.pass();
		#end
	}

	/** A finding the rewrite creates on a line it left alone is not named: only lines the run wrote are its residue. */
	@:pin('control')
	@:killer('M-FIX-RESIDUE-WHOLE-FILE')
	public function testAFindingOnAnUnchangedLineIsNotReported(): Void {
		#if (sys || nodejs)
		final run: ResidueRun = fix('class V {\n\n\tpublic static var FOO:Int = 1;\n\n}\n', [new Rename(), new Mention()], '{}');
		Assert.isTrue(run.after.contains('BAR'));
		Assert.equals(ExitCode.EXIT_OK, run.code);
		Assert.isFalse(run.stderr.contains('on lines this run changed'));
		#else
		Assert.pass();
		#end
	}

	/** A finding the file held beside the one the run wrote does not hide it: the unchanged line spends the baseline first. */
	@:pin('control')
	@:killer('M-FIX-RESIDUE-ORDER')
	public function testASameKeyedFindingBesideTheWrittenOneDoesNotHideIt(): Void {
		#if (sys || nodejs)
		final run: ResidueRun = fix(SOURCE, pair(), '{}');
		Assert.isTrue(run.stderr.contains('V.hx:4:'));
		Assert.isFalse(run.stderr.contains('V.hx:8:'));
		#else
		Assert.pass();
		#end
	}

	/** The pair is `Info` at its default severity and still the run's own output: no severity setting is needed to name it. */
	@:pin('control')
	@:killer('M-FIX-RESIDUE-INFO')
	public function testAnInfoFindingOnAWrittenLineIsResidue(): Void {
		#if (sys || nodejs)
		final run: ResidueRun = fix(SOURCE, pair(), '{}');
		Assert.equals(ExitCode.EXIT_RESIDUE, run.code);
		Assert.isTrue(run.stderr.contains('V.hx:4:'));
		#else
		Assert.pass();
		#end
	}

	/** With a compiler oracle the risky rule applies too, so nothing is left to report. */
	@:pin('guard')
	public function testWithTheOracleTheRiskyFixAppliesAndNothingIsReported(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_fix_residue', [
			{ name: 'src/V.hx', source: SOURCE.replace('}\n\n}\n', '}\n\n\tstatic function main() {}\n\n}\n') },
			{ name: 'check.hxml', source: '-cp src\n-main V\n--interp\n' }
		]);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			if (!CompilerOracle.typecheck('check.hxml', root).match(Confirmed)) {
				out = 'skipped';
				return;
			}
			final run: ResidueRun = fixIn(root, pair(), '{}', [{ hxml: 'check.hxml', dir: root, defines: [] }]);
			final kept: Bool = File.getContent('$root/src/V.hx').contains('!= null');
			out = '${run.code}|$kept|${run.stderr.contains('on lines this run changed')}';
		});
		if (out == 'skipped')
			Assert.pass('haxe unavailable — skipped')
		else
			Assert.equals('0|false|false', out);
		#else
		Assert.pass();
		#end
	}

	/** A finding the file already held, moved onto a rewritten line with its literal, is the tree's own and not the run's. */
	@:pin('control')
	@:killer('M-FIX-RESIDUE-CARRIED')
	public function testAFindingTheFileAlreadyHeldIsNotResidue(): Void {
		#if (sys || nodejs)
		final chain: String = 'package p;\n\nclass C {\n\tpublic function f(a:Bool, b:Bool):Int {\n\t\tif (a) return 1;\n'
			+ '\t\telse if (b) return 2;\n\t\telse return 3;\n\t}\n}\n';
		final run: ResidueRun = fix(chain, Linter.builtins(), '{}');
		Assert.equals(ExitCode.EXIT_OK, run.code);
		Assert.isFalse(run.stderr.contains('on lines this run changed'));
		#else
		Assert.pass();
		#end
	}

	/** The two rules whose output the fixture shows: the safe fold, and the report-only rule that reads its result. */
	private static function pair(): Array<Check> {
		return [new PreferTernaryReturn(), new PreferNullCoalescing()];
	}

	#if (sys || nodejs)
	/** One `lint --fix` over a fresh copy of `SOURCE`, with the ternary fold and the null-guard rule that reports its output. */
	private static function fix(source: String, checks: Array<Check>, config: String): ResidueRun {
		final root: String = CliFixture.writeTree('apq_fix_residue_run', [{ name: 'src/V.hx', source: source }]);
		var run: Null<ResidueRun> = null;
		CliFixture.always(CliFixture.removeDir.bind(root), () -> run = fixIn(root, checks, config, []));
		return run ?? { code: -1, stderr: '', after: '' };
	}

	/** One `lint --fix` over `src/V.hx` of the tree under `root`. */
	private static function fixIn(root: String, checks: Array<Check>, config: String, oracles: Array<OracleConfig>): ResidueRun {
		final files: Array<{ file: String, source: String }> = [{ file: '$root/src/V.hx', source: File.getContent('$root/src/V.hx') }];
		var code: Int = 0;
		final stderr: String = CliFixture.captureStderr(() ->
			code = LintFixDriver.runLintFix(
				files, checks, new HaxeQueryPlugin(), _ -> LintConfig.parse(config), false, null, oracles, oracles.length == 0, null, false
			)
		);
		return { code: code, stderr: stderr, after: files[0].source };
	}
	#end

}

private typedef ResidueRun = {
	final code: Int;
	final stderr: String;
	final after: String;
};

/** Reports each `FOO` and rewrites it to `BAR`: a fix whose output another check reads elsewhere in the file. */
private class Rename implements Check {

	public function new() {}

	public function id(): String {
		return 'residue-rename';
	}

	public function description(): String {
		return 'rewrites FOO to BAR';
	}

	public function category(): RuleCategory {
		return RuleCategory.Design;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) for (at in occurrences(entry.source)) {
				file: entry.file,
				span: new Span(at, at + 3),
				rule: id(),
				severity: Severity.Warning,
				message: 'a FOO'
			}
		];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [for (v in violations) { span: v.span, text: 'BAR' }];
	}

	private static function occurrences(source: String): Array<Int> {
		final at: Array<Int> = [];
		var from: Int = source.indexOf('FOO');
		while (from >= 0) {
			at.push(from);
			from = source.indexOf('FOO', from + 3);
		}
		return at;
	}

}

/** Reports the first line of a file that spells `BAR`: a finding the rewrite creates away from the line it changed. */
private class Mention implements Check {

	public function new() {}

	public function id(): String {
		return 'residue-mention';
	}

	public function description(): String {
		return 'flags a file that spells BAR';
	}

	public function category(): RuleCategory {
		return RuleCategory.Design;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) if (entry.source.indexOf('BAR') >= 0) {
				file: entry.file,
				span: new Span(0, 5),
				rule: id(),
				severity: Severity.Warning,
				message: 'a BAR'
			}
		];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

}
