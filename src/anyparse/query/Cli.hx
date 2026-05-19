package anyparse.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
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
 * [--select PATH] [--at LINE:COL]`. Other subcommands (`search`,
 * `refs`, `meta`) are reserved — calling them prints a "deferred"
 * notice with the phase that owns each.
 */
@:nullSafety(Strict)
final class Cli {

	private static final EXIT_OK:Int = 0;
	private static final EXIT_USAGE:Int = 2;
	private static final EXIT_RUNTIME:Int = 1;

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
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('refs', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final raw:Array<RefHit> = Refs.find(nameStr, tree, shape);
			final filtered:Array<RefHit> = anyFilter
				? raw.filter(h -> kindAllowed(h.kind, wantDecls, wantReads, wantWrites))
				: raw;
			if (filtered.length == 0) continue;
			allEntries.push({file: path, source: source, hits: filtered});
		}

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
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('uses', plugin.parseFileTypeRefs, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final hits:Array<UsesHit> = Uses.find(nameStr, tree, shape);
			if (hits.length == 0) continue;
			allEntries.push({file: path, source: source, hits: hits});
		}

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
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('meta', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
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
		// right tool and proceed anyway (the user may genuinely want
		// the identifier-expression occurrences).
		if (parsed.isDegenerate())
			stderr('apq search: pattern "$patternStr" has no code structure — search matches shape, not bare names. Declaration: apq refs $patternStr --decls | type users: apq uses $patternStr | subtree: apq ast --select. Searching anyway.\n');

		final expanded:{paths:Array<String>, singleFile:Bool} = expandInputs(inputSpecs, '.hx');
		final paths:Array<String> = expanded.paths;
		if (paths.length == 0) {
			stderr('apq search: no input files matched ${inputSpecs.join(" ")}\n');
			return EXIT_RUNTIME;
		}

		final singleFile:Bool = expanded.singleFile;
		final allEntries:Array<{file:String, source:String, matches:Array<Match>}> = [];
		for (path in paths) {
			final source:String = readFile(path);
			final tree:Null<QueryNode> = parseWalked('search', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final matches:Array<Match> = Matcher.search(parsed, tree, kind);
			if (matches.length == 0) continue;
			allEntries.push({file: path, source: source, matches: matches});
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
				case '-h', '--help':
					printAstUsage();
					return EXIT_OK;
				case _:
					if (StringTools.startsWith(a, '--')) {
						stderr('apq ast: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file != null) {
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
			final raw:Array<QueryNode> = Engine.select(tree, selector);
			if (raw.length == 0) {
				// Empty `--select` is indistinguishable from "wrong kind
				// name". Kinds are the exact node-constructor names and the
				// engine never enumerates them — so list the kinds actually
				// present in this file, turning a silent miss into a
				// self-correcting hint (no global kind table needed).
				final present:Array<String> = collectKinds(tree);
				stderr('apq ast: --select "$selectExpr" matched no nodes in $file. '
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
		sysPrint('\n');
		sysPrint("Pattern syntax: language source with `$X` / `$_` metavars.\n");
		sysPrint("  $X      — bind a subtree; reuses must match structurally.\n");
		sysPrint("  $_      — wildcard, no binding.\n");
		sysPrint("\n");
		sysPrint("Use `--` before a pattern that starts with `--` (e.g. the\n");
		sysPrint("prefix-decrement pattern `--$x`): apq search -- '--\\$x' <file>\n");
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
