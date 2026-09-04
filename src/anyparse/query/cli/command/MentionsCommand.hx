package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.Lit.LitHit;
import anyparse.query.Refs.RefHit;
import anyparse.query.Uses.UsesHit;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.query.format.Text;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * Parsed options for `apq mentions` — `lang`, `flat`, `limit`, the `name` to search for, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef MentionsOpts = {
	var lang: String;
	var flat: Bool;
	var limit: Int;
	var name: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq mentions` — every named-leaf occurrence (uses + refs + lit --any-kind --exact).
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class MentionsCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'mentions';
	}

	public function summary(): String {
		return 'Every named-leaf occurrence (uses + refs + lit --any-kind --exact)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runMentions(args, ctx);
	}

	public function usage(): Void {
		printMentionsUsage();
	}

	private static inline function mentionsParseExit(code: Int): MentionsOpts {
		return {
			lang: '',
			flat: false,
			limit: -1,
			name: null,
			inputSpecs: [],
			errExit: code
		};
	}

	/**
	 * `apq mentions <name> <file-or-dir-or-glob>...` — every named-leaf
	 * occurrence of an identifier. Unions three precise queries:
	 *
	 *  - `uses` — type-position references (field/param/return/extends).
	 *  - `refs` — value-binding references (var/fn/param of that name).
	 *  - `lit --any-kind --exact` — every other leaf carrying that name:
	 *    case-patterns (`case Foo(_):` → `IdentExpr 'Foo'`), import path
	 *    segments, `new Foo()` ctor calls, field-name slots.
	 *
	 * The "everything called X" question. Complementary to `blast`:
	 * `blast` answers "what could break when I change type T's shape"
	 * via a name-based field-access SUPERSET; `mentions` answers "where
	 * is the literal token X tokenised in the AST" precisely. No
	 * heuristic — every section is structural and exact-name. Use this
	 * when refs/uses/blast all return 0 but you know the name appears
	 * (case-patterns are the canonical example).
	 */
	private static function runMentions(args: Array<String>, ctx: CliContext): Int {
		final o: MentionsOpts = parseMentionsArgs(args);
		if (o.errExit != null) return o.errExit;
		final name: Null<String> = o.name;
		if (name == null) {
			CliIo.stderr('apq mentions: missing <name> argument\n');
			printMentionsUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq mentions: missing <file-or-dir-or-glob> argument\n');
			printMentionsUsage();
			return EXIT_USAGE;
		}
		final target: String = name;

		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final refShape: RefShape = plugin.refShape();
		final typeShape: TypeRefShape = plugin.typeRefShape();

		final expanded: ExpandedInputs = CliArgs.expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq mentions: no input files matched ${CliArgs.quotedSpecs(o.inputSpecs)}\n');
			return EXIT_RUNTIME;
		}

		final valueTrees: Null<Array<{ path: String, source: String, tree: QueryNode }>> = collectMentionsValueTrees(
			target, paths, plugin, expanded.singleFile
		);
		if (valueTrees == null) return EXIT_RUNTIME;

		final usesAny: Bool = emitMentionsUses(target, valueTrees, plugin, typeShape, expanded.singleFile, o.flat);
		final refsAny: Bool = emitMentionsRefs(target, valueTrees, refShape, o.flat, plugin.lexicalRegions);
		final litAny: Bool = emitMentionsLit(target, valueTrees, o.limit, o.flat);

		final any: Bool = usesAny || refsAny || litAny;
		if (!any) CliIo.stderr('apq mentions: no uses / refs / lit-leaf of "$target" found\n');
		return ctx.emptyExit(!any);
	}

	private static function printMentionsUsage(): Void {
		CliIo.sysPrint('Usage: apq mentions [options] <name> <file-or-dir-or-glob>...\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		CliIo.sysPrint('  --limit <n>         Cap the lit section at n hits\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Every named-leaf occurrence of an identifier. Unions:\n');
		CliIo.sysPrint('  uses  — type-position references (precise)\n');
		CliIo.sysPrint('  refs  — value-binding references (precise)\n');
		CliIo.sysPrint('  lit   — every other leaf with that exact name:\n');
		CliIo.sysPrint('          case-patterns (`case Foo(_):` → IdentExpr),\n');
		CliIo.sysPrint('          imports, `new Foo()`, field-name slots.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Use this when refs/uses/blast return 0 but you know the\n');
		CliIo.sysPrint('name appears (case-patterns are the canonical example —\n');
		CliIo.sysPrint('blind to refs/uses/blast). All three sections are exact-\n');
		CliIo.sysPrint('name and structural; no heuristic / no over-match.\n');
	}

	private static function parseMentionsArgs(args: Array<String>): MentionsOpts {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		var name: Null<String> = null;
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
						return mentionsParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printMentionsUsage();
					return mentionsParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq mentions: unknown option "$a"\n');
						return mentionsParseExit(EXIT_USAGE);
					}
					if (name == null)
						name = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			flat: flat,
			limit: limit,
			name: name,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function collectMentionsValueTrees(
		target: String, paths: Array<String>, plugin: GrammarPlugin, singleFile: Bool
	): Null<Array<{ path: String, source: String, tree: QueryNode }>> {
		// Single value-AST pass per file, shared across all three sections.
		// Mirrors `runBlast`'s caching discipline. All three sections
		// (uses / refs / lit-exact) search for `target` verbatim, so the
		// raw-substring pre-filter is a strict necessary condition.
		// Section 3 (`lit`) matches decoded literal values, so the key is
		// opted out of the pre-filter when it carries a backslash — same
		// escaped-literal caution as `runLit`.
		final mentionsPrefilterKey: Null<String> = target.indexOf('\\') < 0 ? target : null;
		final valueTrees: Array<{ path: String, source: String, tree: QueryNode }> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked(
				'mentions', plugin.parseFile, path, source, singleFile, null, mentionsPrefilterKey
			);
			CliIo.streamProgress('mentions', ++scanned, paths.length, singleFile);
			if (tree == null) {
				if (singleFile) return null;
				continue;
			}
			valueTrees.push({ path: path, source: source, tree: tree });
		}
		return valueTrees;
	}

	private static function emitMentionsUses(
		target: String, valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, plugin: GrammarPlugin,
		typeShape: TypeRefShape, singleFile: Bool, flat: Bool
	): Bool {
		// Section 1 — type-position references (precise). The type-refs
		// re-parse is pre-filtered on `target` (a type position always
		// names the type verbatim).
		var any: Bool = false;
		var header: Bool = false;
		for (entry in valueTrees) {
			final typeTree: Null<QueryNode> = CliWalk.parseWalked(
				'mentions', plugin.parseFileTypeRefs, entry.path, entry.source, singleFile, null, target
			);
			if (typeTree == null) continue;
			final hits: Array<UsesHit> = Uses.find(target, typeTree, typeShape);
			if (hits.length == 0) continue;
			any = true;
			if (!header) {
				CliIo.sysPrint('# uses (type positions)\n');
				header = true;
			}
			CliIo.sysPrint(Text.renderUses(entry.path, entry.source, hits, false, false, flat, plugin.lexicalRegions(entry.source)));
		}
		return any;
	}

	private static function emitMentionsRefs(
		target: String, valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, refShape: RefShape, flat: Bool,
		lexicalRegions: (String) -> Array<LexRegion>
	): Bool {
		// Section 2 — value-binding references (precise).
		var any: Bool = false;
		var header: Bool = false;
		for (entry in valueTrees) {
			final hits: Array<RefHit> = Refs.find(target, entry.tree, refShape);
			if (hits.length == 0) continue;
			any = true;
			if (!header) {
				CliIo.sysPrint('# refs (value bindings)\n');
				header = true;
			}
			CliIo.sysPrint(Text.renderRefs(entry.path, entry.source, hits, false, false, lexicalRegions(entry.source), flat));
		}
		return any;
	}

	private static function emitMentionsLit(
		target: String, valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, limit: Int, flat: Bool
	): Bool {
		// Section 3 — every other leaf carrying this name (case-patterns,
		// imports, new exprs, field-name slots). `lit` with empty kind
		// filter + exact match. `--limit` caps this section only — the
		// precise refs/uses sections are typically small.
		final litEntries: Array<{ file: String, source: String, hits: Array<LitHit> }> = [];
		for (entry in valueTrees) {
			final hits: Array<LitHit> = Lit.find(target, entry.tree, true, null);
			if (hits.length == 0) continue;
			litEntries.push({ file: entry.path, source: entry.source, hits: hits });
		}
		if (litEntries.length == 0) return false;
		var totalHits: Int = 0;
		for (e in litEntries) totalHits += e.hits.length;
		final cappedLimit: Int = CliWalk.effectiveAutoLimit('mentions', limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<LitHit> }> = CliWalk.limitEntries(
			litEntries, cappedLimit, e -> e.hits.length, (e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k) }
		);
		CliIo.sysPrint('# lit (every leaf — case-patterns / imports / new exprs / field-name slots)\n');
		for (entry in shown) CliIo.sysPrint(Lit.render(entry.file, entry.source, entry.hits, flat));
		return true;
	}

}
