package anyparse.query;

import anyparse.query.Cli.TestSummaryHeader;
import anyparse.query.Cli.TestSummaryResult;

/**
 * The five verdicts `tools/mutation-check.sh` reports per track.
 * `SURVIVED` is the finding the tool exists for — a green suite over a
 * mechanism no fixture reaches.
 */
enum MutationVerdictKind {
	Killed;
	Survived;
	Mismatch;
	NoTests;
	RunFail;
}

/** One classified track: the verdict plus the human-readable row detail. */
typedef MutationVerdictResult = {
	kind: MutationVerdictKind,
	detail: String
};

/**
 * `apq mutation-verdict` — turn one parsed utest transcript into a
 * mutation-check verdict.
 *
 * This lives here, and not in `tools/mutation-check.sh`, because the shell
 * copy was a SECOND utest-report parser: `apq test-summary` had existed for
 * exactly this job since before the script was written, and `suite-shard.sh`
 * comments that it reuses it precisely so a divergent parser cannot grow.
 * One grew anyway, and the price is on record — both `fdb44864` ("a red run
 * can no longer be reported SURVIVED") and `ff3f20ae` ("find the utest header
 * by SHAPE") were bugs in the duplicate, 316 changed lines apart, neither
 * reachable by any test because a shell function is not testable.
 *
 * The classification is PURE over `TestSummaryResult`, so the whole of it is
 * covered by `MutationVerdictTest`; the CLI layer only reads the file and
 * prints two lines.
 *
 * Order matters and is not arbitrary:
 *
 *  1. No header at all → `RunFail`. A transcript truncated before utest's
 *     end-of-run block cannot be judged, and guessing from the rows is how a
 *     red run gets reported green.
 *  2. "No tests executed." → `NoTests`, loud on purpose: a typo'd filter would
 *     otherwise read as `Survived`, i.e. as a finding.
 *  3. `header.ok` → `Survived`. This is utest's OWN predicate, which counts
 *     WARNINGS as red — a mutation that stops a test asserting produces
 *     `failures: 0, warnings: N`, and a failure-row scan would call that a
 *     survival. See `TestSummaryHeader`.
 *  4. Red but no result row parsed → `RunFail`: the run is red and the report
 *     cannot name what went red, which is a defect in this classifier or a
 *     transcript shape it has not met.
 *  5. Otherwise match the expectations. An expectation naming nothing is a
 *     `Mismatch` — the track broke something, but not what it claimed.
 *     Failures the expectations did NOT name are reported as `+extra:` and do
 *     NOT demote the verdict: the question a track asks is "does the suite
 *     notice", and a wider blast radius still answers yes.
 */
class MutationVerdict {

	/** Longest failure/expectation list rendered before eliding the tail. */
	private static inline final DETAIL_ITEM_LIMIT: Int = 10;

	/** `KILLED` / `NO-TESTS` / … — the row label the report prints. */
	public static function label(kind: MutationVerdictKind): String {
		return switch kind {
			case Killed: 'KILLED';
			case Survived: 'SURVIVED';
			case Mismatch: 'MISMATCH';
			case NoTests: 'NO-TESTS';
			case RunFail: 'RUN-FAIL';
		};
	}

	/**
	 * Classify one parsed transcript against a track's expectations.
	 * `expected` holds already-trimmed, non-empty substrings; an empty array
	 * means "any red kills".
	 */
	public static function classify(result: TestSummaryResult, expected: Array<String>): MutationVerdictResult {
		final header: Null<TestSummaryHeader> = result.header;
		if (header == null) return { kind: RunFail, detail: 'no utest header block in the transcript' };
		if (result.noTests) return { kind: NoTests, detail: 'filter matched no test class' };
		final assertions: Int = header.assertions;
		if (header.ok) return { kind: Survived, detail: '0 tests failed / $assertions assertions' };
		final failures: Array<String> = dedupeSorted(result.failureNames);
		if (failures.length == 0) return { kind: RunFail, detail: 'header reports a red run but no result row parsed' };

		final missing: Array<String> = [];
		final extra: Array<String> = [];
		if (expected.length > 0) {
			for (want in expected) if (!anyContains(failures, want)) missing.push(want);
			for (name in failures) if (!containsAny(name, expected)) extra.push(name);
		}

		final counted: String = '${failures.length} tests failed / $assertions assertions: ${cap(failures)}';
		return missing.length > 0
			? { kind: Mismatch, detail: '$counted (missing: ${cap(missing)})' }
			: { kind: Killed, detail: extra.length > 0 ? '$counted +extra: ${cap(extra)}' : counted };
	}

	/** Does any of `names` carry `needle` as a substring? */
	private static function anyContains(names: Array<String>, needle: String): Bool {
		for (name in names) if (name.indexOf(needle) >= 0) return true;
		return false;
	}

	/** Does `name` carry any of `needles` as a substring? */
	private static function containsAny(name: String, needles: Array<String>): Bool {
		for (needle in needles) if (name.indexOf(needle) >= 0) return true;
		return false;
	}

	/**
	 * Sorted unique copy — the shell pipeline ended in `sort -u`, and the
	 * count in the detail row is of DISTINCT failing tests. utest can emit
	 * one test twice (a failure row plus a later warning row for the same
	 * method), which would otherwise inflate the number the report prints.
	 */
	private static function dedupeSorted(names: Array<String>): Array<String> {
		final seen: Map<String, Bool> = [];
		final out: Array<String> = [];
		for (name in names) if (!seen.exists(name)) {
			seen[name] = true;
			out.push(name);
		}
		out.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return out;
	}

	/** `a, b, c, …+N more` — a long list must not push the row off screen. */
	private static function cap(items: Array<String>): String {
		if (items.length <= DETAIL_ITEM_LIMIT) return items.join(', ');
		final head: Array<String> = items.slice(0, DETAIL_ITEM_LIMIT);
		return '${head.join(', ')}, …+${items.length - DETAIL_ITEM_LIMIT} more';
	}

}
