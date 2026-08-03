package anyparse.query;

import anyparse.query.ImportOrder.ImportSlot;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

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

/** One import insert: the byte offset to splice at, and the statement text already carrying its own newline. */
private typedef ImportAnchor = {
	var offset: Int;
	var text: String;

	/**
	 * The order carried by the import RUN this anchor lands in, or -1 when it lands in none (a
	 * fallback anchor). Several fresh lines sharing one anchor are sorted under it, so they never
	 * leave that run explained by neither order.
	 */
	var order: Int;
}

/**
 * Prints a type reference INTO a specific file: the import-aware counterpart of a raw
 * `substring(lastIndexOf('.') + 1)`. Every fixer that MATERIALISES a type path — an
 * `explicit-local-type` annotation, a `prefer-typed-throw` `new Exception(...)` — faces the
 * same three-way decision, and getting it wrong emits code that either fails to compile or
 * silently binds a different type. The decision, in preference order:
 *
 *  1. **Short name**, when the type is ALREADY visible in the file:
 *     - a plain `import pack.Module;` / `import pack.Module.SubType;` binding exactly this
 *       path (`TypeInfoProvider.importMap`);
 *     - an ALIASED `import pack.Module as U;` whose target is this path — the ALIAS is
 *       printed (the grammar drops an alias's original path, so it is recovered by slicing
 *       the statement's own source);
 *     - a type declared in THIS module (a same-file secondary type);
 *     - the MAIN type of another module in the SAME package (`pkg.Name` where the file's
 *       package is `pkg`) — visible with no import. A same-package SUB-module type
 *       (`pkg.Module.SubType`) is NOT: it still needs an import, so it takes route 2 / 3;
 *     - an always-in-scope top-level name whose OWN path this is (`String`, `haxe.ds.Map`, ...;
 *       plus, with an index, any type declared in a root-package file — those are global in
 *       Haxe).
 *
 *     Except for the alias route (which reads its own binding), every route above is gated by
 *     `shadowedLocally`: Haxe's resolution order is module type, then import / alias, then same
 *     package, then top level, so a lower-priority route can be overruled by a higher-priority
 *     binding. A bare `Widget` does not mean the same-package `pkg.Widget` in a file that also
 *     carries `import other.Widget;` — nor in one carrying a BULK import (`import other.*;`,
 *     `using other.Widget;`) that binds the name, which `shadowedByBulkImport` decides against
 *     the index.
 *
 *  2. Else **add an import** and use the short name — but ONLY when the short name is FREE
 *     in that file: nothing visible here binds it (`shadowedLocally`), no EARLIER pending
 *     import of a different path already claimed it (Haxe accepts two imports of one simple
 *     name and silently lets the last win), and it does not occur as a word-boundary token
 *     anywhere in the source (an occurrence with no binding to the path being printed must
 *     resolve elsewhere — a wildcard import, a type parameter, a `pkg.Name` qualified use — so
 *     an import would collide with it or retarget it). The insert respects the file's existing
 *     import ORDER: an already-sorted import block keeps its sort, an unsorted one is appended
 *     to (after the last plain `import`, so the file's `using` group stays last).
 *
 *  3. Else the **correct fully-qualified form**. For a SECONDARY (sub-module) type that is
 *     the module-qualified `pack.Module.SubType`, NEVER the `pack.SubType` hybrid — the
 *     hybrid compiles only while an import of the short name happens to exist and breaks the
 *     moment it goes away (observed in the wild: a file carrying
 *     `import api.model.folders.FolderContent.FolderContentEntity;` was given the annotation
 *     `:api.model.folders.FolderContentEntity`). A hybrid handed IN is repaired: `canonicalize`
 *     resolves it against the file's imports and the `SymbolIndex` before anything decides on
 *     it.
 *
 * A run with NO dot is returned verbatim and never triggers an import: a bare name carries
 * no derivable module path, and `printTypeExpr` walks structural field names (`{ name :
 * String }`) through the same entry point.
 *
 * `resolvePath` exposes the other half of that machinery — the DECLARATION a written
 * reference denotes, proven against the index — so a caller rewriting an EXISTING reference
 * (`shorten-type-ref`) can require that its replacement names the same declaration rather
 * than trusting the print alone.
 *
 * LIMIT — an UNRESOLVABLE hybrid. `pack.Module` (a main type) and `pack.SubType` (a hybrid)
 * are textually identical shapes; only the file's imports or the `SymbolIndex` tell them
 * apart. When NEITHER knows the simple name, route 2 reads the path as a module and proposes
 * `import pack.SubType;` — which does not resolve for a real sub-type. That is a proposal, not
 * a silent result: every caller of this printer runs behind a verification pass that
 * typechecks the edited file and reverts it to report-only, and widening the resolution scope
 * (`resolutionRoots`) makes `canonicalize` repair the path instead. The predecessor behaviour
 * was strictly worse — it emitted the hybrid VERBATIM, which typechecks while the import that
 * props it up survives and breaks silently later.
 *
 * The printer is per-file and stateful only in its pending-import set and a lazy inert-region
 * memo; every resolution input is immutable. `importsOnly` builds the degenerate form for a
 * caller with no parsed file — a pure shorten-or-qualify that never inserts an import.
 */
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

	/** The import / using declaration kinds a grammar projects at the top level — the anchor set for an insert and for the bound-name scan. */
	private static final IMPORT_DECL_KINDS: Array<String> = [
		'ImportDecl',
		'UsingDecl',
		'ImportWildDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl'
	];

	/** The wildcard import kind — the one bulk form whose binding set depends on the package it names. */
	private static inline final WILDCARD_IMPORT_KIND: String = 'ImportWildDecl';

	/** The BULK import kinds — the two statements that bind names they do not spell out (`shadowedByBulkImport`). */
	private static final BULK_IMPORT_KINDS: Array<String> = [WILDCARD_IMPORT_KIND, 'UsingDecl'];

	/**
	 * A printer over a file's FULL scope: its parsed `root` (top-level decls and import
	 * statements), raw `source` (the alias-target recovery and the short-name freeness scan),
	 * the plain-import map, and optionally the cross-file `index` for same-package /
	 * root-package / canonical-path resolution. This is the form that can ADD imports.
	 */
	public static function forFile(source: String, root: QueryNode, importMap: Map<String, String>, ?index: SymbolIndex): TypeRefPrinter {
		return new TypeRefPrinter(source, root, importMap, index);
	}

	/**
	 * The degenerate printer with NO file scope — only the plain-import map. It shortens an
	 * already-imported or always-in-scope path and leaves everything else fully qualified; it
	 * never inserts an import (there is no tree to anchor one against and no source to prove
	 * the short name free). The form a caller with no parsed file can still use soundly, and
	 * the one `ExplicitLocalType.normalizeInferredType`'s public pure signature keeps.
	 */
	public static function importsOnly(importMap: Map<String, String>): TypeRefPrinter {
		return new TypeRefPrinter(null, null, importMap, null);
	}

	/**
	 * How to spell the type path `fqn` in this file, per the three-way preference documented
	 * on the class. `fqn` may be a simple name, a module path, a module-qualified sub-type
	 * path, or the `pack.SubType` HYBRID a compiler prints for a secondary type — the hybrid
	 * is canonicalised first, so the result is never one. A returned non-null `importPath` is
	 * also RECORDED for `pendingImportEdits`.
	 *
	 * `owned` is passed through to `canAddImport`: the byte ranges that are written occurrences
	 * of `fqn` itself, which the caller is rewriting. Only a caller that SHORTENS existing
	 * qualified text has any (see `canAddImport`); everyone else omits it and route 2 keeps its
	 * whole-source freeness scan.
	 */
	public function print(fqn: String, ?owned: Array<Span>): PrintedTypeRef {
		final trimmed: String = StringTools.trim(fqn);
		// A dotless run carries no derivable module path, and a lower-initial final segment is a
		// package path or a structural field name, never a type — both pass through untouched.
		if (trimmed.indexOf('.') == -1 || !RefactorSupport.isUpperInitial(lastSegment(trimmed))) return {
			text: trimmed,
			importPath: null
		};
		final canonical: String = canonicalize(trimmed);
		final simple: String = lastSegment(canonical);
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
	 * A caller holding a PARSED type reference should address `print` directly instead: the
	 * grammar's `parseFileTypeRefs` projection carries one node per nominal with an exact span,
	 * so nothing has to be re-lexed out of an annotation's text. This entry point is for a type
	 * expression the caller only has as a STRING — a compiler oracle's answer, a synthesised
	 * annotation.
	 */
	public function printTypeExpr(t: String): String {
		final buf: StringBuf = new StringBuf();
		final n: Int = t.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(t, i);
			if (!RefactorSupport.isIdentChar(c) && c != '.'.code) {
				buf.addChar(c);
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n) {
				final cc: Int = StringTools.fastCodeAt(t, i);
				if (!RefactorSupport.isIdentChar(cc) && cc != '.'.code) break;
				i++;
			}
			buf.add(print(t.substring(start, i)).text);
		}
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
		final trimmed: String = StringTools.trim(ref);
		// The same two rejections `print` opens with, so both entry points read one input class:
		// a dotless run carries no derivable module path, and a lower-initial final segment is a
		// package path or a structural field name, never a type.
		if (trimmed.indexOf('.') == -1 || !RefactorSupport.isUpperInitial(lastSegment(trimmed))) return null;
		final canonical: String = canonicalize(trimmed);
		return declaredAtPath(canonical, lastSegment(canonical)) ? canonical : null;
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
		final buckets: Array<{ offset: Int, order: Int, lines: Array<{ path: String, text: String }> }> = [];
		for (path in _pendingImports) {
			final anchor: ImportAnchor = anchorFor(path);
			final line: { path: String, text: String } = { path: path, text: anchor.text };
			final existing: Null<{ offset: Int, order: Int, lines: Array<{ path: String, text: String }> }> = buckets.find(b ->
				b.offset == anchor.offset
			);
			if (existing == null)
				buckets.push({ offset: anchor.offset, order: anchor.order, lines: [line] });
			else
				existing.lines.push(line);
		}
		return [
			for (bucket in buckets) {
				bucket.lines.sort((a, b) -> ImportOrder.compare(bucket.order, a.path, b.path));
				{
					span: new Span(bucket.offset, bucket.offset),
					text: [for (line in bucket.lines) line.text].join(''),
					paths: [for (line in bucket.lines) line.path]
				};
			}
		];
	}

	/** Whether `print` has promised at least one import that `pendingImportEdits` will materialise. */
	public function hasPendingImports(): Bool {
		return _pendingImports.length > 0;
	}

	private function new(
		source: Null<String>, root: Null<QueryNode>, importMap: Map<String, String>, index: Null<SymbolIndex>
	) {
		_source = source;
		_root = root;
		_importMap = importMap;
		_index = index;
		_pkg = root == null ? null : packageOf(root);
		_module = root == null ? null : mainTypeNameOf(root);
		_aliasTargets = source == null || root == null ? [] : aliasTargetsOf(source, root);
		// Ctor-hoisted like every sibling scan: both `shadowedByGuardedImport` and
		// `shadowedByBulkImport` ask for these, once per printed reference.
		_guardedImports = root == null ? [] : guardedImportDecls(root);
		_bulkImports = root == null ? [] : bulkImportDecls(root, _guardedImports);
		// A `package` declaration with no recoverable span leaves no legal anchor: the file-start
		// fallback would splice the import AHEAD of `package`, which does not parse. Refuse to
		// import at all rather than emit that.
		_canAnchorImports = root == null || !hasSpanlessPackage(root);
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

	/** Whether the file carries a `package` declaration whose span the grammar did not record. */
	private static function hasSpanlessPackage(root: QueryNode): Bool {
		for (c in root.children) if (c.kind == 'PackageDecl' && c.span == null) return true;
		return false;
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
		final root: Null<QueryNode> = _root;
		if (root != null && declaresTypeNamed(root, simple) && canonical == moduleLocalPathOf(simple)) return simple;
		final pkg: Null<String> = _pkg;
		if (pkg != null && canonical == (pkg == '' ? simple : '$pkg.$simple')) return simple;
		return null;
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
		if (shadowedLocally(canonical, simple)) return false;
		if (_pendingImports.exists(p -> p != canonical && lastSegment(p) == simple)) return false;
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
	 * The `import <path>;` line for `path` plus the offset to splice it at. Priority: the slot
	 * `ImportOrder` picks inside the plain-import RUN the path belongs to (that run's own ordering
	 * is preserved), else after the last plain `import` (so a fresh import never lands past the
	 * file's `using` group), else after the last `using` / wildcard / alias, else after the
	 * `package` declaration, else the file start. The statement carries a TRAILING `\n` when the
	 * offset is a line start (a run slot, or a file with nothing to anchor on), a LEADING one when
	 * it splices after a statement's end.
	 */
	private function anchorFor(path: String): ImportAnchor {
		final stmt: String = 'import $path;';
		final root: Null<QueryNode> = _root;
		final source: Null<String> = _source;
		if (root == null) return { offset: 0, text: '$stmt\n', order: -1 };
		if (source != null) {
			final slots: Array<ImportSlot> = ImportOrder.slotsOf(root);
			final runSlot: Int = ImportOrder.insertOffset(source, slots, path);
			if (runSlot >= 0) return { offset: runSlot, text: '$stmt\n', order: ImportOrder.orderAt(source, slots, runSlot) };
		}
		var lastPlain: Null<Span> = null;
		var lastAny: Null<Span> = null;
		var packageSpan: Null<Span> = null;
		for (c in root.children) {
			if (c.kind == 'ImportDecl' && c.span != null) lastPlain = c.span;
			if (IMPORT_DECL_KINDS.contains(c.kind) && c.span != null) lastAny = c.span;
			if (c.kind == 'PackageDecl' && c.span != null) packageSpan = c.span;
		}
		final span: Null<Span> = lastPlain ?? lastAny ?? packageSpan;
		return span == null ? { offset: 0, text: '$stmt\n', order: -1 } : { offset: span.to, text: '\n$stmt', order: -1 };
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
		final simple: String = lastSegment(raw);
		if (declaredAtPath(raw, simple)) return raw;
		final imported: Null<String> = _importMap[simple];
		if (imported != null && imported != raw && dropModuleSegment(imported) == raw) return imported;
		final index: Null<SymbolIndex> = _index;
		if (index != null) {
			final path: Null<String> = index.importPathOf(simple);
			if (path != null && path != raw && dropModuleSegment(path) == raw) return path;
		}
		return raw;
	}

	/** Whether the index knows a type named `simple` whose own import path IS `path` — i.e. `path` is real and needs no repair. */
	private function declaredAtPath(path: String, simple: String): Bool {
		final index: Null<SymbolIndex> = _index;
		return index != null && index.declaringFiles(simple).exists(f -> pathOfTypeIn(f, simple) == path);
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
		if (!RefactorSupport.isUpperInitial(module) || module == parts[parts.length - 1]) return path;
		return parts.slice(0, parts.length - 2).concat([parts[parts.length - 1]]).join('.');
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
		return index != null && index.declaringFiles(simple).exists(f -> f.pkg == '' && pathOfTypeIn(f, simple) == canonical);
	}

	/**
	 * Whether something IN THIS FILE'S SCOPE binds `simple` to a type other than `canonical` —
	 * an import or alias, a module-local declaration, a same-package type, a BULK import
	 * (`import pkg.*;` / `using pkg.Module;`, via `shadowedByBulkImport`), or (globally) a
	 * root-package one. Such a binding shadows the bare name, so neither the builtin
	 * short-circuit nor a fresh import may use it.
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
		if (shadowedByGuardedImport(canonical, simple)) return true;
		final root: Null<QueryNode> = _root;
		if (root != null && declaresTypeNamed(root, simple) && moduleLocalPathOf(simple) != canonical) return true;
		final pkg: Null<String> = _pkg;
		if (pkg != null && packageDeclaresOtherType(canonical, simple)) return true;
		final index: Null<SymbolIndex> = _index;
		if (index != null && index.declaringFiles(simple).exists(f -> f.pkg == '' && pathOfTypeIn(f, simple) != canonical)) return true;
		// An EXPLICIT import or a module-local declaration that binds `simple` to `canonical`
		// OUTRANKS a bulk import in Haxe's own resolution order (verified against the compiler:
		// `import q.*;` + `import p.Foo;` resolves a bare `Foo` to `p.Foo`, and a module-local
		// `Foo` wins over both). The bulk arm may only veto what a wildcard genuinely outranks —
		// the same-package, builtin and root-package routes below it.
		if (_importMap[simple] == canonical) return false;
		if (root != null && declaresTypeNamed(root, simple) && moduleLocalPathOf(simple) == canonical) return false;
		return shadowedByBulkImport(canonical, simple);
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
		final root: Null<QueryNode> = _root;
		if (root == null) return false;
		final index: Null<SymbolIndex> = _index;
		// One index scan per question, not one per bulk statement: `declaringFiles` filters EVERY
		// indexed file (the std is in the default resolution scope), and the argument is loop-invariant.
		final declarers: Array<FileInfo> = index == null ? [] : index.declaringFiles(simple);
		if (index != null && declarers.length == 0) return false;
		for (c in _bulkImports) {
			final path: Null<String> = c.name;
			if (path == null) continue;
			if (c.kind == WILDCARD_IMPORT_KIND) {
				// An unindexed wildcard is unanswerable — nothing can enumerate what it brings in.
				if (index == null) return true;
				final dot: Int = path.lastIndexOf('.');
				final prefix: String = dot < 0 ? '' : path.substring(0, dot);
				if (declarers.exists(f -> f.pkg == prefix && isMainTypeIn(f, simple) && pathOfTypeIn(f, simple) != canonical)) return true;
			} else if (index == null) {
				if (lastSegment(path) == simple) return true;
			} else if (declarers.exists(f -> f.module == path && pathOfTypeIn(f, simple) != canonical))
				return true;
		}
		return false;
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
					if (lastSegment(raw) == simple && raw != canonical) return true;
				// The grammar's name slot for an alias declaration IS the alias, never the aliased path.
				case 'ImportAliasDecl' | 'ImportAliasInDecl':
					if (raw == simple && (span == null || aliasTargetOf(source.substring(span.from, span.to)) != canonical)) return true;
				case _:
			}
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
	 * Whether the index knows a type named `simple` in THIS file's package that is NOT
	 * `canonical` — such a type shadows the bare name. The type being printed is excluded on
	 * purpose: a same-package SUB-module type (`pkg.Mod.Sub`, printed from inside `pkg`) is
	 * declared in this package yet still needs an import, so vetoing on its own declaration
	 * would make route 2 unreachable for it.
	 */
	private function packageDeclaresOtherType(canonical: String, simple: String): Bool {
		final index: Null<SymbolIndex> = _index;
		final pkg: Null<String> = _pkg;
		return index != null && pkg != null && index.declaringFiles(simple)
			.exists(f -> f.pkg == pkg && pathOfTypeIn(f, simple) != canonical);
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

	/**
	 * The dotted path of one `import a.b.C as D;` statement text — the identifier run BEFORE the
	 * trailing `as` / `in` keyword, which is where the aliased path always sits — or `''` when it
	 * does not decode. Comments are stripped first: a `/* … *\/` between the keyword and the path
	 * would otherwise be decoded AS the path, and a wrong target silently prints the alias for
	 * the wrong type. `''` still occupies the alias's name, which is what the collision gate
	 * needs.
	 */
	private static function aliasTargetOf(stmt: String): String {
		final bare: String = stripComments(stmt);
		final runs: Array<String> = [];
		final n: Int = bare.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(bare, i);
			if (!RefactorSupport.isIdentChar(c) && c != '.'.code) {
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n) {
				final cc: Int = StringTools.fastCodeAt(bare, i);
				if (!RefactorSupport.isIdentChar(cc) && cc != '.'.code) break;
				i++;
			}
			runs.push(bare.substring(start, i));
		}
		// `import <path> as <alias>;` -> the run before the `as` / `in` keyword.
		for (r => run in runs) if ((run == 'as' || run == 'in') && r > 0) return runs[r - 1];
		return '';
	}

	/** `text` with every `//` line comment and `/* … *\/` block comment replaced by a space, so a lexical scan cannot read comment content as code. */
	private static function stripComments(text: String): String {
		final buf: StringBuf = new StringBuf();
		final n: Int = text.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(text, i);
			final next: Int = i + 1 < n ? StringTools.fastCodeAt(text, i + 1) : 0;
			if (c == '/'.code && next == '/'.code) {
				while (i < n && StringTools.fastCodeAt(text, i) != '\n'.code) i++;
				buf.addChar(' '.code);
				continue;
			}
			if (c == '/'.code && next == '*'.code) {
				i += 2;
				while (i + 1 < n && !(StringTools.fastCodeAt(text, i) == '*'.code && StringTools.fastCodeAt(text, i + 1) == '/'.code)) i++;
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

	/** The file's `package` payload (`''` for the root package, and for a file with no declaration at all). */
	private static function packageOf(root: QueryNode): String {
		for (c in root.children) if (c.kind == 'PackageDecl') return c.name ?? '';
		return '';
	}

	/** The last dotted segment of `dotted`, or the whole string when unqualified. */
	private static inline function lastSegment(dotted: String): String {
		final dot: Int = dotted.lastIndexOf('.');
		return dot == -1 ? dotted : dotted.substring(dot + 1);
	}

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

	/** The cross-file index for same-package / root-package / canonical-path resolution, or null when the run has none. */
	private final _index: Null<SymbolIndex>;

	/** Whether a fresh import has a legal splice point in this file (see the constructor). */
	private final _canAnchorImports: Bool;

	/** Paths `print` promised an import for, in first-promised order. */
	private final _pendingImports: Array<String> = [];

	/** Every `#if`-guarded import-ish declaration of the file, at any directive nesting depth; empty with no tree. */
	private final _guardedImports: Array<QueryNode>;

	/** The file's BULK import statements, guarded ones included — the `shadowedByBulkImport` input; empty with no tree. */
	private final _bulkImports: Array<QueryNode>;

	/** The file's inert (comment + literal-text) regions, computed on FIRST use and cached — see `inertRegions`. */
	private var _inertRegions: Null<Array<Span>> = null;

}
