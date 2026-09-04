package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.Meta.MetaHit;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliWalk;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * Parsed options for `apq meta` — `lang`, `json`, the `argContains` / `onKind` filters, `flat`, `limit`, and input `positionals`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef MetaOpts = {
	var lang: String;
	var json: Bool;
	var argContains: Null<String>;
	var onKind: Null<String>;
	var flat: Bool;
	var limit: Int;
	var positionals: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq meta` — annotation-on-decl shortcut.
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class MetaCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'meta';
	}

	public function summary(): String {
		return 'Annotation-on-decl shortcut';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runMeta(args, ctx);
	}

	public function usage(): Void {
		printMetaUsage();
	}

	private static inline function metaParseExit(code: Int): MetaOpts {
		return {
			lang: '',
			json: false,
			argContains: null,
			onKind: null,
			flat: false,
			limit: -1,
			positionals: [],
			errExit: code
		};
	}

	private static function runMeta(args: Array<String>, ctx: CliContext): Int {
		final o: MetaOpts = parseMetaArgs(args);
		if (o.errExit != null) return o.errExit;
		final argContains: Null<String> = o.argContains;
		final onKind: Null<String> = o.onKind;
		final positionals: Array<String> = o.positionals;

		// Positional grammar: [<annotation>[(<arg>)]] <file-or-dir-or-glob>...
		// The annotation, when present, is the leading positional and is
		// recognised by its `@` sigil (Haxe annotations always start with
		// `@`; file/dir/glob specs never do) — this disambiguates without
		// a positional-count cap, so multiple input specs are accepted.
		// With `--on` the annotation may be omitted entirely.
		//
		// The annotation may carry an inline arg filter `@:tag(arg)` — the
		// trailing `(...)` is split off the tag here. `argFilter` keeps only
		// hits whose meta has a TOP-LEVEL argument that is either the bare
		// ident `arg` OR a call `arg(...)` (callee match), the precise
		// counterpart to the `--arg-contains` substring scan. `@:fmt` is the
		// driving case (`@:fmt(propagateExprPosition)`), but the split is
		// tag-agnostic. `@:tag` with no `(...)` leaves the tag untouched and
		// `argFilter` null (the historical no-arg behaviour).
		final rawAnnotation: Null<String> = positionals.length > 0 && StringTools.startsWith(positionals[0], '@') ? positionals[0] : null;
		final annotation: Null<String> = rawAnnotation != null ? annotationTag(rawAnnotation) : null;
		final argFilter: Null<String> = rawAnnotation != null ? annotationArgFilter(rawAnnotation) : null;
		final inputSpecs: Array<String> = rawAnnotation != null ? positionals.slice(1) : positionals.copy();
		if (inputSpecs.length == 0) {
			CliIo.stderr('apq meta: missing <file-or-dir-or-glob> argument\n');
			printMetaUsage();
			return EXIT_USAGE;
		}
		if (annotation == null && onKind == null) {
			// One bare positional with no `--on`: ambiguous — it is taken
			// as the <file-or-dir-or-glob>, leaving no annotation/kind to scope
			// the query. Spell out both halves the grammar needs.
			CliIo.stderr('apq meta: need an <annotation> or --on <decl-kind>, plus a <file-or-dir-or-glob>\n');
			printMetaUsage();
			return EXIT_USAGE;
		}
		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final shape: MetaShape = plugin.metaShape();

		final expanded: ExpandedInputs = CliArgs.expandInputs(inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq meta: no input files matched ${CliArgs.quotedSpecs(inputSpecs)}\n');
			return EXIT_RUNTIME;
		}

		final skipEntries: Array<SkipEntry> = [];
		final allEntries: Null<Array<{ file: String, source: String, hits: Array<MetaHit> }>> =
			collectMetaEntries(paths, plugin, shape, expanded.singleFile, skipEntries, {
				annotation: annotation,
				argContains: argContains,
				argFilter: argFilter,
				onKind: onKind
			});
		if (allEntries == null) return EXIT_RUNTIME;

		if (allEntries.length == 0)
			CliIo.stderr('${CliWalk.emptyWalkerNudge('meta', null, paths.length, paths.length - skipEntries.length, skipEntries, null)}\n');

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = CliWalk.effectiveAutoLimit('meta', o.limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<MetaHit> }> = CliWalk.limitEntries(
			allEntries, cappedLimit, e -> e.hits.length, (e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k) }
		);
		if (o.json) {
			CliIo.sysPrint(Json.renderMeta(shown));
		} else {
			for (entry in shown) CliIo.sysPrint(Text.renderMeta(entry.file, entry.source, entry.hits, o.flat));
		}
		return ctx.emptyExit(allEntries.length == 0);
	}

	private static function argMatches(args: Array<String>, sub: Null<String>): Bool {
		if (sub == null) return true;
		final needle: String = sub;
		return args.exists(a -> a.indexOf(needle) >= 0);
	}

	/**
	 * Split the tag off an `@:tag(arg)` annotation positional. Returns the
	 * leading `@:tag` (trimmed, sans any `(...)` suffix); the historical
	 * bare `@:tag` form passes through unchanged.
	 */
	private static function annotationTag(annotation: String): String {
		final parenIdx: Int = annotation.indexOf('(');
		return StringTools.trim(parenIdx < 0 ? annotation : annotation.substring(0, parenIdx));
	}

	/**
	 * Extract the inline arg filter from an `@:tag(arg)` annotation
	 * positional — the text between the first `(` and the matching last
	 * `)`, trimmed. Returns `null` when the annotation has no `(...)`
	 * suffix (no arg filter) or when the parens are empty.
	 */
	private static function annotationArgFilter(annotation: String): Null<String> {
		final parenIdx: Int = annotation.indexOf('(');
		if (parenIdx < 0) return null;
		final closeIdx: Int = annotation.lastIndexOf(')');
		final raw: String = closeIdx > parenIdx ? annotation.substring(parenIdx + 1, closeIdx) : '';
		final trimmed: String = raw.trim();
		return trimmed.length == 0 ? null : trimmed;
	}

	/**
	 * Precise inline arg filter (`@:tag(arg)`): keep a hit only when one of
	 * its TOP-LEVEL meta args is either the bare ident `arg` OR a call
	 * `arg(...)` (callee match). This is the structural counterpart to the
	 * `--arg-contains` substring scan — `propagateExprPosition` matches a
	 * `propagateExprPosition` arg but NOT a `myPropagateExprPositionExtra`
	 * one. `filter == null` is "no inline arg filter" (every hit passes).
	 */
	private static function argFilterMatches(args: Array<String>, filter: Null<String>): Bool {
		if (filter == null) return true;
		final needle: String = filter;
		for (a in args) {
			final arg: String = a.trim();
			if (arg == needle) return true;
			if (arg.startsWith('$needle(')) return true;
		}
		return false;
	}

	private static function printMetaUsage(): Void {
		CliIo.sysPrint('Usage: apq meta [<annotation>[(<arg>)]] [options] <file-or-dir-or-glob>...\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --arg-contains <s>  Keep hits whose argument list contains <s> (substring)\n');
		CliIo.sysPrint('  --on <decl-kind>    Keep hits attached to the given decl kind\n');
		CliUsage.printFlatLimitLangHelp();
		CliIo.sysPrint('<annotation> is the target language source syntax (e.g. `@:foo`),\n');
		CliIo.sysPrint('recognised by its leading `@`. Omit it with `--on` to list every\n');
		CliIo.sysPrint('annotation on a decl kind.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Inline arg filter `@:tag(arg)` keeps only hits whose meta has a\n');
		CliIo.sysPrint('top-level argument that is the bare ident `arg` OR a call `arg(...)`\n');
		CliIo.sysPrint('(callee match) — e.g. `apq meta \'@:fmt(propagateExprPosition)\' src/`.\n');
		CliIo.sysPrint('Unlike --arg-contains (substring), the inline form is exact per arg.\n');
	}

	private static function parseMetaArgs(args: Array<String>): MetaOpts {
		var lang: String = 'haxe';
		var json: Bool = false;
		var argContains: Null<String> = null;
		var onKind: Null<String> = null;
		var flat: Bool = false;
		var limit: Int = -1;
		final positionals: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--arg-contains':
					argContains = CliArgs.expectValue(args, ++i, '--arg-contains');
				case '--on':
					onKind = CliArgs.expectValue(args, ++i, '--on');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
						CliIo.stderr('${e.message}\n');
						return metaParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printMetaUsage();
					return metaParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq meta: unknown option "$a"\n');
						return metaParseExit(EXIT_USAGE);
					}
					positionals.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			json: json,
			argContains: argContains,
			onKind: onKind,
			flat: flat,
			limit: limit,
			positionals: positionals,
			errExit: null
		};
	}

	private static function collectMetaEntries(
		paths: Array<String>, plugin: GrammarPlugin, shape: MetaShape, singleFile: Bool, skipEntries: Array<SkipEntry>, filter: {
			annotation: Null<String>,
			argContains: Null<String>,
			argFilter: Null<String>,
			onKind: Null<String>
		}
	): Null<Array<{ file: String, source: String, hits: Array<MetaHit> }>> {
		final allEntries: Array<{ file: String, source: String, hits: Array<MetaHit> }> = [];
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked('meta', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				// In single-file mode a parse failure is fatal; signal the
				// caller (null) to return EXIT_RUNTIME. In multi-file mode the
				// file is recorded in skipEntries and the walk continues.
				if (singleFile) return null;
				continue;
			}
			final raw: Array<MetaHit> = Meta.find(tree, shape, source);
			final filtered: Array<MetaHit> = raw.filter(
				h ->
					(filter.annotation == null || h.annotation == filter.annotation) && argMatches(h.args, filter.argContains)
					&& argFilterMatches(h.args, filter.argFilter) && (filter.onKind == null || h.declKind == filter.onKind)
			);
			if (filtered.length == 0) continue;
			allEntries.push({ file: path, source: source, hits: filtered });
		}
		return allEntries;
	}

}
