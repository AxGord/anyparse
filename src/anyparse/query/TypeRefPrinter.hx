package anyparse.query;

import anyparse.query.ImportOrder.ImportAnchor;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * How ONE type reference must be spelled inside a particular file. `text` is the
 * reference to write at the use site; `importPath` is the module path an
 * `import <path>;` must bring into scope for that text to resolve, or null when the text
 * already resolves (a short name in scope, or a fully-qualified path). The printer
 * accumulates the `importPath`s it hands out and materialises them through
 * `pendingImportEdits`, so a caller never splices an import per reference.
 */
typedef PrintedTypeRef = {
	var text: String;
	var importPath: Null<String>;
}

/**
 * One pending `import <path>;` insert: the zero-width `span` to splice at, the statement `text`
 * already carrying its own newline, and `paths` — the canonical import paths this ONE edit
 * materialises. `pendingImportEdits` merges every path landing on the same anchor offset into a
 * single edit, so `paths` is what tells a caller which use sites the edit is inseparable from
 * (see `anyparse.check.Check.GroupedFix`); a caller that only splices the edit ignores it.
 */
typedef PendingImportEdit = {
	var span: Span;
	var text: String;
	var paths: Array<String>;
}

@:access(anyparse.query.ModuleScan)
@:nullSafety(Strict)
final class TypeRefPrinter {

	/**
	 * Simple names available in EVERY Haxe file with no import, mapped to the ONE path each
	 * denotes — the std top-level module set (whose path IS the simple name) plus `Map`, which
	 * lives at `haxe.ds.Map` yet is reachable unqualified everywhere. The value half is
	 * load-bearing: matching on the name alone would shorten `haxe.macro.Type` to `Type` and
	 * `foo.Any` to `Any`, silently rebinding both to the builtin — and the `Any` case typechecks,
	 * so no verification pass would catch it.
	 */
	private static final ALWAYS_IN_SCOPE: Map<String, String> = [
		'Int' => 'Int',
		'UInt' => 'UInt',
		'Float' => 'Float',
		'Bool' => 'Bool',
		'String' => 'String',
		'Void' => 'Void',
		'Dynamic' => 'Dynamic',
		'Any' => 'Any',
		'Null' => 'Null',
		'Array' => 'Array',
		'Map' => 'haxe.ds.Map',
		'Class' => 'Class',
		'Enum' => 'Enum',
		'EnumValue' => 'EnumValue',
		'Date' => 'Date',
		'DateTools' => 'DateTools',
		'Math' => 'Math',
		'Reflect' => 'Reflect',
		'Std' => 'Std',
		'StringBuf' => 'StringBuf',
		'StringTools' => 'StringTools',
		'Sys' => 'Sys',
		'Type' => 'Type',
		'EReg' => 'EReg',
		'Lambda' => 'Lambda',
		'Xml' => 'Xml'
	];

	/** Paths `print` promised an import for, in first-promised order. */
	private final _pendingImports: Array<String> = [];

	/** The file's `package` declaration payload (`''` for the root package), or null when the printer has no tree. */
	private final _pkg: Null<String>;

	/** The file's main (first) top-level type name, for same-module sub-type resolution; null with no tree. */
	private final _module: Null<String>;

	/** Alias -> aliased path for every `import … as …` in the file; the keys double as bound-name collisions. */
	private final _aliasTargets: Map<String, String>;

	/** Simple name -> fully-qualified path for every plain `import`, from the grammar's `TypeInfoProvider`. */
	private final _importMap: Map<String, String>;

	/** The file's raw source, for the alias decode and the short-name freeness scan; null in the `importsOnly` form. */
	private final _source: Null<String>;

	/** The file's parsed top level; null in the `importsOnly` form. */
	private final _root: Null<QueryNode>;

	/** The grammar the file was parsed with — `ImportOrder.insertionFor`'s input; null in the `importsOnly` form. */
	private final _plugin: Null<GrammarPlugin>;

	/** The cross-file index for same-package / root-package / canonical-path resolution, or null when the run has none. */
	private final _index: Null<SymbolIndex>;

	/** Whether a fresh import has a legal splice point in this file (see the constructor). */
	private final _canAnchorImports: Bool;

	/** Every `#if`-guarded import-ish declaration of the file, at any directive nesting depth; empty with no tree. */
	private final _guardedImports: Array<QueryNode>;

	/** The file's BULK import statements, guarded ones included — the `shadowedByBulkImport` input; empty with no tree. */
	private final _bulkImports: Array<QueryNode>;

	/** Module paths of the file's UNGUARDED top-level `using` statements — a `moduleImportBinds` provider; empty with no tree. */
	private final _usingModules: Array<String>;

	/** The file's inert (comment + literal-text) regions, computed on FIRST use and cached — see `inertRegions`. */
	private var _inertRegions: Null<Array<Span>> = null;

	/** Value names this file's imports bring in with an enum-like type, computed on FIRST use — see `importedMemberNames`. */
	private var _importedMemberNames: Null<Array<String>> = null;

	/**
	 * The byte offset the reference being printed will be WRITTEN at, or -1 when the caller states
	 * none — set for the length of one `printTypeExpr` call and read by `importReachesSite`.
	 *
	 * A caller that states no site gets the whole-file reading, where every import is anchorable.
	 * That is the honest default for a caller printing a reference it cannot place (a synthesised
	 * annotation with no home yet), and it is what every pre-existing caller of `print` gets.
	 */
	private var _site: Int = -1;

	private function new(
		source: Null<String>, root: Null<QueryNode>, importMap: Map<String, String>, index: Null<SymbolIndex>, plugin: Null<GrammarPlugin>
	) {
		_source = source;
		_root = root;
		_plugin = plugin;
		_importMap = importMap;
		_index = index;
		_pkg = root == null ? null : ModuleScan.packageOf(root);
		_module = root == null ? null : ModuleScan.mainTypeNameOf(root);
		_aliasTargets = source == null || root == null ? [] : ModuleScan.aliasTargetsOf(source, root);
		// Ctor-hoisted like every sibling scan: both `shadowedByGuardedImport` and
		// `shadowedByBulkImport` ask for these, once per printed reference.
		_guardedImports = root == null ? [] : ModuleScan.guardedImportDecls(root);
		_bulkImports = root == null ? [] : ModuleScan.bulkImportDecls(root, _guardedImports);
		_usingModules = root == null ? [] : ModuleScan.usingModulesOf(root);
		// A `package` declaration with no recoverable span leaves no legal anchor: the file-start
		// fallback would splice the import AHEAD of `package`, which does not parse. Refuse to
		// import at all rather than emit that.
		_canAnchorImports = root == null || !ModuleScan.hasSpanlessPackage(root);
	}

	/** Whether `print` has promised at least one import that `pendingImportEdits` will materialise. */
	public inline function hasPendingImports(): Bool {
		return pendingImportMark() > 0;
	}

	/** How many imports `print` has promised so far — the mark `rollbackPendingImports` restores to. */
	public inline function pendingImportMark(): Int {
		return _pendingImports.length;
	}

	/**
	 * Drop every import promised since `mark`. The seam a caller needs when it PRINTS a candidate
	 * and only then decides to abstain from it: printing is what promises the import, so without
	 * this the promise outlives the candidate — `pendingImportEdits` materialises it on the
	 * strength of an unrelated edit, and until then it also vetoes a later import of the same
	 * simple name (`canAddImport`, `moduleImportBinds`).
	 *
	 * The length guard is not decoration: on js `Array.resize` is `this.length = len`, so a mark
	 * ABOVE the current length would pad an `Array<String>` with nulls rather than do nothing —
	 * measured, `length = 3` on a one-element array yields `["x", null, null]` — and the next
	 * `pendingImportEdits` would then call `lastIndexOf` on one of them.
	 */
	public inline function rollbackPendingImports(mark: Int): Void {
		if (mark < _pendingImports.length) _pendingImports.resize(mark);
	}

	/**
	 * Whether this printer has a resolution index — i.e. whether `resolvePath` can answer at all.
	 * A printer built from an import map alone answers null for EVERY path, so a caller gating an
	 * edit on `resolvePath` must not read that unconditional null as a refusal; it means the
	 * question was never asked.
	 */
	public inline function hasResolutionIndex(): Bool {
		return _index != null;
	}

	/**
	 * How to spell the type path `fqn` in this file, per the three-way preference documented
	 * on the class. `fqn` may be a simple name, a module path, a module-qualified sub-type
	 * path, or the `pack.SubType` HYBRID a compiler prints for a secondary type — the hybrid
	 * is canonicalised first, so the result is never one. A returned non-null `importPath` is
	 * also RECORDED for `pendingImportEdits`.
	 *
	 * THE PRINTER DOES NOT HANDLE ABSTENTION. Recording is unconditional, so a caller that may
	 * still REJECT the candidate after printing it owns taking the promise back — bracket the
	 * call with `pendingImportMark` / `rollbackPendingImports`. Leaving it promised is not inert:
	 * `pendingImportEdits` materialises it on the strength of any other edit, and meanwhile it
	 * vetoes a later import of the same simple name (`canAddImport`, `moduleImportBinds`).
	 *
	 * `owned` is passed through to `canAddImport`: the byte ranges that are written occurrences
	 * of `fqn` itself, which the caller is rewriting. Only a caller that SHORTENS existing
	 * qualified text has any (see `canAddImport`); everyone else omits it and route 2 keeps its
	 * whole-source freeness scan.
	 */
	public function print(fqn: String, ?owned: Array<Span>): PrintedTypeRef {
		final trimmed: String = fqn.trim();
		// A dotless run carries no derivable module path, and a lower-initial final segment is a
		// package path or a structural field name, never a type — both pass through untouched.
		if (trimmed.indexOf('.') == -1 || !RefactorSupport.isUpperInitial(RefactorSupport.lastSegment(trimmed))) return {
			text: trimmed,
			importPath: null
		};
		final canonical: String = canonicalize(trimmed);
		final simple: String = RefactorSupport.lastSegment(canonical);
		final visible: Null<String> = visibleNameFor(canonical, simple);
		// Re-bind: a null-check does not narrow into an anonymous-structure literal.
		if (visible != null) {
			final inScope: String = visible;
			return { text: inScope, importPath: null };
		}
		if (!canAddImport(canonical, simple, owned)) return { text: canonical, importPath: null };
		if (!_pendingImports.contains(canonical)) _pendingImports.push(canonical);
		return { text: simple, importPath: canonical };
	}

	/**
	 * Rewrite every maximal qualified-nominal run (`[A-Za-z0-9_.]+`) of the type EXPRESSION
	 * `t` through `print`, copying generic punctuation, spaces and structural field names
	 * verbatim — `Array<pkg.Mod.Sub>` shortens (or qualifies) only its component. The
	 * whole-annotation entry point; `print` is the single-nominal one.
	 *
	 * `at` is the byte offset the annotation will be WRITTEN at, and it decides exactly one thing:
	 * whether a nominal may buy a fresh import or has to be spelled fully qualified — see
	 * `importReachesSite`. Omitting it keeps the whole-file reading, which is right for a caller
	 * that has no home for the text yet and is what every caller had before the seam existed.
	 *
	 * A caller holding a PARSED type reference should address `print` directly instead: the
	 * grammar's `parseFileTypeRefs` projection carries one node per nominal with an exact span,
	 * so nothing has to be re-lexed out of an annotation's text. This entry point is for a type
	 * expression the caller only has as a STRING — a compiler oracle's answer, a synthesised
	 * annotation.
	 */
	public function printTypeExpr(t: String, ?at: Int): String {
		final was: Int = _site;
		_site = at ?? -1;
		final buf: StringBuf = new StringBuf();
		final n: Int = t.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = t.fastCodeAt(i);
			if (!RefactorSupport.isIdentChar(c) && c != '.'.code) {
				buf.addChar(c);
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n) {
				final cc: Int = t.fastCodeAt(i);
				if (!RefactorSupport.isIdentChar(cc) && cc != '.'.code) break;
				i++;
			}
			buf.add(print(t.substring(start, i)).text);
		}
		_site = was;
		return buf.toString();
	}

	/**
	 * The declaration path the written reference `ref` denotes IN THIS FILE, PROVEN against the
	 * resolution index: `pack.Module` for a module's main type, `pack.Module.SubType` for a
	 * secondary one. A `pack.SubType` HYBRID canonicalises first, so a hybrid and its
	 * module-qualified spelling answer the SAME path — which is what lets a caller prove a
	 * rewrite between the two forms keeps the same declaration.
	 *
	 * Null when nothing PROVES a path: a dotless or lower-initial run (whose binding is a scope
	 * question, not an index one — `print` answers that side by construction), a path no indexed
	 * declaration sits at, or a run with no index at all. Fail-closed on purpose: a caller gating
	 * an edit on this must treat "unproven" as "leave the source alone", never as "assume it
	 * resolves".
	 *
	 * PRECONDITION — index COMPLETENESS, the class-level hybrid LIMIT reaching this entry point.
	 * The answer is `canonicalize`'s, so it inherits `canonicalize`'s veto: a `pack.SubType` is
	 * read as a hybrid only when the index declares no type AT that path. A module the index never
	 * saw — outside the lint scope, or one `SymbolIndex` could not parse — removes that veto, and a
	 * REAL `pack.SubType` main type is then repaired onto the imported sub-type instead. Nothing
	 * here can detect that, so a caller that MUTATES on this answer belongs behind the
	 * typecheck-and-revert verification pass (`RiskyFix`), not in front of it.
	 */
	public function resolvePath(ref: String): Null<String> {
		final trimmed: String = ref.trim();
		// The same two rejections `print` opens with, so both entry points read one input class:
		// a dotless run carries no derivable module path, and a lower-initial final segment is a
		// package path or a structural field name, never a type.
		if (trimmed.indexOf('.') == -1 || !RefactorSupport.isUpperInitial(RefactorSupport.lastSegment(trimmed))) return null;
		final canonical: String = canonicalize(trimmed);
		return declaredAtPath(canonical, RefactorSupport.lastSegment(canonical)) ? canonical : null;
	}

	/**
	 * The `import <path>;` insert edits for every path `print` promised, or an empty array
	 * when none was. Paths landing on the SAME anchor offset are merged into ONE edit — two
	 * zero-width edits at one offset would be an overlapping pair the batching splice cannot
	 * order. Call once, after every `print` for the file.
	 *
	 * `paths` names the canonical import paths a merged edit carries, in the order its lines
	 * are emitted. A caller needs it because the merge makes the edit ATOMIC with the
	 * use-site rewrites of EVERY path in it, not of one: dropping a path's rewrites while
	 * keeping this edit leaves an orphan import, which still compiles, so nothing downstream
	 * can detect it — see `Check.GroupedFix`, which is how a fixer states that dependency.
	 *
	 * A merged bucket is sorted under the order the anchored RUN carries, not under a fixed
	 * codepoint one: several fresh lines written in codepoint order into a case-folded run would
	 * leave that run explained by NEITHER order, and every later insert would then fall back to
	 * appending — a one-way degradation of exactly what the ordered insert protects. Two paths
	 * that produced one anchor are in one run by construction (runs occupy disjoint offset
	 * ranges), so the bucket's order is well defined; with no run to read the codepoint reading
	 * is the deterministic default.
	 */
	public function pendingImportEdits(): Array<PendingImportEdit> {
		final buckets: Array<{ anchor: ImportAnchor, paths: Array<String> }> = [];
		for (path in _pendingImports) {
			final anchor: ImportAnchor = anchorFor(path);
			final existing: Null<{ anchor: ImportAnchor, paths: Array<String> }> = buckets.find(b -> b.anchor.offset == anchor.offset);
			if (existing == null)
				buckets.push({ anchor: anchor, paths: [path] });
			else
				existing.paths.push(path);
		}
		return [
			for (bucket in buckets) {
				bucket.paths.sort((a, b) -> ImportOrder.compare(bucket.anchor.order, a, b));
				{
					span: new Span(bucket.anchor.offset, bucket.anchor.offset),
					text: bucket.anchor.lead + [for (path in bucket.paths) 'import $path;\n'].join(''),
					paths: bucket.paths
				};
			}
		];
	}

	/**
	 * Whether THIS module's own top level declares `simple` AND that declaration is `canonical` — the
	 * MODULE-LOCAL binding, which outranks every import in Haxe's resolution order. Asked at two
	 * priorities (`shadowedByModuleImport` exempts it, `shadowedLocally` short-circuits on it), so it
	 * lives here rather than being spelled twice: the two sites must never drift apart about what
	 * "the file declares this type itself" means.
	 */
	private inline function moduleLocalBinds(canonical: String, simple: String): Bool {
		final root: Null<QueryNode> = _root;
		return root != null && ModuleScan.declaresTypeNamed(root, simple) && moduleLocalPathOf(simple) == canonical;
	}

	/**
	 * The file's INERT regions — every byte that cannot bind or read a name (`InertRegions`),
	 * computed on FIRST use and cached for the rest of this printer's life. Lazy rather than
	 * ctor-hoisted because only `canAddImport` needs them, and only after the shadowing and
	 * pending-collision gates have already let a path through — most printed references never
	 * reach it, and the computation is two whole-file passes.
	 */
	private function inertRegions(source: String): Array<Span> {
		final cached: Null<Array<Span>> = _inertRegions;
		if (cached != null) return cached;
		final regions: Array<Span> = InertRegions.of(source, _root);
		_inertRegions = regions;
		return regions;
	}

	/**
	 * Every VALUE name this file's imports bring in ALONGSIDE a type — an imported `enum`'s
	 * constructors and an imported `enum abstract`'s values (`RefShape.bareConstructorTypeKinds`),
	 * computed on FIRST ask and cached for the rest of this printer's life.
	 *
	 * Importing such a type TAKES those names, and it takes them harder than an import of a type
	 * takes its own: measured on 4.3.7, `import types.BASection;` (an `enum` declaring `Hash`) makes
	 * a bare `Hash` in expression position mean the CONSTRUCTOR in a file whose own package declares
	 * `class Hash`, and it keeps meaning the constructor beside an explicit `import module.Hash;` —
	 * in either import order. That is why `shadowedLocally` consults this ABOVE its
	 * explicit-import short-circuit rather than down with the bulk imports.
	 *
	 * Three neighbours do NOT bind a name here, each verified the same way: a plain class's statics
	 * (only a `pkg.Type.*` wildcard imports those), a same-package enum the file does not import,
	 * and — the reason this predicate is CONSERVATIVE rather than exact — a TYPE position, where
	 * `final h: Null<Hash>` still resolves to the class. The printer answers one question per path
	 * with no position to key on, so it answers the expression one; the cost is a type annotation
	 * left fully qualified in a file that imports an enum whose constructor happens to share the
	 * type's simple name, which always resolves.
	 *
	 * A module import binds every top-level type of that module, secondary enums included, so the
	 * scan matches on the module path as well as on an explicitly imported type path; a `using`
	 * binds them on the same terms. Empty without a resolution index — only it knows what a module
	 * declares.
	 */
	private function importedMemberNames(): Array<String> {
		final cached: Null<Array<String>> = _importedMemberNames;
		if (cached != null) return cached;
		final out: Array<String> = [];
		final index: Null<SymbolIndex> = _index;
		final plugin: Null<GrammarPlugin> = _plugin;
		final kinds: Array<String> = plugin == null ? [] : plugin.refShape().bareConstructorTypeKinds ?? [];
		if (index != null && kinds.length > 0) {
			final imported: Array<String> = _usingModules.copy();
			for (path in _importMap) if (!imported.contains(path)) imported.push(path);
			if (imported.length > 0) for (f in index.allFiles()) {
				final byModule: Bool = imported.contains(f.module);
				for (t in f.types) if (kinds.contains(t.kind) && (byModule || imported.contains(ModuleScan.pathOfTypeIn(f, t.name))))
					for (m in t.members) if (!out.contains(m.name)) out.push(m.name);
			}
		}
		_importedMemberNames = out;
		return out;
	}

	/**
	 * The name to write when `canonical` is ALREADY visible in this file, else null. Covers, in
	 * order: an always-in-scope builtin / root-package type, an exact plain import, an alias
	 * whose target is this path, a type declared in this module, and the main type of a module
	 * in this package. See the class doc for why a same-package SUB-module type is deliberately
	 * NOT here.
	 *
	 * `shadowedLocally` gates the WHOLE set, not just the builtin arm: Haxe's own resolution
	 * order (module type, then import / alias, then same package, then top level) means a
	 * lower-priority route can be OVERRULED by a higher-priority binding — a same-package
	 * `pkg.Widget` is not what a bare `Widget` means in a file that also carries
	 * `import other.Widget;`. The alias route reads its own binding, so it is exempt.
	 */
	private function visibleNameFor(canonical: String, simple: String): Null<String> {
		for (alias => target in _aliasTargets) if (target == canonical) return alias;
		if (shadowedLocally(canonical, simple)) return null;
		if (alwaysInScope(canonical, simple)) return simple;
		if (_importMap[simple] == canonical) return simple;
		if (moduleImportBinds(canonical, simple)) return simple;
		final root: Null<QueryNode> = _root;
		if (root != null && ModuleScan.declaresTypeNamed(root, simple) && canonical == moduleLocalPathOf(simple)) return simple;
		final pkg: Null<String> = _pkg;
		return pkg != null && canonical == (pkg == '' ? simple : '$pkg.$simple') ? simple : null;
	}

	/**
	 * Whether a plain `import <module>;` ALREADY in this file binds `simple` to `canonical` — i.e.
	 * `canonical` is `<module>.<simple>`, a SECONDARY top-level type of a module the file imports.
	 * A module import brings in every top-level type the module declares, not only its main one, so
	 * the short name is already visible and a fresh `import <module>.<simple>;` would be pure noise
	 * (the shape `redundant-import` reports; without this route the printer was the thing WRITING
	 * it — `import fs.FileSystemInterface.FileSystemCloudAction;` into a file already carrying
	 * `import fs.FileSystemInterface;`).
	 *
	 * A `using <module>;` qualifies on the same terms — it IS an `import <module>;` plus static
	 * extension — but only UNGUARDED and at the top level, since a `#if`-guarded one binds the name
	 * in one build configuration and not another. An ALIASED module import never qualifies: it is
	 * absent from `_importMap` by construction, and correctly so, an alias binds only the alias.
	 *
	 * A PENDING import of a different path claiming `simple` refuses the route, the same collision
	 * `canAddImport` refuses on: the pending line will be spliced into this same file, and Haxe lets
	 * the LAST import of a simple name win.
	 *
	 * The INDEX is consulted as a VETO, not as the evidence: only a MODULE may be plainly imported,
	 * so the import statement itself proves the parent path is one, and a module-qualified path
	 * under it can only name that module's sub-type. An index that knows the simple name and places
	 * it in OTHER modules only contradicts that reading, and the route steps aside for route 2 —
	 * which prints the same short name but ALSO writes an import, so the file at least states which
	 * type it means (whether that import wins is a position question `anchorFor` decides). An index
	 * that has never heard of the name — the module outside the resolution scope — vetoes nothing:
	 * route 2's alternative is `import <module>.<simple>;`, exactly as unproven, and a wrong short
	 * name there fails LOUD at the verification pass rather than binding something else.
	 *
	 * A COMPETING binder of `simple` is not this predicate's job — `shadowedLocally` runs first in
	 * `visibleNameFor` and owns every shadow, module-import secondaries included
	 * (`shadowedByModuleImport`).
	 */
	private function moduleImportBinds(canonical: String, simple: String): Bool {
		final dot: Int = canonical.lastIndexOf('.');
		if (dot <= 0) return false;
		final module: String = canonical.substring(0, dot);
		if (_importMap[RefactorSupport.lastSegment(module)] != module && !_usingModules.contains(module)) return false;
		if (_pendingImports.exists(p -> p != canonical && RefactorSupport.lastSegment(p) == simple)) return false;
		final index: Null<SymbolIndex> = _index;
		if (index == null) return true;
		final declarers: Array<FileInfo> = index.declaringFiles(simple);
		return declarers.length == 0 || declarers.exists(f -> f.module == module);
	}

	/**
	 * Whether `simple` is free to be BOUND by a new import of `canonical` in this file. False
	 * when a binding already visible here holds the name (`shadowedLocally`), when a PENDING
	 * import of a DIFFERENT path already claimed it (Haxe accepts two imports of one simple name
	 * silently — the last one wins, so the earlier short form would bind the wrong type), when
	 * the name occurs anywhere in the source as a word-boundary token OUTSIDE `owned` (an
	 * occurrence with no binding to `canonical` must resolve to something else), or when no
	 * import can be anchored. False, too, without a file scope: an import needs an anchor and a
	 * freeness proof.
	 *
	 * `owned` is the caller's list of byte ranges that are WRITTEN OCCURRENCES OF `canonical`
	 * ITSELF — a `pkg.Type` the caller is about to shorten. The simple name inside such a range
	 * is the path's own last segment, already bound to `canonical` by the qualification, so
	 * counting it as a foreign occurrence would veto the import by construction: the very text
	 * being rewritten is what makes the name look taken. Omitted (the default) the scan sees the
	 * whole source, which is the conservative reading every non-rewriting caller wants — it may
	 * only cost the short form and fall back to the fully-qualified path.
	 */
	private function canAddImport(canonical: String, simple: String, owned: Null<Array<Span>>): Bool {
		final source: Null<String> = _source;
		if (source == null || _root == null || !_canAnchorImports) return false;
		if (!importReachesSite()) return false;
		if (shadowedLocally(canonical, simple)) return false;
		if (_pendingImports.exists(p -> p != canonical && RefactorSupport.lastSegment(p) == simple)) return false;
		// A mention in INERT text — a comment, or the literal text of a string / regex — is masked
		// out: the scan asks whether anything in this file BINDS the name, and neither binds
		// anything, while the T15 reading refused the import on the strength of a word in a
		// doc-comment or an assertion message. Only the TEXT is masked: a single-quoted Haxe string
		// interpolates, so the `Foo` of `'${Foo.x}'` or `'$Foo'` is a real reference and still
		// vetoes (`inertRegions`).
		final exempt: Array<Span> = (owned ?? []).concat(inertRegions(source));
		return !RefactorSupport.referencedInRange(source, simple, 0, source.length, exempt);
	}

	/**
	 * Whether an import promised for the reference being printed REACHES it — whether the import
	 * LINE would be compiled in every build the reference itself is.
	 *
	 * A fresh import goes where `ImportOrder.insertionFor` puts it, and that is MODULE level unless
	 * this module's whole body sits inside ONE `#if … #end` region, where the seat is inside that
	 * region instead (`ModuleScan.guardedBodyRegion`, whose three gates are what make it sound: every
	 * build that compiles any of this file's code has the guard's condition true). So a reference
	 * written inside a conditional region has exactly one safe case — the region IS that whole-body
	 * guard. Under any OTHER region the import would exist in builds the reference does not: dead
	 * there at best, and `unused-import` then flags the fixer's own output; a hard `Type not found`
	 * when the module it names is target-restricted, which is how a `#if neko` local bought a
	 * module-level `import neko.vm.Module;` and broke the js half of a two-target oracle.
	 *
	 * Refusing costs no rewrite. `print` falls back to the fully-qualified path, which needs no
	 * import and resolves wherever the reference is — the same answer `catch-dynamic` and
	 * `prefer-typed-throw` write by hand for their own conditional sites, here derived once from
	 * where the import would actually land.
	 *
	 * A caller that states no site (`_site` < 0) is answered YES: it is printing a reference it has
	 * not placed, and the whole-file reading is what every caller had before the seam existed.
	 */
	private function importReachesSite(): Bool {
		final offset: Int = _site;
		final source: Null<String> = _source;
		final root: Null<QueryNode> = _root;
		final plugin: Null<GrammarPlugin> = _plugin;
		if (offset < 0 || source == null || root == null || plugin == null) return true;
		final region: Null<Span> = ModuleScan.conditionalRegionAt(root, source, plugin.refShape().conditionalIfKeyword, offset);
		if (region == null) return true;
		final guard: Null<QueryNode> = ModuleScan.guardedBodyRegion(root, source, plugin);
		final span: Null<Span> = guard?.span;
		return span != null && span.from == region.from && span.to == region.to;
	}

	/**
	 * Where `path`'s fresh import line goes in this file — `ImportOrder.insertionFor`, the one seat
	 * every inserting caller shares (its doc holds the slot-then-fallbacks ladder). A printer with no
	 * file scope, or one built without a grammar, anchors at the file start and never reaches here:
	 * `canAddImport` refuses the import first.
	 */
	private function anchorFor(path: String): ImportAnchor {
		final root: Null<QueryNode> = _root;
		final source: Null<String> = _source;
		final plugin: Null<GrammarPlugin> = _plugin;
		return root == null || source == null || plugin == null ? {
			offset: 0,
			lead: '',
			order: -1
		} : ImportOrder.insertionFor(source, root, plugin, path);
	}

	/**
	 * The path `raw` denotes, repaired to the form that actually resolves. A `pack.SubType`
	 * HYBRID — the shape a compiler prints for a secondary type, which resolves only while a
	 * matching import exists — becomes the module-qualified `pack.Module.SubType`; every other
	 * input is returned unchanged. Two independent repairs, imports first: an import of the
	 * simple name whose path REDUCES to `raw` (its module segment dropped) IS this type, and
	 * otherwise the index's unambiguous import path for the simple name, accepted only when it
	 * reduces to `raw` too — so a same-named unrelated type never captures it.
	 *
	 * Both repairs are refused when the index declares a type AT `raw` itself: `raw` is then a
	 * genuine main-type path that merely LOOKS like a hybrid of the imported sub-type, and
	 * repairing it would rewrite one real type into another.
	 */
	private function canonicalize(raw: String): String {
		final simple: String = RefactorSupport.lastSegment(raw);
		if (declaredAtPath(raw, simple)) return raw;
		final imported: Null<String> = _importMap[simple];
		if (imported != null && imported != raw && ModuleScan.dropModuleSegment(imported) == raw) return imported;
		final index: Null<SymbolIndex> = _index;
		if (index == null) return raw;
		// `raw` narrows what `importPathOf` cannot: a simple name ambiguous across PACKAGES
		// (`Position` is both `anyparse.runtime.Span.Position` and `haxe.macro.Expr.Position` once
		// std is in scope) still has one declaration whose module-dropped form is exactly this
		// hybrid. Two sub-module types of the SAME package collide even there — `pkg.A.X` and
		// `pkg.B.X` both drop to `pkg.X` — so a tie is refused rather than guessed: picking wrong
		// would emit an import that COMPILES while binding a different type, which no verification
		// pass can catch.
		final matches: Array<String> = [
			for (path in index.importPathsOf(simple)) if (path != raw && ModuleScan.dropModuleSegment(path) == raw) path
		];
		return matches.length == 1 ? matches[0] : raw;
	}

	/** Whether the index knows a type named `simple` whose own import path IS `path` — i.e. `path` is real and needs no repair. */
	private function declaredAtPath(path: String, simple: String): Bool {
		final index: Null<SymbolIndex> = _index;
		return index != null && index.declaringFiles(simple).exists(f -> ModuleScan.pathOfTypeIn(f, simple) == path);
	}

	/**
	 * Whether the bare `simple` denotes `canonical` with no import anywhere: the builtin whose
	 * OWN path is `canonical`, or — with an index — a type declared in a ROOT-package file,
	 * which Haxe makes globally visible. The caller (`visibleNameFor`) has already ruled out a
	 * local shadow. Matching `canonical`, not just the name, is what keeps `haxe.macro.Type` and
	 * `foo.Any` from collapsing onto the builtins (see `ALWAYS_IN_SCOPE`).
	 */
	private function alwaysInScope(canonical: String, simple: String): Bool {
		if (ALWAYS_IN_SCOPE[simple] == canonical) return true;
		final index: Null<SymbolIndex> = _index;
		return index != null && index.declaringFiles(simple).exists(f -> f.pkg == '' && ModuleScan.pathOfTypeIn(f, simple) == canonical);
	}

	/**
	 * Whether something IN THIS FILE'S SCOPE binds `simple` to something other than `canonical` —
	 * an import or alias, an imported enum's CONSTRUCTOR (`importedMemberNames`), a module-local
	 * declaration, a same-package type, a BULK import (`import pkg.*;` / `using pkg.Module;`, via
	 * `shadowedByBulkImport`), or (globally) a root-package one. Such a binding shadows the bare
	 * name, so neither the builtin short-circuit nor a fresh import may use it.
	 *
	 * The gate covers the WHOLE route set for the reason `visibleNameFor` documents, and its
	 * internal ORDER is Haxe's own: the bulk arm runs last and is short-circuited by an explicit
	 * import or a module-local declaration that already binds `simple` to `canonical`, because the
	 * compiler ranks both of those above a wildcard.
	 */
	private function shadowedLocally(canonical: String, simple: String): Bool {
		final bound: Null<String> = _importMap[simple];
		if (bound != null && bound != canonical) return true;
		final aliased: Null<String> = _aliasTargets[simple];
		if (aliased != null && aliased != canonical) return true;
		if (importedMemberNames().contains(simple)) return true;
		if (shadowedByGuardedImport(canonical, simple)) return true;
		if (shadowedByModuleImport(canonical, simple)) return true;
		final root: Null<QueryNode> = _root;
		if (root != null && ModuleScan.declaresTypeNamed(root, simple) && moduleLocalPathOf(simple) != canonical) return true;
		if (_pkg != null && packageDeclaresOtherType(canonical, simple)) return true;
		final index: Null<SymbolIndex> = _index;
		if (index != null && index.declaringFiles(simple).exists(f -> f.pkg == '' && ModuleScan.pathOfTypeIn(f, simple) != canonical))
			return true;
		// An EXPLICIT import or a module-local declaration that binds `simple` to `canonical`
		// OUTRANKS a bulk import in Haxe's own resolution order (verified against the compiler:
		// `import q.*;` + `import p.Foo;` resolves a bare `Foo` to `p.Foo`, and a module-local
		// `Foo` wins over both). The bulk arm may only veto what a wildcard genuinely outranks —
		// the same-package, builtin and root-package routes below it.
		return _importMap[simple] != canonical && !moduleLocalBinds(canonical, simple) && shadowedByBulkImport(canonical, simple);
	}

	/**
	 * Whether a plain `import <module>;` in this file binds `simple` to a type OTHER than
	 * `canonical`. `_importMap` is keyed by the imported path's LAST SEGMENT, so it answers only for
	 * a module's MAIN type and for an explicitly imported sub-type — a module whose SECONDARY type
	 * carries the name is invisible to it, the mirror of the gap `moduleImportBinds` closes on the
	 * visibility side. Left open, the printer ASSERTED visibility from a module import while staying
	 * BLIND to one as a shadow, and a bare `other.Sub` printed into a file carrying
	 * `import pkg.Mod;` — whose `Mod` declares its own `Sub` — silently named the wrong type.
	 *
	 * Two imports binding one simple name are legal in Haxe and the LAST one wins, so WHICH type the
	 * bare name means is a statement-ORDER question this predicate does not try to answer: it reports
	 * the ambiguity as a shadow, which costs only the short form (the caller falls back to the
	 * fully-qualified path) and never emits a name bound to something else. It therefore vetoes ABOVE
	 * the EXPLICIT-import short-circuit at the end of `shadowedLocally` — unlike a wildcard, a
	 * competing module import genuinely can outrank an explicit import.
	 *
	 * It does NOT outrank a MODULE-LOCAL declaration, which is why that route is exempted here rather
	 * than left to the same short-circuit: a type the file's own module declares wins over every
	 * import unconditionally (verified on 4.3.7 — a module-local `typedef Sub = Int` beside an
	 * `import pkg.Mod;` whose `Mod` declares its own `Sub` resolves the bare name to the LOCAL one).
	 * Vetoing there cost the module-local short form in every file that imported any module carrying
	 * one of its type names.
	 *
	 * Needs the index — only it knows what a module declares. Without one the question is
	 * unanswerable and the arm stays silent, the reading every caller had before it existed.
	 */
	private function shadowedByModuleImport(canonical: String, simple: String): Bool {
		final index: Null<SymbolIndex> = _index;
		if (index == null) return false;
		if (moduleLocalBinds(canonical, simple)) return false;
		final imported: Array<String> = [for (path in _importMap) path];
		return index.declaringFiles(simple).exists(f -> imported.contains(f.module) && ModuleScan.pathOfTypeIn(f, simple) != canonical);
	}

	/**
	 * Whether a BULK import — `import pkg.*;` or a `using pkg.Module;` — could bind `simple` to a
	 * type other than `canonical`. Neither form NAMES what it brings in, so `_importMap` (built
	 * from plain imports) is blind to both.
	 *
	 * The two forms bind different things, verified against the compiler rather than assumed. A
	 * package wildcard `import pkg.*;` binds the MAIN type of each module in that package and
	 * NOTHING else — a secondary type of `pkg.Mod` stays unreachable, so the arm matches only a
	 * main-type declaration. A module wildcard `import pkg.Mod.*;` binds no type name at all (it
	 * imports statics and enum constructors), so it can never shadow and is not tested for. A
	 * `using pkg.Mod;` is an `import pkg.Mod;` plus static extension, so it binds that module's
	 * types.
	 *
	 * WITHOUT an index a wildcard is unanswerable and shadows unconditionally; a `using` is read
	 * textually — only its module's own main-type name is derivable, so a sub-module type it also
	 * binds is a KNOWN miss on that path.
	 *
	 * This arm sits BELOW the explicit-import and module-local routes on purpose (see
	 * `shadowedLocally`): Haxe ranks both above a wildcard, so vetoing them here would refuse a
	 * short name the compiler resolves exactly as intended. It gates the same-package, builtin and
	 * root-package routes, which a wildcard genuinely outranks.
	 *
	 * The conservative direction is the same for every caller: a true here only ever costs the
	 * short form and falls back to the fully-qualified path, which always resolves.
	 */
	private function shadowedByBulkImport(canonical: String, simple: String): Bool {
		if (_root == null) return false;
		final index: Null<SymbolIndex> = _index;
		// One index scan per question, not one per bulk statement: `declaringFiles` filters EVERY
		// indexed file (the std is in the default resolution scope), and the argument is loop-invariant.
		final declarers: Array<FileInfo> = index == null ? [] : index.declaringFiles(simple);
		if (index != null && declarers.length == 0) return false;
		for (c in _bulkImports) {
			final path: Null<String> = c.name;
			if (path == null) continue;
			if (c.kind == ModuleScan.WILDCARD_IMPORT_KIND) {
				// An unindexed wildcard is unanswerable — nothing can enumerate what it brings in.
				if (index == null) return true;
				final dot: Int = path.lastIndexOf('.');
				final prefix: String = dot < 0 ? '' : path.substring(0, dot);
				if (declarers.exists(
					f -> f.pkg == prefix && ModuleScan.isMainTypeIn(f, simple) && ModuleScan.pathOfTypeIn(f, simple) != canonical
				))
					return true;
			} else if (index == null) {
				if (RefactorSupport.lastSegment(path) == simple) return true;
			} else if (declarers.exists(f -> f.module == path && ModuleScan.pathOfTypeIn(f, simple) != canonical))
				return true;
		}
		return false;
	}

	/**
	 * Whether a `#if`-GUARDED plain or aliased import binds `simple` to something OTHER than
	 * `canonical`. Such a file spells one simple name two ways depending on the build — the shape
	 * observed in the wild is an unconditional `import openfl.system.Capabilities;` beside a
	 * `#if flash import flash.system.Capabilities; #end`, with both types then written fully
	 * qualified in disjoint `#elseif` branches, deliberately. `_importMap` is a TOP-LEVEL scan, so
	 * it sees only the unconditional one and would answer that the short name is free for it;
	 * under the guarded build that same short name means the other type.
	 *
	 * The arm therefore runs ABOVE the explicit-import short-circuit in `shadowedLocally`, not
	 * with the bulk imports at the bottom: an unconditional import outranks a wildcard, but it does
	 * NOT outrank a second explicit import of the same simple name — Haxe lets the last one win,
	 * and which one is last depends on the directive.
	 *
	 * A guarded import binding `simple` to `canonical` ITSELF is not a shadow, and it still cannot
	 * enable the short form: it is absent from `_importMap`, so route 1 never fires, and its own
	 * statement text carries the simple name, so route 2's freeness scan refuses. An alias whose
	 * target does not decode counts as a shadow — the alias occupies the name whatever it names.
	 */
	private function shadowedByGuardedImport(canonical: String, simple: String): Bool {
		final root: Null<QueryNode> = _root;
		final source: Null<String> = _source;
		if (root == null || source == null) return false;
		for (c in _guardedImports) {
			final raw: Null<String> = c.name;
			if (raw == null) continue;
			final span: Null<Span> = c.span;
			switch c.kind {
				case 'ImportDecl':
					if (RefactorSupport.lastSegment(raw) == simple && raw != canonical) return true;
				// The grammar's name slot for an alias declaration IS the alias, never the aliased path.
				case 'ImportAliasDecl', 'ImportAliasInDecl':
					if (raw == simple && (span == null || ModuleScan.aliasTargetOf(source.substring(span.from, span.to)) != canonical))
						return true;
				case _:
			}
		}
		return false;
	}

	/**
	 * Whether the index knows a type named `simple` in THIS file's package that is NOT
	 * `canonical` — such a type shadows the bare name. The type being printed is excluded on
	 * purpose: a same-package SUB-module type (`pkg.Mod.Sub`, printed from inside `pkg`) is
	 * declared in this package yet still needs an import, so vetoing on its own declaration
	 * would make route 2 unreachable for it.
	 */
	private function packageDeclaresOtherType(canonical: String, simple: String): Bool {
		final index: Null<SymbolIndex> = _index;
		final pkg: Null<String> = _pkg;
		return index != null && pkg != null
			&& index.declaringFiles(simple).exists(f -> f.pkg == pkg && ModuleScan.pathOfTypeIn(f, simple) != canonical);
	}

	/** The dotted path a type named `simple` declared in THIS module carries: `pkg.Module.simple`, reduced to `pkg.Module` when it IS the main type. */
	private function moduleLocalPathOf(simple: String): Null<String> {
		final module: Null<String> = _module;
		if (module == null) return null;
		final pkg: Null<String> = _pkg;
		final modulePath: String = pkg == null || pkg == '' ? module : '$pkg.$module';
		return module == simple ? modulePath : '$modulePath.$simple';
	}

	/**
	 * A printer over a file's FULL scope: its parsed `root` (top-level decls and import
	 * statements), raw `source` (the alias-target recovery and the short-name freeness scan),
	 * the plain-import map, and optionally the cross-file `index` for same-package /
	 * root-package / canonical-path resolution. This is the form that can ADD imports.
	 */
	public static function forFile(
		source: String, root: QueryNode, importMap: Map<String, String>, plugin: GrammarPlugin, ?index: SymbolIndex
	): TypeRefPrinter {
		return new TypeRefPrinter(source, root, importMap, index, plugin);
	}

	/**
	 * The degenerate printer with NO file scope — only the plain-import map. It shortens an
	 * already-imported or always-in-scope path and leaves everything else fully qualified; it
	 * never inserts an import (there is no tree to anchor one against and no source to prove
	 * the short name free). The form a caller with no parsed file can still use soundly, and
	 * the one `ExplicitLocalType.normalizeInferredType`'s public pure signature keeps.
	 */
	public static function importsOnly(importMap: Map<String, String>): TypeRefPrinter {
		return new TypeRefPrinter(null, null, importMap, null, null);
	}

}
