import testkit.TestRegistry;
import utest.Runner;

/**
 * Entry point for the test suite.
 *
 * The registration layer is GENERATED: `testkit.TestRegistry` is built by
 * `testkit.TestDiscovery`, which walks every package under `test/` and
 * registers each `utest.Test` subclass that carries a fixture. This file
 * used to carry one hand-written `addCase(new X())` per class — 758 of
 * them, plus 758 imports — and a forgotten line there was a test that
 * silently never ran, with nothing in the transcript to say so.
 *
 * What is NOT generated is everything below: the `APQ_TEST` filter, the
 * quiet reporter, the per-test stdout buffering and the executed-count
 * line the gates parse. Those are harness, and they are the reason this
 * class exists at all.
 */
class RunTests {

	public static function main(): Void {
		if (listing()) return;
		final runner: Runner = new Runner();

		// Optional test-class filter for a fast dev inner-loop: APQ_TEST is a
		// comma-separated list of substrings; only test classes whose fully
		// qualified name contains one of them are run. Unset / empty → run
		// every case (the full suite, e.g. before a commit). Substring match,
		// so `APQ_TEST=RemoveParam` runs RemoveParamSliceTest and `APQ_TEST=Apq`
		// runs all `Apq*` tests; comma-separated to run a slice + its siblings.
		final filterEnv: Null<String> = Sys.getEnv('APQ_TEST');
		final filters: Array<String> = filterEnv == null ? [] : [
			for (f in filterEnv.split(',')) if (StringTools.trim(f) != '') StringTools.trim(f)
		];
		function addCase(testCase: utest.Test): Void {
			if (filters.length == 0) {
				runner.addCase(testCase);
				return;
			}
			final className: String = Type.getClassName(Type.getClass(testCase));
			for (filter in filters) if (className.indexOf(filter) >= 0) {
				runner.addCase(testCase);
				return;
			}
		}
		TestRegistry.addAll(addCase);
		// Quiet by DEFAULT. utest's own default is `ShowSuccessResultsWithNoErrors`,
		// which prints one line per passing method: on this suite that is 13 488 lines
		// / ~800 KB, against the six-line summary every gate actually reads. For a
		// delegated run that single difference dominates the whole token cost, so the
		// listing is off unless asked for.
		//
		// `NeverShowSuccessResults` drops ONLY the passing lines — `ReportTools.skipResult`
		// returns false for `!stats.isOk`, so every failure, error and warning still
		// prints in full, with its message and stack.
		//
		// `AlwaysShowHeader` is LOAD-BEARING and not decoration: under the default
		// `ShowHeaderWithResults`, `ReportTools.hasHeader` returns FALSE for a green run
		// once success results are hidden — the summary the gates grep would vanish with
		// the noise. Passing it explicitly is what keeps `successes:` / `errors:` /
		// `failures:` on stdout.
		//
		// `APQ_TEST_VERBOSE=1` restores the per-method listing for a human reading one run.
		// A passing test's own stdout is noise. The CLI e2e tests drive `Cli.run`,
		// which prints progress and summaries; on a green suite that is ~119 KB nobody
		// reads, and for a delegated run it is pure token cost. Buffer each test's
		// stdout and DISCARD it when the test passes; a test with any non-Success
		// assertation gets its buffer flushed verbatim, so a failure keeps the context
		// that explains it.
		//
		// Only stdout is interceptable. `Sys.stderr()` on hxnodejs writes a RAW FD and
		// bypasses `process.stderr.write` entirely — measured: patching both captured
		// 118 706 bytes of stdout and 0 of stderr, while 74 514 bytes still reached the
		// terminal. That half can only be dropped at the shell (`2>/dev/null`), which
		// is why the protocol says so rather than this code pretending to handle it.
		final verbose: Bool = Sys.getEnv('APQ_TEST_VERBOSE') != null;
		#if nodejs
		if (!verbose) {
			final out = js.Node.process.stdout;
			final passThrough: Dynamic = untyped out.write;
			var buffer: Null<StringBuf> = null;
			untyped out.write = function(chunk: Dynamic, ?enc: Dynamic, ?cb: Dynamic): Bool {
				final buf = buffer;
				if (buf == null) return passThrough.call(out, chunk, enc, cb);
				buf.add(Std.string(chunk));
				if (cb != null) cb();
				return true;
			};
			runner.onTestStart.add(function(_): Void buffer = new StringBuf());
			runner.onTestComplete.add(function(h): Void {
				final buf = buffer;
				buffer = null;
				if (buf == null) return;
				for (a in h.results) switch a {
					case Success(_), Ignore(_):
					case _:
						passThrough.call(out, buf.toString(), null, null);
						return;
				}
			});
		}
		#end
		// utest's own end-of-run block carries assertions but no test total, and
		// the quiet reporter prints no row for a passing test — so a green
		// transcript used to carry NO countable test count at all: `apq
		// test-summary` read `0 tests / 0 assertions` off one and
		// `tools/suite-shard.sh` hard-failed on that zero. Emit the total here,
		// counted off the runner's own completion events rather than off
		// `runner.length`, so a run that dies mid-way prints neither this line
		// nor utest's block and the transcript stays visibly UNCOUNTABLE instead
		// of reporting a plausible registered-fixture number.
		//
		// Registered before `Report.create` on purpose: the report's own
		// `onComplete` handler calls `process.exit` from inside the dispatch, so
		// a listener added after it never runs.
		var executed: Int = 0;
		runner.onTestComplete.add(_ -> executed++);
		runner.onComplete.add(_ -> Sys.println('tests executed: $executed'));
		utest.ui.Report.create(runner, verbose ? AlwaysShowSuccessResults : NeverShowSuccessResults, AlwaysShowHeader);
		runner.run();
	}

	/**
	 * `--list-classes` / `--list-dead` / `--list-bases` / `--list-pins` print one
	 * view of the generated registry and exit before a single fixture runs.
	 *
	 * `tools/suite-shard.sh` deals its shard plan off the first of them, so the
	 * class list a shard is filtered by is the one the runner will actually
	 * register. Nothing re-derives that list by parsing a source file — the
	 * generated registry is the only place it exists.
	 */
	private static function listing(): Bool {
		final args: Array<String> = Sys.args();
		final lines: Null<Array<String>> = if (args.contains('--list-classes'))
			TestRegistry.classNames();
		else if (args.contains('--list-dead'))
			TestRegistry.deadTests();
		else if (args.contains('--list-bases'))
			TestRegistry.baseClasses();
		else if (args.contains('--list-pins'))
			TestRegistry.pins();
		else
			null;
		if (lines == null) return false;
		for (line in lines) Sys.println(line);
		return true;
	}

}
