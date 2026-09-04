package anyparse.query.cli.command;

import anyparse.query.Cases.CasesHit;
import anyparse.query.cli.CliArgs.ResolvedInputs;
import anyparse.query.cli.CliCommand;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliWalk.SkipEntry;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * `apq cases` — the READ-ONLY WALK shape of the command seam.
 *
 * It is the pilot for every multi-file query (`refs`, `uses`, `lit`,
 * `mentions`, `meta`, `blast`, `search`, `symbols`, `importers`, `declares`):
 * parse its own flags, expand the path specs, walk them through `CliWalk`,
 * render, and answer `ctx.emptyExit` — the one place a command needs to know
 * something about the RUN rather than about its own arguments.
 */
@:nullSafety(Strict)
final class CasesCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'cases';
	}

	public function summary(): String {
		return 'Precise case-pattern lookup (case Ctor: / case Ctor(_): / case A | Ctor:)';
	}

	/**
	 * `apq cases <Ctor> <file-or-dir-or-glob>...` — precise case-pattern
	 * lookup. Finds every `case <Ctor>(_):` / `case <Ctor>:` / `case A |
	 * <Ctor>:` shape across the input tree. Solves the "search 'case
	 * Foo(_)' is not a valid pattern" pain — case-patterns are not
	 * parseable as top-level decl/stmt/expr, and `mentions` over-matches
	 * (imports, NewExpr, IdentExpr in non-pattern positions). Walks the
	 * QueryNode tree for `CaseBranch` nodes and emits one hit per
	 * matching pattern slot.
	 */
	public function run(args: Array<String>, ctx: CliContext): Int {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		var target: Null<String> = null;
		final inputSpecs: Array<String> = [];

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
					usage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq cases: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (target == null)
						target = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (target == null) {
			CliIo.stderr('apq cases: missing <Ctor> argument\n');
			usage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			CliIo.stderr('apq cases: missing <file-or-dir-or-glob> argument\n');
			usage();
			return EXIT_USAGE;
		}
		final targetStr: String = target;

		final io: ResolvedInputs = CliArgs.resolveInputPaths(lang, inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq cases: no input files matched ${CliArgs.quotedSpecs(inputSpecs)}\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;

		final singleFile: Bool = io.singleFile;
		final allEntries: Array<{ file: String, source: String, hits: Array<CasesHit> }> = [];
		final skipEntries: Array<SkipEntry> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked('cases', plugin.parseFile, path, source, singleFile, skipEntries, targetStr);
			CliIo.streamProgress('cases', ++scanned, paths.length, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final hits: Array<CasesHit> = Cases.find(targetStr, tree);
			if (hits.length == 0) continue;
			allEntries.push({ file: path, source: source, hits: hits });
		}

		if (allEntries.length == 0)
			CliIo.stderr(
				'${CliWalk.emptyWalkerNudge('cases', targetStr, paths.length, paths.length - skipEntries.length, skipEntries, null)}\n'
			);

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = CliWalk.effectiveAutoLimit('cases', limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<CasesHit> }> = CliWalk.limitEntries(
			allEntries, cappedLimit, e -> e.hits.length, (e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k) }
		);
		for (entry in shown) CliIo.sysPrint(Cases.render(entry.file, entry.source, entry.hits, flat));
		return ctx.emptyExit(allEntries.length == 0);
	}

	public function usage(): Void {
		CliIo.sysPrint('Usage: apq cases <Ctor> <file-or-dir-or-glob>... [--flat] [--limit N]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Match every switch case-pattern whose top-level ctor is <Ctor>:\n');
		CliIo.sysPrint('  case Ctor:           case Ctor(_):         case A | Ctor:\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Use when `search \'case Foo(_)\'` rejects the pattern and `mentions` over-\n');
		CliIo.sysPrint('matches (imports / NewExpr / IdentExpr in non-pattern positions).\n');
	}

}
