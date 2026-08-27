package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.ModuleScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The `using`-declaration helpers the static-extension checks share — `dead-binder-counter-loop`,
 * `prefer-exists`, `prefer-foreach`, `prefer-find` and `prefer-static-extension` each rewrite a
 * call into an extension method, so each has to ask the same four questions of a file's header: is
 * the module already brought in with `using`, where would the insert go, does some OTHER `using`
 * already bind the method name (which would make the rewrite resolve elsewhere), and — where a
 * receiver MEMBER shadows the extension and the rule falls back to the QUALIFIED `Module.m(recv, …)`
 * spelling — does the bare module name still mean that module here (`qualifiedCallReaches`).
 *
 * The header is not always the file's TOP LEVEL: a module whose whole body sits inside one
 * `#if … #end` region carries its imports there too, and `headerOf` reads that region as the header —
 * `ModuleScan.guardedBodyRegion` holds the gates that decide when a region qualifies.
 *
 * Split out of `CheckScan`, on the same contract: PURE static helpers over the tree a check
 * already holds, no shared mutable state and no cache — the memo a caller wants is its own
 * `Map` passed in, not state kept here.
 */
@:nullSafety(Strict)
final class UsingScan {

	/** The grammar's `using` declaration kind, spelled literally (see `hasUsingModule`). */
	public static inline final USING_DECL_KIND: String = 'UsingDecl';

	/** The wildcard import kind — the one form that binds names it does not spell out (`headerRebindsName`). */
	private static inline final WILDCARD_IMPORT_KIND: String = 'ImportWildDecl';

	/** The top-level declaration kinds a `using` insert anchors after — the file's package / import / using header. */
	private static final USING_ANCHOR_KINDS: Array<String> = [
		'PackageDecl',
		'PackageEmpty',
		'ImportDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl',
		'ImportWildDecl',
		USING_DECL_KIND
	];

	/**
	 * The `using` header of `tree`: its top level, paired with the `#if … #end` region that guards the
	 * module's WHOLE body when the file has one.
	 *
	 * A debug- or platform-only module wraps everything below `package` in a single conditional, so its
	 * import run — and every call a rewrite touches — sits INSIDE that region while the top level holds
	 * nothing but `package` and the region itself. Read one level down, the insert joins that import run
	 * and a `using` already declared there counts as present; read at the top level only, the insert
	 * lands on an island above the `#if` and the guarded `using` is invisible, so a second one is
	 * spliced in.
	 *
	 * Build it ONCE per file and pass it to the three readers: `guardOf` scans the file's directives,
	 * which a per-site rebuild would repeat for every candidate.
	 */
	public static function headerOf(tree: QueryNode, source: String, plugin: GrammarPlugin): UsingHeader {
		return { root: tree, guard: ModuleScan.guardedBodyRegion(tree, source, plugin) };
	}

	/**
	 * Whether a `using <module>;` the header already binds is in scope — then the module's
	 * extension methods resolve without inserting one. `module` may be QUALIFIED
	 * (`pkg.Lambda`), in which case only an exact match counts; a SIMPLE `module`
	 * (`Lambda`) also matches a qualified declaration ending in it (`pkg.Lambda`),
	 * since both bring the same module into scope. Shared by `prefer-find` and
	 * `prefer-static-extension`.
	 *
	 * CAVEAT on that simple-name match: the index models no packages, so a `using
	 * other.pkg.Lambda` of an UNRELATED project-local module sharing the simple name reads
	 * as present and suppresses the insert. It errs toward not inserting — a loud compile
	 * error rather than a silent behaviour change — and a stdlib module (the configured
	 * default) has no same-named sibling to collide with.
	 *
	 * The declaration kind is spelled literally (`USING_DECL_KIND`): `RefShape` exposes no
	 * using-declaration seam, so a grammar naming it differently reads as having no
	 * `using` at all — which only ever causes a redundant insert, never a wrong one.
	 */
	public static function hasUsingModule(header: UsingHeader, module: String): Bool {
		final simple: Bool = module.indexOf('.') == -1;
		for (child in headerDecls(header)) if (child.kind == USING_DECL_KIND) {
			final name: Null<String> = child.name;
			if (name != null && (name == module || (simple && name.endsWith('.$module')))) return true;
		}
		return false;
	}

	/**
		  * A ZERO-WIDTH edit inserting `using <module>;` into the header. The insert companion of
	 * `hasUsingModule`; the caller applies it only after deciding at least one rewrite needs
	 * the module in scope.
	 *
	 * The position is a CORRECTNESS choice, not cosmetics: Haxe resolves static extensions in
	 * REVERSE declaration order, so the LAST `using` wins. Inserting after an existing `using`
	 * run would give the new module top priority and silently re-target every same-named
	 * extension call the file already makes through an earlier `using`. So the insert goes
	 * ABOVE the FIRST existing `using` — lowest priority, no existing call disturbed — and
	 * falls back to after the last package / import declaration, or the file head with a
	 * trailing blank line, only when the file declares no `using` at all.
	 *
	 * An UNGUARDED `using` decides the position on its own: it is in scope for the whole file, so an
	 * insert below it — inside the guard included — would outrank it. Only when the file has none does
	 * the guard's own header take over, which is where the rewrites and their imports live.
	 */
	public static function usingInsertEdit(header: UsingHeader, module: String): { span: Span, text: String } {
		final unguarded: Null<Span> = firstUsing(header.root);
		if (unguarded != null) return { span: new Span(unguarded.from, unguarded.from), text: 'using $module;\n' };
		final guard: Null<QueryNode> = header.guard;
		if (guard != null) {
			final guarded: Null<Span> = firstUsing(guard);
			if (guarded != null) return { span: new Span(guarded.from, guarded.from), text: 'using $module;\n' };
			final inner: Null<Span> = lastAnchor(guard);
			if (inner != null) return { span: new Span(inner.to, inner.to), text: '\nusing $module;' };
		}
		final at: Null<Span> = lastAnchor(header.root);
		return at == null ? { span: new Span(0, 0), text: 'using $module;\n\n' } : {
			span: new Span(at.to, at.to),
			text: '\nusing $module;'
		};
	}

	/**
	 * Whether a `using` OTHER than `module` in the same file could also supply `method` — the
	 * gate every extension-method rewrite needs before it emits a `<recv>.<method>(…)` call.
	 *
	 * Haxe resolves static extensions in REVERSE declaration order, so a second module declaring
	 * the same name decides where the rewritten call lands. Two rules depend on that: writing an
	 * explicit `Module.m(x)` in such a file may be deliberate disambiguation the rewrite would
	 * undo, and a `using` INSERTED below an existing run (see `usingInsertEdit`) loses to it. A
	 * module naming the same type as `module` is skipped; for the rest a known extension table
	 * decides, and without one `symbols` must PROVE the module declares no such member. Every
	 * doubt — an unknown module with no index, or one the index cannot resolve — counts as a
	 * conflict, so the caller refuses rather than emits a silently retargeted call.
	 *
	 * The verdict depends only on the `(module, method)` pair while a file repeats it across
	 * every site, and each miss costs a whole-index member-closure query, so `memo` carries it
	 * for the caller's run. Pass a fresh map per file — a `using` set is per-file state.
	 */
	public static function conflictingUsing(
		usings: Array<String>, module: String, method: String, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>,
		memo: Map<String, Bool>
	): Bool {
		final key: String = '$module:$method';
		final cached: Null<Bool> = memo[key];
		if (cached != null) return cached;
		final verdict: Bool = conflictScan(usings, module, method, plugin, symbols);
		memo[key] = verdict;
		return verdict;
	}

	/**
	 * Whether the QUALIFIED spelling `<module>.<method>(receiver, …)` provably reaches `module`'s
	 * own static from THIS file — the FALLBACK every `Lambda`-targeting rule emits at a site whose
	 * receiver type declares a member of the same name.
	 *
	 * A real member beats a `using` static extension, so `m.exists(x -> …)` on a receiver whose type
	 * declares `exists` binds to THAT member and does not compile. The fold itself is untouched by
	 * that: `Lambda.exists(m, x -> …)` names the module outright and never consults the receiver's
	 * members. What the qualified call DOES depend on is the one thing the extension form did not —
	 * that the bare name `module` means the module here — and this is that question.
	 *
	 * Three ways it can fail, each a REFUSAL (the rule keeps the report-only finding it had before):
	 *
	 * - the file's own module declares a type named `module`. A same-module type wins the simple
	 *   name outright;
	 * - the header REBINDS the simple name — `import p.Lambda;`, `import p.X as Lambda;`,
	 *   `using p.Lambda;` — or carries a WILDCARD `import p.*;`, which binds main types it does not
	 *   spell out and which no scan of the statement can enumerate without the package's contents;
	 * - the run's index holds a type named `module` that does not declare `method` as a STATIC. That
	 *   is the live case: a project may ship its own root-package `Lambda.hx`, which displaces the
	 *   std one for every file that compiles against it.
	 *
	 * The index arm is VACUOUSLY true when nothing by that name is indexed, which is the same
	 * fail-open posture `memberShadowsExtension` itself takes: no evidence of a shadow is not
	 * evidence of one, and a resolution scope that models neither the std nor the project would
	 * otherwise turn the whole fallback off.
	 */
	public static function qualifiedCallReaches(
		header: UsingHeader, module: String, method: String, symbols: () -> Null<SymbolIndex>
	): Bool {
		if (headerDeclaresType(header, module) || headerRebindsName(header, module)) return false;
		final index: Null<SymbolIndex> = symbols();
		if (index == null) return true;
		for (fi in index.declaringFiles(module))
			for (t in fi.types)
				if (t.name == module && !t.members.exists(m -> m.name == method && m.isStatic)) return false;
		return true;
	}

	/** The module paths of every `using` declaration the header binds — the read side of `hasUsingModule`. */
	public static function usingModules(header: UsingHeader): Array<String> {
		final out: Array<String> = [];
		for (child in headerDecls(header)) if (child.kind == USING_DECL_KIND) {
			final name: Null<String> = child.name;
			if (name != null) out.push(name);
		}
		return out;
	}

	/** The unmemoised body of `conflictingUsing` — one pass over the file's other `using` declarations. */
	private static function conflictScan(
		usings: Array<String>, module: String, method: String, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>
	): Bool {
		final simple: String = CheckScan.simpleModuleName(module);
		for (path in usings) if (path != module && CheckScan.simpleModuleName(path) != simple) {
			final known: Null<Array<String>> = plugin.knownExtensionMethods(path);
			if (known != null) {
				if (known.contains(method)) return true;
				continue;
			}
			final index: Null<SymbolIndex> = symbols();
			// The FULL module path, not its last segment: `typeProvablyLacksMember` resolves a
			// dotted name by import path, so a module whose simple name another package reuses
			// no longer reads as ambiguous-and-therefore-conflicting.
			// The FULL module path, not its last segment: `typeProvablyLacksMember` resolves a
			// dotted name by import path, so a module whose simple name another package reuses
			// no longer reads as ambiguous-and-therefore-conflicting.
			if (index == null || !index.typeProvablyLacksMember(path, method)) return true;
		}
		return false;
	}

	/**
	 * Whether the file's own module declares a top-level type named `name` — the first way a
	 * qualified `<name>.<method>(…)` can mean something other than the module it spells.
	 */
	private static function headerDeclaresType(header: UsingHeader, name: String): Bool {
		for (child in headerDecls(header)) {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(child);
			if (decl != null && decl.name == name) return true;
		}
		return false;
	}

	/**
	 * Whether an `import` / `using` in the header binds the simple name `name` to something other
	 * than the module of that very name — an aliased import taking the name, a qualified path whose
	 * LAST segment is it, or any wildcard import (which binds main types it does not spell out).
	 *
	 * A bare `import Lambda;` / `using Lambda;` is the module itself and is NOT a rebind: those
	 * statements are exactly what a file writes to reach the std module the qualified call wants.
	 */
	private static function headerRebindsName(header: UsingHeader, name: String): Bool {
		for (child in headerDecls(header)) switch (child.kind) {
			case 'ImportAliasDecl', 'ImportAliasInDecl':
				if (child.name == name) return true;
			case WILDCARD_IMPORT_KIND:
				return true;
			case 'ImportDecl', USING_DECL_KIND:
				final path: Null<String> = child.name;
				if (path != null && path != name && path.endsWith('.$name')) return true;
			case _:
		}
		return false;
	}

	/** The declarations the header binds: the file's top level, followed by the whole-body guard's own when it has one. */
	private static function headerDecls(header: UsingHeader): Array<QueryNode> {
		final guard: Null<QueryNode> = header.guard;
		return guard == null ? header.root.children : header.root.children.concat(guard.children);
	}

	/** The span of the FIRST `using` declared directly under `node`, or null when it declares none. */
	private static function firstUsing(node: QueryNode): Null<Span> {
		for (child in node.children) if (child.kind == USING_DECL_KIND) {
			final span: Null<Span> = child.span;
			if (span != null) return span;
		}
		return null;
	}

	/** The span of the LAST package / import / using declared directly under `node` — the declaration an insert follows. */
	private static function lastAnchor(node: QueryNode): Null<Span> {
		var anchor: Null<Span> = null;
		for (child in node.children) if (USING_ANCHOR_KINDS.contains(child.kind)) {
			final span: Null<Span> = child.span;
			if (span != null) anchor = span;
		}
		return anchor;
	}

}

/**
 * A module's `using` header: the file's top level, plus the `#if … #end` region that guards its
 * WHOLE body when it has one — built by `UsingScan.headerOf`. `guard` is null for the ordinary
 * unguarded module and for every region the coverage gates refuse.
 */
typedef UsingHeader = {
	final root: QueryNode;
	final guard: Null<QueryNode>;
}
