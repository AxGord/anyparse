package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an ARROW lambda whose `{ … }` body holds exactly one statement, and collapses the
 * block to a bare expression body:
 *
 * ```haxe
 * moves.sort((a:Item, b:Item) -> {
 *     return a.path < b.path ? -1 : 1;
 * });
 * // ->
 * moves.sort((a:Item, b:Item) -> a.path < b.path ? -1 : 1);
 * ```
 *
 * Purely structural (no type information). `Info` — the code is correct, this is the
 * canon-convergence half of the arrow-lambda family: `prefer-arrow-callback` turns a
 * `function` literal into an arrow, this check then drops the braces the literal needed.
 *
 * ## What is flagged
 *
 * A node of one of the ARROW lambda kinds — every `lambdaKinds` entry EXCEPT `fnExprKind`
 * — whose LAST child (the body; a lambda's other children are its parameters) is a block
 * (`ControlFlowSupport.blockKinds()`) holding exactly one statement, and that statement is
 * either
 *
 * - a VALUE `return` (`valueReturnKinds`) with exactly one child — the returned
 *   expression becomes the body. A value-less `return;` is a distinct kind and is absent
 *   from the set, so it never matches: `(…) -> return;` is not an expression body; or
 * - a single expression statement (`exprStatementKind`) with exactly one child — the
 *   expression becomes the body; or
 * - a CONTROL-FLOW statement (`controlFlowKinds`: `if` with or without `else`, `switch`,
 *   `for`, `while`, `throw`) — the statement itself becomes the body, minus its own
 *   terminator. Each of these is an EXPRESSION in Haxe, so the collapse preserves the
 *   block's value exactly as the two arms above do (see below). This arm is checked FIRST:
 *   an `if` / `for` / `while` node carries two or more children and would otherwise be
 *   rejected by the single-child arity guard the other two arms share.
 *
 * Anything else — a local declaration, a `do … while`, a value-less `return;`, a `break`,
 * a `continue`, two statements, an empty body — is left alone. A `#if` region does NOT
 * match either: a conditional projects as ONE `Conditional` child of the block, which is
 * none of the accepted statement kinds, so a body whose single "statement" is
 * branch-dependent fails closed. That is why this check reads the PLAIN tree rather than
 * the branch-aware one: the branch-aware projection would split the region into
 * `CondBranch` statement lists and could present a one-statement branch as if it were the
 * whole body. `do … while` is outside the accepted set deliberately: its condition is the
 * LAST child, so the body-tail recursion the terminator strip below relies on does not
 * describe it.
 *
 * The `function` literal (`fnExprKind`) is deliberately NOT matched. `prefer-arrow-callback`
 * owns that node in call-argument position and normalises it INTO one of the arrow kinds;
 * this check then fires on the result in the next fixed-point pass. Matching both here would
 * double-report one site, and collapsing a `function` literal's block in place would emit
 * `function(v) return e`, a shape the canon does not want.
 *
 * ## Why the collapse is type-preserving
 *
 * A Haxe block IS an expression whose value is its last expression, so
 * `(v) -> { push(v); }` already has type `(v : Int) -> Int`, not `-> Void` — verified on
 * 4.3.7 for both the `return` and the bare-expression shape, standalone and in a generic
 * argument position (`array.map`). This check therefore carries none of the
 * expected-type machinery `prefer-arrow-callback` needs: THAT rewrite changes a
 * `function` literal's Void-by-default return into an inferred one, while dropping braces
 * around a single statement changes nothing.
 *
 * The SAME argument carries every control-flow kind, because each one is an expression in
 * its own right and the block's value is therefore already that construct's value:
 *
 * - `if` / `if … else` — an if-EXPRESSION. `() -> { if (c) 1 else 2; }` and
 *   `() -> if (c) 1 else 2` both yield `1` for a true `c` (verified on 4.3.7), and an
 *   else-less `if` is `Void`-typed in BOTH forms, so neither gains nor loses a value.
 * - `switch` — a switch-EXPRESSION, its value the matched arm's; the block's value was
 *   already that.
 * - `for` / `while` — `Void`-typed loops, so the block was `Void` before and after.
 * - `throw` — unifies with every type, and does so in both positions: a `Void -> Int`
 *   annotation is accepted by `() -> { throw "x"; }` and by `() -> throw "x"` alike.
 *
 * So the collapse never needs to know the enclosing expected type — the same reason the
 * two original arms do not.
 *
 * A comment anywhere inside the block but outside the copied expression is dropped by the
 * rebuild (the braces, the `return` keyword and the `;` all go away), so the finding is
 * skipped rather than silently losing it — the family's fail-closed comment guard. A
 * comment INSIDE the expression rides along and the site still fires. That holds on the
 * control-flow arm unchanged: a comment trailing the statement is outside the kept span
 * (which `emittedEnd` lands on the last real token) and refuses the site.
 *
 * The kept span is additionally passed through `IfExpressionChain.tokenSpan`, the family's
 * shared trivia normaliser, for a grammar whose node spans run PAST their last token. On
 * the Haxe grammar no end `emittedEnd` can return is preceded by trivia — the two it emits
 * are a descendant's tight span end and a node's own span end, and the Haxe parser closes a
 * statement on its last real token — so the call is a measured NO-OP here and no test
 * discriminates it. It is kept as the family's one way of asking that question rather than
 * as a guard this grammar needs; the refusal of a trailing comment is `emittedEnd`'s doing,
 * not its.
 *
 * ## The dangling `else`
 *
 * Collapsing a control-flow body changes what may follow the emitted text, and one
 * position turns that into a silent semantics break:
 *
 * ```haxe
 * if (x) cb = () -> { if (c) g(); }; else h();
 * // collapsed, WITHOUT the gate below:
 * if (x) cb = () -> if (c) g(); else h();
 * ```
 *
 * Haxe allows a `;` before `else`, so the trailing `else h()` re-parents onto the INNER
 * `if (c)` and the outer else-branch stops running (reproduced with `--interp`). The
 * output still PARSES, so the `--fix` re-parse gate waves it through — nothing but a gate
 * here stops it.
 *
 * Whether an `else` can follow is a property of the lambda's POSITION, so the walk carries
 * one boolean, `shielded`, computed per child on the way down (`childShielded`):
 *
 * - a child of a SHIELD parent (`shieldKinds`: a block, a call, a `new`, a paren, an array
 *   literal, an index access, an object field, a case branch) is shielded — the parent
 *   closes every child with a `)` / `,` / `]` / `}` or a following statement, and none of
 *   those can be `else`;
 * - a child with a FOLLOWING SIBLING is shielded, because the token separating them is not
 *   an `else` — EXCEPT the then-branch of a conditional that has an else-branch after it,
 *   which is exactly the hazard above;
 * - a TAIL child inherits its parent's own value, since whatever can follow the parent can
 *   follow it. This is what makes the hazard reach through a brace-less body chain: a loop
 *   in that then-branch passes the exposure on to its body;
 * - EVERY child of a `#if` region (`RefactorSupport.isConditionalKind`) inherits, following
 *   sibling or not. The plain tree projects each branch's nodes as FLAT siblings of one
 *   `Conditional` / `ConditionalExpr`, so a following sibling proves nothing there: it may
 *   belong to a different branch, and under the defines that select THIS child's branch the
 *   child is the last thing the region emits. Without that arm
 *   `if (x) #if A cb = () -> { if (c) g(); }; #else … #end else h();` collapsed and the
 *   outer `else` re-parented — the identical break, reproduced with `--interp`.
 *
 * A `;` does NOT shield. That is the whole point of the reproduction: the statement in the
 * hazard IS terminated, and the `else` binds through the `;` anyway.
 *
 * In an UNSHIELDED position the site is refused when its body holds an else-less
 * conditional anywhere in its subtree (`IfExpressionChain.holdsElseLessConditional`, the
 * same scan the if-expression collapse rules use for the same reason). That scan is
 * deliberately the conservative WHOLE-subtree walk rather than a right-spine one: an
 * else-less `if` in a delimited interior (a call argument, a paren) could not absorb
 * anything, but proving which is which costs more than the rare cleanup it buys, and the
 * answer to any uncertainty is skip. The cost is bounded because the dominant position —
 * a lambda passed as a CALL ARGUMENT — is shielded and never reaches the scan at all,
 * which is what keeps the widened rule useful.
 *
 * The scan guards EVERY arm, not only the control-flow one. `() -> { return if (c) g(); }`
 * emits an else-less `if` exactly as `() -> { if (c) g(); }` does, so the value arms carry
 * the identical hazard — it predates the control-flow arm and was simply unanswerable until
 * the position walk existed to ask about it.
 *
 * ## Dropping the statement's terminator
 *
 * A statement's span covers the `;` that ended it: `a(() -> { if (c) f(); });` projects
 * `IfStmt @36-47` whose interior `ExprStmt @43-47` runs past the `Call @43-46` to include
 * that `;`. Emitting the raw slice would give `a(() -> if (c) f(););`, which does not
 * parse. `emittedEnd` recovers the tight end STRUCTURALLY — no scan of the source text for
 * a `;`, which would be a grammar leak — by walking the tail: a node whose span ends where
 * its last child's span ends is re-asked about that child, and a `terminatedKinds` node
 * (the kinds whose span covers a trailing terminator: value `return`, `throw`, the control
 * exits, a local declaration, an expression statement, an empty statement) whose last
 * child ends EARLIER gives up its own end in favour of the child's.
 *
 * The worked cases:
 *
 * - `if (c) f();` — `IfStmt` ends where its `ExprStmt` does, so descend; the `ExprStmt` is
 *   terminated and its `Call` ends earlier, so the end is the `Call`'s → `if (c) f()`.
 * - `if (c) f(); else g();` — the same descent through the ELSE-branch's `ExprStmt` →
 *   `if (c) f(); else g()`. The interior `;` stays, and is legal Haxe.
 * - `for (x in xs) f(x);` / `while (c) f();` / `throw "x";` — terminator dropped the same
 *   way (`throw` is itself a terminated kind, so it yields to its value's end).
 * - `switch v { … }` — a bare switch is NOT terminated and its last `CaseBranch` ends
 *   before the closing `}`, so the full span is kept and the `}` survives.
 * - `if (c) { a(); b(); }` — the descent reaches the inner block, which is not terminated
 *   and ends after its last statement, so the inner braces are KEPT.
 * - `while (c);` — the descent reaches a CHILDLESS `EmptyStmt`, which IS terminated, so
 *   there is no structural end to recover and the site is refused. Emitting `while (c)`
 *   would not compile.
 * - `if (c) return;` / `for (…) break;` — a childless `VoidReturnStmt` / `BreakStmt`, both
 *   terminated, refused for the same reason. Fail-closed: their terminator is not
 *   recoverable from any child span.
 * - `if (c) #if A f(); #end` — the descent reaches the `#if` region, which closes on `#end`
 *   with the `;` to drop INSIDE it. No child end recovers that, and the region's own end
 *   would emit `if (c) #if A f(); #end` — text the Haxe compiler rejects once the branch is
 *   active — so a conditional region on the tail is refused outright.
 *
 * The VALUE arms never run that walk — they emit the child's span verbatim, which is sound
 * only while the statement's terminator lies OUTSIDE that child. A GAPLESS terminated
 * statement, whose span ends exactly where its value's does, says the model swallowed the
 * terminator INTO the value, and the emitted text would carry it: `{ @:privateAccess if (c)
 * h(); }` as a block's sole statement projects one `MetaExpr` spanning the `;`, where the
 * same code with a sibling after it projects the `;` under an interior `ExprStmt`. Such a
 * site is refused. This one predates the control-flow arm and is not caught downstream: the
 * emitted `@:privateAccess if (c) h();` is text `haxe` rejects but THIS parser accepts, so
 * the `--fix` re-parse gate is no net for it.
 *
 * A reification subtree (`RefShape.opaqueKinds`, Haxe's `macro { … }`) is skipped wholesale,
 * matching the sibling rewrite rules: its interior is spliced code a consumer may
 * pattern-match on, not source a human reads.
 *
 * ## Autofix
 *
 * `fix` replaces the BLOCK's span — braces included, nothing outside them — with the
 * expression's verbatim source. Trailing trivia is outside the block's span, so the
 * emitted body cannot weld onto what follows. Nested lambdas both match; the outer edit
 * contains the inner one and `RefactorSupport.dropContainedEdits` keeps the outer, the
 * inner surfacing on the next pass.
 *
 * `run` and `fix` share one `collect`, so neither can encode a gate the other misses.
 *
 * ## Grammar-agnostic
 *
 * `lambdaKinds` minus `fnExprKind` are the matched kinds, `ControlFlowSupport.blockKinds()`
 * the block bodies, `valueReturnKinds` / `exprStatementKind` the two value-carrying
 * collapsible statements and `opaqueKinds` the subtrees to skip. No `lambdaKinds` beyond
 * the function literal, no block kinds, or NEITHER value-carrying statement kind → the
 * check is a no-op.
 *
 * The control-flow arm reads four more seams. Three of them unset simply narrow it; the
 * fourth, `conditionalKinds`, is the one that must be set for a grammar that HAS an `if`:
 *
 * - `controlFlowKinds` — `ifExpressionKinds` + `ifStatementKinds` + `switchKinds` +
 *   `loopStatementKinds` + `throwKinds`. EMPTY leaves the arm inert and the check exactly
 *   what it was before it existed, which is why no early `return null` guards it.
 * - `conditionalKinds` — the `if` forms, both expression and statement. NOT inert when
 *   unset: it is the set the dangling-else scan asks about, so leaving it unset for a
 *   grammar with an `if` silently deletes that refusal — on the VALUE arms too, which stay
 *   live even with `controlFlowKinds` empty. Optional only for a grammar whose `if` cannot
 *   absorb a following `else`.
 * - `shieldKinds` — the block kinds plus `callKind` / `newExprKind` / `parenKind` /
 *   `arrayLiteralKind` / `indexAccessKind` / `objectFieldKind` / `caseBranchKind`. Fewer
 *   entries means fewer positions proved safe, so the check refuses MORE: unset is the
 *   conservative direction.
 * - `terminatedKinds` — `valueReturnKinds` + `throwKinds` + `controlExitKinds` +
 *   `localDeclKinds` + `exprStatementKind` + `emptyStmtKind`. A kind missing here keeps
 *   its trailing terminator in the emitted text; the set is a UNION of existing seams
 *   rather than a new one so that a grammar already describing its statements gets the
 *   strip for free, and duplicates across those seams are harmless (membership only). It
 *   is a SUPERSET of the terminator-bearing kinds, not an exact one: the expression-form
 *   members those seams carry (`ReturnExpr` / `ThrowExpr` / `BreakExpr` / `VarMore` …)
 *   end on no terminator at all. Membership only ever makes the walk hand its end to a
 *   child or refuse, never keep a delimiter it should have dropped, so an over-wide set
 *   costs coverage, not correctness.
 */
@:nullSafety(Strict)
final class PreferLambdaExpressionBody implements Check {

	/** A collapsible body block holds exactly one statement. */
	private static inline final SINGLE_STATEMENT: Int = 1;

	/** A collapsible statement carries exactly one child — the value the body becomes. */
	private static inline final SINGLE_VALUE_CHILD: Int = 1;

	/** A conditional's then-branch is `children[1]`, between the condition and the else-branch. */
	private static inline final THEN_BRANCH_INDEX: Int = 1;

	public function new() {}

	public function id(): String {
		return 'prefer-lambda-expression-body';
	}

	public function description(): String {
		return
			'an arrow lambda whose block body is a single return, expression or control-flow statement, collapsible to an expression body';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		return [
			for (entry in files) for (m in collect(plugin, entry.source, seams))
				{
					file: entry.file,
					span: m.span,
					rule: 'prefer-lambda-expression-body',
					severity: Severity.Info,
					message: 'this single-statement lambda body can be an expression body'
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final byKey: Map<String, Match> = [];
		for (m in collect(plugin, source, seams)) byKey['${m.span.from}:${m.span.to}'] = m;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m != null) edits.push({ span: m.span, text: m.text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Every collapsible lambda body in `source` (empty when it does not parse). `run` and
	 * `fix` both go through it, so neither can encode a gate the other misses.
	 */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final out: Array<Match> = [];
		// The module root is shielded: nothing follows a top-level declaration but another
		// one, so no `else` can reach a lambda that inherits its exposure from there.
		walk(tree, source, RefactorSupport.collectCommentTokens(source), s, out, true);
		return out;
	}

	/**
	 * Bundle the kinds this check reads, or null when the grammar leaves the check nothing to
	 * match: no anonymous-function-literal kind (see the body — without it the exclusion that
	 * keeps this check off `prefer-arrow-callback`'s node cannot be made), no arrow lambda
	 * kind, no block kind, or neither collapsible statement kind.
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		// The ARROW forms are every lambda kind that is not the anonymous-function literal:
		// `prefer-arrow-callback` owns that one and normalises it into one of these, so
		// excluding it is what keeps a single site from being reported by both checks. With
		// the seam UNSET nothing would be excluded and this check would collapse a
		// `function` literal's block to `function(v) e`, which does not even compile — so an
		// unset seam is a no-op, not a wider match. `prefer-arrow-callback` is inert without
		// it too, so nothing is lost that this check could compose with.
		final fnExprKind: Null<String> = shape.fnExprKind;
		if (fnExprKind == null) return null;
		final arrowKinds: Array<String> = (shape.lambdaKinds ?? []).filter(k -> k != fnExprKind);
		final blockKinds: Array<String> = support.blockKinds();
		final valueReturnKinds: Array<String> = shape.valueReturnKinds ?? [];
		final exprStatementKind: Null<String> = shape.exprStatementKind;
		if (arrowKinds.length == 0 || blockKinds.length == 0) return null;
		if (valueReturnKinds.length == 0 && exprStatementKind == null) return null;
		final conditionalKinds: Array<String> = IfExpressionChain.conditionalKinds(shape);
		final throwKinds: Array<String> = shape.throwKinds ?? [];
		// `blockKinds()` hands back the plugin's SHARED static array — copy before pushing,
		// or every other consumer of that seam inherits this check's additions.
		final shieldKinds: Array<String> = blockKinds.copy();
		final delimitedHosts: Array<Null<String>> = [
			shape.callKind,
			shape.newExprKind,
			shape.parenKind,
			shape.arrayLiteralKind,
			shape.indexAccessKind,
			shape.objectFieldKind,
			shape.caseBranchKind
		];
		for (host in delimitedHosts) if (host != null) shieldKinds.push(host);
		// A union of existing statement seams, so duplicates are expected and harmless —
		// membership is the only question ever asked of it.
		final terminatedKinds: Array<String> = valueReturnKinds.concat(throwKinds)
			.concat(shape.controlExitKinds ?? [])
			.concat(shape.localDeclKinds ?? []);
		if (exprStatementKind != null) terminatedKinds.push(exprStatementKind);
		final emptyStmtKind: Null<String> = shape.emptyStmtKind;
		if (emptyStmtKind != null) terminatedKinds.push(emptyStmtKind);
		return {
			arrowKinds: arrowKinds,
			blockKinds: blockKinds,
			valueReturnKinds: valueReturnKinds,
			exprStatementKind: exprStatementKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			controlFlowKinds: conditionalKinds.concat(shape.switchKinds ?? []).concat(shape.loopStatementKinds ?? []).concat(throwKinds),
			conditionalKinds: conditionalKinds,
			shieldKinds: shieldKinds,
			terminatedKinds: terminatedKinds
		};
	}

	/**
	 * Walk `node`, collecting every collapsible lambda body; a reification subtree is skipped
	 * whole. `shielded` is `node`'s own answer to "can an `else` follow what I emit here" —
	 * false only in the one position that can absorb one — and is re-derived per child.
	 */
	private static function walk(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, out: Array<Match>, shielded: Bool
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.arrowKinds.contains(node.kind)) {
			final m: Null<Match> = match(node, source, comments, s, shielded);
			if (m != null) out.push(m);
		}
		for (i => child in node.children) walk(child, source, comments, s, out, childShielded(node, i, s, shielded));
	}

	/**
	 * Whether `parent`'s child at `index` is closed by a token that cannot be an `else`.
	 *
	 * A SHIELD parent writes a `)` / `,` / `]` / `}` — or a next statement — after every one
	 * of its children. A child with a FOLLOWING SIBLING is separated from it by a token that
	 * is not an `else`, except the then-branch of a conditional, whose following sibling IS
	 * the else-branch, and except a `#if` region, whose siblings are the OTHER branches and
	 * separate nothing. A TAIL child is bounded by whatever bounds the parent, so it inherits
	 * `shielded`.
	 */
	private static function childShielded(parent: QueryNode, index: Int, s: Seams, shielded: Bool): Bool {
		if (s.shieldKinds.contains(parent.kind)) return true;
		// A `#if` region projects EVERY branch's nodes as FLAT siblings, so a following sibling
		// may belong to a different branch and separate nothing at all: under the defines that
		// select this child's branch, whatever follows the region follows the child. Inherit.
		if (RefactorSupport.isConditionalKind(parent.kind)) return shielded;
		if (index < parent.children.length - 1) return !(index == THEN_BRANCH_INDEX && s.conditionalKinds.contains(parent.kind));
		return shielded;
	}

	/**
	 * The collapse of `node`'s body when it is a one-statement block whose statement is a
	 * value `return`, a bare expression or a control-flow construct, and whose rebuild drops
	 * no comment; else null. The body is the LAST child — a lambda's earlier children are its
	 * parameters.
	 */
	private static function match(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, shielded: Bool
	): Null<Match> {
		if (node.children.length == 0) return null;
		final body: QueryNode = node.children[node.children.length - 1];
		if (!s.blockKinds.contains(body.kind) || body.children.length != SINGLE_STATEMENT) return null;
		// A block that is NOT the lambda's tail cannot be its body: `->` parses its body
		// greedily, so `v -> { return 1; } != null` projects as `ThinArrow(v, NotEq(…))` and
		// the block is a grandchild. That greediness is what spares this check the slot
		// analysis `prefer-ternary-expression` needs — nothing outside can bind INTO an
		// emitted body that the braces were not already shielding.
		final picked: Null<Collapsible> = collapsible(body.children[0], s, shielded);
		if (picked == null) return null;
		final bodySpan: Null<Span> = body.span;
		final pickedSpan: Null<Span> = picked.node.span;
		if (bodySpan == null || pickedSpan == null) return null;
		final valueSpan: Null<Span> = picked.terminated ? emittedSpan(picked.node, pickedSpan, source, comments, s) : pickedSpan;
		if (valueSpan == null || valueSpan.to <= valueSpan.from) return null;
		if (IfExpressionChain.droppedComment(bodySpan, [valueSpan], comments)) return null;
		return { span: bodySpan, text: source.substring(valueSpan.from, valueSpan.to) };
	}

	/**
	 * What a one-statement block collapses to: a control-flow statement WHOLE (`terminated`,
	 * its own trailing terminator to be stripped), or the value of a value `return` / a bare
	 * expression statement (emitted verbatim, exactly as before this arm existed). Null for
	 * every other statement — a value-less `return;`, a declaration, a `do … while`, a control
	 * exit, or a `#if` region (one `Conditional` child, which is no accepted kind).
	 *
	 * The control-flow arm comes FIRST because an `if` / `for` / `while` carries two or more
	 * children and the arity guard below would reject it.
	 */
	private static function collapsible(stmt: QueryNode, s: Seams, shielded: Bool): Null<Collapsible> {
		if (s.controlFlowKinds.contains(stmt.kind)) {
			// Unshielded, an emitted else-less `if` anywhere in the subtree would swallow the
			// `else` that follows the lambda. See the dangling-else section of the class doc.
			if (!shielded && IfExpressionChain.holdsElseLessConditional(stmt, s.conditionalKinds)) return null;
			return { node: stmt, terminated: true };
		}
		if (stmt.children.length != SINGLE_VALUE_CHILD) return null;
		final valueCarrying: Bool = s.valueReturnKinds.contains(stmt.kind) || stmt.kind == s.exprStatementKind;
		if (!valueCarrying) return null;
		// The SAME gate on the value arms: `return if (c) g();` emits an else-less `if` just as
		// the control-flow arm does, so an unshielded position absorbs the following `else`
		// identically. Predates the control-flow arm; the position walk is what makes it
		// answerable.
		final value: QueryNode = stmt.children[0];
		if (!shielded && IfExpressionChain.holdsElseLessConditional(value, s.conditionalKinds)) return null;
		// The value arm emits its child's span verbatim, which is sound only while the statement's
		// own terminator lies OUTSIDE that child. A gapless terminated statement means the model
		// swallowed the terminator into the value (`{ @:privateAccess if (c) h(); }` projects the
		// `;` inside the meta-wrapped value), and the emitted text would carry it. Refuse: the
		// re-parse gate is no net here, since this parser accepts the shape `haxe` rejects.
		final stmtSpan: Null<Span> = stmt.span;
		final valueSpan: Null<Span> = value.span;
		if (stmtSpan == null || valueSpan == null) return null;
		if (s.terminatedKinds.contains(stmt.kind) && stmtSpan.to == valueSpan.to) return null;
		return { node: value, terminated: false };
	}

	/**
	 * `stmt`'s span cut back to its last real token: its own terminator dropped by
	 * `emittedEnd`, then the family's shared trivia normaliser applied on top for a grammar
	 * whose spans run past that token — a measured no-op on the Haxe grammar, see the class
	 * doc. Null when the terminator is not recoverable structurally and the site is refused.
	 */
	private static function emittedSpan(
		stmt: QueryNode, span: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Span> {
		final end: Null<Int> = emittedEnd(stmt, s);
		if (end == null) return null;
		return IfExpressionChain.tokenSpan(new Span(span.from, end), source, comments);
	}

	/**
	 * Where `node`'s emitted text ends with its trailing terminator dropped, or null when no
	 * such end exists and the site must be refused. Purely structural — the source text is
	 * never scanned for a `;`, which would be a grammar leak.
	 *
	 * A node whose span ends exactly where its LAST child's does is a pass-through: the answer
	 * is that child's. Otherwise the gap between the two is the node's own trailing token, and
	 * a `terminatedKinds` node yields its end to the child's while any other node keeps its
	 * own (a bare `switch`'s closing `}`, a block's). A terminated node with no child span to
	 * fall back on — a childless `EmptyStmt` / `return;` / `break;` — has nothing to recover
	 * and fails closed, as does a `#if` region, whose `#end` is mandatory and whose
	 * terminator sits ahead of it. Worked examples live in the class doc.
	 */
	private static function emittedEnd(node: QueryNode, s: Seams): Null<Int> {
		// A `#if` region closes on `#end` and the terminator to drop sits INSIDE it, ahead of
		// that keyword — no structural end recovers it, so the site is refused.
		if (RefactorSupport.isConditionalKind(node.kind)) return null;
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final terminated: Bool = s.terminatedKinds.contains(node.kind);
		if (node.children.length == 0) return terminated ? null : span.to;
		final last: QueryNode = node.children[node.children.length - 1];
		final lastSpan: Null<Span> = last.span;
		if (lastSpan == null) return terminated ? null : span.to;
		if (span.to == lastSpan.to) return emittedEnd(last, s);
		return terminated ? lastSpan.to : span.to;
	}

}

/** The kinds `PreferLambdaExpressionBody` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var arrowKinds: Array<String>;
	var blockKinds: Array<String>;
	var valueReturnKinds: Array<String>;
	var exprStatementKind: Null<String>;
	var opaqueKinds: Array<String>;

	/** The control-flow statements a body may hold whole — `if` / `switch` / loop / `throw`. Empty leaves that arm inert. */
	var controlFlowKinds: Array<String>;

	/** Every `if` form, statement and expression — what an emitted ` else ` could re-parent onto. */
	var conditionalKinds: Array<String>;

	/** Parents that close every child with a delimiter, so no `else` can follow one. */
	var shieldKinds: Array<String>;

	/** Statement kinds whose span covers a trailing terminator the emitted text must not carry. */
	var terminatedKinds: Array<String>;
}

/**
 * What a collapsible block yields: the node whose source becomes the body, and whether its
 * span carries a terminator that the strip must cut (true only for the control-flow arm —
 * the value arms emit a bare expression node's span verbatim).
 */
private typedef Collapsible = {
	var node: QueryNode;
	var terminated: Bool;
}

/** A collapsible lambda body: the block's span (the finding key AND the replaced region) and the expression text. */
private typedef Match = {
	var span: Span;
	var text: String;
}
