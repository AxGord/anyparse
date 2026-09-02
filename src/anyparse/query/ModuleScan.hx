package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.RefactorSupport.ModulePath;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The static readers over a module's TOP LEVEL: its `package`, the names its import / `using`
 * header binds — including the ones the grammar nests under a `Conditional` rather than leaving
 * at the top level — and the types the module itself declares.
 *
 * Split out of `TypeRefPrinter`, which keeps the DECISION side: given a canonical path and the
 * short name it would like to print, is that name free, already bound, or shadowed. Everything
 * here is a pure function of a parsed tree (or of an indexed `FileInfo`) and holds no printer
 * state, which is why the two conditional-region walks and the alias-target recovery sit on this
 * side of the line rather than in the printer.
 */
@:nullSafety(Strict)
final class ModuleScan {

	/** The import / using declaration kinds a grammar projects at the top level — the anchor set for an insert and for the bound-name scan. */
	public static final IMPORT_DECL_KINDS: Array<String> = [
		'ImportDecl',
		'UsingDecl',
		'ImportWildDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl'
	];

	/**
	 * The `package` declaration kinds. A named `package pkg;` and the ROOT-package `package;` project
	 * APART, and every anchor that reads only the named one falls through on a root-package file to
	 * the file-start fallback — which splices the import ABOVE `package`, and does not compile.
	 */
	public static final PACKAGE_DECL_KINDS: Array<String> = ['PackageDecl', 'PackageEmpty'];

	/** The wildcard import kind — the one bulk form whose binding set depends on the package it names. */
	private static inline final WILDCARD_IMPORT_KIND: String = 'ImportWildDecl';

	/** The BULK import kinds — the two statements that bind names they do not spell out (`shadowedByBulkImport`). */
	private static final BULK_IMPORT_KINDS: Array<String> = [WILDCARD_IMPORT_KIND, 'UsingDecl'];

	/**
	 * The `#if … #end` region holding every type `tree` declares, or null when the file has none — the
	 * answer for the ordinary unguarded module, and the conservative one for every shape the gates
	 * below refuse.
	 *
	 * A debug- or platform-only module wraps everything below `package` in a single conditional, so its
	 * import run sits INSIDE that region while the top level holds nothing but `package` and the region
	 * itself. Every reader that anchors an insert on the file's header — `ImportOrder`'s run seat, the
	 * `using` insert, the `import-order` rule — must ask this first, or it reads the file as having no
	 * header at all and lands its line on an island above the `#if`, in scope for nothing the module
	 * declares.
	 *
	 * Three gates, each closing a way the region could fail to cover the code an insert serves:
	 *
	 *  - ONE region at the top level, with no type declared OUTSIDE it. A site in an unguarded type
	 *    resolves in the builds where the condition does not hold, so a declaration placed inside the
	 *    region would not be in scope for it.
	 *  - The region declares a type ITSELF (its own, or one nested in a further region). A guarded
	 *    import run with the code outside it is what the first gate refuses; this one refuses a file
	 *    whose region guards no code at all.
	 *  - NO `#else` / `#elseif` seam of its OWN. The grammar projects every branch of one region as
	 *    flat siblings, so an anchor picked from the children cannot be told from one in another
	 *    branch — and an insert after the first branch's last import is absent from every other
	 *    branch's build. A NESTED region's seams belong to that region and do not count; an unbalanced
	 *    directive scan refuses.
	 */
	public static function guardedBodyRegion(tree: QueryNode, source: String, plugin: GrammarPlugin): Null<QueryNode> {
		final shape: RefShape = plugin.refShape();
		final regionKind: Null<String> = shape.conditionalMemberKind;
		if (regionKind == null) return null;
		var region: Null<QueryNode> = null;
		for (child in tree.children) if (child.kind == regionKind) {
			if (region != null) return null;
			region = child;
		} else if (RefactorSupport.typeDeclOf(child) != null)
			return null;
		final guard: Null<QueryNode> = region;
		return guard != null && regionDeclaresType(guard, regionKind)
			&& singleBranchRegion(guard, source, shape, plugin.lexicalRegions(source))
			? guard
			: null;
	}

	/**
	 * The offset just past `guard`'s opening directive line — the position a fresh header line takes in
	 * a guarded module that declares none of its own, or -1 when the region has no span or no line end.
	 *
	 * The `#if <cond>` directive owns the region's first line, so its line END is a position no
	 * declaration's leading trivia reaches — unlike the first child's span, which a doc comment would be
	 * spliced through.
	 */
	public static function guardBodyStart(source: String, guard: QueryNode): Int {
		final span: Null<Span> = guard.span;
		if (span == null) return -1;
		final newline: Int = source.indexOf('\n', span.from);
		return newline < 0 ? -1 : newline + 1;
	}

	/**
	 * Whether `node`'s source STARTS with the grammar's `#if` directive — i.e. it is a
	 * conditional-compilation region, whatever kind the grammar happens to project it as.
	 *
	 * A kind test cannot do this job. The Haxe grammar carries a dozen conditional ctors, one per
	 * host position (`Conditional` for members and statements, `ConditionalExpr` in expression
	 * position, `ConditionalArgs` in an argument list, five `CondSplice*` forms for a region that
	 * straddles a block or switch boundary, ...), and `RefShape` names only the member one. An
	 * enumerated list would go stale the next time a position is added; the DIRECTIVE cannot,
	 * because every region opens with it by definition. The `#` first-char test keeps it to one
	 * comparison per node before any substring is taken.
	 *
	 * It lives on the QUERY side of the check/query line because `TypeRefPrinter` asks it too, through
	 * `conditionalRegionAt`. It used to be `CheckScan.opensConditionalRegion`; that copy is gone rather
	 * than left as a forwarder, so there is one name for one question.
	 */
	public static function opensConditionalRegion(node: QueryNode, source: String, condIf: Null<String>): Bool {
		final span: Null<Span> = node.span;
		if (condIf == null || span == null) return false;
		// The null checks stay in their own guard: strict null-safety carries a narrowing fact into
		// a later `||` operand only from the chain's FIRST operand.
		final from: Int = span.from;
		return from < source.length && source.fastCodeAt(from) == '#'.code && source.substring(from, from + condIf.length) == condIf;
	}

	/**
	 * The INNERMOST conditional-compilation region of `root` whose span covers `offset`, or null when
	 * nothing conditional does — i.e. when the byte is compiled in every build of the module.
	 *
	 * INNERMOST is the fail-closed reading, and the one an import decision needs: a site nested two
	 * regions deep is compiled only under the conjunction of both conditions, so answering with the
	 * outer one would over-state where it is live. A node the grammar recorded no span for decides
	 * nothing and is descended THROUGH rather than treated as a boundary.
	 */
	public static function conditionalRegionAt(root: QueryNode, source: String, condIf: Null<String>, offset: Int): Null<Span> {
		if (condIf == null) return null;
		var found: Null<Span> = null;
		function walk(node: QueryNode): Void {
			for (child in node.children) {
				final span: Null<Span> = child.span;
				if (span != null && (offset < span.from || offset >= span.to)) continue;
				if (span != null && opensConditionalRegion(child, source, condIf)) found = span;
				walk(child);
			}
		}
		walk(root);
		return found;
	}

	/** The file's `package` payload (`''` for the root package, and for a file with no declaration at all). */
	public static function packageOf(root: QueryNode): String {
		for (c in root.children) if (c.kind == 'PackageDecl') return c.name ?? '';
		return '';
	}

	/** The module `file` declares, read from its own `package` declaration and its basename. */
	public static function moduleOf(root: QueryNode, file: String): ModulePath {
		final pkg: String = packageOf(root);
		final base: String = RefactorSupport.baseNameOf(file);
		return { path: pkg == '' ? base : '$pkg.$base', pkg: pkg, base: base };
	}

	/**
	 * The dotted path of one `import a.b.C as D;` statement text — the identifier run BEFORE the
	 * trailing `as` / `in` keyword, which is where the aliased path always sits — or `''` when it
	 * does not decode. Comments are stripped first: a `/* … *\/` between the keyword and the path
	 * would otherwise be decoded AS the path, and a wrong target silently prints the alias for
	 * the wrong type. `''` still occupies the alias's name, which is what the collision gate
	 * needs.
	 *
	 * The project's ONLY decoder of an alias import's path, and deliberately so. Four call
	 * sites: `aliasTargetsOf` just below (which `TypeRefPrinter` reaches for a whole file's
	 * map), `TypeRefPrinter`'s shadow gate directly, and `SymbolIndexBuilder` TWICE — its
	 * extraction loop, which files the answer into `ImportInfo.aliasTarget` for the whole
	 * index to read, and `importDedupKey`, which keys a guarded alias statement by the path
	 * it binds so two branches binding one name are not read as one import.
	 *
	 * The sibling `aliasKeywordOf` has one caller, `MoveSymbol`, which re-emits a repointed
	 * alias statement; it does NOT call this one.
	 *
	 * The consumers read imprecision in OPPOSITE directions, which any future tightening has to
	 * weigh: `TypeRefPrinter` compares the result to a full canonical path, so a partial decode
	 * reads as "shadow" and withholds; `SymbolIndex` takes its last segment, so a partial decode
	 * costs an alias EDGE — the direction that deletes; and a REWRITER (`aliasKeywordOf`'s
	 * caller) gets `''` and falls back to `as`, which restyles an `in` import rather than
	 * losing it.
	 */
	public static function aliasTargetOf(stmt: String): String {
		final runs: Array<String> = identRuns(stmt);
		final at: Int = aliasKeywordIndexIn(runs);
		return at < 0 ? '' : runs[at - 1];
	}

	/**
	 * Which of the two spellings an alias import statement uses — `'as'`, `'in'`, or `''` when
	 * `stmt` decodes as no alias import at all. The twin of `aliasTargetOf` over the same run scan and the same
	 * keyword rule, for a rewriter that must re-emit the statement: an `import p.T in U;`
	 * re-emitted as `as` is a silent style change in a file the caller only meant to repoint.
	 */
	public static function aliasKeywordOf(stmt: String): String {
		final runs: Array<String> = identRuns(stmt);
		final at: Int = aliasKeywordIndexIn(runs);
		return at < 0 ? '' : runs[at];
	}

	/**
	 * The index in `runs` of the `as` / `in` keyword an alias import spells, or -1 when there
	 * is none (or it leads the statement, which no path can precede). The one place that
	 * decision is made, so `aliasTargetOf` and `aliasKeywordOf` cannot drift apart on which
	 * run is the keyword. Takes the runs rather than the statement so each caller scans once.
	 */
	private static function aliasKeywordIndexIn(runs: Array<String>): Int {
		for (r => run in runs) if ((run == 'as' || run == 'in') && r > 0) return r;
		return -1;
	}

	/**
	 * `stmt`s maximal runs of identifier characters and `.`, comments stripped first so comment
	 * text cannot read as code.
	 */
	private static function identRuns(stmt: String): Array<String> {
		final bare: String = stripComments(stmt);
		final runs: Array<String> = [];
		final n: Int = bare.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = bare.fastCodeAt(i);
			if (!RefactorSupport.isIdentChar(c) && c != '.'.code) {
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n) {
				final cc: Int = bare.fastCodeAt(i);
				if (!RefactorSupport.isIdentChar(cc) && cc != '.'.code) break;
				i++;
			}
			runs.push(bare.substring(start, i));
		}
		return runs;
	}

	/** Whether the file carries a `package` declaration whose span the grammar did not record. */
	private static function hasSpanlessPackage(root: QueryNode): Bool {
		return root.children.exists(c -> PACKAGE_DECL_KINDS.contains(c.kind) && c.span == null);
	}

	/**
	 * `pack.Module.SubType` reduced to the `pack.SubType` hybrid a compiler prints for a
	 * secondary type — the MODULE segment dropped when the path has one (a second-to-last
	 * upper-initial segment that is not the type's own name). A main-type path (`pack.Module`)
	 * and a simple name come back unchanged, so a reduction never invents a hybrid where none
	 * exists.
	 */
	private static function dropModuleSegment(path: String): String {
		final parts: Array<String> = path.split('.');
		if (parts.length < 3) return path;
		final module: String = parts[parts.length - 2];
		return !RefactorSupport.isUpperInitial(module) || module == parts[parts.length - 1]
			? path
			: parts.slice(0, parts.length - 2).concat([parts[parts.length - 1]]).join('.');
	}

	/**
	 * The module paths of the file's UNGUARDED, top-level `using <module>;` statements. A `using` IS
	 * an `import` plus static extension, so it brings the module's top-level types into scope on the
	 * same terms — but a `#if`-guarded one does so in one build configuration only, which is why the
	 * guarded set (`guardedImportDecls`) is deliberately not merged in here.
	 */
	private static function usingModulesOf(root: QueryNode): Array<String> {
		return [
			for (c in root.children) if (c.kind == 'UsingDecl' && c.name != null) (c.name: String)
		];
	}

	/**
	 * The file's BULK import statements — `ImportWildDecl` and `UsingDecl` — including the ones
	 * LIFTED out of a `#if … #end` region, which the grammar nests under a `Conditional` rather
	 * than leaving at the top level. A guarded bulk import genuinely binds its names under its
	 * own guard, and this predicate only ever refuses a short form, so counting it is the
	 * conservative reading; ignoring it was a FALSE NEGATIVE — the direction that emits a short
	 * name binding a different type in one build configuration.
	 */
	private static function bulkImportDecls(root: QueryNode, guarded: Array<QueryNode>): Array<QueryNode> {
		final out: Array<QueryNode> = [for (c in root.children) if (BULK_IMPORT_KINDS.contains(c.kind)) c];
		for (c in guarded) if (BULK_IMPORT_KINDS.contains(c.kind)) out.push(c);
		return out;
	}

	/**
	 * The file's import-ish declarations LIFTED out of a `#if … #end` region — the ones the grammar
	 * nests under a `Conditional` rather than leaving at the top level, and therefore exactly the ones
	 * `_importMap` and `_aliasTargets` (both top-level scans) cannot see.
	 *
	 * The walk RECURSES. Flattening is a property of a region's BRANCHES, not of nested regions: the
	 * grammar lifts every `#if` / `#elseif` / `#else` branch of ONE directive into that region node's
	 * own children, but a region written INSIDE another (`#if a #if b import … #end #end`) projects as
	 * `Conditional > Conditional > ImportDecl`. A one-level reading of that shape sees no import at
	 * all, which is a FALSE NEGATIVE in the direction that matters — it lets a short name bind a
	 * different type in the build where both guards hold.
	 */
	private static function guardedImportDecls(root: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		collectGuardedImports(root, false, out);
		return out;
	}

	/**
	 * Append every import-ish declaration reachable from `node` through conditional regions ONLY —
	 * the walk never enters a type body, so it stays proportional to the file's directive nesting
	 * rather than its size. `guarded` is false at the file's top level and true once the walk has
	 * entered a region, so an UNGUARDED top-level import is skipped (it is already in
	 * `_importMap` / `_aliasTargets`).
	 */
	private static function collectGuardedImports(node: QueryNode, guarded: Bool, out: Array<QueryNode>): Void {
		for (c in node.children) if (c.kind == 'Conditional' || c.kind == 'CondSharedBodyDecl')
			collectGuardedImports(c, true, out);
		else if (guarded && IMPORT_DECL_KINDS.contains(c.kind))
			out.push(c);
	}

	/** Whether `node` declares a type directly, or inside a region nested in it — `guardedBodyRegion`'s coverage gate. */
	private static function regionDeclaresType(node: QueryNode, regionKind: String): Bool {
		for (child in node.children) {
			if (RefactorSupport.typeDeclOf(child) != null) return true;
			if (child.kind == regionKind && regionDeclaresType(child, regionKind)) return true;
		}
		return false;
	}

	/** Whether `region` opens no `#else` / `#elseif` branch of its own — `guardedBodyRegion`'s third gate. */
	private static function singleBranchRegion(region: QueryNode, source: String, shape: RefShape, regions: Array<LexRegion>): Bool {
		final span: Null<Span> = region.span;
		final opener: Null<String> = shape.conditionalIfKeyword;
		final closer: Null<String> = shape.conditionalEndKeyword;
		final seams: Null<Array<String>> = shape.conditionalElseKeywords;
		if (span == null || opener == null || closer == null || seams == null) return false;
		var depth: Int = 0;
		for (directive in CondDirectives.scan(source, shape, () -> regions)) {
			if (directive.span.from < span.from || directive.span.to > span.to) continue;
			if (directive.keyword == opener)
				depth++;
			else if (directive.keyword == closer) {
				depth--;
				if (depth == 0) return true;
			} else if (depth == 1 && seams.contains(directive.keyword))
				return false;
		}
		return false;
	}

	/** Whether the type named `name` in `file` is that module's MAIN type — the only kind a package wildcard binds. */
	private static function isMainTypeIn(file: FileInfo, name: String): Bool {
		final decl: Null<TypeDeclInfo> = file.types.find(t -> t.name == name);
		return decl != null && decl.isMain;
	}

	/** The import path a type named `name` declared in `file` carries: the module itself for the main type, else `module.name`. */
	private static function pathOfTypeIn(file: FileInfo, name: String): String {
		final decl: Null<TypeDeclInfo> = file.types.find(t -> t.name == name);
		return decl != null && decl.isMain ? file.module : '${file.module}.$name';
	}

	/** Whether the file's own top level declares a type named `name` — a same-module type, visible with no import. `final class` wrappers normalised via `RefactorSupport.typeDeclOf`. */
	private static function declaresTypeNamed(root: QueryNode, name: String): Bool {
		for (c in root.children) {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(c);
			if (decl != null && decl.name == name) return true;
		}
		return false;
	}

	/**
	 * Every `import <path> as <alias>;` in the file, mapped alias -> target path. The grammar
	 * exposes only the ALIAS in the node's name slot (the documented `ImportInfo` limitation),
	 * so the target is recovered by slicing the statement's own source. A statement that does
	 * not decode maps to `''` — the alias still counts as a bound name through the key.
	 */
	private static function aliasTargetsOf(source: String, root: QueryNode): Map<String, String> {
		final out: Map<String, String> = [];
		for (c in root.children) if (c.kind == 'ImportAliasDecl' || c.kind == 'ImportAliasInDecl') {
			final alias: Null<String> = c.name;
			final span: Null<Span> = c.span;
			if (alias != null && span != null) out[alias] = aliasTargetOf(source.substring(span.from, span.to));
		}
		return out;
	}

	/** `text` with every `//` line comment and `/* … *\/` block comment replaced by a space, so a lexical scan cannot read comment content as code. */
	private static function stripComments(text: String): String {
		final buf: StringBuf = new StringBuf();
		final n: Int = text.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = text.fastCodeAt(i);
			final next: Int = i + 1 < n ? text.fastCodeAt(i + 1) : 0;
			if (c == '/'.code && next == '/'.code) {
				while (i < n && text.fastCodeAt(i) != '\n'.code) i++;
				buf.addChar(' '.code);
				continue;
			}
			if (c == '/'.code && next == '*'.code) {
				i += 2;
				while (i + 1 < n && (text.fastCodeAt(i) != '*'.code || text.fastCodeAt(i + 1) != '/'.code)) i++;
				i = i + 2 < n ? i + 2 : n;
				buf.addChar(' '.code);
				continue;
			}
			buf.addChar(c);
			i++;
		}
		return buf.toString();
	}

	/** The module's main type name — the FIRST named top-level type declaration (the module basename is not available to the printer). */
	private static function mainTypeNameOf(root: QueryNode): Null<String> {
		for (c in root.children) {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(c);
			if (decl != null) return decl.name;
		}
		return null;
	}

}
