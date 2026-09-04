package anyparse.query.cli.command;

import anyparse.check.Linter;
import anyparse.query.LintDiff.LintDiffResult;
import anyparse.query.LintDiff.LintMessageIdentities;
import anyparse.query.cli.CliContext;
import anyparse.query.format.json.LintFindingJson;
import haxe.Exception;
import anyparse.query.ExitCode.*;

/**
 * `apq lint-diff` — multiset diff of two lint --format json snapshots (blast radius).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class LintDiffCommand implements CliCommand {

	private static inline final LINT_DIFF_EXAMPLE_LIMIT: Int = 20;

	public function new() {}

	public function name(): String {
		return 'lint-diff';
	}

	public function summary(): String {
		return 'Multiset diff of two lint --format json snapshots (blast radius)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runLintDiff(args);
	}

	public function usage(): Void {
		printLintDiffUsage();
	}

	#if (sys || nodejs)
	/**
	 * `apq lint-diff --old <a.json> --new <b.json>` — the blast-radius gate
	 * `tools/battery.sh` runs once per compared tree.
	 *
	 * Both arguments are `apq lint --format json` snapshots; the comparison is a
	 * MULTISET diff over `(file, rule, severity, message)` with the two
	 * normalizations `LintDiff` documents — `--root` makes a relative and an
	 * absolute snapshot of one tree comparable, and `duplicate-code` messages are
	 * digit-masked.
	 *
	 * The two non-zero exits are deliberately DIFFERENT, because a caller must be
	 * able to waive one and never the other: 1 means the comparison ran and the
	 * snapshots disagree (the blast radius moved — a slice that adds code expects
	 * this), 2 means the comparison could not run at all (a snapshot missing,
	 * unreadable or malformed, or the flags wrong). Collapsing them would let
	 * `battery.sh --allow-blast` — reached for exactly when movement is expected —
	 * silently accept a broken baseline as a passed gate.
	 */
	private static function runLintDiff(args: Array<String>): Int {
		var oldPath: Null<String> = null;
		var newPath: Null<String> = null;
		var root: String = '';
		var label: String = '';
		var limit: Int = LINT_DIFF_EXAMPLE_LIMIT;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--old':
					oldPath = CliArgs.expectValue(args, ++i, '--old');
				case '--new':
					newPath = CliArgs.expectValue(args, ++i, '--new');
				case '--root':
					root = CliArgs.expectValue(args, ++i, '--root');
				case '--label':
					label = CliArgs.expectValue(args, ++i, '--label');
				case '--limit':
					limit = Std.parseInt(CliArgs.expectValue(args, ++i, '--limit')) ?? LINT_DIFF_EXAMPLE_LIMIT;
				case '--lang':
					// hxq shim auto-injects --lang haxe; harmless here (lint-diff
					// reads two JSON reports, no grammar plugin needed). Accept +
					// consume the value to keep shim invariance, as sweep does.
					CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printLintDiffUsage();
					return EXIT_OK;
				case _:
					CliIo.stderr('apq lint-diff: unknown option "$a"\n');
					printLintDiffUsage();
					return EXIT_USAGE;
			}
			i++;
		}
		if (oldPath == null || newPath == null) {
			CliIo.stderr('apq lint-diff: both --old <path> and --new <path> are required\n');
			printLintDiffUsage();
			return EXIT_USAGE;
		}
		final oldFile: String = oldPath;
		final newFile: String = newPath;
		var result: Null<LintDiffResult> = null;
		try {
			final before: Array<LintFindingJson> = LintDiff.parseReport(CliIo.readFile(oldFile));
			final after: Array<LintFindingJson> = LintDiff.parseReport(CliIo.readFile(newFile));
			// The rule -> `messageIdentity` map is asked of the check registry, so a rule that
			// quotes a source coordinate is covered by declaring it on ITSELF. Both snapshots go
			// through the same map, which is what lets a baseline cached before a declaration
			// existed still compare clean against a run made after it.
			final identities: LintMessageIdentities = Linter.messageIdentities();
			result = LintDiff.compare(LintDiff.tally(before, root, identities), LintDiff.tally(after, root, identities));
		} catch (exception: Exception) {
			// EXIT_USAGE, not EXIT_RUNTIME: "could not compare" must not look like
			// "compared, and things moved". A half-read baseline UNDERSTATES the
			// blast radius, and the caller that waives movement must still fail on
			// this.
			CliIo.stderr('apq lint-diff: cannot compare $oldFile against $newFile: ${exception.message}\n');
			return EXIT_USAGE;
		}
		if (result == null) throw 'apq lint-diff: the comparison neither produced a result nor threw';
		for (line in LintDiff.render(result, label, limit)) CliIo.sysPrint('$line\n');
		return result.addedTotal == 0 && result.removedTotal == 0 ? EXIT_OK : EXIT_RUNTIME;
	}

	private static function printLintDiffUsage(): Void {
		CliIo.sysPrint('Usage: apq lint-diff --old <a.json> --new <b.json> [--root <prefix>] [--label <name>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Compare two `apq lint --format json` snapshots as MULTISETS of\n');
		CliIo.sysPrint('(file, rule, severity, message) keys and report added and removed.\n');
		CliIo.sysPrint('Line, column and address are deliberately not part of the key —\n');
		CliIo.sysPrint('they move under any edit above them, and `apq lint --format json`\n');
		CliIo.sysPrint('records DO carry all three (file, line, col, severity, rule,\n');
		CliIo.sysPrint('message, address) for any caller that wants them.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The MEASUREMENTS a message quotes are masked too, and each check\n');
		CliIo.sysPrint('declares its own: a type going 518 -> 519 members, a clone block\n');
		CliIo.sysPrint('whose partner moved a line, a repetition count — each re-keyed a\n');
		CliIo.sysPrint('finding that neither appeared nor went away. The `(max N)`\n');
		CliIo.sysPrint('THRESHOLDS beside them are NOT masked: a configuration change is a\n');
		CliIo.sysPrint('change this gate must show. So two snapshots can differ in the text\n');
		CliIo.sysPrint('they print and still compare equal here — that is the design, not a\n');
		CliIo.sysPrint('missed difference.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Exit 0 when the two snapshots carry the same findings, 1 when\n');
		CliIo.sysPrint('anything moved, 2 when the comparison could not run (snapshot\n');
		CliIo.sysPrint('missing or malformed).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --old <path>    Baseline snapshot (required)\n');
		CliIo.sysPrint('  --new <path>    Snapshot compared against it (required)\n');
		CliIo.sysPrint('  --root <prefix> Strip this path prefix from EITHER side before comparing,\n');
		CliIo.sysPrint('                  so a relative and an absolute snapshot of one tree agree\n');
		CliIo.sysPrint('  --label <name>  Name this comparison in the output (a battery run has two)\n');
		CliIo.sysPrint('  --limit <n>     Example keys shown per sign (default 20; -1 shows all)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}
	#end

}
