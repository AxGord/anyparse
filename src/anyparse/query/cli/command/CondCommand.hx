package anyparse.query.cli.command;

import anyparse.query.CondQuery;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.cli.CliArgs.ResolvedInputs;
import anyparse.query.cli.CliCommand;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliWalk.SkipEntry;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq cond` — the branch BODIES of every `#if` region that mentions a define.
 *
 * The read-only walk `lit --include-directives` leaves half-finished. That flag reaches a
 * directive's text, which is the only thing about a region no node carries — but it answers with a
 * `line:col` and nothing else, so the region's extent is still unknown and each site costs one
 * `source --range` with a guessed end line. Measured on this tree for the define `nodejs` over
 * `src/anyparse/query`: 87 regions, so 88 commands (one `lit`, then one `source --range` per site) and 57 497
 * bytes of stdout — and 25 of the 87 guessed windows did not reach their own `#end`, so the real figure is over
 * 110 commands. `apq cond nodejs src/anyparse/query` is one command and 40 750 bytes, or 27 807 with `--names`.
 *
 * The delimiting mechanism, and why a branch cannot simply be selected, is `CondQuery`'s: a region
 * projects as ONE node covering every branch, so a branch is delimited by its DIRECTIVES, not by a
 * node. This module is the argument surface over it.
 */
@:nullSafety(Strict)
final class CondCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'cond';
	}

	public function summary(): String {
		return 'Branch bodies of every #if region mentioning a define';
	}

	/**
	 * `apq cond <DEFINE> <file-or-dir-or-glob>...` — for every conditional-compilation region whose
	 * own `#if` / `#elseif` conditions mention `<DEFINE>`, print each branch's position, its
	 * verbatim directive, its liveness under "`<DEFINE>` is set" and its body.
	 *
	 * The walk shares `CliWalk` with every other read-only query, with one deliberate difference: a
	 * file that fails to parse is NOT skipped. The directive scan is lexical, so the branch bodies
	 * of an unparseable file are still exact — only their interiors are unmodelled, and those come
	 * back tagged `raw span`. Skipping such a file would throw away the answer the command can
	 * still give.
	 */
	public function run(args: Array<String>, ctx: CliContext): Int {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var names: Bool = false;
		var active: Bool = false;
		var inactive: Bool = false;
		var limit: Int = -1;
		var maxBody: Int = CondQuery.DEFAULT_MAX_BODY;
		var define: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--names':
					names = true;
				case '--active':
					active = true;
				case '--inactive':
					inactive = true;
				case '--limit':
					try limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
						CliIo.stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '--max-body':
					final raw: String = CliArgs.expectValue(args, ++i, '--max-body');
					final parsed: Null<Int> = SourceText.parseStrictInt(raw);
					if (parsed == null || parsed < 0) {
						CliIo.stderr('apq cond: --max-body expects a non-negative line budget, got "$raw"\n');
						return EXIT_USAGE;
					}
					maxBody = parsed;
				case '-h', '--help':
					usage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq cond: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (define == null)
						define = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (define == null) {
			CliIo.stderr('apq cond: missing <DEFINE> argument\n');
			usage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			CliIo.stderr('apq cond: missing <file-or-dir-or-glob> argument\n');
			usage();
			return EXIT_USAGE;
		}
		final defineStr: String = define;

		final io: ResolvedInputs = CliArgs.resolveInputPaths(lang, inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq cond: no input files matched ${CliArgs.quotedSpecs(inputSpecs)}\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;
		final singleFile: Bool = io.singleFile;
		final opts: CondRenderOptions = {
			flat: flat,
			names: names,
			active: active,
			inactive: inactive,
			maxBody: maxBody
		};

		final allEntries: Array<{
			file: String,
			source: String,
			tree: Null<QueryNode>,
			regions: Array<CondRegion>
		}> = [];
		final skipEntries: Array<SkipEntry> = [];
		// Hoisted: `refShape()` rebuilds a two-hundred-field structure, two of whose entries are
		// themselves derived by a walk over the grammar — once per file and once per printed entry
		// is a per-input cost for an answer that is a property of the PLUGIN.
		final shape: RefShape = plugin.refShape();
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			// The pre-filter `CliWalk.parseWalked` would apply is done here instead: a define must
			// appear verbatim in the directive that mentions it, so a file whose bytes do not hold
			// the word cannot yield a region — and doing it here keeps `parseWalked`'s null return
			// meaning ONE thing (the parse failed), which is what lets the walk continue on it.
			if (!singleFile && source.indexOf(defineStr) < 0) {
				CliIo.streamProgress('cond', ++scanned, paths.length, singleFile);
				continue;
			}
			final tree: Null<QueryNode> = CliWalk.parseWalked('cond', plugin.parseFile, path, source, singleFile, skipEntries);
			CliIo.streamProgress('cond', ++scanned, paths.length, singleFile);
			final found: Array<CondRegion> =
				CondQuery.regionsMentioning(source, tree, shape, plugin.lexicalRegions.bind(source), defineStr);
			if (found.length == 0) continue;
			allEntries.push({
				file: path,
				source: source,
				tree: tree,
				regions: found
			});
		}

		if (allEntries.length == 0)
			CliIo.stderr(
				'${CliWalk.emptyWalkerNudge('cond', defineStr, paths.length, paths.length - skipEntries.length, skipEntries, null)}\n'
			);

		final shown: Array<{
			file: String,
			source: String,
			tree: Null<QueryNode>,
			regions: Array<CondRegion>
		}> = CliWalk.capAndReport('cond', allEntries, limit, e -> e.regions.length, (e, k) -> {
			file: e.file,
			source: e.source,
			tree: e.tree,
			regions: e.regions.slice(0, k)
		}, paths.length);
		for (entry in shown) CliIo.sysPrint(CondQuery.render(entry.file, entry.source, entry.tree, entry.regions, opts, shape));
		return ctx.emptyExit(allEntries.length == 0);
	}

	public function usage(): Void {
		CliIo.sysPrint('Usage: apq cond <DEFINE> <file-or-dir-or-glob>... [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('For every conditional-compilation region whose own #if / #elseif conditions\n');
		CliIo.sysPrint('mention <DEFINE> as a standalone identifier, print one head line per branch —\n');
		CliIo.sysPrint('its position, its verbatim directive and its tags — with the branch body\n');
		CliIo.sysPrint('indented under it. `#if (sys || nodejs)` answers a query for either name.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A branch is NOT a node: a whole #if/#elseif/#else/#end region projects as one\n');
		CliIo.sysPrint('node covering every branch. A branch here is delimited by its DIRECTIVES —\n');
		CliIo.sysPrint('from the end of its own to the start of the next one at the same nesting\n');
		CliIo.sysPrint('depth — so a body never carries a directive and needs no #end hunting.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Tags:\n');
		CliIo.sysPrint('  [live]      taken whenever <DEFINE> is set\n');
		CliIo.sysPrint('  [dead]      never taken when <DEFINE> is set\n');
		CliIo.sysPrint('  [maybe]     some flag outside the query decides\n');
		CliIo.sysPrint('  [raw span]  the body holds text no node covers (an expression-position #if):\n');
		CliIo.sysPrint('              printed verbatim, and --names has nothing to answer with\n');
		CliIo.sysPrint('  [no parse]  the FILE has no tree, so every non-blank branch of it is\n');
		CliIo.sysPrint('              unmodelled for THAT reason and not for want of a node\n');
		CliIo.sysPrint('  [nested]    the region sits inside another one, so its text also appears\n');
		CliIo.sysPrint('              inside that region\'s own branch body\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --active        Keep only branches that can run with <DEFINE> set (not [dead])\n');
		CliIo.sysPrint('  --inactive      Keep only the branches that cannot ([dead]) — the complement\n');
		CliIo.sysPrint('  --names         Print the distinct `<Kind> <name>` rows of the branch instead\n');
		CliIo.sysPrint('                  of its source. Answers "what does this flag reach" without\n');
		CliIo.sysPrint('                  paying for the bodies. A [raw span] branch keeps its source.\n');
		CliIo.sysPrint('  --limit N       Cap rendered REGIONS, so a region is never half-printed\n');
		CliIo.sysPrint('                  (default: auto-cap at 500)\n');
		CliIo.sysPrint('  --max-body N    Lines of each branch body (or name rows) to print before the\n');
		CliIo.sysPrint('                  rest fold into a `… +N more` marker (default: 20, 0 for no\n');
		CliIo.sysPrint('                  cap). --limit counts REGIONS, so it cannot bound a define\n');
		CliIo.sysPrint('                  used as a whole-file guard — this is the flag that does.\n');
		CliIo.sysPrint('  --flat          One `<file>:<line>:<col>:` prefix per head line, no group header\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The scan is lexical, so an unparseable file is walked rather than skipped: its\n');
		CliIo.sysPrint('bodies are still exact and come back tagged [raw span].\n');
	}

}
