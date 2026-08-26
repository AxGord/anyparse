package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.query.GrammarPlugin;
import anyparse.query.ModuleScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Per-file scan seams for `UnusedLocal`: the grammar-derived kind sets the walk and
 * the shadowed-region model read, plus the file coordinates and the reporting sink.
 * Built once per analyzed file so the recursive walk threads one value rather than
 * six positional arguments.
 *
 * `localDeclContinuationKinds` is `RefShape.localDeclContinuationKinds` — the next-link kinds of
 * a multi-declarator chain, which `bindsOwnValue` subtracts to tell an initializer from the
 * declarator that follows it.
 *
 * `conditionalIfKeyword` is `RefShape.conditionalIfKeyword`, and the conditional gates
 * test the DIRECTIVE that opens a region (`ModuleScan.opensConditionalRegion`) rather
 * than a node kind: the grammar projects a statement-position `#if` and an
 * expression-position one under different kinds, so a kind test covers only whichever
 * position it happens to name.
 */
private typedef ScanCtx = {
	var out: Array<Violation>;
	var file: String;
	var source: String;
	var scopeKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var localDeclContinuationKinds: Array<String>;
	var selfScopeDeclKinds: Array<String>;
	var valueBinderKinds: Array<String>;
	var conditionalIfKeyword: Null<String>;
}

/**
 * Flags local `var` / `final` declarations whose bound name is never
 * referenced within its lexical scope — dead bindings the formatter cannot
 * remove. Statement-position locals only (`VarStmt` / `FinalStmt`); function
 * parameters, `for` iterators, `catch` variables, class fields and top-level
 * declarations are deliberately out of scope (an unused parameter is usually
 * a signature constraint, not dead code).
 *
 * ## Why a raw scope-bounded text scan
 *
 * A local is visible only from its declaration to the end of the enclosing
 * scope, so its entire visibility region lies inside that scope node's source
 * span. The "is it referenced" test is therefore a raw word-boundary scan of
 * the enclosing scope's source, OUTSIDE the declaration itself
 * (`RefactorSupport.referencedInRange`) — the same conservative approach
 * `unused-import` uses, for the same reason: an AST projection misses
 * reference forms the resolution index does not bind — a read inside a
 * rescanned, escape-spelled `${ … }` hole (which carries no parsed
 * expression at all), a cross-file or implicit-`this` reference, an
 * identifier the grammar surfaces under a ctor the walker does not match.
 * (The braceless simple-interpolation read
 * `'$name'` IS indexed as a read — that one is no longer a
 * reason to prefer the scan.) A textual scan catches every reference the
 * compiler can see, at the cost of also counting the name inside comments /
 * strings / a sibling nested scope that re-declares it — which only ever
 * yields a missed finding (a kept binding), never a wrong deletion. Bounding
 * the scan to the enclosing scope (not the whole file) is what stops a
 * same-named local in a different function from masking this one.
 *
 * ## Occurrences a shadowing binding owns
 *
 * That scan also counts occurrences that CANNOT be a reference to this binding, because another
 * binding owns the region they sit in. Two forms, and the second is the one a NAME-counting scan
 * is blindest to:
 *
 * - an inner construct re-binds the name over its own region — the AS3-heritage `var item;
 *   for (item in xs) use(item);`, where the `for` iterator is a fresh binding scoped to the loop
 *   and the outer declaration is dead in every compile;
 * - the SAME statement list declares the name again. That is legal, and since `6c1dc26b` the
 *   resolver reads it the way the compiler does: the second declaration is a second BINDING, in
 *   effect from its own position on, so `var a = 1; var a = 2; return a;` leaves the first dead
 *   while the name still appears below. Only the re-declaration's BINDER TOKEN and everything
 *   past its end are excluded, never its initializer — `var a = a + 1` reads the FIRST binding in
 *   the second declaration's own right-hand side, and cutting the whole declaration would flag a
 *   live one. DIRECT children of the scope only: a declaration in a nested block, a `switch` arm
 *   or a conditional-compilation arm is scoped to what encloses it and takes nothing over — which
 *   is how the last of those reaches the same refusal `RefactorSupport.exclusiveBranchRedeclaration`
 *   makes for `rename` / `extract-method`, without a second model of it.
 *
 * A scan that reports a reference is therefore run a SECOND time with those regions excluded as
 * well, and the declaration is flagged only when nothing textual survives outside them. The
 * self-scoped half of them comes from the grammar's own declarations (`RefShape.selfScopeDeclKinds`
 * — the `for` iterator in both its statement and comprehension positions, the
 * `catch` exception), never from a second resolver: each contributes its binder
 * token and its body, and only when the construct's shape is verified (see
 * `appendShadowedRegion`). The head is NOT covered — a `for` loop's iterated
 * expression is evaluated in the enclosing scope, so `for (item in item)` reads
 * the outer `item`, which keeps the declaration live. Everything else the scan
 * still counts: a mention in a comment, a string, an interpolation or a nested
 * re-declaration outside those regions keeps the binding exactly as
 * conservatively as before.
 *
 * Conditional compilation suspends the SELF-SCOPED half on both sides — a declaration inside a
 * `#if` region, or a shadowing loop inside one — since the region's branches project as flat
 * siblings and no state of that tree is the source a single compile sees. Both gates test the
 * opening DIRECTIVE (`ModuleScan.opensConditionalRegion`), not a node kind: statement- and
 * expression-position regions project under different kinds, and a refusal naming one of them
 * silently covers only that position.
 *
 * The re-declaration half is NOT suspended, and the asymmetry is deliberate. A re-declaration
 * that is a direct child of the block exists in EVERY configuration, so a first declaration
 * guarded by `#if` is dead in the configuration that has it and absent in the rest — dead either
 * way. That is the same reasoning `RefactorSupport.exclusiveBranchRedeclaration` records for the
 * mirror shape ("a sibling declaration AFTER the region is safe: it is in effect in every
 * configuration from its own position on"). Verified by building the `--fix` output of a
 * guarded declaration under both configurations. The reverse — a re-declaration ON an arm — is
 * refused, by the direct-child rule rather than by this gate.
 *
 * ## Reification is opaque
 *
 * Inside a metaprogramming-reification subtree (the plugin's `opaqueKinds` —
 * Haxe `macro { … }`), a binding's uses can be injected by splicing rather
 * than written literally, so a source scan cannot see them. Declarations
 * inside such a subtree are skipped entirely: flagging one would be a false
 * positive, and the autofix would then delete a live binding. This is the one
 * structural concession the text scan makes, and it is plugin-declared so the
 * check stays grammar-agnostic.
 *
 * ## Autofix
 *
 * A flagged local is by construction wholly unreferenced, so the only
 * deletion hazard is a side-effecting initializer (`final x = compute();`).
 * `fix` deletes the declaration line only when it has no initializer or a
 * side-effect-free one, or (with a symbol index) a type-aware deletion-pure expression — a plain field read, a pure array literal, or a provably-pure stdlib static call (`TypeResolver.isDeletionPure`); a side-effecting
 * initializer is reported but left for the author to resolve.
 */
@:nullSafety(Strict)
final class UnusedLocal implements Check implements VolatileMessage {

	/**
	 * The fragment that precedes the RE-DECLARATION's position in the message — shared by
	 * `redeclarationNote` and by `messageIdentity`, so the anchor cannot drift away from the
	 * wording it points at.
	 */
	private static inline final REDECLARED_AT: String = ' — re-declared at ';

	public function new() {}

	public function id(): String {
		return 'unused-local';
	}

	public function description(): String {
		return 'local var/final declared but never referenced in its scope';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final ctx: ScanCtx = {
				out: violations,
				file: entry.file,
				source: entry.source,
				scopeKinds: shape.scopeKinds,
				opaqueKinds: shape.opaqueKinds ?? [],
				localDeclKinds: shape.localDeclKinds ?? [],
				localDeclContinuationKinds: shape.localDeclContinuationKinds ?? [],
				selfScopeDeclKinds: shape.selfScopeDeclKinds,
				valueBinderKinds: shape.iterationValueBinderKinds ?? [],
				conditionalIfKeyword: shape.conditionalIfKeyword
			};
			walk(ctx, tree, null);
		}
		return violations;
	}

	/**
	 * Delete each fixable unused-local declaration. A flagged local is wholly
	 * unreferenced, so the deletion is safe whenever the initializer carries
	 * no side effect (or is absent). The declaration's whole physical line is
	 * removed (`lineExtendedSpan`) so the batched `canonicalize` leaves no
	 * blank residue; a side-effecting initializer is skipped (no edit).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return edits;

		final shape: RefShape = plugin.refShape();
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final continuationKinds: Array<String> = shape.localDeclContinuationKinds ?? [];
		final declByFrom: Map<Int, QueryNode> = [];
		collectLocalDecls(tree, declByFrom, opaqueKinds, localDeclKinds);

		// Type-aware purity allow-path: with a symbol index and declared types,
		// `TypeResolver.isDeletionPure` widens the plain `isSideEffectFree` set — a
		// plain (non-getter) field read, an array literal of pure elements, and a
		// provably-pure stdlib static call all become safe to discard. Without an
		// index it falls back to the conservative base predicate. A side-effecting
		// or unprovable initializer is reported but left in place for the author.
		final treeRoot: QueryNode = tree;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];

		for (v in violations) if (v.severity == Severity.Warning) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final decl: Null<QueryNode> = declByFrom[span.from];
			if (decl == null) continue;
			final init: Null<QueryNode> = decl.children.length > 0 ? decl.children[0] : null;
			final deletable: Bool = init == null || (
				index != null
					? TypeResolver.isDeletionPure(init, treeRoot, shape, declaredTypes, index)
					: RefactorSupport.isSideEffectFree(init)
			);
			if (!deletable) continue;
			// A binding that SHARES its line with another one is reported but never cut: the deletion
			// below takes the whole LINE. That is both a continuation (`b` in `var a = 1, b = 2;`) and
			// a head that still carries one — deleting `a` there dropped the live `b` with it and left
			// the code uncompilable. Removing a single binding is a different edit per position — a
			// middle one is its span MINUS the continuation nested inside it (the chain is
			// right-recursive), and a head needs its first continuation promoted into its place — so it
			// is refused rather than approximated.
			if (continuationKinds.contains(decl.kind) || decl.children.exists(k -> continuationKinds.contains(k.kind))) continue;
			edits.push({ span: RefactorSupport.lineExtendedSpan(source, span), text: '' });
		}
		return edits;
	}

	/**
	 * The RE-DECLARATION's position is masked; the local's NAME is not.
	 *
	 * The note names where the second binding starts, so any edit above it renames the
	 * finding while nothing about the finding changed. The mask is anchored on the note's own
	 * lead-in rather than run over every digit in the message, which is what `lint-diff` did
	 * before: a blanket mask also collapsed `v1` and `v2` onto one key, so a rename between
	 * two digit-suffixed locals passed the gate as no movement at all.
	 */
	public function messageIdentity(message: String): String {
		return MessageMask.maskAfter(message, REDECLARED_AT);
	}

	/**
	 * Walk `node`, tracking the innermost enclosing scope, and append a
	 * `Warning` for every unreferenced local declaration. A subtree whose root
	 * kind is in `opaqueKinds` (macro reification) is skipped wholesale — its
	 * bindings' uses may be splice-injected and invisible to a source scan. A
	 * scope-introducing node (`scopeKinds`) becomes the enclosing scope of its
	 * descendants; a local declaration is tested against the scope it was
	 * passed (its parent scope), never one it might open itself.
	 */
	private static function walk(ctx: ScanCtx, node: QueryNode, enclosingScope: Null<QueryNode>): Void {
		if (ctx.opaqueKinds.contains(node.kind)) return;
		if (ctx.localDeclKinds.contains(node.kind)) checkDecl(ctx, node, enclosingScope);
		final childScope: Null<QueryNode> = ctx.scopeKinds.contains(node.kind) ? node : enclosingScope;
		for (c in node.children) walk(ctx, c, childScope);
	}

	/**
		 * Append a `Warning` if the local `decl` is unreferenced in `enclosingScope`.
		 * Bails (no finding) when any coordinate the test needs is missing — a null
		 * name, declaration span, or scope span — so an unspanned node is never
		 * flagged.
		 *
		 * A scan that DOES find a reference is re-run once with the regions an inner
		 * self-scoped binding of the same name owns excluded as well
		 * (`shadowedRegions`), and by a RE-DECLARATION of it in the same statement
		 * list (`sameScopeRedeclaration`): every occurrence of `var item; for (item in
		 * xs) use(item);` belongs to the loop, and every read past the second
		 * `var a` belongs to the second binding. The two feed ONE exclusion set, and
		 * the second scan is the same predicate over it, so the refinement can only
		 * turn a silence into a finding, never a finding into a silence — measured over Pony (867 files),
	anyparse `src test` (1471), the Haxe std (2625) and ~/dev/haxelib (16 744): 21 findings added
	in total, none removed anywhere.
		 *
		 * A re-declaration also puts its own position in the message. The name IS
		 * visible below the finding there, so a bare "unused local" reads as wrong.
	 */
	private static function checkDecl(ctx: ScanCtx, decl: QueryNode, enclosingScope: Null<QueryNode>): Void {
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null || enclosingScope == null) return;
		final scopeSpan: Null<Span> = enclosingScope.span;
		if (scopeSpan == null) return;
		final excluded: Array<Span> = [declSpan];
		var note: String = '';
		if (RefactorSupport.referencedInRange(ctx.source, name, scopeSpan.from, scopeSpan.to, excluded)) {
			final shadowed: Array<Span> = shadowedRegions(ctx, enclosingScope, name, declSpan);
			// An INITIALIZER-LESS declaration carries no value of its own, so "its value is never
			// read" is not what makes it dead — a WRITE does, and a build macro that rewrites the
			// whole statement list can supply one. Pony's `@:async` methods pre-declare `var err;
			// var _;` ahead of an `@await`, and `com.dongxiguo.continuation` turns each bare
			// declaration into a continuation step: probed on that shape, the compiler reports
			// `(_ : Unknown<1>) -> Void should be () -> Unknown<0>` AT the bare declaration, so the
			// macro binds it, and deleting one is a silent CPS change no gate here would catch. The
			// loop form needs no such guard — its shadowing binding is the language's own `for` /
			// `catch` binder, which no statement-list rewrite moves.
			final redecl: Null<QueryNode> = bindsOwnValue(ctx, decl) ? sameScopeRedeclaration(ctx, enclosingScope, name, declSpan) : null;
			var claimed: Null<QueryNode> = null;
			if (redecl != null && appendRedeclaredRegion(ctx, redecl, name, scopeSpan, shadowed)) claimed = redecl;
			if (shadowed.length == 0) return;
			for (region in shadowed) excluded.push(region);
			if (RefactorSupport.referencedInRange(ctx.source, name, scopeSpan.from, scopeSpan.to, excluded)) return;
			if (claimed != null) note = redeclarationNote(ctx, claimed);
		}
		ctx.out.push({
			file: ctx.file,
			span: declSpan,
			rule: 'unused-local',
			severity: Severity.Warning,
			message: 'unused local \'$name\'$note'
		});
	}

	/**
	 * The regions of `scope` in which an occurrence of `name` belongs to an INNER binding rather than
	 * to the declaration at `declSpan` — one self-scoped declaration of the same name
	 * (`RefShape.selfScopeDeclKinds`: the `for` iterator, the `catch` exception) per pair of spans, its
	 * binder token and its body.
	 *
	 * Empty when the grammar declares no self-scoped kind, when the declaration itself sits inside a
	 * conditional-compilation region, or when no construct passes the shape check. Empty is no longer
	 * the same as "the declaration stays silent": `checkDecl` appends the RE-DECLARATION regions to
	 * this same array afterwards, and that half is deliberately not suspended inside a `#if` region
	 * (see the class doc).
	 */
	private static function shadowedRegions(ctx: ScanCtx, scope: QueryNode, name: String, declSpan: Span): Array<Span> {
		final out: Array<Span> = [];
		if (ctx.selfScopeDeclKinds.length == 0 || withinConditional(ctx, scope, declSpan.from)) return out;
		collectShadowedRegions(ctx, scope, name, out);
		return out;
	}

	/**
	 * Whether `decl` binds a VALUE of its own — whether it has a child that is not the next link of
	 * a multi-declarator chain.
	 *
	 * The chain is right-recursive, so a middle declarator's only child is the declarator AFTER it:
	 * `children.length > 0` reads `var a, i, j;` as though `i` had an initializer, which is exactly
	 * the shape this test exists to reject.
	 */
	private static function bindsOwnValue(ctx: ScanCtx, decl: QueryNode): Bool {
		return decl.children.exists(c -> !ctx.localDeclContinuationKinds.contains(c.kind));
	}

	/**
	 * The RE-DECLARATION of `name` in `scope`'s own statement list that takes the binding over from
	 * the declaration at `declSpan` — the first later DIRECT child of `scope` that declares the same
	 * name — or null when there is none.
	 *
	 * Declaring a name twice in one statement list is legal, and since `6c1dc26b` the resolver reads
	 * it the way the compiler does: the second declaration is a SECOND BINDING, in effect from its
	 * own position on, so every read past it belongs to it and the first can be dead while the name
	 * still appears below. That is invisible to a scan that counts the NAME, which is why
	 * `var a = 1; var a = 2; return a;` reported nothing.
	 *
	 * DIRECT children only, and that is the whole safety argument. A declaration one level down is
	 * scoped to what encloses it and takes nothing over: a nested block, a switch arm and a
	 * brace-less `if` body each bind only within themselves, and `topLevelDeclaredName`'s descent
	 * through single-child wrappers — right for a predicate whose conservative direction is REFUSAL —
	 * would claim them here, where the conservative direction is silence. A conditional-compilation
	 * arm is excluded by the same rule for a stronger reason: its declarations are children of the
	 * region, not of the block, so a name declared there is never seen as taking over — which is
	 * exactly the refusal `RefactorSupport.exclusiveBranchRedeclaration` makes for the mutation ops,
	 * reached here without a second model of it.
	 */
	private static function sameScopeRedeclaration(ctx: ScanCtx, scope: QueryNode, name: String, declSpan: Span): Null<QueryNode> {
		for (c in scope.children) {
			final span: Null<Span> = c.span;
			if (span != null && span.from > declSpan.from && c.name == name && ctx.localDeclKinds.contains(c.kind)) return c;
		}
		return null;
	}

	/**
	 * Append the two regions a re-declaration owns — its binder token and everything past its end to
	 * the end of the scope — and report whether it claimed them.
	 *
	 * The INITIALIZER is deliberately left out, and it is the one place this shape differs from a
	 * loop's: `var a = 1; var a = a + 1;` reads the FIRST binding in the second declaration's own
	 * right-hand side, so cutting the whole declaration would flag a live binding and the autofix
	 * would delete it. Excluding only the binder token leaves that read counted, exactly as the
	 * loop model leaves the iterated expression counted.
	 *
	 * That is the whole of this rule's opinion on "does the initializer read the shadowed name" —
	 * a region left out of an exclusion set, not a predicate. `shadowing-local` reaches the same
	 * verdict for the same input through `Refs`, and the two are NOT one question wearing two
	 * implementations: this one asks whether the FIRST binding is dead and reports THAT declaration,
	 * with silence as its conservative direction; the other asks whether the SECOND declaration
	 * consumes what it hides and reports the second, with reporting as its conservative direction.
	 * On `var a = 1; var a = 2; return a;` both fire, on two lines, and each says something the other
	 * does not. Do not fold them together.
	 */
	private static function appendRedeclaredRegion(ctx: ScanCtx, redecl: QueryNode, name: String, scopeSpan: Span, out: Array<Span>): Bool {
		final span: Null<Span> = redecl.span;
		if (span == null) return false;
		final binder: Null<Span> = RefactorSupport.binderTokenSpan(ctx.source, span.from, span.to, name);
		if (binder == null) return false;
		out.push(binder);
		out.push(new Span(span.to, scopeSpan.to));
		return true;
	}

	/** Where the second binding starts, so a reader who can see the name below knows which one owns it. */
	private static function redeclarationNote(ctx: ScanCtx, redecl: QueryNode): String {
		final span: Null<Span> = redecl.span;
		if (span == null) return '';
		final at: Position = span.lineCol(ctx.source);
		return '$REDECLARED_AT${at.line}:${at.col}, and every read past that belongs to the second binding';
	}

	/**
	 * Collect the shadowed regions of every self-scoped declaration of `name` in `node`'s
	 * subtree. Reification (`opaqueKinds`) and conditional-compilation subtrees are not
	 * descended: a binding whose uses a splice may inject, and a branch the tree flattens
	 * into its siblings, are both regions this model cannot claim.
	 */
	private static function collectShadowedRegions(ctx: ScanCtx, node: QueryNode, name: String, out: Array<Span>): Void {
		final kind: String = node.kind;
		if (ctx.opaqueKinds.contains(kind) || ModuleScan.opensConditionalRegion(node, ctx.source, ctx.conditionalIfKeyword)) return;
		if (ctx.selfScopeDeclKinds.contains(kind) && bindsShadowingName(ctx, node, name)) appendShadowedRegion(ctx, node, name, out);
		for (c in node.children) collectShadowedRegions(ctx, c, name, out);
	}

	/**
	 * Whether the self-scoped binder `node` binds `name` — its own name (the `for` iterator,
	 * the `catch` exception) or the VALUE binder a key-value iteration carries as a separate
	 * child (`RefShape.iterationValueBinderKinds`).
	 *
	 * The loop node's own name is the KEY only, so `for (k => item in m)` used to leave a
	 * shadowing `item` unseen and the outer declaration silently live. The binder region
	 * `appendShadowedRegion` then cuts is the same either way — it locates the binder TOKEN in
	 * the header, which holds both names.
	 */
	private static function bindsShadowingName(ctx: ScanCtx, node: QueryNode, name: String): Bool {
		return node.name == name || node.children.exists(c -> ctx.valueBinderKinds.contains(c.kind) && c.name == name);
	}

	/**
	 * Whether `[from, to)` of `source` holds nothing but trivia — whitespace, comments, and
	 * a statement terminator the parser folded into the enclosing construct's span rather
	 * than projecting as its own node.
	 *
	 * A construct's span reaches past its last child by however much the FORMATTING put
	 * there (the space before a comprehension's `]`, a stray `;` after a block-terminated
	 * loop), so an exact end-offset comparison would make a finding a property of layout.
	 * Only text that could BIND or REFERENCE something disqualifies the shape.
	 */
	private static function onlyTrivia(source: String, from: Int, to: Int): Bool {
		var at: Int = from;
		while (at < to) {
			final next: Int = RefactorSupport.skipForwardTrivia(source, at);
			if (next > at) {
				at = next;
				continue;
			}
			if (source.fastCodeAt(at) != ';'.code) return false;
			at++;
		}
		return true;
	}

	/**
	 * Append the binder token and the body of the self-scoped declaration `node` — the two
	 * regions in which an occurrence of `name` cannot be a reference to an outer binding.
	 *
	 * The construct's shape is VERIFIED, not assumed: the body is its trailing child, and
	 * only when nothing but trivia separates that child's end from the construct's own
	 * (`onlyTrivia` — an exact end-offset match would hand the verdict to the formatter,
	 * whose spacing and stray terminators the span absorbs); the binder must sit ahead of
	 * the body. Anything else is a shape this model does not describe, and nothing is
	 * claimed. The
	 * head BETWEEN the two is deliberately not claimed either — a `for` loop's iterated
	 * expression is evaluated in the ENCLOSING scope, so `for (item in item)` reads the
	 * outer `item` and the declaration is live.
	 */
	private static function appendShadowedRegion(ctx: ScanCtx, node: QueryNode, name: String, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		final children: Array<QueryNode> = node.children;
		if (span == null || children.length == 0) return;
		final body: Null<Span> = children[children.length - 1].span;
		if (body == null || body.to > span.to || body.from <= span.from || !onlyTrivia(ctx.source, body.to, span.to)) return;
		final binder: Null<Span> = RefactorSupport.binderTokenSpan(ctx.source, span.from, body.from, name);
		if (binder == null) return;
		out.push(binder);
		out.push(body);
	}

	/**
	 * Whether `offset` sits inside a conditional-compilation region of `node`'s subtree. A
	 * `#if` region projects as ONE node whose branches are flattened into flat siblings, so
	 * no state of that tree is the text a single compile sees: a declaration inside one
	 * cannot be weighed against a shadowing construct, and the refinement is suspended.
	 */
	private static function withinConditional(ctx: ScanCtx, node: QueryNode, offset: Int): Bool {
		if (ctx.conditionalIfKeyword == null) return false;
		final span: Null<Span> = node.span;
		if (span != null && (offset < span.from || offset >= span.to)) return false;
		return ModuleScan.opensConditionalRegion(node, ctx.source, ctx.conditionalIfKeyword)
			|| node.children.exists(c -> withinConditional(ctx, c, offset));
	}

	/**
	 * Index every statement-position local declaration by its span's `from`
	 * offset, skipping reification (`opaqueKinds`) subtrees so the autofix
	 * never resolves to a binding inside one.
	 */
	private static function collectLocalDecls(
		node: QueryNode, out: Map<Int, QueryNode>, opaqueKinds: Array<String>, localDeclKinds: Array<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (localDeclKinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out[span.from] = node;
		}
		for (c in node.children) collectLocalDecls(c, out, opaqueKinds, localDeclKinds);
	}

}
