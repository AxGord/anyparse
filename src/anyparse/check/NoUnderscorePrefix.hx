package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a function PARAMETER or a LOCAL binding (a `var` / `final` local, a loop
 * variable, a comprehension variable) whose identifier carries a leading underscore
 * — `_event`, `__selectedIndex`. The `_` prefix is a private-FIELD marker; on a
 * binding that lives inside one function it carries no information, and it collides
 * with the "intentionally unused" convention `unused-parameter` writes.
 *
 * Opinionated, so DEFAULT OFF (`DefaultOff`): a project opts in with
 * `"no-underscore-prefix": { "enabled": true }`. Two options narrow it:
 * `params` (default true) and `locals` (default true).
 *
 * ## What is never flagged
 *
 *  - A name that is underscores only (`_`, `__`) — a discard binding with nothing
 *    to rename — and a dunder name (`__init__`): both arrive from the grammar's
 *    projection as `NamedDecl.reservedName`.
 *  - A CATCH variable. A `_`-prefixed catch variable is `swallowed-exception`'s
 *    marker for a deliberately discarded exception; de-prefixing it would turn a
 *    silenced finding back into a reported one.
 *
 * ## Autofix
 *
 * `fix` strips EVERY leading underscore (`_event` -> `event`, `__selectedIndex` ->
 * `selectedIndex`) and rewrites every occurrence of the binding, reusing the
 * `naming` check's rename machinery rather than restating it: `Naming.collidesInScope`
 * for the scope-aware target-name collision proof, `Naming.declaringFileRenameSpans`
 * for the scope-correct occurrence set plus its completeness gate (a `#if` region, a
 * string literal, a `noqa` line or a resolver-missed active-code occurrence bails; a
 * distinctive comment mention renames along). Every gate fails CLOSED — an
 * unprovable occurrence leaves the finding report-only.
 *
 * The collision proof is what makes the ctor idiom safe: in
 * `function new(_x) { x = _x; }` the field write `x` is an in-scope occurrence of the
 * target name, so `_x -> x` would silently turn the write into a parameter
 * self-assignment. `collidesInScope` sees it and the rename is refused. An INHERITED
 * member of the same name is proven separately through the resolution index
 * (`supertypeDeclaresMember`), and a target name that is itself a declared top-level
 * type is refused as well.
 *
 * A simple `$name` string-interpolation read is NOT in the reference walker's index,
 * so it is resolved here (`stringInterpIdentKind`, restricted to the binding's own
 * function and only when the file declares the name once) and handed to
 * `declaringFileRenameSpans` as an already-covered occurrence — it renames along
 * instead of blocking. A `"$name"` inside a DOUBLE-quoted string is literal text, not
 * a read: it stays uncovered, and the completeness gate refuses the whole rename.
 *
 * ## Cross-rule loop guard
 *
 * `unused-parameter` silences a parameter it cannot remove by renaming it to
 * `_<name>`. Left alone, the two fixes would ping-pong `_event` <-> `event` forever.
 * So a parameter that is UNREFERENCED in its function is not reported at all while
 * that silencing rename is live — `unused-parameter` enabled in the same config and
 * its `renameSilence` option not explicitly `false` (absent means on: that is the
 * behaviour the knob was carved out of).
 */
@:nullSafety(Strict)
@:access(anyparse.check.Naming)
final class NoUnderscorePrefix implements Check implements DefaultOff implements ConfigAware {

	private static inline final RULE_ID: String = 'no-underscore-prefix';

	/** The rule whose silencing `_<name>` rename this one must not fight — see the class doc. */
	private static inline final UNUSED_PARAMETER_ID: String = 'unused-parameter';

	/** Whether parameters are in scope, unless an `apqlint.json` sets `params`. */
	private static inline final DEFAULT_PARAMS: Bool = true;

	/** Whether locals are in scope, unless an `apqlint.json` sets `locals`. */
	private static inline final DEFAULT_LOCALS: Bool = true;

	/**
	 * A flagged name: one or more leading underscores followed by an alphanumeric. An
	 * all-underscore name has no character after the run and is not matched (it is also
	 * `reservedName` in the projection), and `_1` is matched but its stripped form fails
	 * the identifier check in `strippedName`.
	 */
	private static final UNDERSCORE_PREFIX: EReg = new EReg('^_+[a-zA-Z0-9]', '');

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a parameter or local binding whose name carries a leading underscore';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final shape: RefShape = plugin.refShape();
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final params: Bool = config.boolOption(RULE_ID, 'params') ?? DEFAULT_PARAMS;
			final locals: Bool = config.boolOption(RULE_ID, 'locals') ?? DEFAULT_LOCALS;
			// The silencing rename is live unless the config turns it off: absent means ON,
			// which is what `unused-parameter` did before the knob existed.
			final silenceGuard: Bool = config.enabledFor(UNUSED_PARAMETER_ID)
				&& (config.boolOption(UNUSED_PARAMETER_ID, 'renameSilence') ?? true);
			for (decl in support.project(tree))
				checkDecl(violations, entry.file, entry.source, tree, decl, shape, params, locals, silenceGuard);
		}
		return violations;
	}

	/**
	 * Strip every leading underscore from each flagged binding and rewrite its whole
	 * occurrence set. A finding whose rename cannot be proven complete and collision-free
	 * yields no edit and stays report-only — see `renameFor` for the gate list.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final policy: NamingPolicy = support.policyFor(violations[0].file);
		final shape: RefShape = plugin.refShape();
		// The inherited-member proof walks the FULL supertype closure, so it resolves through the
		// plugin's resolution scope (report files UNION the configured libraries) when present,
		// exactly as the `naming` field rename does; the report-scoped index is the fallback.
		final resolutionIndex: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final flaggedFroms: Array<Int> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s != null) flaggedFroms.push(s.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (decl in support.project(tree)) {
			final span: Null<Span> = decl.span;
			if (span == null || !flaggedFroms.contains(span.from)) continue;
			final rename: Null<RenameEdits> = renameFor(decl, source, tree, policy, shape, plugin, resolutionIndex);
			if (rename != null) for (occ in rename.occurrences) edits.push({ span: occ, text: rename.name });
		}
		return edits;
	}

	/**
	 * Append a violation for `decl` when it is an in-scope underscore-prefixed binding: a
	 * parameter (with `params` on) or a local (with `locals` on) — never a catch variable,
	 * whose `_` prefix is `swallowed-exception`'s intentional-discard marker — carrying a
	 * name the grammar does not reserve and matching `UNDERSCORE_PREFIX`. A parameter
	 * UNREFERENCED in its function is skipped while `unused-parameter`'s silencing rename
	 * is live (`silenceGuard`), or the two fixes would ping-pong.
	 */
	private static function checkDecl(
		out: Array<Violation>, file: String, source: String, tree: QueryNode, decl: NamedDecl, shape: RefShape, params: Bool, locals: Bool,
		silenceGuard: Bool
	): Void {
		final span: Null<Span> = decl.span;
		// `renameUnsafe` on a Param means the grammar projected an anon-STRUCTURE field, not a
		// parameter (`{ _name: String }`): its identifier is a wire contract, so it is neither a
		// finding of this rule nor renameable.
		if (span == null || decl.reservedName == true || decl.renameUnsafe == true) return;
		final isParam: Bool = decl.category == NamingCategory.Param;
		final inScope: Bool = isParam ? params : decl.category == NamingCategory.Local && locals;
		if (!inScope || !UNDERSCORE_PREFIX.match(decl.name)) return;
		if (isParam && silenceGuard && isUnreferenced(source, tree, decl.name, span, shape)) return;
		out.push({
			file: file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: 'underscore-prefixed ${isParam ? 'parameter' : 'local'} \'${decl.name}\''
		});
	}

	/**
	 * The rename to apply to one flagged binding, or null when a gate refuses it: the
	 * grammar marked the declaration rename-unsafe, the stripped name is not usable
	 * (`strippedName`), it collides with something reachable from the binding's scope
	 * (`Naming.collidesInScope` — a sibling parameter, an overlapping local, an own member,
	 * a static, an import), it names a member INHERITED from a supertype, it names a
	 * declared top-level type, or the occurrence set cannot be proven complete
	 * (`Naming.declaringFileRenameSpans`).
	 */
	private static function renameFor(
		decl: NamedDecl, source: String, tree: QueryNode, policy: NamingPolicy, shape: RefShape, plugin: GrammarPlugin,
		resolutionIndex: Null<SymbolIndex>
	): Null<RenameEdits> {
		final span: Null<Span> = decl.span;
		if (span == null || decl.renameUnsafe == true) return null;
		final target: Null<String> = strippedName(decl, policy);
		if (target == null) return null;
		final name: String = target;
		if (Naming.collidesInScope(decl, source, tree, name, shape, resolutionIndex)) return null;
		if (collidesWithProjectSymbol(decl, name, resolutionIndex)) return null;
		final spans: Null<Array<Span>> = Naming.declaringFileRenameSpans(
			source, tree, span.from, decl.name, shape, plugin, Naming.isDistinctiveName(decl.name),
			interpolationReadSpans(tree, source, decl.name, span.from, shape)
		);
		return spans == null ? null : {
			occurrences: spans,
			name: name
		};
	}

	/**
	 * `decl`'s name with every leading underscore stripped, or null when the result must
	 * not be written: nothing was stripped, the remainder is not a valid identifier
	 * (`_1` -> `1`), the applicable naming rule's own normalizer rejects the name (how a
	 * grammar reports "the stripped form is a keyword" — `_new` -> `new`), or the
	 * remainder violates that rule's format, which would trade this finding for a `naming`
	 * one. With no applicable rule (a `checkstyle.json` policy that governs neither
	 * category) the bare strip stands, keyword-unchecked.
	 */
	private static function strippedName(decl: NamedDecl, policy: NamingPolicy): Null<String> {
		final name: String = decl.name;
		var i: Int = 0;
		while (i < name.length && StringTools.fastCodeAt(name, i) == '_'.code) i++;
		if (i == 0) return null;
		final stripped: String = name.substr(i);
		if (!RefactorSupport.isIdentifier(stripped)) return null;
		final rule: Null<NamingRule> = Naming.applicableRule(decl, policy);
		if (rule == null) return stripped;
		final normalize: Null<String -> Null<String>> = rule.normalize;
		if (normalize != null && normalize(name) == null) return null;
		return rule.format.match(stripped) ? stripped : null;
	}

	/**
	 * Whether `target` names something the in-file collision scan cannot see: a member
	 * INHERITED from a supertype of the binding's enclosing type (a bare `target` in this
	 * function would then read the inherited member once the binding is gone), or a
	 * declared top-level type — its simple name is in scope in every file of its package.
	 * Both are proven, never assumed: an unresolvable hierarchy or a missing index answers
	 * "no collision", and the in-file scan stays the primary proof.
	 */
	private static function collidesWithProjectSymbol(decl: NamedDecl, target: String, index: Null<SymbolIndex>): Bool {
		if (index == null) return false;
		final idx: SymbolIndex = index;
		if (idx.declaringFiles(target).length > 0) return true;
		final owner: Null<String> = decl.enclosingType;
		return owner == null ? false : idx.supertypeDeclaresMember(owner, target);
	}

	/**
	 * The identifier-token spans of every simple `$name` string-interpolation read of the
	 * binding declared at `declFrom` — occurrences the reference walker does not index, so
	 * `Rename.renameOccurrences` misses them and the completeness gate would refuse the
	 * whole rename. Restricted to the binding's own innermost function so a same-named
	 * binding in a sibling body is untouched, and returned EMPTY (leaving any such read
	 * uncovered, hence blocking) unless the file declares the name exactly once — with two
	 * declarations the reads cannot be attributed without re-implementing scope resolution.
	 */
	private static function interpolationReadSpans(
		tree: QueryNode, source: String, name: String, declFrom: Int, shape: RefShape
	): Array<Span> {
		final interpKind: Null<String> = shape.stringInterpIdentKind;
		if (interpKind == null) return [];
		var declCount: Int = 0;
		for (h in Refs.find(name, tree, shape)) if (h.kind == RefKind.Decl) declCount++;
		if (declCount != 1) return [];
		final scope: Null<Span> = Naming.innermostSpanOfKinds(tree, functionScopeKinds(shape), declFrom);
		if (scope == null) return [];
		final out: Array<Span> = [];
		collectInterpolationReads(tree, interpKind, name, source, scope, out);
		return out;
	}

	/** Walk `node`, appending the identifier-token span of every `$name` interpolation read inside `scope`. */
	private static function collectInterpolationReads(
		node: QueryNode, interpKind: String, name: String, source: String, scope: Span, out: Array<Span>
	): Void {
		final span: Null<Span> = node.span;
		if (node.kind == interpKind && node.name == name && span != null && span.from >= scope.from && span.to <= scope.to) {
			final off: Int = RefactorSupport.identTokenOffset(source, span, name);
			if (off >= 0) out.push(new Span(off, off + name.length));
		}
		for (child in node.children) collectInterpolationReads(child, interpKind, name, source, scope, out);
	}

	/**
	 * Whether `name`, declared at `declSpan`, is referenced nowhere else in its innermost
	 * enclosing function — the `unused-parameter` condition, decided by the same
	 * scope-bounded textual scan that check uses (`#if`-inclusive, so a conditional use
	 * counts as a reference). False when no enclosing function is found: unproven is not
	 * unreferenced.
	 */
	private static function isUnreferenced(source: String, tree: QueryNode, name: String, declSpan: Span, shape: RefShape): Bool {
		final fn: Null<Span> = Naming.innermostSpanOfKinds(tree, functionScopeKinds(shape), declSpan.from);
		return fn != null && !RefactorSupport.referencedInRange(source, name, fn.from, fn.to, [declSpan]);
	}

	/** Every node kind that bounds a binding's visibility to one body: a function declaration, a local function, a lambda. */
	private static function functionScopeKinds(shape: RefShape): Array<String> {
		return (shape.functionKinds ?? []).concat(shape.localFunctionKinds ?? []).concat(shape.lambdaKinds ?? []);
	}

}

/**
 * A computed rename for one binding: every span to rewrite and the identifier to write
 * at each.
 */
private typedef RenameEdits = {
	final occurrences: Array<Span>;
	final name: String;
};
