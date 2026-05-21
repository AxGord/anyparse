package anyparse.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.Lit.LitHit;
import anyparse.query.Matcher.Match;
import anyparse.query.Meta.MetaHit;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.Uses.UsesHit;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;
import haxe.Exception;

#if (sys || nodejs)
import sys.io.File;
#end

/**
 * `apq` CLI entry point. Parses argv, picks a grammar plugin via
 * `--lang`, dispatches on the subcommand.
 *
 * Phase 1 surface: `apq ast <file> [--lang L] [--json] [--depth N]
 * [--select PATH] [--at LINE:COL] [--min-children N] [--max-children N]`.
 * Other subcommands (`search`,
 * `refs`, `meta`) are reserved — calling them prints a "deferred"
 * notice with the phase that owns each.
 */
@:nullSafety(Strict)
final class Cli {

	private static final EXIT_OK:Int = 0;
	private static final EXIT_USAGE:Int = 2;
	private static final EXIT_RUNTIME:Int = 1;

	private static final SKIP_PATHS_SHOWN:Int = 5;
	private static final FUZZY_MAX_DIST:Int = 3;
	private static final FUZZY_TOP_K:Int = 3;
	/**
	 * Substring "did you mean" — `query` ≥ this length OR the substring
	 * pre-filter is skipped (avoids `Hx` matching every grammar type).
	 */
	private static final FUZZY_SUBSTRING_MIN_QUERY:Int = 4;
	/**
	 * Substring "did you mean" — candidate's extra char count over
	 * `query.length` must not exceed this (avoids `Foo` matching a huge
	 * `FooSomeReallyLongName` and crowding out true neighbours).
	 */
	private static final FUZZY_SUBSTRING_MAX_EXTRA:Int = 8;

	public static function main():Void {
		#if (sys || nodejs)
		Sys.exit(run(Sys.args()));
		#else
		throw 'apq: only sys targets supported';
		#end
	}

	/** Pure-argv entry. Returns process exit code. */
	public static function run(args:Array<String>):Int {
		if (args.length == 0 || args[0] == '-h' || args[0] == '--help') {
			printUsage();
			return EXIT_OK;
		}
		final cmd:String = args[0];
		final rest:Array<String> = args.slice(1);
		switch cmd {
			case 'ast': return runAst(rest);
			case 'search': return runSearch(rest);
			case 'refs': return runRefs(rest);
			case 'uses': return runUses(rest);
			case 'meta': return runMeta(rest);
			case 'blast': return runBlast(rest);
			case 'lit': return runLit(rest);
			case _:
				stderr('apq: unknown subcommand "$cmd"\n');
				printUsage();
				return EXIT_USAGE;
		}
	}

	private static function runRefs(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var wantDecls:Bool = false;
		var wantReads:Bool = false;
		var wantWrites:Bool = false;
		var wantDoc:Bool = false;
		var wantSource:Bool = false;
		var limit:Int = -1;
		var name:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--decls':
					wantDecls = true;
				case '--reads':
					wantReads = true;
				case '--writes':
					wantWrites = true;
				case '--doc':
					wantDoc = true;
				case '--source':
					wantSource = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printRefsUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq refs: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (name == null) name = a;
					else inputSpecs.push(a);
			}
			i++;
		}
		if (name == null) {
			stderr('apq refs: missing <name> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq refs: missing <file-or-dir-or-glob> argument\n');
			printRefsUsage();
			return EXIT_USAGE;
		}
		final nameStr:String = name;
		// No flag = no filter (emit every hit). Any flag flips on the
		// allow-set; sister CLIs (`git log --author --grep`) follow the
		// same any-flag-narrows convention.
		final anyFilter:Bool = wantDecls || wantReads || wantWrites;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:RefShape = plugin.refShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq refs: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<RefHit>}> = [];
		final skipPaths:Array<String> = [];
		final candidateNames:Map<String, Bool> = new Map();
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('refs', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				skipPaths.push(path);
				continue;
			}
			final raw:Array<RefHit> = Refs.find(nameStr, tree, shape);
			final filtered:Array<RefHit> = anyFilter
				? raw.filter(h -> kindAllowed(h.kind, wantDecls, wantReads, wantWrites))
				: raw;
			if (filtered.length == 0) {
				collectNames(tree, candidateNames);
				continue;
			}
			allEntries.push({file: path, source: source, hits: filtered});
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('refs', nameStr, paths.length, paths.length - skipPaths.length, skipPaths, candidateNames) + '\n');

		final shown:Array<{file:String, source:String, hits:Array<RefHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		if (json) {
			sysPrint(Json.renderRefs(shown, wantDoc, wantSource));
		} else {
			for (entry in shown) sysPrint(Text.renderRefs(entry.file, entry.source, entry.hits, wantDoc, wantSource));
		}
		return EXIT_OK;
	}

	private static function runUses(args:Array<String>):Int {
		var lang:String = 'haxe';
		var wantDoc:Bool = false;
		var wantSource:Bool = false;
		var limit:Int = -1;
		var name:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--doc':
					wantDoc = true;
				case '--source':
					wantSource = true;
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printUsesUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq uses: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (name == null) name = a;
					else inputSpecs.push(a);
			}
			i++;
		}
		if (name == null) {
			stderr('apq uses: missing <type-name> argument\n');
			printUsesUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq uses: missing <file-or-dir-or-glob> argument\n');
			printUsesUsage();
			return EXIT_USAGE;
		}
		final nameStr:String = name;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:TypeRefShape = plugin.typeRefShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq uses: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<UsesHit>}> = [];
		final skipPaths:Array<String> = [];
		final candidateNames:Map<String, Bool> = new Map();
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('uses', plugin.parseFileTypeRefs, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				skipPaths.push(path);
				continue;
			}
			final hits:Array<UsesHit> = Uses.find(nameStr, tree, shape);
			if (hits.length == 0) {
				collectNames(tree, candidateNames);
				continue;
			}
			allEntries.push({file: path, source: source, hits: hits});
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('uses', nameStr, paths.length, paths.length - skipPaths.length, skipPaths, candidateNames) + '\n');

		final shown:Array<{file:String, source:String, hits:Array<UsesHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		for (entry in shown) sysPrint(Text.renderUses(entry.file, entry.source, entry.hits, wantDoc, wantSource));
		return EXIT_OK;
	}

	private static function runMeta(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var argContains:Null<String> = null;
		var onKind:Null<String> = null;
		var limit:Int = -1;
		final positionals:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--arg-contains':
					argContains = expectValue(args, ++i, '--arg-contains');
				case '--on':
					onKind = expectValue(args, ++i, '--on');
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printMetaUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq meta: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					positionals.push(a);
			}
			i++;
		}

		// Positional grammar: [<annotation>] <file-or-dir-or-glob>...
		// The annotation, when present, is the leading positional and is
		// recognised by its `@` sigil (Haxe annotations always start with
		// `@`; file/dir/glob specs never do) — this disambiguates without
		// a positional-count cap, so multiple input specs are accepted.
		// With `--on` the annotation may be omitted entirely.
		final annotation:Null<String> = positionals.length > 0 && StringTools.startsWith(positionals[0], '@')
			? positionals[0] : null;
		final inputSpecs:Array<String> = annotation != null ? positionals.slice(1) : positionals.copy();
		if (inputSpecs.length == 0) {
			stderr('apq meta: missing <file-or-dir-or-glob> argument\n');
			printMetaUsage();
			return EXIT_USAGE;
		}
		if (annotation == null && onKind == null) {
			// One bare positional with no `--on`: ambiguous — it is taken
			// as the <file-or-dir-or-glob>, leaving no annotation/kind to scope
			// the query. Spell out both halves the grammar needs.
			stderr('apq meta: need an <annotation> or --on <decl-kind>, plus a <file-or-dir-or-glob>\n');
			printMetaUsage();
			return EXIT_USAGE;
		}
		final plugin:GrammarPlugin = pickPlugin(lang);
		final shape:MetaShape = plugin.metaShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq meta: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<MetaHit>}> = [];
		final skipPaths:Array<String> = [];
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('meta', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				skipPaths.push(path);
				continue;
			}
			final raw:Array<MetaHit> = Meta.find(tree, shape, source);
			final filtered:Array<MetaHit> = raw.filter(h ->
				(annotation == null || h.annotation == annotation)
				&& argMatches(h.args, argContains)
				&& (onKind == null || h.declKind == onKind));
			if (filtered.length == 0) continue;
			allEntries.push({file: path, source: source, hits: filtered});
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('meta', null, paths.length, paths.length - skipPaths.length, skipPaths, null) + '\n');

		final shown:Array<{file:String, source:String, hits:Array<MetaHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		if (json) {
			sysPrint(Json.renderMeta(shown));
		} else {
			for (entry in shown) sysPrint(Text.renderMeta(entry.file, entry.source, entry.hits));
		}
		return EXIT_OK;
	}

	/**
	 * `apq lit <text> <file-or-dir-or-glob>...` — leaf-name probe over
	 * the parsed AST. Default kind filter `Literal` catches every
	 * string-literal occurrence (the leaf inside `SingleStringExpr`
	 * / `DoubleStringExpr` / `RawString`); pass `--kind <K1,K2>` to
	 * widen (e.g. `Literal,IdentExpr`) or override.
	 *
	 * The structural alternative to `# HXQ_OK:prose`-escaped grep for
	 * annotation-key / config-string lookups inside parseable `.hx`.
	 * Skips comments and string interpolations as a side effect of
	 * routing through the parser — no false positives from prose
	 * inside doc-comments or `'$ident'` interpolation segments.
	 */
	private static function runLit(args:Array<String>):Int {
		var lang:String = 'haxe';
		var exact:Bool = false;
		var limit:Int = -1;
		var kindFilter:Array<String> = ['Literal'];
		var target:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--exact':
					exact = true;
				case '--kind':
					kindFilter = expectValue(args, ++i, '--kind').split(',');
				case '--any-kind':
					kindFilter = [];
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printLitUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq lit: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (target == null) target = a;
					else inputSpecs.push(a);
			}
			i++;
		}
		if (target == null) {
			stderr('apq lit: missing <text> argument\n');
			printLitUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq lit: missing <file-or-dir-or-glob> argument\n');
			printLitUsage();
			return EXIT_USAGE;
		}
		final targetStr:String = target;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq lit: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, hits:Array<LitHit>}> = [];
		final skipPaths:Array<String> = [];
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('lit', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				skipPaths.push(path);
				continue;
			}
			final hits:Array<LitHit> = Lit.find(targetStr, tree, exact, kindFilter);
			if (hits.length == 0) continue;
			allEntries.push({file: path, source: source, hits: hits});
		}

		if (allEntries.length == 0)
			stderr(emptyWalkerNudge('lit', targetStr, paths.length, paths.length - skipPaths.length, skipPaths, null) + '\n');

		final shown:Array<{file:String, source:String, hits:Array<LitHit>}> = limitEntries(allEntries, limit,
			e -> e.hits.length,
			(e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)});
		for (entry in shown) sysPrint(Lit.render(entry.file, entry.source, entry.hits));
		return EXIT_OK;
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
	private static function runBlast(args:Array<String>):Int {
		var lang:String = 'haxe';
		var limit:Int = -1;
		var name:Null<String> = null;
		final inputSpecs:Array<String> = [];

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--limit':
					try limit = parseLimit(args, ++i) catch (e:Exception) {
						stderr('${e.message}\n');
						return EXIT_USAGE;
					}
				case '-h', '--help':
					printBlastUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq blast: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (name == null) name = a;
					else inputSpecs.push(a);
			}
			i++;
		}
		if (name == null) {
			stderr('apq blast: missing <type-name> argument\n');
			printBlastUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq blast: missing <file-or-dir-or-glob> argument\n');
			printBlastUsage();
			return EXIT_USAGE;
		}
		final typeName:String = name;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final refShape:RefShape = plugin.refShape();
		final typeShape:TypeRefShape = plugin.typeRefShape();

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq blast: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		// Pass 1: learn the type's member names + the spans of its own
		// declaration(s) (to exclude the decl's internals from the
		// heuristic). Walks the value-AST of every file once; cached for
		// pass 2.
		final memberNames:Array<String> = [];
		final declSpans:Array<Span> = [];
		final valueTrees:Array<{path:String, source:String, tree:QueryNode}> = [];
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('blast', plugin.parseFile, path, source, expanded.singleFile);
			if (tree == null) {
				if (expanded.singleFile) return EXIT_RUNTIME;
				continue;
			}
			valueTrees.push({path: path, source: source, tree: tree});
			collectTypeDecl(tree, typeName, memberNames, declSpans);
		}

		var any:Bool = false;

		// Section 1 — type-position references (precise). The header is
		// emitted once, before the first file with a hit.
		var usesHeader:Bool = false;
		for (entry in valueTrees) {
			final typeTree:Null<QueryNode> = parseWalked('blast', plugin.parseFileTypeRefs, entry.path, entry.source, expanded.singleFile);
			if (typeTree == null) continue;
			final hits:Array<UsesHit> = Uses.find(typeName, typeTree, typeShape);
			if (hits.length == 0) continue;
			any = true;
			if (!usesHeader) {
				sysPrint('# uses (type positions)\n');
				usesHeader = true;
			}
			sysPrint(Text.renderUses(entry.path, entry.source, hits, false, false));
		}

		// Section 2 — value-binding references (precise).
		var refsHeader:Bool = false;
		for (entry in valueTrees) {
			final hits:Array<RefHit> = Refs.find(typeName, entry.tree, refShape);
			if (hits.length == 0) continue;
			any = true;
			if (!refsHeader) {
				sysPrint('# refs (value bindings)\n');
				refsHeader = true;
			}
			sysPrint(Text.renderRefs(entry.path, entry.source, hits, false, false));
		}

		// Section 3 — heuristic member-name field-access (superset).
		if (memberNames.length == 0) {
			stderr('apq blast: no declaration of "$typeName" in the scanned set — '
				+ 'heuristic field-access section skipped (uses/refs above are complete).\n');
			if (!any) stderr('apq blast: no uses / refs of "$typeName" found\n');
			return EXIT_OK;
		}
		final heur:Array<{loc:String, line:String}> = [];
		for (entry in valueTrees)
			collectMemberAccess(entry.tree, memberNames, declSpans, entry.path, entry.source, heur);
		if (heur.length > 0) {
			final capped:Array<{loc:String, line:String}> = (limit >= 0 && heur.length > limit) ? heur.slice(0, limit) : heur;
			sysPrint('# heuristic field-access (member-name superset of "$typeName" — VERIFY each; '
				+ 'name-based, over-matches; ${capped.length}/${heur.length} shown)\n');
			for (h in capped) sysPrint('${h.line}\n');
			any = true;
		}

		if (!any) stderr('apq blast: no uses / refs / member-access of "$typeName" found\n');
		return EXIT_OK;
	}

	/**
	 * Collect the member names + declaration spans of every top-level
	 * declaration named `typeName` (kind ends in `Decl` — the Haxe
	 * decl-kind convention). `@:meta` / `@:fmt(...)` argument subtrees
	 * are skipped so meta identifiers don't pollute the member set.
	 */
	private static function collectTypeDecl(node:QueryNode, typeName:String, names:Array<String>, declSpans:Array<Span>):Void {
		if (StringTools.endsWith(node.kind, 'Decl') && node.name == typeName) {
			if (node.span != null) declSpans.push(node.span);
			collectMemberNames(node, typeName, names);
			return;
		}
		for (c in node.children) collectTypeDecl(c, typeName, names, declSpans);
	}

	private static function collectMemberNames(node:QueryNode, typeName:String, names:Array<String>):Void {
		if (node.kind == 'Meta' || node.kind == 'MetaCall') return;
		final n:Null<String> = node.name;
		if (n != null && n != typeName && !names.contains(n)) names.push(n);
		for (c in node.children) collectMemberNames(c, typeName, names);
	}

	/**
	 * Walk for `FieldAccess` nodes whose accessed member name is one of
	 * `names`, excluding any inside a declaration-of-type span. Records
	 * a `file:line:col` line per hit.
	 */
	private static function collectMemberAccess(node:QueryNode, names:Array<String>, declSpans:Array<Span>, file:String, source:String, out:Array<{loc:String, line:String}>):Void {
		if (node.kind == 'FieldAccess') {
			final n:Null<String> = node.name;
			final span:Null<Span> = node.span;
			if (n != null && span != null && names.contains(n) && !spanInsideAny(span, declSpans)) {
				final pos:Position = span.lineCol(source);
				final loc:String = '$file:${pos.line}:${pos.col}';
				out.push({loc: loc, line: '$loc: .$n'});
			}
		}
		for (c in node.children) collectMemberAccess(c, names, declSpans, file, source, out);
	}

	private static function spanInsideAny(span:Span, outer:Array<Span>):Bool {
		for (o in outer) if (o.from <= span.from && span.to <= o.to) return true;
		return false;
	}

	private static function argMatches(args:Array<String>, sub:Null<String>):Bool {
		if (sub == null) return true;
		final needle:String = sub;
		for (a in args) if (a.indexOf(needle) >= 0) return true;
		return false;
	}

	private static inline function kindAllowed(k:RefKind, decls:Bool, reads:Bool, writes:Bool):Bool {
		return switch k {
			case Decl: decls;
			case Read: reads;
			case Write: writes;
		}
	}

	private static function runSearch(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var kind:Null<String> = null;
		var limit:Int = -1;
		var explain:Bool = false;
		var pattern:Null<String> = null;
		final inputSpecs:Array<String> = [];

		// `--` is the standard end-of-options sentinel: every token after
		// it is positional, never an option. A search pattern can legally
		// start with `--` (`--$x` = prefix-decrement), which would
		// otherwise be rejected as an unknown option — the sentinel is the
		// only way to reach those patterns.
		var optsEnded:Bool = false;
		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			var isOption:Bool = false;
			if (!optsEnded) {
				isOption = true;
				switch a {
					case '--lang':
						lang = expectValue(args, ++i, '--lang');
					case '--json':
						json = true;
					case '--kind':
						kind = expectValue(args, ++i, '--kind');
					case '--explain':
						explain = true;
					case '--limit':
						try limit = parseLimit(args, ++i) catch (e:Exception) {
							stderr('${e.message}\n');
							return EXIT_USAGE;
						}
					case '-h', '--help':
						printSearchUsage();
						return EXIT_OK;
					case '--':
						optsEnded = true;
					case _:
						if (StringTools.startsWith(a, '--')) {
							stderr('apq search: unknown option "$a"\n');
							return EXIT_USAGE;
						}
						isOption = false;
				}
			}
			if (!isOption) {
				if (pattern == null) pattern = a;
				else inputSpecs.push(a);
			}
			i++;
		}
		if (pattern == null) {
			stderr('apq search: missing <pattern> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			stderr('apq search: missing <file-or-dir-or-glob> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		final patternStr:String = pattern;

		final plugin:GrammarPlugin = pickPlugin(lang);
		final parsed:Pattern = try plugin.parsePattern(patternStr)
			catch (e:Exception) {
				stderr('apq search: pattern: ${e.message}\n');
				return EXIT_RUNTIME;
			};

		// Non-fatal: a leaf pattern (bare name / lone metavar / bare
		// literal) has no code shape — search only hits it in
		// expression position, never a decl or type. Point at the
		// right tool (kind-aware) and proceed anyway.
		//
		// Kind branches:
		//  - Metavar           — lone `$x` matches every node; refs/uses
		//                        don't apply (no name to look up).
		//  - Literal / *Lit    — literal value; `apq lit '<value>'` is
		//                        the right tool (refs/uses don't apply).
		//  - IdentExpr / other — bare identifier; refs/uses/lit all
		//                        plausible depending on intent.
		if (parsed.isDegenerate())
			stderr(degenerateNudge(patternStr, parsed.root.kind) + '\n');

		// `--explain`: emit the parsed pattern's S-expr to stderr at
		// scan start. When 0 matches across all scanned files the
		// closing diagnostic also prints the top input-kind histogram
		// — the most common reason a structurally-valid pattern misses
		// is a kind mismatch (e.g. searching `switch $x { … }` against
		// a tree whose actual kind is `SwitchExpr`, not `Switch`).
		if (explain) {
			stderr('apq search: pattern parses as:\n');
			stderr(Text.render(parsed.root));
		}

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq search: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, matches:Array<Match>}> = [];
		final kindCounts:Map<String, Int> = new Map();
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('search', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			if (explain) tallyKinds(tree, kindCounts);
			final matches:Array<Match> = Matcher.search(parsed, tree, kind);
			if (matches.length == 0) continue;
			allEntries.push({file: path, source: source, matches: matches});
		}

		// `--explain` closing diagnostic on 0 hits: print the kind
		// histogram so the user can see whether the pattern's root
		// kind even appears in the scanned input. The most common
		// mismatch is "pattern parses as Kind X but inputs only
		// expose Kind Y for the same construct" — visible at a
		// glance once both lists are on screen.
		if (explain && allEntries.length == 0) {
			final patternKind:String = parsed.root.kind;
			final entries:Array<{k:String, n:Int}> = [for (k => n in kindCounts) {k: k, n: n}];
			entries.sort((a, b) -> a.n == b.n ? (a.k < b.k ? -1 : 1) : b.n - a.n);
			final topN:Int = entries.length < 12 ? entries.length : 12;
			stderr('apq search: 0 matches; pattern root kind is "$patternKind". Top kinds seen in input (${entries.length} distinct):\n');
			for (k in 0...topN) {
				final e = entries[k];
				final marker:String = e.k == patternKind ? ' ← matches pattern root' : '';
				stderr('  ${e.k} (${e.n})$marker\n');
			}
			if (!Lambda.exists(entries, e -> e.k == patternKind))
				stderr('  (pattern root kind "$patternKind" NOT present in any scanned file — likely the wrong kind for this construct; check `apq ast <file>` to see the actual node shape)\n');
		}

		final shown:Array<{file:String, source:String, matches:Array<Match>}> = limitEntries(allEntries, limit,
			e -> e.matches.length,
			(e, k) -> {file: e.file, source: e.source, matches: e.matches.slice(0, k)});
		if (json) {
			final combined:StringBuf = new StringBuf();
			combined.add('{"matches":[');
			var first:Bool = true;
			for (entry in shown) {
				for (m in entry.matches) {
					if (!first) combined.add(',');
					first = false;
					combined.add(perMatchJson(entry.file, entry.source, m));
				}
			}
			combined.add(']}\n');
			sysPrint(combined.toString());
		} else {
			for (entry in shown) sysPrint(Text.renderSearchMatches(entry.file, entry.source, entry.matches));
		}
		return EXIT_OK;
	}

	private static function perMatchJson(file:String, source:String, m:Match):String {
		// Render a single match through the macro-generated writer by
		// wrapping it in a singleton envelope, then slicing the inner
		// JSON object out. Keeps every entry typed through the same path
		// as the multi-match render — no separate stringify code.
		final rendered:String = Json.renderSearchMatches(file, source, [m]);
		// Strip the `{"matches":[` prefix and `]}\n` suffix to get the
		// bare match object for inclusion in the multi-file array.
		final inner:String = StringTools.trim(rendered);
		final openIdx:Int = inner.indexOf('[');
		final closeIdx:Int = inner.lastIndexOf(']');
		if (openIdx < 0 || closeIdx <= openIdx) return rendered;
		return inner.substring(openIdx + 1, closeIdx);
	}

	private static function runAst(args:Array<String>):Int {
		var lang:String = 'haxe';
		var json:Bool = false;
		var depth:Int = -1;
		var selectExpr:Null<String> = null;
		var atExpr:Null<String> = null;
		var wantDoc:Bool = false;
		var wantSource:Bool = false;
		var minChildren:Int = -1;
		var maxChildren:Int = -1;
		var file:Null<String> = null;

		var i:Int = 0;
		while (i < args.length) {
			final a:String = args[i];
			switch a {
				case '--lang':
					lang = expectValue(args, ++i, '--lang');
				case '--json':
					json = true;
				case '--depth':
					final v:String = expectValue(args, ++i, '--depth');
					final parsed:Null<Int> = Std.parseInt(v);
					if (parsed == null) {
						stderr('apq ast: --depth expects an integer, got "$v"\n');
						return EXIT_USAGE;
					}
					depth = parsed;
				case '--select':
					selectExpr = expectValue(args, ++i, '--select');
				case '--at':
					atExpr = expectValue(args, ++i, '--at');
				case '--doc':
					wantDoc = true;
				case '--source':
					wantSource = true;
				case '--min-children':
					final v:String = expectValue(args, ++i, '--min-children');
					final parsed:Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						stderr('apq ast: --min-children expects a non-negative integer, got "$v"\n');
						return EXIT_USAGE;
					}
					minChildren = parsed;
				case '--max-children':
					final v:String = expectValue(args, ++i, '--max-children');
					final parsed:Null<Int> = Std.parseInt(v);
					if (parsed == null || parsed < 0) {
						stderr('apq ast: --max-children expects a non-negative integer, got "$v"\n');
						return EXIT_USAGE;
					}
					maxChildren = parsed;
				case '-h', '--help':
					printAstUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq ast: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file != null) {
						// `apq ast <TypeName> <dir>` is a common miss — `ast` is single-
						// file, while `<TypeName> <dir>` is the refs/uses/meta surface.
						// Detect the shape (first arg looks like a TypeName, second arg
						// is an existing directory or .hx file) and route the user.
						final maybeTypeArg:String = file;
						final maybeDirArg:String = a;
						if (looksLikeTypeName(maybeTypeArg) && looksLikePath(maybeDirArg))
							stderr('apq ast: only one file argument supported (got "$maybeTypeArg" and "$maybeDirArg").\n'
								+ '         "$maybeTypeArg" looks like a TypeName and "$maybeDirArg" like a path — `ast` is single-file.\n'
								+ '         For type lookup across a directory:\n'
								+ '           apq refs $maybeTypeArg $maybeDirArg --decls    # value bindings + decl site\n'
								+ '           apq uses $maybeTypeArg $maybeDirArg            # type-position consumers\n'
								+ '           apq blast $maybeTypeArg $maybeDirArg           # full change-impact (uses + refs + field-access)\n'
								+ '           apq meta @:peg $maybeDirArg                    # all PEG decls in scope\n'
								+ '         For a subtree of one file:\n'
								+ '           apq ast <path-to-file.hx> --select Kind:$maybeTypeArg\n');
						else
							stderr('apq ast: only one file argument supported (got "$file" and "$a")\n');
						return EXIT_USAGE;
					}
					file = a;
			}
			i++;
		}

		if (file == null) {
			stderr('apq ast: missing <file> argument\n');
			printAstUsage();
			return EXIT_USAGE;
		}
		final plugin:GrammarPlugin = pickPlugin(lang);
		final source:String = readFile(file);
		final tree:QueryNode = try plugin.parseFile(source) catch (e:ParseError) {
			stderr('apq ast: $file: ${e.toString()}\n');
			return EXIT_RUNTIME;
		} catch (e:Exception) {
			stderr('apq ast: $file: ${e.message}\n');
			return EXIT_RUNTIME;
		}

		if (atExpr != null) {
			final colonIdx:Int = atExpr.indexOf(':');
			if (colonIdx < 0) {
				stderr('apq ast: --at expects LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			final atLine:Null<Int> = Std.parseInt(atExpr.substring(0, colonIdx));
			final atCol:Null<Int> = Std.parseInt(atExpr.substring(colonIdx + 1));
			if (atLine == null || atCol == null) {
				stderr('apq ast: --at expects integer LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			// Capture into non-null locals immediately after the null
			// check — Strict narrows locals, not the Null<Int> bindings,
			// and `Span.offsetOf` takes plain Int.
			final atLineN:Int = atLine;
			final atColN:Int = atCol;
			if (atLineN < 1 || atColN < 1) {
				stderr('apq ast: --at expects 1-indexed LINE:COL, got "$atExpr"\n');
				return EXIT_USAGE;
			}
			final offset:Int = Span.offsetOf(source, atLineN, atColN);
			final node:Null<QueryNode> = Engine.at(tree, offset);
			final matches:Array<QueryNode> = node == null ? [] : [depth < 0 ? node : Engine.truncate(node, depth)];
			sysPrint(json ? Json.renderMatches(file, source, matches, wantDoc, wantSource) : Text.renderMatches(matches, source, wantDoc, wantSource));
			return EXIT_OK;
		}

		if (selectExpr != null) {
			final selector:Selector = Selector.parse(selectExpr);
			final preFilter:Array<QueryNode> = Engine.select(tree, selector);
			// ω-ast-child-count-filter: post-filter on direct-child count so
			// "find all multi-arg ParamCtor ctors" is one query. The selector
			// grammar (`Kind` / `Kind:name` / `Kind > Child`) is deliberately
			// minimal and stays that way — arity is a numeric predicate, not
			// a structural one, and lives on the CLI instead of the path.
			final raw:Array<QueryNode> = (minChildren < 0 && maxChildren < 0)
				? preFilter
				: [
					for (m in preFilter)
						if ((minChildren < 0 || m.children.length >= minChildren)
							&& (maxChildren < 0 || m.children.length <= maxChildren)) m
				];
			if (raw.length == 0) {
				// Empty `--select` is indistinguishable from "wrong kind
				// name". Kinds are the exact node-constructor names and the
				// engine never enumerates them — so list the kinds actually
				// present in this file, turning a silent miss into a
				// self-correcting hint (no global kind table needed).
				final present:Array<String> = collectKinds(tree);
				final filterParts:Array<String> = [];
				if (minChildren >= 0) filterParts.push('--min-children=$minChildren');
				if (maxChildren >= 0) filterParts.push('--max-children=$maxChildren');
				if (preFilter.length > 0) filterParts.push('${preFilter.length} pre-filter match(es) dropped by child-count');
				final filterNote:String = filterParts.length == 0 ? '' : ' (with ${filterParts.join(", ")})';
				stderr('apq ast: --select "$selectExpr"$filterNote matched no nodes in $file. '
					+ 'Kinds present here: ${present.join(", ")}. '
					+ 'Kinds are exact node-constructor names — run `apq ast $file` to see the tree.\n');
			}
			final matches:Array<QueryNode> = depth < 0 ? raw : [for (m in raw) Engine.truncate(m, depth)];
			sysPrint(json ? Json.renderMatches(file, source, matches, wantDoc, wantSource) : Text.renderMatches(matches, source, wantDoc, wantSource));
			return EXIT_OK;
		}

		final shaped:QueryNode = Engine.truncate(tree, depth);
		sysPrint(json ? Json.renderTree(file, source, shaped) : Text.render(shaped));
		return EXIT_OK;
	}

	private static function pickPlugin(lang:String):GrammarPlugin {
		return switch lang {
			case 'haxe': new HaxeQueryPlugin();
			case _: throw 'apq: no grammar plugin for --lang "$lang"';
		};
	}

	private static function readFile(path:String):String {
		#if (sys || nodejs)
		return File.getContent(path);
		#else
		throw 'apq: file IO requires a sys target';
		#end
	}

	private static function expectValue(args:Array<String>, idx:Int, flag:String):String {
		if (idx >= args.length) throw 'apq: $flag requires a value';
		return args[idx];
	}

	/**
	 * Expand one-or-more file/dir/glob specs into a deduped path list,
	 * order-preserving. `singleFile` (parse-fail becomes a hard error,
	 * mirroring `apq ast`) holds only when exactly one spec was given
	 * and it resolved to exactly that one concrete file — multi-spec or
	 * glob/dir scans skip unparseable files silently.
	 */
	private static function expandInputs(specs:Array<String>, ext:String):{paths:Array<String>, singleFile:Bool} {
		final paths:Array<String> = [];
		for (spec in specs)
			for (p in Glob.expand(spec, ext))
				if (!paths.contains(p)) paths.push(p);
		final singleFile:Bool = specs.length == 1 && paths.length == 1 && paths[0] == specs[0];
		return {paths: paths, singleFile: singleFile};
	}

	/**
	 * Keep at most `limit` hits total across the per-file entries,
	 * truncating the entry that crosses the budget and dropping the
	 * rest. `limit < 0` is "no limit" (the no-flag default). Generic
	 * over the entry shape: `len` reads a hit count, `trim` rebuilds an
	 * entry capped to the first `k` hits.
	 */
	private static function limitEntries<T>(entries:Array<T>, limit:Int, len:T -> Int, trim:(T, Int) -> T):Array<T> {
		if (limit < 0) return entries;
		final out:Array<T> = [];
		var remaining:Int = limit;
		for (e in entries) {
			if (remaining <= 0) break;
			final n:Int = len(e);
			if (n <= remaining) {
				out.push(e);
				remaining -= n;
			} else {
				out.push(trim(e, remaining));
				remaining = 0;
			}
		}
		return out;
	}

	/**
	 * Parse `--limit <n>` at position `i` (the flag itself already
	 * matched). Returns the parsed non-negative count, or throws the
	 * same way `expectValue` does on a missing/!int value — callers
	 * surface it as a usage error.
	 */
	private static function parseLimit(args:Array<String>, idx:Int):Int {
		final v:String = expectValue(args, idx, '--limit');
		final n:Null<Int> = Std.parseInt(v);
		if (n == null || n < 0) throw 'apq: --limit expects a non-negative integer, got "$v"';
		return n;
	}

	private static function printUsage():Void {
		sysPrint('apq — anyparse query CLI\n');
		sysPrint('\n');
		sysPrint('Usage: apq <command> [options] <file>\n');
		sysPrint('\n');
		sysPrint('Commands:\n');
		sysPrint('  ast      Dump parsed AST (S-expr or JSON)\n');
		sysPrint('  search   Structural pattern search\n');
		sysPrint('  refs     Symbol references (value bindings; scope-aware)\n');
		sysPrint('  uses     Type references (field/param/type-param positions)\n');
		sysPrint('  meta     Annotation-on-decl shortcut\n');
		sysPrint('  blast    Change-impact checklist (uses + refs + member-access)\n');
		sysPrint('  lit      Leaf-name probe (string literals, identifiers — prose-in-code)\n');
		sysPrint('\n');
		sysPrint('Global options:\n');
		sysPrint('  --lang <name>   Pick grammar plugin (default: haxe)\n');
		sysPrint('  -h, --help      Show help\n');
	}

	private static function printSearchUsage():Void {
		sysPrint('Usage: apq search [options] <pattern> <file-or-dir-or-glob>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of text\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('  --kind <Kind>       Only match nodes of this AST kind\n');
		sysPrint('  --explain           Print parsed pattern AST; on 0 hits show input-kind histogram\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('\n');
		sysPrint("Pattern syntax: language source with `$X` / `$_` metavars.\n");
		sysPrint("  $X      — bind a subtree; reuses must match structurally.\n");
		sysPrint("  $_      — wildcard, no binding.\n");
		sysPrint("\n");
		sysPrint("Use `--` before a pattern that starts with `--` (e.g. the\n");
		sysPrint("prefix-decrement pattern `--$x`): apq search -- '--\\$x' <file>\n");
	}

	private static function printLitUsage():Void {
		sysPrint('Usage: apq lit [options] <text> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --exact             Require exact string equality (default: substring)\n');
		sysPrint('  --kind <K1,K2,...>  Restrict to leaves of these kinds (default: Literal)\n');
		sysPrint('  --any-kind          Match every named leaf regardless of kind\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint("Walks parsed AST for leaf nodes whose `name` slot matches <text>.\n");
		sysPrint("Default `--kind Literal` catches string-literal contents only —\n");
		sysPrint("the structural alternative to `# HXQ_OK:prose` grep for annotation-\n");
		sysPrint("key / config-string lookups (e.g. `apq lit 'lit.kwText' src/`).\n");
		sysPrint("Skips comments and string interpolation as a side effect of routing\n");
		sysPrint("through the parser — no false positives from doc-comments.\n");
	}

	private static function printBlastUsage():Void {
		sysPrint('Usage: apq blast [options] <type-name> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --limit <n>         Cap the heuristic section at n hits\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Change-impact checklist for a type. Unions three sections:\n');
		sysPrint('  uses  — type-position references (precise)\n');
		sysPrint('  refs  — value-binding references (precise)\n');
		sysPrint('  heuristic field-access — `expr.member` whose member name is\n');
		sysPrint('          a member of the type\'s decl. SUPERSET / name-based —\n');
		sysPrint('          over-matches, VERIFY each. This is the signal plain\n');
		sysPrint('          `uses`/`refs` are blind to (the typedef->enum gap).\n');
		sysPrint('Needs the type\'s declaration in the scanned set for the\n');
		sysPrint('heuristic; absent ⇒ that section is skipped (uses/refs stand).\n');
	}

	private static function printRefsUsage():Void {
		sysPrint('Usage: apq refs [options] <name> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of text\n');
		sysPrint('  --decls             Filter to declarations\n');
		sysPrint('  --reads             Filter to read references\n');
		sysPrint('  --writes            Filter to write references (Phase 3.3)\n');
		sysPrint('  --doc               Also emit each hit\'s leading doc-comment\n');
		sysPrint('  --source            Also emit each hit\'s verbatim source slice\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Phase 3.1: name-only matching, no lexical scope. Filters combine\n');
		sysPrint('inclusively — passing `--decls --reads` keeps both kinds.\n');
	}

	private static function printUsesUsage():Void {
		sysPrint('Usage: apq uses [options] <type-name> <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --doc               Also emit each hit\'s leading doc-comment\n');
		sysPrint('  --source            Also emit each hit\'s verbatim source slice\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('Finds type-position references — a field/var type annotation,\n');
		sysPrint('an enum-constructor parameter type, a type parameter. Sister of\n');
		sysPrint('`refs` (value bindings). `Array<T>` reports both `Array` and\n');
		sysPrint('`T`. For "where is X declared" use `refs --decls` / `ast --select`.\n');
	}

	private static function printMetaUsage():Void {
		sysPrint('Usage: apq meta [<annotation>] [options] <file-or-dir-or-glob>...\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --arg-contains <s>  Keep hits whose argument list contains <s>\n');
		sysPrint('  --on <decl-kind>    Keep hits attached to the given decl kind\n');
		sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		sysPrint('\n');
		sysPrint('<annotation> is the target language source syntax (e.g. `@:foo`),\n');
		sysPrint('recognised by its leading `@`. Omit it with `--on` to list every\n');
		sysPrint('annotation on a decl kind.\n');
	}

	private static function printAstUsage():Void {
		sysPrint('Usage: apq ast [options] <file>\n');
		sysPrint('\n');
		sysPrint('Options:\n');
		sysPrint('  --json              Emit JSON instead of S-expr\n');
		sysPrint('  --depth <n>         Truncate beyond depth n\n');
		sysPrint('  --select <path>     Subtree(s) matching a selector (e.g. "ClassDecl > FnDecl:foo")\n');
		sysPrint('  --at <line>:<col>   Innermost node enclosing the 1-indexed position\n');
		sysPrint('  --doc               With --select/--at: emit the match\'s leading doc-comment\n');
		sysPrint('  --source            With --select/--at: emit the match\'s verbatim source slice\n');
		sysPrint('  --min-children <n>  With --select: keep only matches with >= n direct children (e.g. multi-arg ParamCtor)\n');
		sysPrint('  --max-children <n>  With --select: keep only matches with <= n direct children\n');
		sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
	}

	private static function stderr(s:String):Void {
		#if (sys || nodejs)
		Sys.stderr().writeString(s);
		#end
	}

	/**
	 * Parse one walked file for the scan subcommands
	 * (`refs`/`uses`/`meta`/`search`). The behaviour on a parse failure
	 * depends on how the input was given. When the user named exactly
	 * one file (`singleFile`), the failure IS the query's answer: it is
	 * reported and the caller turns it into a hard error, mirroring
	 * `apq ast`. In directory / glob / multi-file scan mode an
	 * unparseable file is out of scope by nature, so it is skipped
	 * silently — no per-file error noise on every walk. Returns the
	 * parsed tree, or `null` to skip (scan) / fail (single file).
	 */
	private static function parseWalked(cmd:String, parse:String -> QueryNode, path:String, source:String, singleFile:Bool):Null<QueryNode> {
		return try parse(source)
			catch (exception:ParseError) {
				if (singleFile) stderr('apq $cmd: $path: ${exception.toString()}\n');
				null;
			}
			catch (exception:Exception) {
				if (singleFile) stderr('apq $cmd: $path: ${exception.message}\n');
				null;
			};
	}

	/**
	 * Increment `counts[node.kind]` for every node in the tree. Used
	 * by `apq search --explain` to build the kind histogram that
	 * surfaces "pattern's root kind is not present in input" mismatches.
	 */
	private static function tallyKinds(root:QueryNode, counts:Map<String, Int>):Void {
		function walk(n:QueryNode):Void {
			final prev:Null<Int> = counts.get(n.kind);
			counts.set(n.kind, prev == null ? 1 : prev + 1);
			for (c in n.children) walk(c);
		}
		walk(root);
	}

	/**
	 * Heuristic: does the string look like a Haxe TypeName? First letter
	 * uppercase ASCII, no `/`, no `.` (eliminates relative paths like
	 * `./Foo.hx` and dotted accesses like `Foo.bar`). Used by `ast` to
	 * detect `apq ast <TypeName> <dir>` (refs/uses surface mistakenly
	 * fed to ast).
	 */
	private static function looksLikeTypeName(s:String):Bool {
		if (s.length == 0) return false;
		final c:Int = StringTools.fastCodeAt(s, 0);
		if (c < 'A'.code || c > 'Z'.code) return false;
		return s.indexOf('/') < 0 && s.indexOf('.') < 0;
	}

	/**
	 * Heuristic: does the string look like a file/dir path? Contains `/`
	 * or `.hx` suffix, OR is an existing filesystem entry. Pairs with
	 * `looksLikeTypeName` to detect the `ast <TypeName> <dir>` shape.
	 */
	private static function looksLikePath(s:String):Bool {
		if (s.indexOf('/') >= 0) return true;
		if (StringTools.endsWith(s, '.hx')) return true;
		#if (sys || nodejs)
		return sys.FileSystem.exists(s);
		#else
		return false;
		#end
	}

	/**
	 * Build the per-kind nudge for `search` on a degenerate (single-leaf)
	 * pattern. Kind-aware: a lone metavar has no name to refs/uses; a
	 * literal value goes through `lit`; a bare identifier supports all
	 * three (refs/uses/lit). Sister of `emptyWalkerNudge` — both emit
	 * tool-suggestion messages on a structurally-valid-but-misaimed query.
	 */
	private static function degenerateNudge(patternStr:String, rootKind:String):String {
		final prefix:String = 'apq search: pattern "$patternStr" ';
		return switch rootKind {
			case 'Metavar':
				prefix + 'is a lone metavar — matches every node. Narrow with structural '
					+ "context (e.g. \"$x.field\", \"func($x)\"), or look up by name: apq refs <name> --decls / apq uses <Type>. Searching anyway.";
			case 'Literal' | 'StringLit' | 'BoolLit' | 'IntLit' | 'FloatLit'
				| 'SingleStringExpr' | 'DoubleStringExpr' | 'RawString':
				prefix + 'is a bare literal — for literal-content lookup use: apq lit \'$patternStr\' <files>. Searching anyway.';
			case _:
				// Bare identifier (IdentExpr) and anything else that
				// parses to a single leaf.
				prefix + 'has no code structure — search matches shape, not bare names. '
					+ 'Try one of: apq refs $patternStr --decls (value binding), '
					+ 'apq uses $patternStr (type position), '
					+ 'apq lit \'$patternStr\' (string-literal content), '
					+ 'apq ast --select. Searching anyway.';
		}
	}

	/**
	 * Stderr nudge emitted by walker subcommands (refs/uses/meta/lit) when
	 * they return zero hits. Composes up to three diagnostic layers:
	 *
	 *  - SUMMARY: counts of files scanned vs parseable — turns a silent
	 *    miss into an observable signal.
	 *  - KIND HINT: when `name` is non-null, a kind-aware tool suggestion
	 *    (`refs <X>` on UpperCase → try `uses`/`blast`; `uses <x>` on
	 *    lowercase → try `refs`/`lit`; etc.). `meta` has no `<name>` and
	 *    skips this layer.
	 *  - SKIP-PARSE WARNING: when `skipPaths` lists files that failed to
	 *    parse, surface count + first few paths. The answer may be hiding
	 *    in unparsed files, so silence here would mislead.
	 *  - FUZZY DID-YOU-MEAN: for refs/uses with a non-null `candidates`
	 *    name pool, suggest top-K candidates within Levenshtein distance.
	 *    Silent when nothing close enough qualifies.
	 */
	private static function emptyWalkerNudge(
		cmd:String,
		name:Null<String>,
		scanned:Int,
		parseable:Int,
		?skipPaths:Array<String>,
		?candidates:Map<String, Bool>
	):String {
		final summary:String = 'apq $cmd: 0 hits ($scanned file(s) scanned, $parseable parseable)';
		final tail:StringBuf = new StringBuf();
		if (name != null) {
			final n:String = name;
			final first:Int = n.length > 0 ? StringTools.fastCodeAt(n, 0) : 0;
			final isUpper:Bool = first >= 'A'.code && first <= 'Z'.code;
			final isLower:Bool = first >= 'a'.code && first <= 'z'.code;
			final hint:String = switch cmd {
				case 'refs':
					if (isUpper) ' — "$n" starts uppercase, looks like a TypeName. Try: apq uses $n <dir> (type positions), apq blast $n <dir> (full change-impact incl. field-access), or apq lit \'$n\' <dir> --any-kind (every leaf — case-patterns / imports / new exprs).';
					else ' — "$n" has no value-binding here. Locals/params are NOT indexed. Try: apq lit \'$n\' <dir> --any-kind (every leaf — strings/idents/field-names) or apq search \'$$x.$n\' <dir> (field-access shape).';
				case 'uses':
					if (isLower) ' — "$n" starts lowercase, not a TypeName. Try: apq refs $n <dir> (value bindings) or apq lit \'$n\' <dir> --any-kind (every leaf).';
					else ' — no type-position references. For full change-impact incl. `.field` access try: apq blast $n <dir>, or apq lit \'$n\' <dir> --any-kind (every leaf — incl. case-patterns).';
				case 'blast':
					' — no declaration of "$n" in the scanned set (the heuristic section needs it). Either widen the scan, or use apq uses $n <dir> + apq refs $n <dir> directly.';
				case 'lit':
					' — no string-literal content matches "$n". Default --kind is Literal; widen with --kind Literal,IdentExpr or --any-kind, or try: apq refs $n <dir> --decls.';
				case 'meta':
					''; // meta has no <name> arg (annotation is its own thing) — leave silent.
				case _:
					'';
			};
			tail.add(hint);
		}

		// Skip-parse warning: parseable < scanned means the answer may
		// be hiding in unparsed files. Surface this loudly so a 0-hit
		// query on a broken corpus is not silently trusted.
		if (skipPaths != null && skipPaths.length > 0) {
			final n:Int = skipPaths.length;
			tail.add('\napq $cmd: WARNING: $n file(s) skip-parse — answer may be hiding in unparsed files. Probe via: hxq ast <one-of-them> to verify parse failure.');
			final shown:Int = n < SKIP_PATHS_SHOWN ? n : SKIP_PATHS_SHOWN;
			for (i in 0...shown)
				tail.add('\n  skip: ${skipPaths[i]}');
			if (n > shown)
				tail.add('\n  ... and ${n - shown} more');
		}

		// Fuzzy "did you mean": for refs/uses on 0 hits, propose the
		// top-K decl/type names within Levenshtein distance. Stays
		// silent when no candidate qualifies — don't fabricate hints.
		if (name != null && candidates != null && (cmd == 'refs' || cmd == 'uses')) {
			final suggestions:Array<String> = findFuzzy(name, candidates);
			if (suggestions.length > 0)
				tail.add('\napq $cmd: Did you mean: ${suggestions.join(", ")}?');
		}

		return summary + tail.toString();
	}

	/**
	 * Collect every named leaf/inner-node into `out` for fuzzy
	 * "did you mean" suggestions. The full vocabulary covered by the
	 * walked tree — wider than just decls — keeps the suggestion list
	 * useful for either refs (value bindings) or uses (type positions)
	 * without needing a per-shape collector.
	 */
	private static function collectNames(root:QueryNode, out:Map<String, Bool>):Void {
		function walk(n:QueryNode):Void {
			final nm:Null<String> = n.name;
			if (nm != null && nm.length > 0) out.set(nm, true);
			for (c in n.children) walk(c);
		}
		walk(root);
	}

	/**
	 * Top-`FUZZY_TOP_K` "did you mean" candidates ranked in two tiers:
	 *
	 *  - Tier 0 — substring match: `query` is a contiguous substring of
	 *    `cand` (prefix/suffix/inner). Score = extra char count
	 *    `cand.length - query.length`. Catches the common grammar miss
	 *    `HxTypeParam` → `HxTypeParamDecl` (Levenshtein distance 4 from
	 *    appending "Decl" — beyond `FUZZY_MAX_DIST`, but `HxTypeParam` IS
	 *    a substring of `HxTypeParamDecl`). Guarded by
	 *    `FUZZY_SUBSTRING_MIN_QUERY` (avoids `Hx` matching everything)
	 *    and `FUZZY_SUBSTRING_MAX_EXTRA` (avoids `Foo` crowding out true
	 *    neighbours with a long-name match).
	 *
	 *  - Tier 1 — Levenshtein within `FUZZY_MAX_DIST`. Catches typos and
	 *    transpositions a substring scan can't.
	 *
	 * A candidate that qualifies under Tier 0 is NOT also evaluated under
	 * Tier 1 — the substring tier always wins, and we don't double-add.
	 * Returns empty when nothing qualifies; the caller emits the "did you
	 * mean" line only on a non-empty result (never fabricates hints).
	 */
	private static function findFuzzy(query:String, pool:Map<String, Bool>):Array<String> {
		final scored:Array<{name:String, tier:Int, score:Int}> = [];
		final qLen:Int = query.length;
		final substringEnabled:Bool = qLen >= FUZZY_SUBSTRING_MIN_QUERY;
		for (cand in pool.keys()) {
			if (cand == query) continue;
			if (substringEnabled && cand.length > qLen && cand.length - qLen <= FUZZY_SUBSTRING_MAX_EXTRA && cand.indexOf(query) >= 0) {
				scored.push({name: cand, tier: 0, score: cand.length - qLen});
				continue;
			}
			final d:Int = levenshtein(query, cand);
			if (d <= FUZZY_MAX_DIST) scored.push({name: cand, tier: 1, score: d});
		}
		scored.sort((a, b) -> a.tier != b.tier ? a.tier - b.tier : (a.score != b.score ? a.score - b.score : (a.name < b.name ? -1 : 1)));
		final take:Int = scored.length < FUZZY_TOP_K ? scored.length : FUZZY_TOP_K;
		return [for (i in 0...take) scored[i].name];
	}

	/** Levenshtein edit distance (insert/delete/substitute = 1). */
	private static function levenshtein(a:String, b:String):Int {
		final la:Int = a.length;
		final lb:Int = b.length;
		if (la == 0) return lb;
		if (lb == 0) return la;
		var prev:Array<Int> = [for (j in 0...lb + 1) j];
		var cur:Array<Int> = [for (j in 0...lb + 1) 0];
		for (i in 1...la + 1) {
			cur[0] = i;
			final ai:Int = StringTools.fastCodeAt(a, i - 1);
			for (j in 1...lb + 1) {
				final cost:Int = ai == StringTools.fastCodeAt(b, j - 1) ? 0 : 1;
				final del:Int = prev[j] + 1;
				final ins:Int = cur[j - 1] + 1;
				final sub:Int = prev[j - 1] + cost;
				var m:Int = del < ins ? del : ins;
				if (sub < m) m = sub;
				cur[j] = m;
			}
			final tmp:Array<Int> = prev;
			prev = cur;
			cur = tmp;
		}
		return prev[lb];
	}

	/** Distinct node-constructor kinds present in a tree, sorted — the
	 * self-discovery list shown when `--select` matches nothing. */
	private static function collectKinds(root:QueryNode):Array<String> {
		final seen:Array<String> = [];
		function walk(n:QueryNode):Void {
			if (!seen.contains(n.kind)) seen.push(n.kind);
			for (c in n.children) walk(c);
		}
		walk(root);
		seen.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		return seen;
	}

	private static inline function sysPrint(s:String):Void {
		#if (sys || nodejs)
		Sys.print(s);
		#end
	}
}
