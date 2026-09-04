package anyparse.query.cli.command;

import anyparse.query.Diff;
import anyparse.query.cli.CliContext;
import anyparse.runtime.ParseError;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq diff` — structural AST diff between two files.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class DiffCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'diff';
	}

	public function summary(): String {
		return 'Structural AST diff between two files';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runDiff(args);
	}

	public function usage(): Void {
		printDiffUsage();
	}

	/**
	 * `apq diff <a> <b>` — structural AST diff between two parseable
	 * source files. Output is `file:L:C ↔ file:L:C: <diff>` per hit.
	 * The pair walk is top-down without LCS realignment: it surfaces
	 * "single edit" / "end-of-list change" / "subtree swap" cleanly,
	 * but a mid-list insert into a long Star cascades every following
	 * sibling as `differs`. For those cases use byte diff or `--limit`.
	 */
	private static function runDiff(args: Array<String>): Int {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		var fileA: Null<String> = null;
		var fileB: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
						CliIo.stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printDiffUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq diff: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (fileA == null)
						fileA = a;
					else if (fileB == null)
						fileB = a;
					else {
						CliIo.stderr('apq diff: only two file arguments supported (got "$fileA", "$fileB", "$a")\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (fileA == null || fileB == null) {
			CliIo.stderr('apq diff: missing <a> <b> arguments\n');
			printDiffUsage();
			return EXIT_USAGE;
		}
		final a: String = fileA;
		final b: String = fileB;

		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final sourceA: String = CliIo.readSourceForParse(a);
		final sourceB: String = CliIo.readSourceForParse(b);
		final treeA: QueryNode = try plugin.parseFile(sourceA) catch (e: ParseError) {
			CliIo.stderr('apq diff: $a: $e\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			CliIo.stderr('apq diff: $a: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		final treeB: QueryNode = try plugin.parseFile(sourceB) catch (e: ParseError) {
			CliIo.stderr('apq diff: $b: $e\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			CliIo.stderr('apq diff: $b: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		var hits: Array<DiffHit> = Diff.diff(treeA, treeB);
		if (limit >= 0 && hits.length > limit) hits = hits.slice(0, limit);
		CliIo.sysPrint(Diff.render(a, sourceA, b, sourceB, hits, flat));
		return EXIT_OK;
	}

	private static function printDiffUsage(): Void {
		CliIo.sysPrint('Usage: apq diff [options] <a> <b>\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --flat              Legacy flat `file:line:col:` per-hit format (default: paired-header)\n');
		CliIo.sysPrint('  --limit <n>         Stop after n hits (default: no limit)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Structural AST diff: walks both trees pairwise and reports nodes\n');
		CliIo.sysPrint('where kind / name slot / child count diverges. No LCS realignment\n');
		CliIo.sysPrint('— mid-list inserts cascade the tail as `differs`. Useful for strip-\n');
		CliIo.sysPrint('test reconciliation when a byte diff is whitespace-noisy.\n');
	}

}
