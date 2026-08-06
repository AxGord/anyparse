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
 * Two flagged bindings differing only in underscore count (`_a` / `__a`) strip to the
 * SAME name, and neither is visible to the other's collision proof - that scans the
 * PRE-fix source, where each occurrence still carries its own prefix. Renaming both would
 * merge two bindings into one, silently and compilably. So every target is derived first,
 * and a target claimed twice from overlapping scopes refuses both (`claimedByAnother`).
 *
 * A derived name landing on a RESERVED WORD (`_new` -> `new`) is refused through the
 * grammar's `RefShape.reservedWords`, unconditionally - a naming policy cannot stand in
 * for that gate, since one adapted from a project config carries no normalizer and every
 * camelCase format matches `dynamic` just as it matches `event`.
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
 * that silencing rename is live — `unused-parameter` enabled in the same config AND its
 * `renameSilence` option resolving TRUE (`UnusedParameter.renameSilenceLive`, the one seat
 * for the key and its FALSE default). So an ABSENT option means the rename is dead and
 * there is nothing to ping-pong with: an unreferenced `_event` is flagged and
 * de-underscored like any other parameter.
 *
 * Consequence of that default, deliberate: `unused-parameter` also SKIPS an `_`-prefixed
 * name outright, reading the prefix as the intentional-discard convention. Stripping the
 * prefix hands the parameter back to it, and for the autofixable subset (a local function
 * or a confined private method, whose call set is provable in-file) its `Warning` arm then
 * REMOVES the parameter and its arguments. That is the intended reach — the prefix carries
 * nothing on a binding scoped to one function — but it means enabling this rule can delete
 * a parameter its author marked as discarded. A project that wants the marker respected
 * opts into `renameSilence`, which restores the guard. Note the asymmetry with a CATCH
 * variable, exempted unconditionally above: there the same strip re-opens a
 * `swallowed-exception` finding instead of removing dead weight.
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
	 * Whether the supertype-shadow veto stands for a local / parameter / catch variable,
	 * unless an `apqlint.json` sets `allowInheritedShadow`. Default keeps the veto.
	 */
	private static inline final DEFAULT_ALLOW_INHERITED_SHADOW: Bool = false;

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

	@:access(anyparse.check.UnusedParameter)
	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final shape: RefShape = plugin.refShape();
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final options: Options = {
				params: config.boolOption(RULE_ID, 'params') ?? DEFAULT_PARAMS,
				locals: config.boolOption(RULE_ID, 'locals') ?? DEFAULT_LOCALS,
				// `enabledFor` too: a disabled `unused-parameter` emits no finding to silence,
				// so its rename cannot run whatever the option says.
				silenceGuard: config.enabledFor(UNUSED_PARAMETER_ID) && UnusedParameter.renameSilenceLive(config)
			};
			for (decl in support.project(tree)) checkDecl(violations, entry.file, entry.source, tree, decl, shape, options);
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
		// Resolved per fix() call from the findings' own file, exactly as `run` resolves `params` /
		// `locals`: the option governs a GATE inside the rename, so it belongs to the fix path.
		final config: LintConfig = LintConfig.resolveWith(_resolveConfig, violations[0].file);
		final allowInheritedShadow: Bool = config.boolOption(RULE_ID, 'allowInheritedShadow') ?? DEFAULT_ALLOW_INHERITED_SHADOW;
		// The inherited-member proof walks the FULL supertype closure, so it resolves through the
		// plugin's resolution scope (report files UNION the configured libraries) when present,
		// exactly as the `naming` field rename does; the report-scoped index is the fallback.
		final resolutionIndex: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final flaggedFroms: Array<Int> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s != null) flaggedFroms.push(s.from);
		}
		// Every flagged binding's derived target, resolved BEFORE any rename is emitted: two
		// bindings differing only in underscore count (`_a` / `__a`) strip to the same name, and
		// neither can see the other through `collidesInScope` - that scans the PRE-fix source,
		// where each occurrence still carries its own prefix. Renaming both would merge two
		// bindings into one, silently and compilably (Haxe permits the shadowing).
		final candidates: Array<Candidate> = [];
		for (decl in support.project(tree)) {
			final span: Null<Span> = decl.span;
			if (span == null || !flaggedFroms.contains(span.from)) continue;
			final target: Null<String> = strippedName(decl, policy, shape);
			if (target == null) continue;
			// Re-bind to a non-null final: strict null-safety does not narrow inside a struct literal.
			final name: String = target;
			candidates.push({ decl: decl, target: name, scope: Naming.innermostSpanOfKinds(tree, functionScopeKinds(shape), span.from) });
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (i in 0...candidates.length) {
			final c: Candidate = candidates[i];
			if (claimedByAnother(candidates, i)) continue;
			final rename: Null<Array<Span>> = renameSpansFor(
				c.decl, c.target, source, tree, shape, plugin, resolutionIndex, allowInheritedShadow
			);
			if (rename != null) for (occ in rename) edits.push({ span: occ, text: c.target });
		}
		return edits;
	}

	/**
	 * Whether another candidate claims the same target name from an OVERLAPPING scope, making
	 * both renames unsafe (see `fix`). Scopes overlap when either is unresolvable (fail-closed)
	 * or their spans intersect - a nested closure's scope lies inside its enclosing function's,
	 * so the two conflict; two disjoint bodies do not.
	 */
	private static function claimedByAnother(candidates: Array<Candidate>, index: Int): Bool {
		final own: Candidate = candidates[index];
		final mine: Null<Span> = own.scope;
		for (i in 0...candidates.length) if (i != index && candidates[i].target == own.target) {
			final other: Null<Span> = candidates[i].scope;
			if (other == null || mine == null) return true;
			if (mine.from < other.to && other.from < mine.to) return true;
		}
		return false;
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
		out: Array<Violation>, file: String, source: String, tree: QueryNode, decl: NamedDecl, shape: RefShape, options: Options
	): Void {
		final span: Null<Span> = decl.span;
		// `renameUnsafe` on a Param means the grammar projected an anon-STRUCTURE field, not a
		// parameter (`{ _name: String }`): its identifier is a wire contract, so it is neither a
		// finding of this rule nor renameable.
		if (span == null || decl.reservedName == true || decl.renameUnsafe == true) return;
		final isParam: Bool = decl.category == NamingCategory.Param;
		final inScope: Bool = isParam ? options.params : decl.category == NamingCategory.Local && options.locals;
		if (!inScope || !UNDERSCORE_PREFIX.match(decl.name)) return;
		if (isParam && options.silenceGuard && isUnreferenced(source, tree, decl.name, span, shape)) return;
		out.push({
			file: file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: 'underscore-prefixed ${isParam ? 'parameter' : 'local'} \'${decl.name}\''
		});
	}

	/**
	 * The spans to rewrite to `target` for one flagged binding, or null when a gate refuses the rename: `target` collides with something reachable from the binding's scope (`Naming.collidesInScope` - a sibling parameter, an overlapping local, an own member, a static, an import), it names a member INHERITED from a supertype, it names a declared top-level type, or the occurrence set cannot be proven complete (`Naming.declaringFileRenameSpans`). The same-target conflict between two flagged bindings is settled by the caller (`claimedByAnother`); the derived `target` itself comes from `strippedName`.
	 */
	private static function renameSpansFor(
		decl: NamedDecl, target: String, source: String, tree: QueryNode, shape: RefShape, plugin: GrammarPlugin,
		resolutionIndex: Null<SymbolIndex>, allowInheritedShadow: Bool
	): Null<Array<Span>> {
		final span: Null<Span> = decl.span;
		if (span == null) return null;
		if (Naming.collidesInScope(decl, source, tree, target, shape, resolutionIndex, plugin)) return null;
		if (collidesWithProjectSymbol(decl, target, resolutionIndex, allowInheritedShadow)) return null;
		return Naming.declaringFileRenameSpans(
			source, tree, span.from, decl.name, shape, plugin, Naming.isDistinctiveName(decl.name),
			interpolationReadSpans(tree, source, decl.name, span.from, shape)
		);
	}

	/**
	 * `decl`'s name with every leading underscore stripped, or null when the result must not be written: nothing was stripped, the remainder is not a valid identifier (`_1` -> `1`), it is a reserved word of the grammar (`_new` -> `new`), or it violates the applicable naming rule's format, which would trade this finding for a `naming` one. With no applicable rule (a project policy governing neither category) the bare strip stands - still keyword-checked, since that gate is the grammar's, not the policy's.
	 */
	private static function strippedName(decl: NamedDecl, policy: NamingPolicy, shape: RefShape): Null<String> {
		final name: String = decl.name;
		var i: Int = 0;
		while (i < name.length && StringTools.fastCodeAt(name, i) == '_'.code) i++;
		if (i == 0) return null;
		final stripped: String = name.substr(i);
		if (!RefactorSupport.isIdentifier(stripped)) return null;
		// Reserved words are a GRAMMAR fact, checked unconditionally: a policy cannot stand in
		// for it. One adapted from a project config carries no `normalize`, and every camelCase
		// format matches `dynamic` / `macro` / `new` exactly as it matches `event` - so gating the
		// keyword veto on the policy would emit source the parser rejects.
		final reserved: Array<String> = shape.reservedWords ?? [];
		if (reserved.contains(stripped)) return null;
		final rule: Null<NamingRule> = Naming.applicableRule(decl, policy);
		if (rule == null) return stripped;
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
	private static function collidesWithProjectSymbol(
		decl: NamedDecl, target: String, index: Null<SymbolIndex>, allowInheritedShadow: Bool
	): Bool {
		if (index == null) return false;
		final idx: SymbolIndex = index;
		if (idx.declaringFiles(target).length > 0) return true;
		// A local / parameter / catch variable LEGALLY shadows an inherited member, so this veto
		// is a STYLE stance, not a correctness gate — the correctness gate is `collidesInScope`,
		// which refuses when the enclosing function already reads that member through a bare
		// identifier the renamed binding would recapture. A UI codebase where nearly every type
		// inherits a display-object member (`x`, `y`, `width`) has the stance silence the rule
		// wholesale, so a project can cede it for exactly these three categories.
		final category: NamingCategory = decl.category;
		final shadowsBinding: Bool = category == NamingCategory.Local || category == NamingCategory.Param
			|| category == NamingCategory.CatchVar;
		if (allowInheritedShadow && shadowsBinding) return false;
		final owner: Null<String> = decl.enclosingType;
		return owner == null ? false : idx.supertypeDeclaresMember(owner, target);
	}

	/**
	 * The identifier-token spans of every simple `$name` string-interpolation read of the
	 * binding declared at `declFrom` — occurrences the reference walker does not index, so
	 * `Rename.renameOccurrences` misses them and the completeness gate would refuse the
	  * whole rename. Restricted to the binding's own innermost function, and returned EMPTY
	 * (leaving any such read uncovered, hence blocking) unless the file declares the name
	 * exactly ONCE: at zero the read binds to something the file does not declare (an
	 * inherited field), at two or more it cannot be attributed without re-implementing scope
	 * resolution. Both are refused rather than guessed.
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

	/** Every node kind that bounds a binding's visibility to one body: a function declaration, a local (or local inline) function, a lambda. */
	private static function functionScopeKinds(shape: RefShape): Array<String> {
		return (
			shape.functionKinds ?? []
		).concat(shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []).concat(shape.lambdaKinds ?? []);
	}

}

/**
 * The per-file option set of one `run`: whether parameters / locals are in scope, and
 * whether `unused-parameter`'s silencing `_<name>` rename is live (see the class doc).
 */
private typedef Options = {
	final params: Bool;
	final locals: Bool;
	final silenceGuard: Bool;
};

/**
 * One flagged binding whose derived target name passed `strippedName`: the declaration, that target, and the scope the target must be unique within. The set of these decides the same-target conflict between two flagged bindings before any rename is emitted.
 */
private typedef Candidate = {
	final decl: NamedDecl;
	final target: String;

	/** The binding's innermost enclosing function span, or null when none resolves (treated as conflicting with everything). */
	final scope: Null<Span>;
};
