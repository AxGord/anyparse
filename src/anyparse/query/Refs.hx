package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Scope.ScopeFrame;
import anyparse.query.Scope.ScopeStack;
import anyparse.runtime.Span;

/**
 * Lexical reference / declaration walker for `apq refs`.
 *
 * Walks a `QueryNode` tree and collects every node whose `name` slot
 * matches the target identifier. Each hit is classified per the
 * plugin's `RefShape`:
 *
 *  - `kind ∈ shape.declHostKinds` → `RefKind.Decl` (binding site).
 *  - `kind == shape.identKind`    → `RefKind.Read` (reference).
 *  - `kind == shape.stringInterpIdentKind` → `RefKind.Read` — a braceless
 *    `$name` inside an interpolating string literal, which binds to the
 *    enclosing scope by the same rules a bare identifier there would. Its
 *    span covers the `$` too, so the hit is marked `RefHit.interpolated`
 *    and a splicing consumer must locate the identifier token inside it —
 *    which an escape-spelled `$` or name denies, the one shape `rename`
 *    still refuses.
 *
 * Phase 3.2 scope: lexical scope tracking. The walker maintains a
 * `ScopeStack` and pushes a frame on every `kind ∈ shape.scopeKinds`
 * node; a frame's decl-host descendants are pre-collected on entry (the
 * walk stops at inner scope boundaries).
 *
 * Whether a pre-collected binding is visible to a reference EARLIER in the frame is the
 * frame's own policy. A type body hoists, so a method resolves a field declared below it. A
 * function body, a block or a `switch` arm (`RefShape.positionScopedKinds`) does not, so a
 * reference that precedes the declaration resolves past the frame — Haxe locals are not
 * hoisted. `ScopeBinding.visibleFrom` carries the offset each binding takes effect at.
 *
 * A TYPE annotation declares nothing, however much its ctors look like declarations: an
 * anonymous structure spells its field labels on the very ctors a parameter or a field uses,
 * so `RefShape.typeAnnotationKinds` gates them out of both the pre-collect and the hits.
 *
 * Each emitted hit carries a `bindingSpan` and the declaring node
 * behind it (`bindingNode`):
 *  - Decl hits self-bind (`bindingSpan == own span`).
 *  - Read / Write hits bind to the innermost in-file declaration with
 *    a matching name (null when unresolved — typically a cross-file or
 *    implicit-`this` reference).
 *
 * Phase 3.3 scope: Write classification via `RefShape.writeParentKinds`.
 * When a parent node's kind is in that set and the matching `identKind`
 * child sits at child-index 0 of the parent, the hit is emitted as
 * `Write` instead of `Read`. The flag does NOT propagate through
 * intermediate non-ident wrappers — only a direct `IdentExpr` child
 * of a write-parent ctor reclassifies. `arr[i] = v` and `obj.x = 1`
 * therefore keep `arr`/`obj` as Reads, which matches the semantic
 * intent of the `--writes` filter.
 *
 * Phase 3.2b-α scope: self-scoped declarations via
 * `RefShape.selfScopeDeclKinds`. A scope-introducer in that set binds
 * its own `name` into the frame it opens (not the enclosing one), so a
 * Haxe `for (i in xs) …` iterator is a `Decl` visible only inside the
 * loop body. Reads inside resolve to it via the innermost frame; reads
 * after the loop fall through to any enclosing binding.
 *
 * Phase 3.2b-β scope: catch-clause exception names and lambda-parameter
 * names. Their `@:spanned`-tagged grammar structs now surface as
 * addressable nodes, so a catch-clause exception is a self-scoped decl
 * (visible only inside the clause body) and a lambda parameter is a
 * decl-host bound into the enclosing lambda scope frame.
 *
 * Nodes carrying a null `span` are skipped — without source coordinates
 * the result is not addressable.
 */
@:nullSafety(Strict)
final class Refs {

	/**
	 * Walk `tree` and return every reference / declaration of `name` per
	 * `shape`. Hits are returned in pre-order traversal.
	 *
	 * When `shape.refsCache` is set (a run-scoped `RefsCache` attached by
	 * `CachingGrammarPlugin.refShape`), resolution goes through the cache's
	 * memoized full-tree index instead of a fresh walk — see `RefsCache` for
	 * the equivalence argument. A bare shape with no cache walks directly via
	 * `findMulti`, byte-identical to the pre-cache behavior.
	 */
	public static function find(name: String, tree: QueryNode, shape: RefShape): Array<RefHit> {
		final cache: Null<RefsCache> = shape.refsCache;
		return cache != null ? cache.find(name, tree, shape) : findMulti([name], tree, shape)[name] ?? [];
	}

	/**
	 * Multi-name variant of `find` — ONE tree walk resolving every name in
	 * `names` simultaneously (duplicates tolerated). The call-graph layer needs
	 * bindings for dozens of names per file; per-name `find` walks made that
	 * quadratic. The result map is pre-seeded, so every requested name has an
	 * entry and `exists()` doubles as the membership test during the walk.
	 */
	public static function findMulti(names: Array<String>, tree: QueryNode, shape: RefShape): Map<String, Array<RefHit>> {
		final out: Map<String, Array<RefHit>> = [];
		for (n in names) if (!out.exists(n)) out[n] = [];
		if (names.length == 0) return out;
		final scopes: ScopeStack = new ScopeStack();
		walkMulti(tree, shape, scopes, out, WalkFlags.None);
		return out;
	}

	/**
	 * `find`, plus how many occurrences of `name` the SAME walk declined to classify
	 * because they sit in a member-access slot (`isMemberAccess` — `Type.name`,
	 * `expr?.name`, `expr!.name`): the name there belongs to the receiver's TYPE, which a
	 * lexical walk cannot resolve. Counted at the exact point emission is declined, so the
	 * two numbers cannot drift apart — any access form the grammar gains is covered for
	 * free, and an occurrence inside a macro-reification block is excluded from the count
	 * exactly as it is from the hits. Lets a caller report what it did NOT look at instead
	 * of letting an empty result read as "unreferenced". Bypasses `shape.refsCache` (which
	 * memoizes hits only) — one direct walk yields both numbers.
	 */
	public static function findWithSkipped(name: String, tree: QueryNode, shape: RefShape): { hits: Array<RefHit>, skipped: Int } {
		final out: Map<String, Array<RefHit>> = [name => []];
		final skipped: Map<String, Int> = [name => 0];
		walkMulti(tree, shape, new ScopeStack(), out, WalkFlags.None, skipped);
		return { hits: out[name] ?? [], skipped: skipped[name] ?? 0 };
	}

	/**
	 * The offset from which a SELF-SCOPED binder's own name is in scope: the start of the BODY the
	 * construct opens, or `0` when `node` opens no such binding.
	 *
	 * The constructs are exactly the `selfScopeDeclKinds` ones — a `for`, a catch clause: they
	 * bind into the frame they open, so `visibleFrom` answers their own span start and would put
	 * the binding in scope across the header too. Measured against the compiler: `for (i in 0...i)`
	 * iterates over the OUTER `i`, and renaming that outer binding must therefore rewrite the
	 * `0...i` operand. A catch clause carries no expression in its header today, which is why it
	 * never showed the defect; the floor makes that safety structural instead of incidental.
	 *
	 * The body is the LAST child in all three projections (`ForStmt` / `ForExpr` / `CatchClause`) —
	 * the key-value binder and the iterable precede it.
	 *
	 * PUBLIC because `shadowing-local` decides from it whether a nested declaration hides the binder,
	 * and the resolver and that check must not disagree about where the binding starts. `0` is
	 * OVERLOADED — it means both "no such binding" and "from the very first byte" — so a caller
	 * comparing against it has to test the kind itself rather than read `0` as a refusal.
	 */
	public static function selfScopeBinderFloor(node: QueryNode, shape: RefShape): Int {
		if (!shape.selfScopeDeclKinds.contains(node.kind)) return 0;
		final children: Array<QueryNode> = node.children;
		if (children.length == 0) return 0;
		final body: Null<Span> = children[children.length - 1].span;
		return body == null ? 0 : body.from;
	}

	/**
	 * Whether `kind` is a member-access slot — `expr.name`, `expr?.name`, `expr!.name`.
	 * The name there denotes a member of the RECEIVER's type, so a lexical walk has
	 * nothing to bind it to; every one of these is an occurrence `find` cannot report.
	 */
	private static inline function isMemberAccess(kind: String, shape: RefShape): Bool {
		return kind == shape.fieldAccessKind || kind == shape.nullSafeAccessKind || kind == shape.forceFieldAccessKind;
	}

	/**
	 * The reference class of a node of `kind`, or null when the node is not one.
	 *
	 * `stringInterpIdentKind` classifies as a READ, never as a Write: the braceless
	 * `$name` shorthand inside an interpolating string literal binds to the enclosing
	 * scope exactly like a bare identifier at that position, and no assignment ctor can
	 * own it (its parent is always the string literal). Its span covers the bytes that
	 * SPELL the read — the `$` included — which is the same wide-span convention the
	 * self-scoped decl hosts already use, so a consumer splicing at a hit must locate the
	 * identifier token inside the span (`RefactorSupport.identTokenOffset`) rather than
	 * assume the span IS the name. A `${ … }` hole needs nothing here: the parser gives
	 * its interior a real expression subtree, whose identifiers are ordinary `identKind`
	 * reads already.
	 */
	private static inline function classify(kind: String, shape: RefShape, flags: WalkFlags): Null<RefKind> {
		// Decl-host takes precedence over identKind: a single grammar
		// would normally place the decl name on a different ctor than
		// the reference ctor, but the contract leaves the option open.
		return if (shape.declHostKinds.contains(kind) || shape.selfScopeDeclKinds.contains(kind))
			// Inside a type annotation the SAME ctor spells a structural field LABEL, which
			// binds no value — see the `Refs` seam on `RefShape.typeAnnotationKinds`.
			flags.has(WalkFlags.InTypeAnnotation) ? null : RefKind.Decl
		else if (kind == shape.identKind)
			flags.has(WalkFlags.WriteTarget) ? RefKind.Write : RefKind.Read
		else if (isInterpRead(kind, shape))
			RefKind.Read
		else
			null;
	}

	/**
	 * Whether a node of `kind` is a braceless string-interpolation read. Stated ONCE
	 * because two places ask: `classify`, and the emission site that stamps
	 * `RefHit.interpolated`. The `identKind` exclusion keeps them from disagreeing in a
	 * grammar that declares the two seams equal — `classify` would take the identifier
	 * arm there, so the flag must not be set.
	 */
	private static inline function isInterpRead(kind: String, shape: RefShape): Bool {
		return kind == shape.stringInterpIdentKind && kind != shape.identKind;
	}

	/**
	 * Whether a node of `kind` opens a TYPE annotation — a subtree that declares no value
	 * binding, however much its ctors look like declarations. See the `Refs` seam on
	 * `RefShape.typeAnnotationKinds`.
	 */
	private static inline function isTypeAnnotation(kind: String, shape: RefShape): Bool {
		final kinds: Null<Array<String>> = shape.typeAnnotationKinds;
		return kinds != null && kinds.contains(kind);
	}


	private static function walkMulti(
		node: QueryNode, shape: RefShape, scopes: ScopeStack, out: Map<String, Array<RefHit>>, flags: WalkFlags, ?skipped: Map<String, Int>
	): Void {
		// Inside a macro-reification subtree a plain identifier is a runtime emit spliced into
		// generated code — NOT a reference to the enclosing scope — and a reified `var` is not a
		// real binding, so this context suppresses scope handling and ref emission alike. Where the
		// context begins and ends is `childContext`'s answer.
		final macroEmit: Bool = flags.has(WalkFlags.MacroEmit);
		final frame: Null<ScopeFrame> = frameFor(node, shape, macroEmit, out, scopes);
		if (frame != null) scopes.push(frame);
		if (!macroEmit) {
			final nname: Null<String> = node.name;
			if (nname != null) {
				final hits: Null<Array<RefHit>> = out[nname];
				if (hits != null) {
					final span: Null<Span> = node.span;
					if (span != null) {
						final kind: Null<RefKind> = classify(node.kind, shape, flags);
						if (kind != null) {
							// Re-bind: a narrowed local does not reach an anonymous-structure literal.
							final at: Span = span;
							final binding: Null<RefBinding> = kind == RefKind.Decl
								? ({ node: node, span: at }: RefBinding)
								: scopes.resolveInnermost(nname, at.from);
							hits.push(new RefHit(kind, nname, at, binding, isInterpRead(node.kind, shape)));
						} else if (skipped != null && isMemberAccess(node.kind, shape))
							skipped[nname] = (skipped[nname] ?? 0) + 1;
					}
				}
			}
		}
		final isWriteParent: Bool = shape.writeParentKinds.contains(node.kind);
		final childFlags: WalkFlags = childContext(node, shape, flags);
		final children: Array<QueryNode> = node.children;
		for (i in 0...children.length)
			walkMulti(children[i], shape, scopes, out, childFlags.with(WalkFlags.WriteTarget, isWriteParent && i == 0), skipped);
		if (frame != null) scopes.pop();
	}

	/**
	 * The context every child of `node` inherits, given the context `node` itself was walked in.
	 *
	 * `MacroEmit` enters at a reification (`opaqueKinds`, e.g. `macro { … }`), where a plain
	 * identifier is a runtime emit spliced into generated code rather than a reference to the
	 * enclosing scope; only a macro interpolation (`interpolationKinds`: `${…}` / `$v{…}`) re-opens
	 * normal resolution for its own subtree.
	 *
	 * `InTypeAnnotation` enters at a type annotation and never leaves it — the interior stays
	 * READABLE (a metadata argument there is a real reference), but nothing in it DECLARES.
	 */
	private static function childContext(node: QueryNode, shape: RefShape, flags: WalkFlags): WalkFlags {
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final interpolationKinds: Array<String> = shape.interpolationKinds ?? [];
		final macroEmit: Bool = opaqueKinds.contains(node.kind)
			|| (!interpolationKinds.contains(node.kind) && flags.has(WalkFlags.MacroEmit));
		final inTypeAnnotation: Bool = flags.has(WalkFlags.InTypeAnnotation) || isTypeAnnotation(node.kind, shape);
		return flags.with(WalkFlags.MacroEmit, macroEmit).with(WalkFlags.InTypeAnnotation, inTypeAnnotation);
	}

	/**
	 * The scope frame `node` opens, primed with the declarations it binds, or null when it opens none. Three kinds open one:
	 *
	 * - a grammar `scopeKinds` node — a real lexical scope, which also binds its OWN name when it is a
	 *   `selfScopeDeclKinds` host (a `for` iterator, a catch-clause exception);
	 * - a grammar `branchScopeKinds` node — a `switch` arm. A real lexical scope too, but not a
	 *   declaration container any check reasons about, hence its own vocabulary; `collectIntoMulti`
	 *   stops there as well, so the enclosing frame does not adopt the arm's locals. Contrast the
	 *   `CondBranch` case below: an arm's local genuinely dies at the arm's end;
	 * - the branch-aware projection's synthetic `CondBranch`. That one is NOT a lexical scope — a
	 *   declaration written inside `#if` stays visible after `#end`, and the enclosing frame's
	 *   pre-collect already holds it — but a resolution PREFERENCE: a reference inside a branch binds
	 *   to that branch's own declaration before any same-name declaration of a MUTUALLY EXCLUSIVE
	 *   sibling branch. Without the frame the enclosing block's first-wins rule binds EVERY branch's
	 *   reads to the FIRST branch's declaration, so a name declared in two sibling branches reads as
	 *   twice-referenced in one branch and unreferenced in the other.
	 *
	 * The preference is exact INSIDE a region only: a reference past `#end` still resolves through the
	 * enclosing frame, i.e. to the first branch's declaration, while the compiler resolves it to
	 * whichever branch is active. A consumer that reasons about a branch declaration's reference COUNT
	 * must handle that itself (`CheckScan.escapesConditionalRegion`).
	 *
	 * Only the branch-aware projection carries the kind, so a plain parse frames byte-identically to
	 * before.
	 */
	private static function frameFor(
		node: QueryNode, shape: RefShape, macroEmit: Bool, out: Map<String, Array<RefHit>>, scopes: ScopeStack
	): Null<ScopeFrame> {
		if (macroEmit) return null;
		final isScope: Bool = shape.scopeKinds.contains(node.kind);
		// A switch ARM frames its own body (`branchScopeKinds`): a local declared there dies at the
		// arm's end. `collectIntoMulti` stops at the same kinds so the enclosing frame does not adopt
		// it — the two halves together are what confine an arm's binding. (An enum-PATTERN binding is
		// not a declaration to this walker at all; it projects as a plain identifier read.)
		final branchKinds: Null<Array<String>> = shape.branchScopeKinds;
		final isBranchScope: Bool = branchKinds != null && branchKinds.contains(node.kind);
		final isCondBranch: Bool = node.kind == CondBranchProjection.COND_BRANCH_KIND;
		if (!isScope && !isBranchScope && !isCondBranch) return null;
		// A `CondBranch` overlays the frame it sits in rather than containing anything, so it borrows
		// that frame's visibility policy — see `ScopeStack.currentPositionScoped`.
		final posKinds: Null<Array<String>> = shape.positionScopedKinds;
		final positionScoped: Bool = isCondBranch ? scopes.currentPositionScoped() : posKinds != null && posKinds.contains(node.kind);
		final frame: ScopeFrame = new ScopeFrame(node, positionScoped, headerFloor(node, shape, positionScoped));
		collectDeclsMulti(node, shape, frame, out);
		final selfSpan: Null<Span> = node.span;
		final selfName: Null<String> = node.name;
		if (isScope && selfSpan != null && selfName != null && out.exists(selfName) && shape.selfScopeDeclKinds.contains(node.kind))
			frame.declare(selfName, node, selfSpan, visibleFrom(node, selfSpan, shape, positionScoped));
		return frame;
	}

	/**
	 * `ScopeFrame.visibleFloor` for the frame `node` opens — `selfScopeBinderFloor` for a
	 * position-scoped frame, else `0`. A HOISTING frame puts its declarations in scope across its
	 * whole span by definition, so it has no floor to answer.
	 */
	private static function headerFloor(node: QueryNode, shape: RefShape, positionScoped: Bool): Int {
		return positionScoped ? selfScopeBinderFloor(node, shape) : 0;
	}

	private static function collectDeclsMulti(
		scopeNode: QueryNode, shape: RefShape, frame: ScopeFrame, out: Map<String, Array<RefHit>>
	): Void {
		for (c in scopeNode.children) collectIntoMulti(c, shape, frame, out);
	}

	private static function collectIntoMulti(node: QueryNode, shape: RefShape, frame: ScopeFrame, out: Map<String, Array<RefHit>>): Void {
		// A TYPE annotation binds nothing, however much its ctors look like declarations — an
		// anonymous structure spells its field labels on the parameter / field ctors. Without this
		// stop a field's `{p:Int}` declares `p` into the CLASS frame, shadowing the real member for
		// every method of the type. See the `Refs` seam on `RefShape.typeAnnotationKinds`.
		if (isTypeAnnotation(node.kind, shape)) return;
		// A switch arm's declarations belong to ITS frame, not this one — stop, exactly as at a
		// nested scope. `CondBranch` is deliberately absent: a `#if` branch's declaration stays
		// visible past `#end`, so the enclosing frame must still adopt it.
		final branchKinds: Null<Array<String>> = shape.branchScopeKinds;
		if (shape.scopeKinds.contains(node.kind) || (branchKinds != null && branchKinds.contains(node.kind))) {
			declareIfHost(node, shape, frame, out);
			return;
		}
		declareIfHost(node, shape, frame, out);
		for (c in node.children) collectIntoMulti(c, shape, frame, out);
	}

	/**
	 * Bind `node`'s own name into `frame` when it hosts a declaration of one of the searched
	 * names, at the offset from which the frame lets a reference see it.
	 */
	private static function declareIfHost(node: QueryNode, shape: RefShape, frame: ScopeFrame, out: Map<String, Array<RefHit>>): Void {
		final name: Null<String> = node.name;
		if (name == null || !out.exists(name) || !shape.declHostKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		if (span != null) frame.declare(name, node, span, visibleFrom(node, span, shape, frame.positionScoped));
	}

	/**
	 * The source offset from which a reference resolves to `node`'s binding within the frame it
	 * is declared in.
	 *
	 * A hoisting frame answers `0`: every reference in a type body sees every member of it,
	 * which is what lets a method read a field declared further down.
	 *
	 * A position-scoped frame answers where the binding takes effect, and that is NOT simply the
	 * declaration's start:
	 *
	 * - a declaration that opens a scope of its OWN — a local `function`, a nested type — is
	 *   visible from its start, because the scope it opens lies inside its span and the binding
	 *   must be reachable there: a local function recurses;
	 * - any other declaration is visible only past its own end, so its initializer still reads
	 *   the enclosing binding of the same name (`var x = x;` binds the outer `x` — measured
	 *   against the compiler, not assumed);
	 * - except that a multi-binding list (`var a = 1, b = a;`) carries its later bindings as
	 *   CONTINUATION children inside the first one's span, and those do see it. The answer is
	 *   then the first continuation child's start, which is past the first initializer and
	 *   before every later one.
	 */
	private static function visibleFrom(node: QueryNode, span: Span, shape: RefShape, positionScoped: Bool): Int {
		if (!positionScoped) return 0;
		if (shape.scopeKinds.contains(node.kind)) return span.from;
		final continuationKinds: Null<Array<String>> = shape.localDeclContinuationKinds;
		if (continuationKinds != null) for (c in node.children) if (continuationKinds.contains(c.kind)) {
			final continuationSpan: Null<Span> = c.span;
			if (continuationSpan != null) return continuationSpan.from;
		}
		return span.to;
	}

}

/**
 * The context `Refs.walkMulti` carries down the tree, as one bit set.
 *
 * Three independent booleans that all propagate to children and are all `Bool`. As three adjacent positional parameters a transposition at the call site compiles clean and silently
 * mis-walks the whole tree; as one value it is unrepresentable. The abstract IS an `Int`, so
 * the walker's hottest signature gets cheaper rather than dearer.
 */
enum abstract WalkFlags(Int) from Int to Int {

	/** Nothing set — the walk's entry state. */
	final None = 0;

	/** The node sits at child-index 0 of a `RefShape.writeParentKinds` ctor: an assignment target. */
	final WriteTarget = 1;

	/** Inside a `RefShape.opaqueKinds` reification, where an identifier is emitted code, not a reference. */
	final MacroEmit = 2;

	/** Inside a `RefShape.typeAnnotationKinds` subtree, where a decl-host ctor spells a field LABEL. */
	final InTypeAnnotation = 4;

	public inline function has(flag: WalkFlags): Bool {
		return this & (flag: Int) != 0;
	}

	public inline function with(flag: WalkFlags, on: Bool): WalkFlags {
		return on ? this | (flag: Int) : this & ~(flag: Int);
	}

}

/**
 * One classified reference site discovered by `Refs.find`.
 *
 * `name` is redundant with the search target (the walker only emits
 * matching nodes) but is kept on the hit so downstream renderers can
 * be driven by the hit alone without threading the target separately.
 *
 * `bindingSpan` is the span of the declaration this hit resolves to, and
 * `bindingNode` that declaration's own node:
 *  - Decl hits self-bind (`bindingSpan == span`, `bindingNode` the hit's
 *    own node).
 *  - Read / Write hits point to the innermost enclosing decl with a
 *    matching name, or null when unresolved (cross-file / implicit-
 *    `this` / grammar-gap on the binding's decl site).
 */
@:nullSafety(Strict)
final class RefHit {

	public final kind: RefKind;
	public final name: String;
	public final span: Span;
	public final bindingSpan: Null<Span>;

	/**
	 * The node that DECLARES `bindingSpan` — the very node the resolving `ScopeFrame` bound the
	 * name from. `bindingSpan` says WHERE the declaration is; this says WHAT it is, without a
	 * consumer re-finding it by span arithmetic (which answers for the outermost declaration
	 * covering the offset, not for the one that actually binds).
	 *
	 * Null exactly when `bindingSpan` is, and structurally so rather than by convention: the two
	 * arrive as ONE optional `RefBinding`, so neither can be supplied without the other.
	 */
	public final bindingNode: Null<QueryNode>;

	/**
	 * Whether the occurrence is a braceless `$name` inside an interpolating string literal
	 * rather than an ordinary identifier.
	 *
	 * A rename-class rewrite needs no special case for the ORDINARY spelling — the identifier
	 * token sits inside the span and `RefactorSupport.identTokenOffset` finds it. An
	 * escape-spelled `$` or name (`'\x24p'`) puts no locatable token there, and that one is
	 * refused (`Rename.uncoveredInterpRead`).
	 *
	 * A rewrite substituting a NON-identifier — an inlined expression, an `obj.` qualification,
	 * an accessor call — must refuse or brace every one of them: `$` binds to a bare identifier
	 * only, so `$obj.p` reads `obj` and then the literal text `.p`.
	 */
	public final interpolated: Bool;

	public function new(kind: RefKind, name: String, span: Span, ?binding: RefBinding, interpolated: Bool = false) {
		this.kind = kind;
		this.name = name;
		this.span = span;
		bindingSpan = binding?.span;
		bindingNode = binding?.node;
		this.interpolated = interpolated;
	}

}

/**
 * The declaration a `RefHit` resolves to: the node that spells it and that node's span, as one
 * value. Passing the pair as a single optional constructor argument is what makes `RefHit`'s
 * "both or neither" contract structural instead of prose — the shape a `ScopeFrame` binding
 * already has, so the resolver hands its own record straight over.
 */
typedef RefBinding = {
	final node: QueryNode;
	final span: Span;
};

/**
 * Reference classification per `docs/cli-query-tool.md` JSON schema.
 *
 * Phase 3.3 emits all three variants. `Write` covers any `identKind`
 * that sits at child-index 0 of a `RefShape.writeParentKinds` ctor —
 * see the walker docstring for the propagation rule.
 */
enum abstract RefKind(Int) {

	final Decl = 0;
	final Read = 1;
	final Write = 2;

	public function toString(): String {
		return switch (cast this: RefKind) {
			case Decl: 'decl';
			case Read: 'read';
			case Write: 'write';
		}
	}

}
