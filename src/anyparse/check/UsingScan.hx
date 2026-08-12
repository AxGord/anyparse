package anyparse.check;

import anyparse.query.CondDirectives;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `using`-declaration helpers the static-extension checks share — `dead-binder-counter-loop`,
 * `prefer-find` and `prefer-static-extension` each rewrite a call into an extension method, so
 * each has to ask the same three questions of a file's header: is the module already brought in
 * with `using`, where would the insert go, and does some OTHER `using` already bind the method
 * name (which would make the rewrite resolve elsewhere).
 *
 * The header is not always the file's TOP LEVEL: a module whose whole body sits inside one
 * `#if … #end` region carries its imports there too, and `headerOf` reads that region as the
 * header — its doc holds the gates that decide when a region qualifies.
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
		return { root: tree, guard: guardOf(tree, source, plugin) };
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
			if (name != null && (name == module || (simple && StringTools.endsWith(name, '.$module')))) return true;
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

	/** The declarations the header binds: the file's top level, followed by the whole-body guard's own when it has one. */
	private static function headerDecls(header: UsingHeader): Array<QueryNode> {
		final guard: Null<QueryNode> = header.guard;
		return guard == null ? header.root.children : header.root.children.concat(guard.children);
	}

	/**
	 * The `#if … #end` region holding every type `tree` declares, or null when the file has none — the
	 * answer for the ordinary unguarded module, and the conservative one for every shape the gates
	 * below refuse.
	 *
	 * Three gates, each closing a way the region could fail to cover a rewrite site:
	 *
	 *  - ONE region at the top level, with no type declared OUTSIDE it. A site in an unguarded type
	 *    resolves in the builds where the condition does not hold, so a `using` placed inside the
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
	private static function guardOf(tree: QueryNode, source: String, plugin: GrammarPlugin): Null<QueryNode> {
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
		return guard != null && declaresType(guard, regionKind) && singleBranch(guard, source, shape) ? guard : null;
	}

	/** Whether `node` declares a type directly, or inside a region nested in it — `guardOf`'s coverage gate. */
	private static function declaresType(node: QueryNode, regionKind: String): Bool {
		for (child in node.children) {
			if (RefactorSupport.typeDeclOf(child) != null) return true;
			if (child.kind == regionKind && declaresType(child, regionKind)) return true;
		}
		return false;
	}

	/** Whether `region` opens no `#else` / `#elseif` branch of its own — `guardOf`'s third gate. */
	private static function singleBranch(region: QueryNode, source: String, shape: RefShape): Bool {
		final span: Null<Span> = region.span;
		final opener: Null<String> = shape.conditionalIfKeyword;
		final closer: Null<String> = shape.conditionalEndKeyword;
		final seams: Null<Array<String>> = shape.conditionalElseKeywords;
		if (span == null || opener == null || closer == null || seams == null) return false;
		var depth: Int = 0;
		for (directive in CondDirectives.scan(source, shape)) {
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
