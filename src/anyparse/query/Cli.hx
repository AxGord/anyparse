package anyparse.query;

import anyparse.check.Check;
import anyparse.check.Severity;
import anyparse.query.cli.CliCommand;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliIo;
import anyparse.query.cli.CliRegistry;
import anyparse.query.cli.WriteFailure;
import anyparse.runtime.Span;
import anyparse.query.ExitCode.*;

using Lambda;

#if (sys || nodejs)
#end

/**
 * Discriminator on the first-failure locus utest emitted —
 * `Fail` covers `FAIL` / `FAILURE` rows; `Error` covers `ERROR` rows
 * (an unhandled exception inside the test body). Used by callers to
 * pick the user-facing label without string comparison.
 */
enum abstract TestSummaryFailureKind(Int) {

	final Fail = 0;

	final Error = 1;

}

/**
 * First-failure locus captured by `Cli.parseTestSummary` from a utest OR
 * tink_testrunner stdout transcript (format auto-detected — see
 * `parseTestSummary`). `className` is the suite/class header emitted
 * above the test group (utest: unindented CamelCase; tink: the
 * `SuiteName: [file:line]` header); empty string when the transcript
 * doesn't carry one. `testName` is the failing test/case name. `line` is
 * the 1-indexed source line — for utest, decoded from the detail row's
 * `line: N, …` prefix (`-1` when only a bare detail was emitted, since
 * utest's `Print.formatFailure` omits the prefix for plain-string
 * failures); for tink, read directly from the assertion row's own
 * `[file:line]` position (`-1` only for a case-level throw, which has no
 * assertion row at all). `message` is the diagnostic text: utest's
 * detail-row content, or tink's assertion-failure detail line /
 * case-throw message.
 */
typedef TestSummaryFailureLocus = {
	className: String,
	testName: String,
	line: Int,
	message: String,
	kind: TestSummaryFailureKind
};

/**
 * utest's own end-of-run header block, read by SHAPE rather than by
 * position. utest emits it LAST, so everything the tests printed to
 * stdout comes first — a real unfiltered run of this suite puts ~1700
 * lines of CLI chatter ahead of it, and taking the first `results:` line
 * in the file would read a line the TESTS control. Requiring
 * `assertations:` immediately followed by `successes:` opens the block;
 * the counts and `results:` are taken from inside it, so neither end can
 * be spoofed.
 *
 * `ok` is utest's OWN verdict (`results: … (success: true)`), keyed on
 * `ResultStats.isOk = !(hasFailures || hasErrors || hasWarnings)`. It is
 * NOT `failures == 0 && errors == 0`: `ITestHandler` auto-adds
 * `Warning('no assertions')` to any test that completes without
 * asserting, so a change that stops a test asserting produces
 * `failures: 0, warnings: N` — a red run that a failure-row scan would
 * call green. Read the verdict from here, never from the row counts.
 *
 * `assertions` is the header's own `assertations:` value, which counts
 * ignores too. `TestSummaryResult.assertions` REPORTS this number whenever
 * a header is present and falls back to the result rows' dot sum only when
 * there is none: under the quiet reporter a passing test emits no row, so
 * the dot sum is 0 on every green run.
 */
typedef TestSummaryHeader = {
	assertions: Int,
	successes: Int,
	errors: Int,
	failures: Int,
	warnings: Int,
	ok: Bool
};

/**
 * Structured result of parsing a utest OR tink_testrunner stdout
 * transcript. `tests` is the runner's own `tests executed: N` line when the
 * transcript carries one; otherwise it counts PASSING test cases (utest:
 * `OK`-marked test rows; tink: case blocks with no failed/thrown assertion)
 * — the legacy contract, which matches neither framework's own "total run"
 * count and reads 0 under the quiet reporter.
 * `firstFailure` is null when the run had no failures or errors;
 * otherwise it carries the first encountered locus (subsequent failures
 * only bump counters).
 *
 * `header` is utest's own end-of-run block — null for tink, and for a
 * transcript truncated before it. Read `header.ok` for the red/green
 * verdict, never the row counts. `noTests` flags utest's "No tests
 * executed." row, which a filter matching no class produces and which
 * would otherwise read as a clean green run. `failureNames` lists every non-OK result row as `<fq.Class>.<method>`.
 *
 * `counted` says a REPORT was found — utest's header block, a parsed result row,
 * or (for tink) the reporter shape that routed the parse there. It is NOT "some
 * count is non-zero": a suite that ran nothing and a run that died before printing
 * anything both read all-zero, and only the first is an answer.
 */
typedef TestSummaryResult = {
	tests: Int,
	assertions: Int,
	failures: Int,
	errors: Int,
	firstFailure: Null<TestSummaryFailureLocus>,
	header: Null<TestSummaryHeader>,
	noTests: Bool,
	failureNames: Array<String>,
	counted: Bool
};

/**
 * Recon cluster bucket: how many fixtures fall under a normalised
 * forward-locus key, a couple of example file paths, and one raw
 * locus sample for display. The cluster KEY is shared via the map
 * that owns the bucket; only the per-bucket payload lives here.
 *
 * `paths` holds the full path list (every file in the cluster) for
 * `apq recon --cluster <substr>` drill — distinct from `examples`,
 * which is capped at `RECON_EXAMPLES_PER_CLUSTER` for the histogram
 * "e.g. … in: A, B" display.
 */
typedef ReconCluster = {
	var count: Int;
	var examples: Array<String>;
	var paths: Array<String>;
	var rawSample: String;
};

/**
 * What ONE check answered for ONE file's share of its own findings, before the writer-emit gate
 * has had its say: the `findings` it was asked about, the `edits` it produced, whether an earlier
 * check this pass already claimed an overlapping region, and the sentence of whatever gate
 * refused those edits (null while nothing has).
 *
 * The group exists so a refusal can be attributed. `RefactorSupport.canonicalize` round-trips the
 * WHOLE spliced file, so its verdict is per FILE, and a flat edit array left the driver no way to
 * say which check's edits the writer would not write — or to keep the rest.
 */
typedef RuleEdits = {
	final rule: String;
	final findings: Array<Violation>;
	final edits: Array<{ span: Span, text: String }>;
	var overlapped: Bool;
	var refusal: Null<String>;
};

/**
 * `apq` CLI entry point. Parses argv, picks a grammar plugin via
 * `--lang`, dispatches on the subcommand.
 *
 * Phase 1 surface: `apq ast <file> [--lang L] [--json] [--depth N]
 * [--select PATH] [--at LINE:COL] [--min-children N] [--max-children N]`.
 * Other subcommands (`search`,
 * `refs`, `meta`) are reserved — calling them prints a "deferred"
 * notice with the phase that owns each.
 */
@:nullSafety(Strict)
final class Cli {

	public static function main(): Void {
		#if nodejs
		// Set the exit code and let Node exit naturally — do NOT call
		// `Sys.exit` -> `process.exit`. `process.exit` terminates before async
		// `process.stdout`/`stderr` writes to a pipe fd flush, truncating
		// captured output at the ~8 KB pipe buffer (file / TTY fds write
		// synchronously, which is why `apq … > file` was always complete). `run`
		// is fully synchronous, so the event loop empties immediately and Node
		// drains stdout/stderr before exiting with this code.
		js.Node.process.exitCode = run(Sys.args());
		#elseif sys
		Sys.exit(run(Sys.args()));
		#else
		throw 'apq: only sys targets supported';
		#end
	}

	/**
	 * Pure-argv entry. Returns process exit code.
	 *
	 * The one place a `WriteFailure` becomes an exit code again. `writeFile` WAS reached from 31
	 * call sites in this class and from `FixVerifier`'s candidate writes, and only one of them —
	 * `formatOneFile` — caught anything: one unwritable file took the whole run down with a raw
	 * host error, no summary line, and part of the tree already rewritten. Catching at each site
	 * would be 31 catches that each have to decide what their op does next; catching here is the
	 * answer every one of them would have given — say which file, and exit non-zero.
	 *
	 * Only this exception. An internal error still reaches the reader as a stack trace, which is
	 * what a bug wants.
	 */
	public static function run(args: Array<String>): Int {
		try
			return dispatch(args)
		catch (failure: WriteFailure) {
			// Named with the subcommand, like every other line the CLI prints: a bare `apq:` costs
			// a script the identity of the op that failed, and `args[0]` is the op by construction
			// (the empty / `--help` argv returned above).
			CliIo.stderr('apq ${args[0]}: ${failure.message}\n');
			return EXIT_RUNTIME;
		}
	}

	/**
	 * The subcommand switch — every op's entry, and the whole of what `run` wraps.
	 *
	 * Separate from `run` so the write-failure catch has somewhere to sit that is not inside 100
	 * arms: the split is the catch, and nothing else moved.
	 */
	private static function dispatch(args: Array<String>): Int {
		if (args.length == 0 || args[0] == '-h' || args[0] == '--help') {
			printUsage();
			return EXIT_OK;
		}
		final cmd: String = args[0];
		var requireMatch: Bool = false;
		final rest: Array<String> = [];
		for (a in args.slice(1)) if (a == '--exit-on-empty' || a == '--require-match')
			requireMatch = true;
		else
			rest.push(a);
		final registered: Null<CliCommand> = CliRegistry.find(cmd);
		if (registered == null) {
			CliIo.stderr('apq: unknown subcommand "$cmd"\n');
			printUsage();
			return EXIT_USAGE;
		}
		return registered.run(rest, new CliContext(requireMatch));
	}

	private static function printUsage(): Void {
		CliIo.sysPrint('apq — anyparse query CLI\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Usage: apq <command> [options] <file>\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Commands:\n');
		for (command in CliRegistry.commands()) CliIo.sysPrint(CliRegistry.helpLine(command.name()));
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Global options:\n');
		CliIo.sysPrint('  --lang <name>   Pick grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show help\n');
	}

}

/**
 * What `apq fmt` decided, with the summary as DATA.
 *
 * `summary` is empty for every exit taken before a file was read (a usage
 * error, an empty match, a lang with no writer) — those already printed their
 * own sentence, and a count line about a run that never counted anything would
 * be the family's own defect.
 */
typedef FmtRunResult = {
	var exit: Int;
	var summary: String;
};

/**
 * What ONE rule's autofix did over a whole `lint --fix` run — the ledger behind the per-rule
 * "reported but got no edit" block.
 *
 * `reported` is the FIRST pass's finding count (later passes see only what an earlier edit
 * exposed, so summing them would not be a number to compare `fixed N` against). `declined` counts the first-pass findings that got no LANDED edit — either their `Check.fix`
 * answered with none at all, or it answered and the writer-emit gate refused the lot; the
 * measurement, taken where the call happens, that replaces guessing. `edits` accumulates over
 * EVERY pass on purpose: one edit anywhere PROVES the rule can fix, which is exactly the claim
 * a reader of `fixed 0` got wrong twice.
 *
 * `reasons` are the check's own `Violation.declineReason` texts — or, for an edit set the
 * writer-emit gate refused, that gate's sentence — each with the number of DECLINED findings that
 * carried it, never one sentence per rule. First-seen-wins was the shape while every
 * converted rule declined for a single cause; the first rule to adopt the field per-ARM declines for
 * four different ones on one tree (`unused-import`: 110 out-of-scope, 54 `#if`-guarded, 25 unknown
 * `using`, 15 unknown wildcard), and reporting whichever the file walk reached first would state one
 * quarter of the answer with the confidence of the whole. An empty array means the check said
 * nothing and the run must not invent it; a sum below `declined` means it spoke for only some.
 *
 * `refusals` counts the writer-emit gate's own refusals, per sentence, over EVERY pass, in EDIT
 * SETS rather than findings — the one thing `declined` cannot carry. `declined` is deliberately a
 * FIRST-pass measurement, because a later pass re-reports whatever an earlier edit exposed and summing those would count one finding
 * several times; but a gate refusal that first happens on pass 2 is no re-report, it is the only
 * word anyone gets about why that fix vanished, and it used to reach no report at all.
 *
 * `gateRefusalLines` renders it, in a block of its own under the ledger: an edit-set count and a
 * finding count are different quantities and one header cannot total both.
 */
typedef RuleFixOutcome = {
	var reported: Int;
	var declined: Int;
	var edits: Int;
	var reasons: Array<{ text: String, count: Int }>;
	var refusals: Array<{ text: String, count: Int }>;
};
