package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.Refs.RefHit;
import anyparse.query.Uses.UsesHit;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.query.format.Text;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * Parsed options for `apq blast` — `lang`, `flat`, `limit`, `showAll`, the symbol `name`, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef BlastOpts = {
	var lang: String;
	var flat: Bool;
	var limit: Int;
	var showAll: Bool;
	var name: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq blast` — change-impact checklist (uses + refs + member-access).
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class BlastCommand implements CliCommand {

	private static inline final HEUR_DEFAULT_CAP: Int = 20;

	public function new() {}

	public function name(): String {
		return 'blast';
	}

	public function summary(): String {
		return 'Change-impact checklist (uses + refs + member-access)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runBlast(args, ctx);
	}

	public function usage(): Void {
		printBlastUsage();
	}

	private static inline function blastParseExit(code: Int): BlastOpts {
		return {
			lang: '',
			flat: false,
			limit: -1,
			showAll: false,
			name: null,
			inputSpecs: [],
			errExit: code
		};
	}

	/**
	 * `apq blast <type-name> <file-or-dir-or-glob>...` — typedef→enum (or
	 * any type-shape) change-impact checklist. Unions three signals the
	 * lone `uses`/`refs` queries each miss:
	 *
	 *  - `uses` — type-position references (field/param/type-param).
	 *  - `refs` — value-binding references (var/fn/param named the type).
	 *  - heuristic field-access — `expr.member` sites whose member name
	 *    matches a member of the type's own declaration. This is the
	 *    signal `uses`/`refs` are STRUCTURALLY blind to (a `.field`
	 *    access on a value of the type is neither a type position nor a
	 *    value binding) — exactly what was missed assessing a
	 *    typedef→enum blast. Name-based ⇒ a deliberate SUPERSET: it
	 *    over-matches any `.member` with the same identifier. It is a
	 *    verify-each checklist, not a precise result (precise would need
	 *    type inference, which `apq` deliberately does not do).
	 *
	 * The heuristic needs the type's declaration in the scanned set to
	 * learn its member names; if absent, that section is skipped with a
	 * note (the precise `uses`/`refs` sections still print).
	 */
	private static function runBlast(args: Array<String>, ctx: CliContext): Int {
		final o: BlastOpts = parseBlastArgs(args);
		if (o.errExit != null) return o.errExit;
		final name: Null<String> = o.name;
		if (name == null) {
			CliIo.stderr('apq blast: missing <type-name> argument\n');
			printBlastUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq blast: missing <file-or-dir-or-glob> argument\n');
			printBlastUsage();
			return EXIT_USAGE;
		}
		final typeName: String = name;

		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final refShape: RefShape = plugin.refShape();
		final typeShape: TypeRefShape = plugin.typeRefShape();

		final expanded: ExpandedInputs = CliArgs.expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq blast: no input files matched ${CliArgs.quotedSpecs(o.inputSpecs)}\n');
			return EXIT_RUNTIME;
		}

		// Pass 1: learn the type's member names + the spans of its own
		// declaration(s) (to exclude the decl's internals from the
		// heuristic). Walks the value-AST of every file once; cached for
		// the section passes below. NOT pre-filtered on `typeName`: the
		// heuristic field-access section matches MEMBER names, which can
		// occur in files that never name the type textually
		// (`obj.someField` with no mention of the type).
		final memberNames: Array<String> = [];
		final declSpans: Array<Span> = [];
		final valueTrees: Array<{ path: String, source: String, tree: QueryNode }> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked('blast', plugin.parseFile, path, source, expanded.singleFile);
			CliIo.streamProgress('blast', ++scanned, paths.length, expanded.singleFile);
			if (tree == null) {
				if (expanded.singleFile) return EXIT_RUNTIME;
				continue;
			}
			valueTrees.push({ path: path, source: source, tree: tree });
			collectTypeDecl(tree, typeName, memberNames, declSpans);
		}

		var any: Bool = false;
		// Section 1 — type-position references (precise). Section 2 —
		// value-binding references (precise). Section 3 — heuristic
		// member-name field-access (superset). Order is fixed (precise
		// before heuristic); each section returns whether it printed a hit.
		if (blastUsesSection(valueTrees, typeName, typeShape, plugin, expanded.singleFile, o.flat)) any = true;
		if (blastRefsSection(valueTrees, typeName, refShape, o.flat, plugin.lexicalRegions)) any = true;

		if (memberNames.length == 0) {
			CliIo.stderr(
				'apq blast: no declaration of "$typeName" in the scanned set — '
				+ 'heuristic field-access section skipped (uses/refs above are complete).\n'
			);
			if (!any) CliIo.stderr('apq blast: no uses / refs of "$typeName" found\n');
			return ctx.emptyExit(!any);
		}
		if (blastHeuristicSection(valueTrees, memberNames, declSpans, typeName, o.showAll, o.limit)) any = true;

		if (!any) CliIo.stderr('apq blast: no uses / refs / member-access of "$typeName" found\n');
		return ctx.emptyExit(!any);
	}

	/**
	 * Collect the member names + declaration spans of every top-level
	 * declaration named `typeName` (kind ends in `Decl` — the Haxe
	 * decl-kind convention). `@:meta` / `@:fmt(...)` argument subtrees
	 * are skipped so meta identifiers don't pollute the member set.
	 */
	private static function collectTypeDecl(node: QueryNode, typeName: String, names: Array<String>, declSpans: Array<Span>): Void {
		if (node.kind.endsWith('Decl') && node.name == typeName) {
			if (node.span != null) declSpans.push(node.span);
			collectMemberNames(node, typeName, names);
			return;
		}
		for (c in node.children) collectTypeDecl(c, typeName, names, declSpans);
	}

	private static function collectMemberNames(node: QueryNode, typeName: String, names: Array<String>): Void {
		if (node.kind == 'Meta' || node.kind == 'MetaCall') return;
		final n: Null<String> = node.name;
		if (n != null && n != typeName && !names.contains(n)) names.push(n);
		for (c in node.children) collectMemberNames(c, typeName, names);
	}

	/**
	 * Walk for `FieldAccess` nodes whose accessed member name is one of
	 * `names`, excluding any inside a declaration-of-type span. Records
	 * a `file:line:col` line per hit.
	 */
	private static function collectMemberAccess(
		node: QueryNode, names: Array<String>, declSpans: Array<Span>, file: String, source: String,
		out: Array<{ loc: String, line: String }>
	): Void {
		if (node.kind == 'FieldAccess') {
			final n: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (n != null && span != null && names.contains(n) && !spanInsideAny(span, declSpans)) {
				final pos: Position = span.lineCol(source);
				final loc: String = '$file:${pos.line}:${pos.col}';
				out.push({ loc: loc, line: '$loc: .$n' });
			}
		}
		for (c in node.children) collectMemberAccess(c, names, declSpans, file, source, out);
	}

	private static function spanInsideAny(span: Span, outer: Array<Span>): Bool {
		return outer.exists(o -> o.from <= span.from && span.to <= o.to);
	}

	private static function printBlastUsage(): Void {
		CliIo.sysPrint('Usage: apq blast [options] <type-name> <file-or-dir-or-glob>...\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		CliIo.sysPrint('  --limit <n>         Explicit cap on the heuristic section (overrides smart default)\n');
		CliIo.sysPrint('  --all               Disable the smart-default cap on the heuristic section\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Heuristic field-access (`.member` superset) is capped at ${HEUR_DEFAULT_CAP} by default.\n');
		CliIo.sysPrint('Pass --all for the full list, or --limit N for an explicit cap.\n');
		CliIo.sysPrint('Precise uses / refs sections are uncapped.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Change-impact checklist for a type. Unions three sections:\n');
		CliIo.sysPrint('  uses  — type-position references (precise)\n');
		CliIo.sysPrint('  refs  — value-binding references (precise)\n');
		CliIo.sysPrint('  heuristic field-access — `expr.member` whose member name is\n');
		CliIo.sysPrint('          a member of the type\'s decl. SUPERSET / name-based —\n');
		CliIo.sysPrint('          over-matches, VERIFY each. This is the signal plain\n');
		CliIo.sysPrint('          `uses`/`refs` are blind to (the typedef->enum gap).\n');
		CliIo.sysPrint('Needs the type\'s declaration in the scanned set for the\n');
		CliIo.sysPrint('heuristic; absent ⇒ that section is skipped (uses/refs stand).\n');
	}

	private static function parseBlastArgs(args: Array<String>): BlastOpts {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		var showAll: Bool = false;
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
						return blastParseExit(EXIT_USAGE);
					}
				case '--all':
					showAll = true;
				case '-h', '--help':
					printBlastUsage();
					return blastParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq blast: unknown option "$a"\n');
						return blastParseExit(EXIT_USAGE);
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
			showAll: showAll,
			name: name,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function blastUsesSection(
		valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, typeName: String, typeShape: TypeRefShape,
		plugin: GrammarPlugin, singleFile: Bool, flat: Bool
	): Bool {
		var any: Bool = false;
		var usesHeader: Bool = false;
		for (entry in valueTrees) {
			final typeTree: Null<QueryNode> = CliWalk.parseWalked(
				'blast', plugin.parseFileTypeRefs, entry.path, entry.source, singleFile, null, typeName
			);
			if (typeTree == null) continue;
			final hits: Array<UsesHit> = Uses.find(typeName, typeTree, typeShape);
			if (hits.length == 0) continue;
			any = true;
			if (!usesHeader) {
				CliIo.sysPrint('# uses (type positions)\n');
				usesHeader = true;
			}
			CliIo.sysPrint(Text.renderUses(entry.path, entry.source, hits, false, false, flat, plugin.lexicalRegions(entry.source)));
		}
		return any;
	}

	private static function blastRefsSection(
		valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, typeName: String, refShape: RefShape, flat: Bool,
		lexicalRegions: (String) -> Array<LexRegion>
	): Bool {
		var any: Bool = false;
		var refsHeader: Bool = false;
		for (entry in valueTrees) {
			final hits: Array<RefHit> = Refs.find(typeName, entry.tree, refShape);
			if (hits.length == 0) continue;
			any = true;
			if (!refsHeader) {
				CliIo.sysPrint('# refs (value bindings)\n');
				refsHeader = true;
			}
			CliIo.sysPrint(Text.renderRefs(entry.path, entry.source, hits, false, false, lexicalRegions(entry.source), flat));
		}
		return any;
	}

	private static function blastHeuristicSection(
		valueTrees: Array<{ path: String, source: String, tree: QueryNode }>, memberNames: Array<String>, declSpans: Array<Span>,
		typeName: String, showAll: Bool, limit: Int
	): Bool {
		final heur: Array<{ loc: String, line: String }> = [];
		for (entry in valueTrees) collectMemberAccess(entry.tree, memberNames, declSpans, entry.path, entry.source, heur);
		if (heur.length == 0) return false;
		// Smart-default cap on the heuristic section — the typical
		// transcript pain is `blast` flooding hundreds of `.member`
		// lines when the type's member names are common identifiers
		// (`.name`, `.type`, `.value`). Without `--limit` the
		// heuristic caps at HEUR_DEFAULT_CAP and prints a hint
		// pointing at `--all` (no cap) or `--limit N` (explicit).
		// Precise `uses` / `refs` sections stay uncapped — they
		// are name-bound and rarely flood.
		final defaultCap: Int = showAll ? -1 : HEUR_DEFAULT_CAP;
		final effectiveLimit: Int = limit >= 0 ? limit : defaultCap;
		final capped: Array<{ loc: String, line: String }> = effectiveLimit >= 0 && heur.length > effectiveLimit
			? heur.slice(0, effectiveLimit)
			: heur;
		final hint: String = capped.length < heur.length ? (limit >= 0 ? '' : ' — pass --all to show all, --limit N for explicit cap') : '';
		CliIo.sysPrint(
			'# heuristic field-access (member-name superset of "$typeName" — VERIFY each; '
			+ 'name-based, over-matches; ${capped.length}/${heur.length} shown$hint)\n'
		);
		for (h in capped) CliIo.sysPrint('${h.line}\n');
		return true;
	}

}
