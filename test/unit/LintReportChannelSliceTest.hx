package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.query.Cli;
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
	 * RED at base on the two machine arms (both answered 1 of 2). The text arms are green at base
	 * BY CONSTRUCTION and are the discriminator: lift the cap for every format and the third
	 * assertion goes red while the machine ones stay green.
	 */
	public function testMachineFormatsAreNotSubjectToTheInfoCap(): Void {
		Assert.equals(2, Cli.reportedViolations(findings(), false, 'json').length, 'json is a machine reader — it gets everything');
		Assert.equals(2, Cli.reportedViolations(findings(), false, 'checkstyle').length, 'and so is checkstyle, by the same argument');
		Assert.equals(
			1, Cli.reportedViolations(findings(), false, 'text').length, 'the TEXT report still caps — that is what --all is for'
		);
		Assert.equals(2, Cli.reportedViolations(findings(), true, 'text').length, 'and --all lifts it');
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

		final mixed: ExpandedInputs = Cli.expandInputs([dir, missing], '.hx');
		Assert.equals(1, mixed.paths.length, 'the spec that DID match still resolves');
		Assert.equals(1, mixed.unmatched.length, 'and the one that did not is named rather than dropped');
		Assert.equals(missing, mixed.unmatched[0]);

		final allGood: ExpandedInputs = Cli.expandInputs([dir], '.hx');
		Assert.equals(0, allGood.unmatched.length, 'a scope where every argument matched names nothing');

		final noneGood: ExpandedInputs = Cli.expandInputs([missing, '$dir/AlsoMissing.hx'], '.hx');
		Assert.equals(0, noneGood.paths.length);
		Assert.equals(2, noneGood.unmatched.length, 'the wholly-empty case names each argument, not the joined list');

		// END TO END, and RED at base by BEHAVIOUR: the mixed scope is still a SUCCESSFUL run —
		// naming the miss is a diagnostic, not a new failure mode — but the run now SAYS which
		// argument it could not find, where base said nothing at all.
		var exit: Int = -1;
		final noise: String = captureStderr(() -> exit = Cli.run(['lint', '--rule', 'prefer-single-quotes', '--no-oracle', dir, missing]));
		Assert.equals(0, exit, 'a scope argument that matched nothing does not fail the run');
		Assert.isTrue(noise.indexOf('NoSuchFile.hx') != -1, 'the run names the argument it could not find: $noise');
		Assert.isTrue(noise.indexOf('"$missing"') != -1, 'and quotes it, so its boundaries are visible: $noise');

		// And it says it ONCE: when NOTHING matched, the command's own `matched no .hx files` line
		// already names every argument, so the per-spec note would be the same fact twice.
		final onlyMissing: String = captureStderr(() -> Cli.run(['lint', '--rule', 'prefer-single-quotes', '--no-oracle', missing]));
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
		final missing: String = Cli.realPath('/private/tmp/apq-s9-no-such-dir/NoSuchFile.hx');
		Assert.notNull(missing);
		Assert.notEquals('', missing);
		Assert.notEquals('null', missing, 'a null that reached string conversion would key the dedup map under "null"');
		Assert.isTrue(haxe.io.Path.isAbsolute(missing), 'the fallback still normalises: $missing');
		// A path that DOES resolve is the discriminator — green before the bridge and after it, so
		// it separates "the fallback works" from "the fallback replaced the real answer".
		final here: String = Cli.realPath('.');
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
		Assert.equals('"a.hx", "b.hx"', Cli.quotedSpecs(['a.hx', 'b.hx']));
		Assert.equals('"a.hx\nb.hx"', Cli.quotedSpecs(['a.hx\nb.hx']), 'one argument holding a newline reads as ONE argument');
		Assert.equals(
			'"a\\"b.hx"', Cli.quotedSpecs(['a"b.hx']),
			'and a quote INSIDE an argument is escaped — unescaped it would read as two arguments, the very misreading the quotes add'
		);
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

	/**
	 * The same for stderr, where every `apq` diagnostic goes.
	 *
	 * NOT `process.stderr`: `Cli.stderr` writes through `Sys.stderr()`, which hxnodejs implements
	 * as `fs.writeSync(2, …)` — swapping the stream's `write` captures nothing, and the arm reads
	 * as "the tool printed nothing" whether or not it did.
	 */
	private static function captureStderr(fn: () -> Void): String {
		#if nodejs
		final buffer: Array<String> = [];
		final fs: Dynamic = js.Syntax.code('require("fs")'); // noqa: avoid-dynamic
		final original: Dynamic = fs.writeSync; // noqa: avoid-dynamic
		fs.writeSync = js.Syntax.code(
			'function(fd, data) { if (fd === 2) { {0}.push(String(data)); return 0; } return {1}.apply(null, arguments); }', buffer,
			original
		);
		try fn() catch (exception: haxe.Exception) {
			fs.writeSync = original;
			throw exception;
		}
		fs.writeSync = original;
		return buffer.join('');
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

}
