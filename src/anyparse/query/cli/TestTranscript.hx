package anyparse.query.cli;

import anyparse.query.Cli.TestSummaryFailureKind;
import anyparse.query.Cli.TestSummaryFailureLocus;
import anyparse.query.Cli.TestSummaryHeader;
import anyparse.query.Cli.TestSummaryResult;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * A utest / tink_testrunner stdout transcript, parsed.
 *
 * `test-summary` prints it and `mutation-verdict` classifies it, so the parser
 * is shared by two commands and owned by neither. `Cli.parseTestSummary` stays
 * as the published entry point — tests outside this package call it by that
 * name, and the two module-level types it answers with are sub-module types of
 * `anyparse.query.Cli`.
 */
@:nullSafety(Strict)
final class TestTranscript {

	#if (sys || nodejs)
	/**
	 * Pure parser over a utest OR tink_testrunner stdout transcript.
	 * Exposed for unit tests so the structured result (counts +
	 * first-failure locus) can be asserted directly without the
	 * stdout-capture round-trip Cli.run would impose.
	 *
	 * ANSI color escapes are stripped first (see `stripAnsi`) so neither
	 * format's regexes need to tolerate embedded `ESC[...m` sequences,
	 * then `looksLikeTinkTranscript` picks the parser: tink_testrunner's
	 * shape (`- [OK]/[FAIL] [file:line] ...` rows, `N Assertions   N
	 * Success   ...` summary — see `parseTinkTestSummary`) or, by
	 * default, utest's.
	 *
	 * utest line shape recognition (utest 1.13.x):
	 *  - `  testName: OK <dots>` — pass; dot-count adds to assertions.
	 *  - `  testName: FAIL[URE] <…>` — failure counter.
	 *  - `  testName: ERR[OR] <…>` — error counter.
	 *  - `ClassName` (unindented CamelCase token, no colon) — class header;
	 *    tracked so first-failure carries its qualifier.
	 *  - `    <detail>` (4-space indent) following a fail/err — the
	 *    failure's detail line. `line: N, <msg>` and
	 *    `fileName: X, line: N, <msg>` shapes are decoded into structured
	 *    fields; bare detail falls into `message`.
	 *
	 * The detail capture only fires for the FIRST fail/err — once
	 * `firstFailure` is set, subsequent failures only bump counters.
	 */
	public static function parseTestSummary(raw: String): TestSummaryResult {
		final lines: Array<String> = stripAnsi(raw).split('\n');
		if (looksLikeTinkTranscript(lines)) return parseTinkTestSummary(lines);
		final okRe: EReg = ~/^\s+(\w[\w.]*):\s+OK(\s+(\.+))?/;
		final failRe: EReg = ~/^\s+(\w[\w.]*):\s+FAIL/;
		final errRe: EReg = ~/^\s+(\w[\w.]*):\s+ERR/;
		final classRe: EReg = ~/^([A-Z]\w*)$/;
		final detailFullRe: EReg = ~/^\s*fileName:\s*([^,]+),\s*line:\s*(\d+),\s*(.*)$/;
		final detailLineRe: EReg = ~/^\s*line:\s*(\d+),\s*(.*)$/;
		// Bare-message detail: any non-zero indent + non-empty content.
		// Widened from `\s{4,}` because utest's indent isn't guaranteed
		// 4-space (tabs / 2-space variants exist in older transcripts).
		final detailBareRe: EReg = ~/^\s+(\S.*)$/;
		// "No tests executed." arrives as an ordinary assertion-detail row,
		// so match that row's SHAPE: an unanchored search would also fire on
		// a test whose own message quotes the phrase.
		final noTestsRe: EReg = ~/^\s*line: \d*, No tests executed\.$/;
		var tests: Int = 0;
		var assertions: Int = 0;
		var failures: Int = 0;
		var errors: Int = 0;
		var currentClass: String = '';
		var firstFailure: Null<TestSummaryFailureLocus> = null;
		var awaitingDetail: Bool = false;
		var noTests: Bool = false;
		for (line in lines) {
			if (!noTests && noTestsRe.match(line)) noTests = true;
			if (awaitingDetail) {
				awaitingDetail = false;
				final locus: Null<TestSummaryFailureLocus> = firstFailure;
				if (locus != null && tryCaptureDetail(locus, line, detailFullRe, detailLineRe, detailBareRe)) continue;
				// Fall through: the line was NOT a detail row (utest emitted
				// no detail for this failure, or the next test row arrived
				// immediately). Re-process via the normal regex chain so we
				// don't silently swallow it.
			}
			if (okRe.match(line)) {
				tests++;
				final dots: Null<String> = try okRe.matched(3) catch (_: Exception) null; // noqa: magic-number
				if (dots != null) assertions += (dots: String).length;
			} else if (failRe.match(line)) {
				failures++;
				if (firstFailure == null) {
					firstFailure = {
						className: currentClass,
						testName: failRe.matched(1),
						line: -1,
						message: '',
						kind: TestSummaryFailureKind.Fail
					};
					awaitingDetail = true;
				}
			} else if (errRe.match(line)) {
				errors++;
				if (firstFailure == null) {
					firstFailure = {
						className: currentClass,
						testName: errRe.matched(1),
						line: -1,
						message: '',
						kind: TestSummaryFailureKind.Error
					};
					awaitingDetail = true;
				}
			} else if (classRe.match(line)) {
				currentClass = classRe.matched(1);
			}
		}
		// The header is utest's own totals and outranks the rows whenever it is
		// present: under the quiet reporter (`NeverShowSuccessResults`) a passing
		// test emits no row at all, so the dot sum is 0 on every green run while
		// `assertations:` still carries the real figure. Failure and error counts
		// stay row-derived — failing rows ARE still printed, and the rows count
		// TESTS where the header counts assertations.
		final block: Null<TestSummaryHeader> = readTestSummaryHeader(lines);
		// The `tests executed:` line is trusted ONLY alongside utest's own block,
		// because the runner prints the two together — the line, then the block, both
		// after every test's output. Read on its own it is forgeable: a transcript
		// that dies mid-run after a failing test whose flushed stdout happens to carry
		// the phrase reported `999 tests` at exit 0, for a run that never reached a
		// report at all.
		final executed: Null<Int> = block != null ? readExecutedCount(lines) : null;
		return {
			tests: executed ?? tests,
			assertions: block != null ? block.assertions : assertions,
			failures: failures,
			errors: errors,
			firstFailure: firstFailure,
			header: block,
			noTests: noTests,
			failureNames: collectFailureNames(lines),
			counted: sawUtestReport(block, tests, failures, errors)
		};
	}

	/**
	 * utest's end-of-run header block, or null when the transcript carries
	 * none (truncated, or a framework that emits no such block).
	 *
	 * Its own pass over the lines rather than a branch inside
	 * `parseTestSummary`'s loop: the two read different things — that loop
	 * reads the per-class RESULT ROWS, this reads the summary — and folding
	 * the state machine in pushed the function past the complexity gate for
	 * no shared work. Three cheap passes over a transcript beat one
	 * unreadable one.
	 *
	 * The shape anchoring is the whole point; `TestSummaryHeader` documents
	 * why the first `results:` line in the file is the wrong one to read.
	 */
	private static function readTestSummaryHeader(lines: Array<String>): Null<TestSummaryHeader> {
		final assertRe: EReg = ~/^assertations:\s+(\d+)$/;
		final successRe: EReg = ~/^successes:\s+(\d+)$/;
		final countRe: EReg = ~/^(errors|failures|warnings):\s+(\d+)$/;
		final resultsRe: EReg = ~/^results:/;
		// 0 — outside the block; 1 — `assertations:` seen, still needs the
		// `successes:` line right after it; 2 — inside, reading counts.
		var open: Int = 0;
		var assertions: Int = 0;
		var successes: Int = 0;
		var errors: Int = 0;
		var failures: Int = 0;
		var warnings: Int = 0;
		for (line in lines) {
			if (assertRe.match(line)) {
				assertions = Std.parseInt(assertRe.matched(1)) ?? 0;
				open = 1;
			} else if (open == 1 && successRe.match(line)) {
				successes = Std.parseInt(successRe.matched(1)) ?? 0;
				open = 2;
			} else if (open >= 2 && countRe.match(line)) {
				final n: Int = Std.parseInt(countRe.matched(2)) ?? 0;
				switch countRe.matched(1) {
					case 'errors':
						errors = n;
					case 'failures':
						failures = n;
					case _:
						warnings = n;
				}
			} else if (open >= 2 && resultsRe.match(line))
				return {
					assertions: assertions,
					successes: successes,
					errors: errors,
					failures: failures,
					warnings: warnings,
					ok: line.indexOf('(success: true)') >= 0
				};
			else if (open == 1)
				open = 0;
		}
		return null;
	}

	/**
	 * The `tests executed: N` line `test/RunTests.hx` prints from the runner's
	 * own `onComplete`. utest's end-of-run block has no test total and the quiet
	 * reporter emits no row for a passing test, so on a green transcript this
	 * line is the ONLY test count there is.
	 *
	 * Anchored, and the LAST match wins. That alone is not enough — the caller reads
	 * this only when utest's own block is present too, because the runner prints the
	 * two together and every test's output comes first. Without that pairing a
	 * transcript that DIED mid-run, after a failing test whose flushed stdout carried
	 * the phrase, reported `999 tests` at exit 0.
	 */
	private static function readExecutedCount(lines: Array<String>): Null<Int> {
		final executedRe: EReg = ~/^tests executed:\s+(\d+)$/;
		var found: Null<Int> = null;
		for (line in lines) if (executedRe.match(line)) found = Std.parseInt(executedRe.matched(1));
		return found;
	}

	/**
	 * Was a REPORT found, whatever it says? Not "is some count non-zero": a run of
	 * nothing and a run that died before printing anything both read all-zero, and
	 * only the first is an answer. utest's end-of-run block is the strong evidence;
	 * a parsed result row is the weak one, for a transcript truncated after the rows
	 * but before the block.
	 */
	private static inline function sawUtestReport(block: Null<TestSummaryHeader>, tests: Int, failures: Int, errors: Int): Bool {
		return block != null || tests > 0 || failures > 0 || errors > 0;
	}

	/**
	 * Every non-OK result row as `<fq.Class>.<method>` — what NAMED went red,
	 * for `apq mutation-verdict`. Whether the run WAS red is the header's
	 * answer, never this list's.
	 *
	 * A bare identifier at column 0 is only a CANDIDATE class name, promoted
	 * once the next line is an indented result row: utest splices multi-line
	 * assertion messages in raw, and such a message's last line can look
	 * identical to a class header. That narrows the hijack window without
	 * closing it, and the residue is bounded — a mis-attributed NAME, never a
	 * wrong red/green call.
	 *
	 * The marker slot takes ANY uppercase word rather than the four utest
	 * emits today. Anything that is not `OK` is failing, so a marker a future
	 * utest adds gets named instead of silently dropped.
	 */
	private static function collectFailureNames(lines: Array<String>): Array<String> {
		final classRe: EReg = ~/^[A-Za-z_][A-Za-z0-9_.]*$/;
		final rowRe: EReg = ~/^\s+([A-Za-z_][A-Za-z0-9_.]*):\s+[A-Z]+(\s|$)/;
		final okRe: EReg = ~/:\s+OK(\s|$)/;
		final names: Array<String> = [];
		var pending: String = '';
		var current: String = '';
		for (line in lines) if (classRe.match(line))
			pending = line;
		else if (rowRe.match(line)) {
			if (pending.length > 0) {
				current = pending;
				pending = '';
			}
			if (!okRe.match(line)) names.push('$current.${rowRe.matched(1)}');
		} else
			pending = '';
		return names;
	}

	/**
	 * Strips ANSI SGR color escapes (`ESC [ <params> m`) from `s`. Both
	 * transcript formats this parser reads (utest, tink_testrunner) are
	 * commonly captured with color on (tink's `AnsiFormatter` wraps every
	 * status token — `[OK]`/`[FAIL]`, positions, the summary line — in
	 * `ESC[<n>m ... ESC[39m`); stripping first keeps every downstream
	 * regex a plain-text match instead of threading ANSI-tolerant
	 * patterns through both parsers. Built from `String.fromCharCode(27)`
	 * rather than a `\x1b` literal so the escape byte is unambiguous
	 * across targets.
	 */
	private static function stripAnsi(s: String): String {
		final esc: String = String.fromCharCode(27); // noqa: magic-number
		final re: EReg = new EReg('$esc\\[[0-9;]*m', 'g');
		return re.replace(s, '');
	}

	/**
	 * Format sniff for `parseTestSummary`: does `lines` look like a
	 * tink_testrunner transcript rather than utest? Checked via either of
	 * tink's two unambiguous, ANSI-independent markers — an assertion row
	 * (`- [OK] [...]` / `- [FAIL] [...]`) or the final summary block
	 * (`N Assertions   N Success   N Failure   N Error`). Neither shape
	 * occurs in a utest transcript (utest's own summary line and
	 * per-test rows use `testName: OK/FAIL/ERROR`, no `[OK]`/`[FAIL]`
	 * bracket token and no `Assertions   ... Success` block).
	 */
	private static function looksLikeTinkTranscript(lines: Array<String>): Bool {
		final assertRe: EReg = ~/^\s*-\s*\[(OK|FAIL)\]\s*\[[^\]]+\]/;
		final summaryRe: EReg = ~/^\d+\s+Assertions?\s+\d+\s+Success\s+\d+\s+Failures?\s+\d+\s+Errors?\s*$/;
		return lines.exists(line -> assertRe.match(line) || summaryRe.match(line));
	}

	/**
	 * Pure parser over a tink_testrunner (tink_unittest) stdout
	 * transcript — the reporter TM's `openfl test macos -DUNIT_TESTS`
	 * suite uses (haxelib tink_testrunner, `BasicReporter`). Dispatched
	 * from `parseTestSummary` once `looksLikeTinkTranscript` flags the
	 * shape; `lines` is already ANSI-stripped.
	 *
	 * Line shape recognition (tink_testrunner 0.9.x `BasicReporter`):
	 *  - `SuiteName: [file:line]` (0-indent) — suite header; tracked for
	 *    `firstFailure.className`.
	 *  - `  case description: [file:line] ` (2-indent) — case header;
	 *    tracked for `firstFailure.testName`. A case with no failed/
	 *    thrown assertion counts toward `tests` (the passing-case tally)
	 *    once the NEXT header or the summary line closes it.
	 *  - `    - [OK] [file:line] desc` / `    - [FAIL] [file:line] desc`
	 *    (4-indent, dashed) — one assertion; `desc` is the caller-supplied
	 *    assertion label (same for pass/fail, NOT the failure reason).
	 *  - `        <message>` (8-indent, no dash) following a `[FAIL]` row
	 *    — that assertion's actual failure detail (`Failure(msg)`'s
	 *    `msg`); captured as `firstFailure.message` when it's the first.
	 *  - `    - <message>` (4-indent, dashed, NO `[...]` brackets) — a
	 *    case-level throw with no assertion row at all
	 *    (`CaseResultType.Failed(e)`). Buckets as an ERROR, matching
	 *    `BatchResult.summary()`'s own classification (`AssertionFailed`
	 *    -> failures, everything else, incl. `CaseFailed`/`SuiteFailed`
	 *    -> errors).
	 *  - `N Assertions   N Success   N Failure   N Error` (0-indent) —
	 *    final summary; authoritative when present (overrides the
	 *    per-row tally, which is otherwise a decent estimate for a
	 *    transcript truncated before the summary block was written).
	 *
	 * Only the FIRST failing/thrown row sets `firstFailure` — subsequent
	 * ones only bump counters (same contract as the utest path).
	 */
	private static function parseTinkTestSummary(lines: Array<String>): TestSummaryResult {
		final assertRe: EReg = ~/^\s*-\s*\[(OK|FAIL)\]\s*\[([^\]]+)\]\s*(.*)$/;
		final suiteRe: EReg = ~/^([A-Za-z_]\w*(?:\.\w+)*):\s*\[([^\]]+)\]\s*$/;
		final caseRe: EReg = ~/^  ([^\s\[][^\[]*?):\s*\[([^\]]+)\]\s*.*$/;
		final caseFailRe: EReg = ~/^ {4}-\s+(.+)$/; // noqa: magic-number
		final summaryRe: EReg = ~/^(\d+)\s+Assertions?\s+(\d+)\s+Success\s+(\d+)\s+Failures?\s+(\d+)\s+Errors?\s*$/;
		final locRe: EReg = ~/^(.*):(\d+)$/;
		// Capture-group ordinals of the regexes above, named so a reader does not
		// have to count groups: `assertRe`'s trailing free-text message, and
		// `summaryRe`'s Failures / Errors counts.
		final assertMessageGroup: Int = 3;
		final summaryFailuresGroup: Int = 3;
		final summaryErrorsGroup: Int = 4;
		// The FAILED-assertion detail row: `println(indent(failure, 8))`
		// in BasicReporter — 8-space indent, no leading dash, no
		// `[...]` brackets (that shape is the assertion row itself,
		// already consumed by `assertRe` before this ever runs). The
		// 8-space floor is exact enough to stay clear of the 4-indent
		// assertion/case-throw rows and the 2-indent case header.
		final detailRe: EReg = ~/^\s{8,}(\S.*)$/; // noqa: magic-number
		var assertions: Int = 0;
		var failures: Int = 0;
		var errors: Int = 0;
		var currentClass: String = '';
		var currentCase: String = '';
		var caseFailed: Bool = false;
		var caseHasAssertion: Bool = false;
		var passingCases: Int = 0;
		var firstFailure: Null<TestSummaryFailureLocus> = null;
		var awaitingDetail: Bool = false;
		inline function closeCase(): Void {
			if (caseHasAssertion && !caseFailed) passingCases++;
			caseFailed = false;
			caseHasAssertion = false;
		}
		for (line in lines) {
			if (awaitingDetail) {
				awaitingDetail = false;
				final locus: Null<TestSummaryFailureLocus> = firstFailure;
				if (locus != null && detailRe.match(line)) {
					locus.message = detailRe.matched(1).trim();
					continue;
				}
				// Not a detail row (assertion held with no failure detail
				// printed, or the next row arrived immediately) — fall
				// through and classify this line normally.
			}
			if (assertRe.match(line)) {
				caseHasAssertion = true;
				assertions++;
				final failed: Bool = assertRe.matched(1) == 'FAIL';
				final locRaw: String = assertRe.matched(2);
				final locLine: Int = locRe.match(locRaw) ? parsePositiveInt(locRe.matched(2)) : -1;
				if (failed) {
					failures++;
					caseFailed = true;
					if (firstFailure == null) {
						firstFailure = {
							className: currentClass,
							testName: currentCase,
							line: locLine,
							message: assertRe.matched(assertMessageGroup).trim(),
							kind: TestSummaryFailureKind.Fail
						};
						awaitingDetail = true;
					}
				}
			} else if (summaryRe.match(line)) {
				closeCase();
				currentClass = '';
				currentCase = '';
				assertions = parsePositiveInt(summaryRe.matched(1));
				failures = parsePositiveInt(summaryRe.matched(summaryFailuresGroup));
				errors = parsePositiveInt(summaryRe.matched(summaryErrorsGroup));
			} else if (suiteRe.match(line)) {
				closeCase();
				currentClass = suiteRe.matched(1);
				currentCase = '';
			} else if (caseRe.match(line)) {
				closeCase();
				currentCase = caseRe.matched(1).trim();
			} else if (caseFailRe.match(line)) {
				errors++;
				caseFailed = true;
				if (firstFailure == null) firstFailure = {
					className: currentClass,
					testName: currentCase,
					line: -1,
					message: caseFailRe.matched(1).trim(),
					kind: TestSummaryFailureKind.Error
				};
			}
			// Anything else (compile noise, plain trace() lines, blank
			// separators) is not part of the reporter's own output shape
			// — ignored, same as utest's fallthrough.
		}
		closeCase();
		return {
			tests: passingCases,
			assertions: assertions,
			failures: failures,
			errors: errors,
			firstFailure: firstFailure,
			// tink_testrunner emits no utest-shaped header block and no
			// "No tests executed." row, and nothing consumes tink failure
			// names today — the three utest-only fields stay empty rather
			// than being approximated from the rows.
			header: null,
			noTests: false,
			failureNames: [],
			// Reaching this parser at all IS the report: `looksLikeTinkTranscript`
			// routes here only on a `- [OK|FAIL] [loc]` assertion row or on the
			// `N Assertions N Success N Failures N Errors` summary line. A suite that
			// ran nothing prints that summary with four zeros — an answer, not a
			// truncated run, and it must not be refused as uncountable.
			counted: true
		};
	}

	private static function tryCaptureDetail(locus: TestSummaryFailureLocus, line: String, full: EReg, lineOnly: EReg, bare: EReg): Bool {
		// Disambiguate bare detail from regular test rows: a fail/err line
		// fits `bare` too (`^\s+\S.*`). The fail/err regexes already
		// consumed those, so we additionally require the bare branch to
		// NOT look like an indented test row (contain `: OK|FAIL|ERR`).
		if (full.match(line)) {
			locus.line = parsePositiveInt(full.matched(2));
			locus.message = full.matched(3).trim(); // noqa: magic-number
			return true;
		}
		if (lineOnly.match(line)) {
			locus.line = parsePositiveInt(lineOnly.matched(1));
			locus.message = lineOnly.matched(2).trim();
			return true;
		}
		if (!bare.match(line) || ~/:\s+(OK|FAIL|ERR)/.match(line)) return false;
		locus.message = bare.matched(1).trim();
		return true;
	}

	private static inline function parsePositiveInt(s: String): Int {
		final v: Null<Int> = Std.parseInt(s);
		return v ?? -1;
	}
	#end

}
