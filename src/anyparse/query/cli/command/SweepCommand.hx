package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import anyparse.query.format.json.SweepFixture;
import anyparse.query.format.json.SweepSnapshot;
import anyparse.query.format.json.SweepSnapshotParser;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Corpus harness sweep snapshot (`bin/.last-sweep.json` schema).
 * Mirrors `HxFormatterCorpusTest.printSweepDelta`'s write contract —
 * `apq sweep` reads the JSON and reports totals + delta without
 * re-running the corpus.
 */
typedef SweepTotals = {
	pass: Int,
	fail: Int,
	skipParse: Int,
	skipWrite: Int,
	skipConfig: Int,
	skipMalformed: Int
};

/**
 * One fixture whose sweep status moved, as `apq sweep --diff` reports it: `key` is the
 * breakdown bucket (`PASS->FAIL`, `ADDED(FAIL)`, …) and `line` the human row.
 */
typedef SweepFixtureMove = {
	var key: String;
	var line: String;
};

/**
 * `apq sweep` — read corpus sweep snapshot totals + Δ vs prior.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class SweepCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'sweep';
	}

	public function summary(): String {
		return 'Read corpus sweep snapshot totals + Δ vs prior';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runSweep(args);
		#else
		CliIo.stderr('apq sweep: requires a sys target (file read)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		#if (sys || nodejs)
		printSweepUsage();
		#end
	}

	#if (sys || nodejs)
	/**
	 * Read `bin/.last-sweep.json`'s `fixtures` array (written by
	 * `HxFormatterCorpusTest.printSweepDelta`) into a `path → status` map, via the
	 * declared `SweepSnapshot` schema. Returns an empty map on any parse / shape
	 * failure — malformed JSON, a missing `fixtures` array, OR any one entry
	 * carrying a wrong-typed `path`/`status` (the ByName parser throws rather than
	 * skipping just that entry) — so the caller can fail-soft with a "no baseline"
	 * diagnostic instead of crashing on a malformed snapshot. An entry MISSING
	 * `path` or `status` (present but absent, both `@:optional`) still degrades
	 * per-entry, unchanged from the pre-schema reader.
	 */
	public static function loadSweepFixtureStatus(path: String): Map<String, String> {
		final out: Map<String, String> = [];
		try {
			final raw: String = sys.io.File.getContent(path);
			final snapshot: SweepSnapshot = SweepSnapshotParser.parse(raw);
			final fixtures: Null<Array<SweepFixture>> = snapshot.fixtures;
			if (fixtures == null) return out;
			for (entry in fixtures) {
				final entryPath: Null<String> = entry.path;
				final entryStatus: Null<String> = entry.status;
				if (entryPath == null || entryStatus == null) continue;
				// Normalise snapshot path to match what
				// `stripRootPrefix` emits for the recon walker. The
				// corpus harness records paths as
				// `test/testcases/<subdir>/<name>` (rooted at the fork);
				// recon walks from `<fork>/test/testcases` so its
				// stripped paths are `<subdir>/<name>`. Trim the leading
				// `test/testcases/` here so the diff lookup is keyed
				// the same way on both sides.
				final corpusPrefix: String = 'test/testcases/';
				final normalised: String = StringTools.startsWith(entryPath, corpusPrefix)
					? entryPath.substr(corpusPrefix.length)
					: entryPath;
				out[normalised] = entryStatus;
			}
		} catch (_: Exception) {
			// best-effort: a scan failure leaves the partial status map (or the
			// whole array — a wrong-typed `path`/`status` in ANY entry now
			// throws and fails the read soft here, rather than skipping just
			// that entry; an entry MISSING `path`/`status` still degrades
			// per-entry via the null checks above, unchanged)
		}
		return out;
	}

	/**
	 * `apq sweep` — read-only view on the corpus harness's
	 * `bin/.last-sweep.json` snapshot. Prints totals (+ Δ vs a prior
	 * snapshot if `--prev <path>` is given) without re-running the
	 * corpus. THE no-corpus-rerun lookup for "what does the last sweep
	 * say" — closes the manual `cat bin/.last-sweep.json | grep` +
	 * `tail /tmp/sweep.log | grep ===== sweep totals` dance.
	 *
	 * Default path is `bin/.last-sweep.json` (matches the corpus
	 * harness's `SWEEP_JSON_PATH` constant). `--file <path>` overrides
	 * — useful for sanity-checking an alternate snapshot. Exit 0 when
	 * the file is read; exit 1 when it doesn't exist or is unparseable.
	 */
	private static function runSweep(args: Array<String>): Int {
		var filePath: String = 'bin/.last-sweep.json';
		var prevPath: Null<String> = null;
		var diffPath: Null<String> = null;
		// The auto-rotated baseline, named once so the run can RECOGNISE it rather than
		// infer it from how the argument was spelled. Those are not the same test, and the
		// difference is the whole point: this file is overwritten with the previous run's
		// snapshot before every corpus write, so a `0 changed` against it is a statement
		// about the last two runs of one tree. Keying on "the caller passed no path" would
		// have exempted `--diff bin/.prev-sweep.json` — the same vacuous comparison, spelled
		// out — from the note that exists to catch it.
		final autoRotatedBaseline: String = 'bin/.prev-sweep.json';
		// `--save <path>`: discoverable shorthand for "copy the current
		// snapshot to <path> so I can `--prev` / `--diff` against it
		// after the next sweep". Replaces the manual
		// `cp bin/.last-sweep.json /tmp/prev.json` step that's easy to
		// forget before a grammar slice. Performs the copy AFTER the
		// totals print so the user still sees the snapshot's contents.
		var savePath: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--file':
					filePath = CliArgs.expectValue(args, ++i, '--file');
				case '--prev':
					prevPath = CliArgs.expectValue(args, ++i, '--prev');
				case '--diff':
					// Allow bare `--diff` (no arg) → default to
					// `bin/.prev-sweep.json` (auto-rotated by the corpus
					// harness before every sweep write). The next-token
					// check follows expectValue's contract: a `--`-prefixed
					// token is a flag, not a value.
					diffPath = i + 1 < args.length && !StringTools.startsWith(args[i + 1], '--')
						? CliArgs.expectValue(args, ++i, '--diff')
						: autoRotatedBaseline;
				case '--save':
					savePath = CliArgs.expectValue(args, ++i, '--save');
				case '--lang':
					// hxq shim auto-injects --lang haxe; harmless here (sweep
					// reads a JSON snapshot, no grammar plugin needed). Accept
					// + consume the value to keep shim invariance.
					CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printSweepUsage();
					return EXIT_OK;
				case _:
					CliIo.stderr('apq sweep: unknown option "$a"\n');
					printSweepUsage();
					return EXIT_USAGE;
			}
			i++;
		}
		final cur: Null<SweepTotals> = loadSweepJson(filePath);
		if (cur == null) {
			CliIo.stderr(sweepNoSnapshot(filePath, savePath));
			return EXIT_RUNTIME;
		}
		CliIo.warnIfTestJsStale('sweep');
		final total: Int = cur.pass + cur.fail + cur.skipParse + cur.skipWrite + cur.skipConfig + cur.skipMalformed;
		CliIo.sysPrint(
			'${cur.pass} pass / ${cur.fail} fail / ${cur.skipParse} skip-parse / ${cur.skipWrite} skip-write / ${cur.skipConfig}'
			+ ' skip-config / ${cur.skipMalformed} malformed (total $total)\n'
		);
		if (prevPath != null) {
			final prev: Null<SweepTotals> = loadSweepJson(prevPath);
			if (prev == null) {
				CliIo.stderr(sweepNoSnapshot(prevPath, null, true));
				return EXIT_RUNTIME;
			}
			CliIo.sysPrint(
				'  Δpass ${sweepSigned(cur.pass - prev.pass)} / Δfail ${sweepSigned(cur.fail - prev.fail)} / Δskip-parse '
				+ '${sweepSigned(cur.skipParse - prev.skipParse)}  vs $prevPath (${prev.pass} / ${prev.fail} / ${prev.skipParse})\n'
			);
		}
		if (savePath != null) {
			try {
				final raw: String = sys.io.File.getContent(filePath);
				sys.io.File.saveContent((savePath: String), raw);
				CliIo.sysPrint('apq sweep: saved snapshot $filePath -> $savePath\n');
			} catch (e: Exception) {
				CliIo.stderr('apq sweep: --save failed: ${e.message}\n');
				return EXIT_RUNTIME;
			}
		}
		return diffPath != null ? runSweepDiff(filePath, diffPath, diffPath == autoRotatedBaseline) : EXIT_OK;
	}

	/**
	 * Per-fixture status diff between two sweep snapshots. THE answer to
	 * "which fixtures flipped between these two runs" — replaces the
	 * ad-hoc python3 reads against `bin/.last-sweep.json`'s `fixtures`
	 * array. Composes with `--prev` (totals delta is printed first, then
	 * the per-fixture rows; the two are orthogonal).
	 *
	 * Output shape: one line per changed path, plus a transition-count breakdown summary naming the
	 * baseline it compared, and sorted by path for deterministic output.
	 *
	 * `autoRotated` says the baseline was the DEFAULT `bin/.prev-sweep.json` rather than a path the
	 * caller spelled. It changes no comparison — it decides what the run is allowed to CLAIM: that
	 * default is overwritten with the previous run's snapshot before every corpus write, so its
	 * `0 changed` is a statement about the last two runs of one tree and not about a change.
	 */
	private static function runSweepDiff(curPath: String, prevPath: String, autoRotated: Bool): Int {
		final cur: Map<String, String> = loadSweepFixtureStatus(curPath);
		final prev: Map<String, String> = loadSweepFixtureStatus(prevPath);
		if (!cur.iterator().hasNext()) {
			CliIo.stderr(
				'apq sweep: --diff: $curPath'
				+ ' has no `fixtures` array — re-run `node bin/test.js` under $$ANYPARSE_HXFORMAT_FORK to seed it\n'
			);
			return EXIT_RUNTIME;
		}
		if (!prev.iterator().hasNext()) {
			CliIo.stderr(sweepDiffNoBaseline(prevPath, sweepSnapshotExists(prevPath), autoRotated));
			return EXIT_RUNTIME;
		}
		final allPaths: Map<String, Bool> = [];
		for (k in cur.keys()) allPaths[k] = true;
		for (k in prev.keys()) allPaths[k] = true;
		final sorted: Array<String> = [for (k in allPaths.keys()) k];
		sorted.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		final transitions: Map<String, Int> = [];
		var changed: Int = 0;
		for (path in sorted) {
			final ps: Null<String> = prev[path];
			final cs: Null<String> = cur[path];
			if (ps == cs) continue;
			changed++;
			final moved: SweepFixtureMove = sweepDiffMove(path, ps, cs);
			transitions[moved.key] = (transitions[moved.key] ?? 0) + 1;
			CliIo.sysPrint('${moved.line}\n');
		}
		final breakdown: Array<String> = [for (k => v in transitions) '$k: $v'];
		breakdown.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		CliIo.sysPrint(
			changed == 0
				? '--- sweep --diff: 0 fixtures changed vs $prevPath (snapshots identical) ---\n'
				: '--- sweep --diff: $changed fixtures changed vs $prevPath (${breakdown.join(', ')}) ---\n'
		);
		// The one line this gate was missing. A `0 changed` off the auto-rotated
		// baseline is not a verdict about a change — see `sweepDiffAutoRotatedNote`.
		if (changed == 0 && autoRotated) CliIo.stderr(sweepDiffAutoRotatedNote(prevPath));
		return EXIT_OK;
	}

	/** Whether a sweep snapshot file is on disk — the half of "no baseline" that is not a FORMAT problem. */
	private static inline function sweepSnapshotExists(path: String): Bool {
		return FileSystem.exists(path);
	}

	/**
	 * The breakdown KEY and the printed line for one fixture whose status moved. ONE three-way
	 * decision: the two parallel copies it replaces drifted apart the moment either was edited.
	 */
	private static function sweepDiffMove(path: String, prev: Null<String>, cur: Null<String>): SweepFixtureMove {
		return if (prev == null)
			{ key: 'ADDED($cur)', line: 'ADDED $path (now $cur)' }
		else if (cur == null)
			{ key: 'REMOVED($prev)', line: 'REMOVED $path (was $prev)' }
		else
			{ key: '$prev->$cur', line: '$prev -> $cur: $path' };
	}

	/**
	 * The "there is no snapshot to read" diagnostic for the totals path — the
	 * sibling of `sweepDiffNoBaseline`, which the `--diff` path already had.
	 *
	 * `apq sweep` REPORTS a corpus run; it never performs one. The totals are
	 * written by the corpus harness inside `bin/test.js`, which needs
	 * `ANYPARSE_HXFORMAT_FORK`. So in a tree where that has not run yet EVERY sweep
	 * form fails, `--save` included — there is nothing to copy — and running a
	 * plain `sweep` first does not seed it either, because a plain `sweep` reads
	 * the very same file. The old line named only the path, which reads as a
	 * corrupt JSON rather than as a file nobody has written yet; a batch protocol
	 * grew a "run a plain sweep first" step off that misreading, and it never
	 * worked.
	 */
	public static function sweepNoSnapshot(path: String, savePath: Null<String>, prev: Bool = false): String {
		final head: String = if (prev)
			'apq sweep: --prev $path: '
		else if (savePath == null)
			'apq sweep: '
		else
			'apq sweep: --save $savePath has nothing to copy: ';
		// A `--prev` path is a BASELINE the user named, not the harness's own snapshot, so the
		// remedy is `--save`, never the corpus run. Pointing at `node bin/test.js` there both
		// blamed the wrong thing and contradicted the totals printed one line above — which
		// only print when the harness HAS run.
		return if (sweepSnapshotExists(path))
			'$head$path exists but is not a sweep snapshot — malformed JSON, or no pass / fail / skip-parse totals.'
				+ ' Re-run `node bin/test.js` under $$ANYPARSE_HXFORMAT_FORK to rewrite it\n'
		else if (prev)
			'${head}no snapshot at $path — a `--prev` baseline is one you saved, not one the corpus harness writes.'
				+ ' Create it with `apq sweep --save $path` on the tree you want to compare against\n'
		else
			'${head}no corpus snapshot at $path — this tree has not run the corpus harness yet, and `sweep` only READS what that'
				+ ' run writes (a plain `sweep` first reads the same file, so it does not seed it). Run `node bin/test.js` under'
				+ ' $$ANYPARSE_HXFORMAT_FORK, then re-run this command\n';
	}

	/**
	 * Why `--diff` has no baseline, as the line the caller prints — and the remedy that
	 * matches the actual cause.
	 *
	 * `loadSweepFixtureStatus` fails soft: an ABSENT file, a malformed one and one holding
	 * no `fixtures` array all come back as the same empty map. The single message this
	 * used to print named the last of the three, so the common case — a fresh worktree
	 * whose first corpus run has not rotated a baseline into existence yet — sent the
	 * reader looking for a corrupt snapshot that was never written. `exists` is what tells
	 * the two apart, and the auto-rotated default gets the extra sentence its provenance
	 * needs: the harness copies the PREVIOUS snapshot over it before each write, so the
	 * first sweep in a tree leaves it absent by construction and only the second creates it.
	 */
	public static function sweepDiffNoBaseline(prevPath: String, exists: Bool, autoRotated: Bool): String {
		final cause: String = exists
			? 'carries no readable `fixtures` array — malformed JSON, an older snapshot format, or a wrong-typed entry'
			: 'does not exist';
		final remedy: String = if (exists)
			' — re-run `node bin/test.js` under $$ANYPARSE_HXFORMAT_FORK to rewrite it'
		else if (autoRotated)
			' — the corpus harness creates it by ROTATION, copying the previous `bin/.last-sweep.json` over it before each write, so '
				+ 'the FIRST sweep in a tree leaves it absent and only the SECOND one makes a comparison possible. For a baseline that can '
				+ 'fail against a CHANGE, save one before the change (`apq sweep --save <path>`) and pass it (`apq sweep --diff <path>`)'
		else
			' — save one with `apq sweep --save <path>` after a sweep of the tree you want to compare against';
		return 'apq sweep: --diff: $prevPath $cause$remedy\n';
	}

	/**
	 * What a `0 fixtures changed` off the DEFAULT baseline is worth, printed next to it.
	 *
	 * `bin/.prev-sweep.json` is not a baseline anybody chose: the corpus harness overwrites
	 * it with the preceding run's snapshot before every write. So `--diff` with no path
	 * compares the last TWO runs of this tree — and when both of them ran after the edit
	 * under test, which is the whole of a fresh worktree's history, 0 is the only answer it
	 * can give. That line has been quoted as a slice gate; it is not one, and a gate that
	 * cannot fail has to say so rather than print a pass.
	 */
	public static function sweepDiffAutoRotatedNote(prevPath: String): String {
		return 'apq sweep: --diff: $prevPath is the AUTO-ROTATED baseline — the corpus harness overwrites it with the PREVIOUS run\'s'
			+ ' snapshot before every write, so this compared the last two runs of this tree, not a change against its base. If both'
			+ ' of those runs measured the same sources, 0 was the only possible answer. For a gate that can fail, snapshot before the'
			+ ' change (`apq sweep --save <path>`) and compare with `apq sweep --diff <path>`.\n';
	}

	/**
	 * Read `path` (`bin/.last-sweep.json` / a `--prev`/`--diff` snapshot) into
	 * the six-int `SweepTotals`, via the declared `SweepSnapshot` schema.
	 * Returns null when the file is missing, the JSON is malformed, OR a
	 * modelled key holds a value of the wrong type (the ByName parser throws
	 * rather than degrading that field alone) — every case reads as "no usable
	 * snapshot" to the caller. Requires `pass`/`fail`/`skipParse` to be present
	 * (the historical "trio" contract); the other three ints default to 0 when
	 * absent, matching the pre-schema Reflect-based reader.
	 */
	private static function loadSweepJson(path: String): Null<SweepTotals> {
		return !sys.FileSystem.exists(path)
			? null
			: try {
				final raw: String = sys.io.File.getContent(path);
				final snapshot: SweepSnapshot = SweepSnapshotParser.parse(raw);
				final pass: Null<Int> = snapshot.pass;
				final fail: Null<Int> = snapshot.fail;
				final skipParse: Null<Int> = snapshot.skipParse;
				if (pass == null || fail == null || skipParse == null) return null;
				{
					pass: pass,
					fail: fail,
					skipParse: skipParse,
					skipWrite: snapshot.skipWrite ?? 0,
					skipConfig: snapshot.skipConfig ?? 0,
					skipMalformed: snapshot.skipMalformed ?? 0
				};
			} catch (_: Exception) null;
	}

	private static inline function sweepSigned(n: Int): String return n > 0 ? '+$n' : '$n';

	private static function printSweepUsage(): Void {
		CliIo.sysPrint('Usage: apq sweep [--file <path>] [--prev <path>] [--diff <path>] [--save <path>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Read the corpus harness sweep snapshot (`bin/.last-sweep.json` by\n');
		CliIo.sysPrint('default) and print totals + optional delta vs a prior snapshot.\n');
		CliIo.sysPrint('No corpus rerun — only reads JSON, so a tree that has never run the\n');
		CliIo.sysPrint('corpus harness has nothing to read. `node bin/test.js` under\n');
		CliIo.sysPrint('$$ANYPARSE_HXFORMAT_FORK is what writes the snapshot; every sweep form,\n');
		CliIo.sysPrint('--save included, fails until it has.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --file <path>   Snapshot file (default: bin/.last-sweep.json)\n');
		CliIo.sysPrint('  --prev <path>   Compare against another snapshot, print Δ triple\n');
		CliIo.sysPrint('  --diff <path>   Per-fixture status diff vs another snapshot (PASS->FAIL,\n');
		CliIo.sysPrint('                  FAIL->PASS, ADDED/REMOVED entries). Composes with --prev.\n');
		CliIo.sysPrint('                  Auto-default: `bin/.prev-sweep.json` (the corpus harness\n');
		CliIo.sysPrint('                  auto-rotates this before each sweep write), no path needed —\n');
		CliIo.sysPrint('                  but that default is the PREVIOUS RUN of this same tree, so\n');
		CliIo.sysPrint('                  its 0 is not a verdict about a change. For a gate that can\n');
		CliIo.sysPrint('                  fail, --save a baseline BEFORE the change and --diff it.\n');
		CliIo.sysPrint('  --save <path>   Copy the current snapshot to <path>. Use before a grammar\n');
		CliIo.sysPrint('                  slice to capture a baseline for `--prev` / `--diff` later.\n');
		CliIo.sysPrint('                  Copies; it does not RUN anything, so it needs a snapshot\n');
		CliIo.sysPrint('                  already on disk.\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}
	#end

}
