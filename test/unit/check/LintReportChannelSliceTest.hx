package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.query.Cli;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.command.LintCommand;
import anyparse.query.format.LintFormat;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The two lint CLI channels that answered less than the run knew, without saying so.
 *
 * A machine `--format` and a scope ARGUMENT are both consumed by something that cannot read a
 * stderr aside: the first is a redirected stdout, the second is whatever the caller believed it
 * asked for. In both places the run held the missing half and simply did not put it anywhere the
 * consumer would see — which is a confidently wrong answer, not a missing one:
 *
 *  - `--format json` honoured the `--all` info cap, so a run holding only advisories printed `[]`
 *    on stdout while `--fail-on info` — which counts every finding, capped or not — exited 1 on
 *    that same run. The payload and the exit code disagreed;
 *  - a scope argument matching no `.hx` file vanished into the union the moment ANY other argument
 *    matched, so a lint over a list with one bad path analysed a smaller scope than it was given
 *    and reported success.
 *
 * Both are pinned at their seat rather than through stdout: `Cli.run` prints with `Sys.print` and
 * this suite has no in-process capture for it, so the assertions drive the two functions that
 * decide — `reportedViolations` and `expandInputs` — with the same arguments `runLint` passes them.
 */
@:access(anyparse.query.Cli)
@:nullSafety(Strict)
class LintReportChannelSliceTest extends Test {

	/** A fixture whose ONLY finding is an `Info` advisory — the run whose json payload used to be `[]`. */
	private static inline final ADVISORY: String = 'package pkg;\n\nclass C {\n\n\tpublic function new() {}\n\n\tpublic function f(s: String): Bool {\n'
		+ '\t\treturn StringTools.endsWith(s, \'x\');\n\t}\n\n}\n';

	/**
	 * A machine format carries every finding the run produced; the text report still caps.
	 *
	 * RED at base on the two machine arms (both answered the capped count). The text arms are green at base
	 * BY CONSTRUCTION and are the discriminator: lift the cap for every format and the third
	 * assertion goes red while the machine ones stay green.
	 */
	public function testMachineFormatsAreNotSubjectToTheInfoCap(): Void {
		Assert.equals(2, LintCommand.reportedViolations(findings(), false, 'json').length, 'json is a machine reader — it gets everything');
		Assert.equals(
			2, LintCommand.reportedViolations(findings(), false, 'checkstyle').length, 'and so is checkstyle, by the same argument'
		);
		Assert.equals(
			1, LintCommand.reportedViolations(findings(), false, 'text').length, 'the TEXT report still caps — that is what --all is for'
		);
		Assert.equals(2, LintCommand.reportedViolations(findings(), true, 'text').length, 'and --all lifts it');
	}

	/**
	 * The same, END TO END through `Cli.run`: the bytes a `--format json` consumer receives carry
	 * the advisory, and the run's exit code agrees with them.
	 *
	 * This is the arm that is RED at base by BEHAVIOUR rather than by a missing seam — base prints
	 * `[]` for this fixture while `--fail-on info` on it exits 1. The text arm beside it is the
	 * discriminator and is green at base: the human report must still cap.
	 */
	public function testTheJsonAConsumerReceivesAgreesWithTheExitCode(): Void {
		// `#if nodejs`, not `(sys || nodejs)`: the capture is a `process.stdout.write` swap, so on any
		// other sys target it would silently return the empty string and the assertions below would
		// read a working tool as a broken one.
		#if nodejs
		final dir: String = CliFixture.writeDir('lintjson', [{ name: 'C.hx', source: ADVISORY }]);
		final args: Array<String> = [
			'lint',
			'--rule',
			'prefer-static-extension',
			'--no-oracle',
			'--format',
			'json',
			dir
		];
		var exit: Int = 0;
		final json: String = captureStdout(() -> exit = Cli.run(args.concat(['--fail-on', 'info'])));
		Assert.equals(1, exit, 'the run has an Info finding, so --fail-on info gates on it');
		Assert.isTrue(json.indexOf('prefer-static-extension') != -1, 'and the json payload carries it: $json');

		final text: String = captureStdout(() -> Cli.run(['lint', '--rule', 'prefer-static-extension', '--no-oracle', dir]));
		Assert.equals('', text.trim(), 'the TEXT report still withholds an uncapped advisory');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	/**
	 * `expandInputs` reports every spec that expanded to nothing, whatever the others did.
	 *
	 * RED at base on all three `unmatched` assertions — the record had no such field, and the union
	 * alone cannot answer for a spec that matched nothing beside one that did. The `paths`
	 * assertions are green at base and are the discriminator: they pin that naming the miss did not
	 * change WHICH files a mixed scope resolves to.
	 */
	public function testAScopeArgumentThatMatchedNothingIsNamed(): Void {
		// `#if nodejs` for the same reason as the arm above: the stderr half is an `fs.writeSync` swap.
		#if nodejs
		final dir: String = CliFixture.writeDir('lintchan', [{ name: 'C.hx', source: 'package pkg;\n\nclass C {}\n' }]);
		final missing: String = '$dir/NoSuchFile.hx';

		final mixed: ExpandedInputs = CliArgs.expandInputs([dir, missing], '.hx');
		Assert.equals(1, mixed.paths.length, 'the spec that DID match still resolves');
		Assert.equals(1, mixed.unmatched.length, 'and the one that did not is named rather than dropped');
		Assert.equals(missing, mixed.unmatched[0]);

		final allGood: ExpandedInputs = CliArgs.expandInputs([dir], '.hx');
		Assert.equals(0, allGood.unmatched.length, 'a scope where every argument matched names nothing');

		final noneGood: ExpandedInputs = CliArgs.expandInputs([missing, '$dir/AlsoMissing.hx'], '.hx');
		Assert.equals(0, noneGood.paths.length);
		Assert.equals(2, noneGood.unmatched.length, 'the wholly-empty case names each argument, not the joined list');

		// END TO END, and RED at base by BEHAVIOUR: the mixed scope is still a SUCCESSFUL run —
		// naming the miss is a diagnostic, not a new failure mode — but the run now SAYS which
		// argument it could not find, where base said nothing at all.
		var exit: Int = -1;
		final noise: String = CliFixture.captureStderr(() ->
			exit = Cli.run(['lint', '--rule', 'prefer-single-quotes', '--no-oracle', dir, missing])
		);
		Assert.equals(0, exit, 'a scope argument that matched nothing does not fail the run');
		Assert.isTrue(noise.indexOf('NoSuchFile.hx') != -1, 'the run names the argument it could not find: $noise');
		Assert.isTrue(noise.indexOf('"$missing"') != -1, 'and quotes it, so its boundaries are visible: $noise');

		// And it says it ONCE: when NOTHING matched, the command's own `matched no .hx files` line
		// already names every argument, so the per-spec note would be the same fact twice.
		final onlyMissing: String = CliFixture.captureStderr(() ->
			Cli.run(['lint', '--rule', 'prefer-single-quotes', '--no-oracle', missing])
		);
		Assert.isTrue(onlyMissing.indexOf('matched no .hx files') != -1, onlyMissing);
		Assert.equals(-1, onlyMissing.indexOf('were skipped'), 'a wholly-unmatched scope is reported once, not twice: $onlyMissing');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stderr capture needs the node target');
		#end
	}

	/**
	 * `realPath` never answers null or empty, whatever it is handed.
	 *
	 * The call inside it does not promise that. `sys.FileSystem.fullPath` is DECLARED to return a
	 * non-null `String` and on hxnodejs RETURNS NULL for a path that is not there — it does not
	 * throw, so the `catch` alone never sees it and `@:nullSafety(Strict)` trusts the declaration.
	 * The value is a Map KEY here, so an unbridged null keys every unresolvable path under the one
	 * string "null": a report path and a library path that both fail collapse onto it and the
	 * library file is silently dropped from the resolution scope.
	 *
	 * RED against the first draft of this slice, which caught and fell back but never tested for
	 * null. The existing symlink arm in `ResolutionScopeCliTest` cannot reach this — every path it
	 * gives exists, which is exactly the branch where `fullPath` succeeds.
	 */
	public function testRealPathNeverAnswersNullForAPathThatIsNotThere(): Void {
		#if (sys || nodejs)
		final missing: String = LintCommand.realPath('/private/tmp/apq-s9-no-such-dir/NoSuchFile.hx');
		Assert.notNull(missing);
		Assert.notEquals('', missing);
		Assert.notEquals('null', missing, 'a null that reached string conversion would key the dedup map under "null"');
		Assert.isTrue(haxe.io.Path.isAbsolute(missing), 'the fallback still normalises: $missing');
		// A path that DOES resolve is the discriminator — green before the bridge and after it, so
		// it separates "the fallback works" from "the fallback replaced the real answer".
		final here: String = LintCommand.realPath('.');
		Assert.notNull(here);
		Assert.isTrue(haxe.io.Path.isAbsolute(here), here);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A spec is quoted in the diagnostics, so an argument carrying whitespace cannot pass for a
	 * list of arguments.
	 *
	 * Green at base only in the sense that nothing quoted anything: the assertion is RED at base
	 * because `quotedSpecs` did not exist and the messages joined the raw strings. It is here
	 * because that unquoted rendering is what made one earlier report read a caller's un-split
	 * argument list as the tool losing a path — the message showed a column of paths, which is
	 * exactly what a correct invocation would have shown.
	 */
	public function testASpecIsQuotedSoItsBoundariesAreVisible(): Void {
		Assert.equals('"a.hx", "b.hx"', CliArgs.quotedSpecs(['a.hx', 'b.hx']));
		Assert.equals('"a.hx\nb.hx"', CliArgs.quotedSpecs(['a.hx\nb.hx']), 'one argument holding a newline reads as ONE argument');
		Assert.equals(
			'"a\\"b.hx"', CliArgs.quotedSpecs(['a"b.hx']),
			'and a quote INSIDE an argument is escaped — unescaped it would read as two arguments, the very misreading the quotes add'
		);
	}

	/**
	 * The threshold decides between the list and the summary, and nothing else does except the two flags.
	 *
	 * RED under M-LINT-SUMMARY-NEVER (the decision always answers "list"): every `isTrue` below goes red,
	 * while the `isFalse` arms — at the threshold, a machine format, a non-positive threshold, `--full` —
	 * stay green and are what separate "summarises over the threshold" from "summarises always".
	 */
	@:pin('control')
	@:killer('M-LINT-SUMMARY-NEVER')
	public function testTheThresholdDecidesBetweenListAndSummary(): Void {
		Assert.isTrue(LintCommand.summarises(201, 'text', null, 200), 'over the threshold is summarised');
		Assert.isFalse(LintCommand.summarises(200, 'text', null, 200), 'AT the threshold still lists');
		Assert.isFalse(LintCommand.summarises(5000, 'json', null, 200), 'json always lists');
		Assert.isFalse(LintCommand.summarises(5000, 'checkstyle', true, 200), 'checkstyle too, whatever is forced');
		Assert.isFalse(LintCommand.summarises(5000, 'text', null, 0), 'a threshold of zero never summarises');
		Assert.isFalse(LintCommand.summarises(5000, 'text', false, 200), '--full lists over the threshold');
		Assert.isTrue(LintCommand.summarises(1, 'text', true, 200), '--summary summarises under it');
	}

	/**
	 * A summary of several rules is one line per rule, most findings first, each with its top files; a
	 * summary of ONE rule is a by-file breakdown instead.
	 *
	 * RED under M-LINT-SUMMARY-ONE-SHAPE (the single-rule branch cut, so one rule gets the inline top-3
	 * line): the one-per-line file rows and the `+N more file(s)` tail go red. The multi-rule
	 * assertions are green under the arm and pin that the cut changed only the one-rule shape.
	 */
	@:pin('control')
	@:killer('M-LINT-SUMMARY-ONE-SHAPE')
	public function testASummaryIsPerRuleAndOneRuleIsByFile(): Void {
		final many: Array<Violation> = [
			for (i in 0...12) finding('F$i.hx', 'rule-a', Severity.Warning)
		].concat([
			finding('F0.hx', 'rule-a', Severity.Warning),
			finding('G.hx', 'rule-b', Severity.Error)
		]);
		final mixed: String = LintFormat.summary(many.concat([finding('G.hx', 'rule-b', Severity.Info)]));
		final lines: Array<String> = mixed.split('\n');
		Assert.isTrue(lines[0].startsWith('rule-a  13  warning  12 file(s)'), 'the rule with most findings leads: $mixed');
		Assert.equals('    F0.hx (2), F1.hx (1), F10.hx (1), +9 more', lines[1], 'its top 3 files, most first, the rest counted');
		Assert.isTrue(lines[2].startsWith('rule-b   2  error/info  1 file(s)'), 'a rule at two severities names both, worst first: $mixed');

		final one: String = LintFormat.summary(many.filter(v -> v.rule == 'rule-a'));
		final rows: Array<String> = one.split('\n');
		Assert.equals('rule-a  13  warning  12 file(s)', rows[0]);
		Assert.equals('   2  F0.hx', rows[1], 'one rule lists its files one per line: $one');
		Assert.equals(13, rows.length, 'the header, ten file rows, the tail and the trailing newline: $one');
		Assert.equals('  ... +2 more file(s)', rows[11]);
	}

	/**
	 * END TO END: a text run over its `reportSummaryThreshold` prints the summary on stdout and the way
	 * to the full list on stderr; `--full` restores the list; `--summary` with a machine format is refused.
	 *
	 * RED under M-LINT-SUMMARY-THRESHOLD-UNREAD (the config key ignored, so the default 200 applies and
	 * three findings are listed): the summary assertions go red. The `--full` and refusal arms are green
	 * under it and pin that the flags do not ride on the config.
	 */
	@:pin('control')
	@:killer('M-LINT-SUMMARY-THRESHOLD-UNREAD')
	public function testATextRunOverTheThresholdPrintsTheSummary(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('lintsum', [
			{ name: 'apqlint.json', source: '{ "reportSummaryThreshold": 2 }' },
			{
				name: 'C.hx',
				source: 'package pkg;\n\nclass C {\n\n\tpublic function f(k: Int): Int {\n\t\treturn k * 7 + k * 9 + k * 11;\n\t}\n\n}\n'
			}
		]);
		final args: Array<String> = ['lint', '--rule', 'magic-number', '--no-oracle', dir];
		var summary: String = '';
		final noise: String = CliFixture.captureStderr(() -> summary = captureStdout(() -> Cli.run(args)));
		Assert.isTrue(summary.startsWith('magic-number  3  warning  1 file(s)\n'), 'three findings over a threshold of 2: $summary');
		Assert.equals(-1, summary.indexOf(':6:'), 'and no finding is listed: $summary');
		Assert.isTrue(noise.indexOf('the full list: --full') != -1, 'stderr names the way back: $noise');

		final full: String = captureStdout(() -> Cli.run(args.concat(['--full'])));
		Assert.equals(3, full.split('\n').filter(l -> l.indexOf('magic number') != -1).length, '--full lists all three: $full');

		var exit: Int = 0;
		CliFixture.captureStderr(() -> exit = Cli.run(args.concat(['--summary', '--format', 'json'])));
		Assert.equals(2, exit, 'a summary of a machine format is a usage error');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	/**
	 * `fn`'s writes to stdout, captured.
	 *
	 * `Cli.run` reports through `Sys.print`, which on node is `process.stdout.write` — there is no
	 * other seam, and without one the arms below could only assert the FUNCTION that decides rather
	 * than the bytes a consumer receives. The original is restored on the exception path too, or a
	 * failure here would silence the rest of the suite.
	 */
	private static function captureStdout(fn: () -> Void): String {
		#if nodejs
		return captureOn(js.Syntax.code('process.stdout'), fn);
		#else
		fn();
		return '';
		#end
	}

	/** The shared swap: `stream.write` collects instead of writing, and is restored on both paths.
	 *
	 * `Dynamic` throughout because the subject is a raw node stream object and the swap replaces one of
	 * its properties — `Any` permits neither the read nor the write. */
	private static function captureOn(stream: Dynamic, fn: () -> Void): String { // noqa: avoid-dynamic
		final buffer: Array<String> = [];
		final original: Dynamic = stream.write; // noqa: avoid-dynamic
		stream.write = (chunk: Dynamic) -> { // noqa: avoid-dynamic
			buffer.push(Std.string(chunk));
			return true;
		};
		try fn() catch (exception: haxe.Exception) {
			stream.write = original;
			throw exception;
		}
		stream.write = original;
		return buffer.join('');
	}

	/** One advisory and one warning — the mix that makes a capped report differ from an uncapped one. */
	private static function findings(): Array<Violation> {
		return [
			{
				file: 'C.hx',
				span: null,
				rule: 'demo-info',
				severity: Severity.Info,
				message: 'an advisory'
			},
			{
				file: 'C.hx',
				span: null,
				rule: 'demo-warn',
				severity: Severity.Warning,
				message: 'a warning'
			}
		];
	}

	/** A span-less finding of `rule` at `severity` in `file`. */
	private static function finding(file: String, rule: String, severity: Severity): Violation {
		return {
			file: file,
			span: null,
			rule: rule,
			severity: severity,
			message: 'm'
		};
	}

}
