package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `using`-declaration helpers the static-extension checks share — `dead-binder-counter-loop`,
 * `prefer-find` and `prefer-static-extension` each rewrite a call into an extension method, so
 * each has to ask the same three questions of a file's header: is the module already brought in
 * with `using`, where would the insert go, and does some OTHER `using` already bind the method
 * name (which would make the rewrite resolve elsewhere).
 *
 * Split out of `CheckScan`, on the same contract: PURE static helpers over the tree a check
 * already holds, no shared mutable state and no cache — the memo a caller wants is its own
 * `Map` passed in, not state kept here.
 */
@:nullSafety(Strict)
final class UsingScan {

	/** The grammar's `using` declaration kind, spelled literally (see `hasUsingModule`). */
	public static inline final USING_DECL_KIND: String = 'UsingDecl';

	/** The top-level declaration kinds a `using` insert anchors after — the file's package / import / using header. */
	private static final USING_ANCHOR_KINDS: Array<String> = [
		'PackageDecl',
		'ImportDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl',
		'ImportWildDecl',
		USING_DECL_KIND
	];

	/**
	 * Whether a top-level `using <module>;` is already present — then the module's
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
	public static function hasUsingModule(tree: QueryNode, module: String): Bool {
		final simple: Bool = module.indexOf('.') == -1;
		for (child in tree.children) if (child.kind == USING_DECL_KIND) {
			final name: Null<String> = child.name;
			if (name != null && (name == module || (simple && StringTools.endsWith(name, '.$module')))) return true;
		}
		return false;
	}

	/**
	 * A ZERO-WIDTH edit inserting `using <module>;` into `tree`. The insert companion of
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
	 */
	public static function usingInsertEdit(tree: QueryNode, module: String): { span: Span, text: String } {
		var anchor: Null<Span> = null;
		for (child in tree.children) {
			if (child.kind == USING_DECL_KIND) {
				final first: Null<Span> = child.span;
				if (first != null) return { span: new Span(first.from, first.from), text: 'using $module;\n' };
			}
			if (!USING_ANCHOR_KINDS.contains(child.kind)) continue;
			final span: Null<Span> = child.span;
			if (span != null) anchor = span;
		}
		final at: Null<Span> = anchor;
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

	/** The module paths of every top-level `using` declaration in `tree` — the read side of `hasUsingModule`. */
	public static function usingModules(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		for (child in tree.children) if (child.kind == USING_DECL_KIND) {
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

}
