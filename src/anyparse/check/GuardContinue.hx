package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.check.IfExpressionChain.ShieldSeams;
import anyparse.query.BinderScan;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a loop (`for` / `while` / `do … while`) whose braced body's LAST statement is
 * a bare `if (cond) { … }` (no `else`) preceded by at least one other statement, and
 * de-nests it into an early-`continue` guard so the body sheds an indentation level:
 * `for (…) { pre; if (cond) { BODY } }` → `for (…) { pre; if (!cond) continue; BODY }`.
 * The user's rule (preferences-haxe): sequential null checks each introducing their own
 * variable read better as flat `continue` guards than as growing nesting. Runs to a
 * fixpoint, so a two-level `if (a) { … if (b) { … } }` chain flattens over two `--fix`
 * passes. `Severity.Info`.
 *
 * ## The `if (!cond)` inversion — De Morgan when possible, order-safe
 *
 * `cond` is negated by `NegationScan.negateConditionText`, two-tier. When the grammar exposes
 * a `BooleanLogicSupport` and the condition span is comment-free, the negation is pushed
 * inward by De Morgan (`a && b` → `!a || !b`, `!(a || b)` → `a && b`, `==` / `!=` flipped),
 * with the ordered comparisons `< <= > >=` deliberately KEPT wrapped `!(a < b)` unless
 * proven totally ordered — a NaN or `null` breaks it. A `||` chain that would
 * STRAND a null-safety narrowing (Haxe carries a narrowing fact into a later `||` operand
 * from the FIRST operand only) right-nests a parenthesised group at the stranded operand
 * instead: `a != null && b != null && p(a.length, b.length)` becomes
 * `a == null || (b == null || !p(a.length, b.length))`, which narrows fine — measured on
 * the compiler. Falling back — a seam-less grammar, or a comment in the condition the
 * De Morgan rewrite would drop — the old text engine wraps `!(cond)` VERBATIM (`!` strip,
 * NaN-safe `==` / `!=` flip, everything else parenthesised-wrapped), preserving the
 * comment. Either tier is sound and compiles.
 *
 * ## Gates — every one is a correctness gate; a violated gate is a semantic bug
 *
 * The `if` must be the loop body's last statement — exactly, or followed ONLY by a
 * hoistable tail: independent plain `=` assignments of read-free literals (bool / null /
 * numeric; never strings, whose interpolation could read state the body writes) to locals
 * that are not the iterator and are mentioned nowhere in the `if` (condition, body,
 * nested captures). Such a tail is emitted ABOVE the guard, which is order-safe (nothing
 * it touches is touched by the `if`) — but only when the then-branch cannot escape the
 * iteration early (no `return` / `throw` / grammar exit outside nested functions, no
 * `break` / `continue` outside an inner loop): an escaping path SKIPPED the tail in the
 * original, so hoisting would newly execute it. The `if` must also be preceded by ≥1 statement (or a
 * non-empty tail), with NO `else` (an `else` branch the `continue` form would lose), and a braced,
 * non-empty then-branch. What precedes it must ALSO not be `loop-guard`'s own shape,
 * which has two spellings and two separate gates here: a SOLE-`if` body is the positive
 * `for (…) if (cond) …` combine form (the `ifIndex == 0` bail above), and a body OPENING with a
 * liftable `if (g) continue;` guard is the same claim written the other way (`loopGuardClaims`,
 * which asks `LoopScan.leadingContinueGuard` — the predicate `loop-guard` itself reads — plus the
 * site conditions that predicate cannot see). Without the second, the two checks reported one loop
 * body and disagreed, and the winner was argument order. A CASCADE of leading guards is NOT
 * loop-guard's and stays here, and neither is a `do … while`, which `loop-guard` never visits. It must be a DIRECT
 * child of the loop's own body block — an `if` nested in an inner loop / `switch` / `try`
 * targets a different `continue` or `finally` and is never reached. Additionally refused:
 *
 *  - a comment in the `if (` or `) {` glue, or between the `if` and its hoisted tail
 *    statements, that the rewrite drops (comments in the condition or the then-body are
 *    preserved).
 *
 * ## The collision rename
 *
 * A then-branch top-level local whose name collides with a preceding sibling local or the
 * loop iterator is NOT refused — de-nesting would widen it into the loop scope and
 * same-scope re-declare it (a `-D no-shadowing` hazard), so it is AUTO-RENAMED inside the
 * moved block to the first free `<name>2`…`<name>99` (`path` → `path2`): the binder token
 * plus every read, plain identifiers and `$name` string interpolations alike. "Free" is
 * judged against the WHOLE parse tree, not the loop — a class field is invisible to any
 * local scan, yet an unqualified read of a same-named field binds to it silently.
 *
 * That rename — and with it the whole de-nest — is refused when the name is re-declared
 * DEEPER inside the then-branch (a nested block, or a nested loop's iterator), when a nested
 * function / lambda subtree mentions it (an inner scope may own the occurrence), when the
 * grammar exposes no string-interpolation seam (interpolated reads would be missed), when
 * every candidate suffix is taken, when an occurrence sits AHEAD of the declaring
 * statement's end — there the name still resolves to the OUTER binding, as in
 * `final path = path + '/sub';`, whose initializer reads the outer `path` — or when the
 * then-branch holds a standalone textual occurrence no rewritten span accounts for: an
 * invisible binder (a `catch` variable, a `k => v` value iterator, a lambda parameter) or a
 * mention in a comment or a plain string.
 *
 * A flow exit (`break` / `continue` / `return` / `throw`) anywhere in the then-branch does
 * NOT refuse the plain (tail-less) de-nest: it moves the then-branch's statements into the
 * SAME loop body, in the same function, executed under the same condition — every jump
 * target (nearest enclosing loop, enclosing function) is unchanged, so the transform is
 * flow-equivalent by construction. (An earlier over-conservative gate refused these and
 * silenced the check on exactly the deeply nested real-code bodies it exists for.) Only
 * the HOIST variant re-checks escapes, per above — there the tail's execution set changes.
 *
 * ## Grammar-agnostic
 *
 * Driven by `loopStatementKinds` (body = last child) and `doWhileLoopKinds` (body = first
 * child), `ifStatementKinds`, `continueStatementKind`, and `ControlFlowSupport.blockKinds`
 * (any of which unset → no-op), plus `localDeclKinds` (collision rename), `opaqueKinds`
 * (skip macro reification), the `notKind` / `eqKind` / `notEqKind` / `parenKind` /
 * atomic kinds that shape the inversion, and the optional hoist seams
 * (`exprStatementKind` / `assignKind` / literal, exit and nested-scope kinds — any
 * missing piece disables only the hoist, and its `identKind` / `stringInterpIdentKind`
 * pair also gates the collision rename).
 */
@:nullSafety(Strict)
final class GuardContinue implements Check {

	/** A guard `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** The first suffix a collision rename tries (`path` → `path2`). */
	private static inline final FRESH_NAME_FIRST: Int = 2;

	/** One past the last suffix a collision rename tries (`path99` is the last candidate). */
	private static inline final FRESH_NAME_LIMIT: Int = 100;

	public function new() {}

	public function id(): String {
		return 'guard-continue';
	}

	public function description(): String {
		return 'a trailing if in a loop body, de-nestable to an if (!cond) continue; guard';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			// The module root is shielded, for the reason `loop-guard` seeds the same flag true
			// there: nothing follows a top-level declaration but another one.
			if (tree != null)
				walk(
					tree, tree, violations, entry.file, entry.source, seams, true,
					CheckScan.typeNominalResolver(entry.source, plugin, tree, entry.file)
				);
		}
		return violations;
	}

	/** De-nest each flagged trailing `if` into an `if (!cond) continue;` guard, replacing the `if` statement. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byIf: Map<String, Candidate> = [];
		indexCandidates(tree, tree, source, seams, byIf, true);
		final types: Null<(QueryNode) -> Null<String>> = violations.length == 0
			? null
			: CheckScan.typeNominalResolver(source, plugin, tree, violations[0].file, index);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final m: Null<Candidate> = byIf['${span.from}:${span.to}'];
			if (m == null) continue;
			final edit: Null<{ span: Span, text: String }> = editFor(m, source, seams, types);
			if (edit != null) edits.push(edit);
		}
		return CanonicalEdit.dropContainedEdits(edits);
	}

	/** The local declaration node a top-level statement holds, or null — see `RefactorSupport.topLevelDeclaredNode`. */
	private static inline function declaredNode(stmt: QueryNode, s: Seams): Null<QueryNode> {
		return BinderScan.topLevelDeclaredNode(stmt, s.localDeclKinds, s.localDeclExprKinds, s.metaKinds);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return null;
		final continueKind: Null<String> = shape.continueStatementKind;
		if (continueKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final loopKinds: Array<String> = shape.loopStatementKinds ?? [];
		final doWhileKinds: Array<String> = shape.doWhileLoopKinds ?? [];
		return loopKinds.length == 0 && doWhileKinds.length == 0 ? null : {
			loopKinds: loopKinds,
			doWhileKinds: doWhileKinds,
			ifKinds: ifKinds,
			blockKinds: support.blockKinds(),
			blockStmtKind: shape.blockStmtKind,
			continueKind: continueKind,
			localDeclKinds: shape.localDeclKinds ?? [],
			localDeclExprKinds: shape.localDeclExprKinds ?? [],
			metaKinds: plugin.metaShape().metaKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			hoist: hoistSeams(shape),
			negation: NegationScan.negationSeams(shape),
			shield: IfExpressionChain.shieldSeams(shape, support.blockKinds()),
			support: plugin.booleanLogicSupport()
		};
	}

	/**
	 * The optional hoistable-tail seams, or null (hoist disabled — only an EXACT
	 * trailing `if` matches) when a required kind is unset.
	 */
	private static function hoistSeams(shape: RefShape): Null<HoistSeams> {
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final baseLiterals: Array<String> = [
			for (k in [
				(shape.boolLitKind: Null<String>),
				shape.nullLiteralKind
			]) if (k != null) k
		];
		final literalKinds: Array<String> = baseLiterals.concat(shape.numericLiteralKinds ?? []);
		if (literalKinds.length == 0) return null;
		final loopJumpKinds: Array<String> = [
			for (k in [
				(shape.breakStatementKind: Null<String>),
				shape.continueStatementKind
			]) if (k != null) k
		];
		return {
			exprStmtKind: exprStmtKind,
			assignKind: assignKind,
			identKind: shape.identKind,
			interpIdentKind: shape.stringInterpIdentKind,
			literalKinds: literalKinds,
			hardExitKinds: hoistHardExitKinds(shape, loopJumpKinds),
			loopJumpKinds: loopJumpKinds,
			nestedScopeKinds: LoopScan.nestedScopeKinds(shape)
		};
	}

	/**
	 * The return / throw / grammar-specific exit kinds that always escape the
	 * iteration — minus the loop jumps, which get the inner-loop exemption
	 * (`controlExitKinds` carries the break / continue kinds too).
	 */
	private static function hoistHardExitKinds(shape: RefShape, loopJumpKinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (k in [
			(shape.returnStatementKind: Null<String>),
			shape.voidReturnKind
		]) if (k != null && !out.contains(k)) out.push(k);
		for (grp in [
			shape.valueReturnKinds ?? [],
			shape.throwKinds ?? [],
			shape.controlExitKinds ?? []
		]) for (k in grp) if (!out.contains(k) && !loopJumpKinds.contains(k)) out.push(k);
		return out;
	}

	/** Walk `node`, flagging each loop whose body ends in a de-nestable trailing `if`. */
	private static function walk(
		node: QueryNode, root: QueryNode, out: Array<Violation>, file: String, source: String, s: Seams, shielded: Bool,
		?types: (QueryNode) -> Null<String>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (isLoop(node, s)) {
			final m: Null<Candidate> = match(node, root, source, s, shielded, types);
			// An inversion that cannot shed its `!( … )` wrap reads worse than the nesting it
			// removes — the guard form buys nothing there, so the site is left alone.
			if (m != null && NegationScan.negationIsClean(m.cond, source, s.support, types)) {
				final span: Null<Span> = m.ifNode.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'guard-continue',
					severity: Severity.Info,
					message: 'this trailing if can de-nest to an if (!cond) continue; guard'
				});
			}
		}
		for (i => c in node.children)
			walk(c, root, out, file, source, s, IfExpressionChain.childShielded(node, i, s.shield, shielded), types);
	}

	/** Index every de-nestable loop's candidate by its `if`'s `from:to` span key (for `fix` to re-find it). */
	private static function indexCandidates(
		node: QueryNode, root: QueryNode, source: String, s: Seams, out: Map<String, Candidate>, shielded: Bool
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (isLoop(node, s)) {
			// No type resolver, deliberately: `run` builds one from the ENTRY source and `fix` one that
			// can also carry the report index, and where the two disagree about a guard's inversion
			// they disagree about `loopGuardClaims` — which would drop from `byIf` a candidate `run`
			// reported, and `fix` would then skip that edit in silence. Asked type-blind, the deferral
			// can only ever answer "not claimed" here, so this map stays the SUPERSET of what `run`
			// reported that `fix` has always relied on.
			final m: Null<Candidate> = match(node, root, source, s, shielded);
			if (m != null) {
				final span: Null<Span> = m.ifNode.span;
				if (span != null) out['${span.from}:${span.to}'] = m;
			}
		}
		for (i => c in node.children)
			indexCandidates(c, root, source, s, out, IfExpressionChain.childShielded(node, i, s.shield, shielded));
	}

	private static function isLoop(node: QueryNode, s: Seams): Bool {
		return s.loopKinds.contains(node.kind) || s.doWhileKinds.contains(node.kind);
	}

	/**
	 * If `loop`'s braced body ends in a de-nestable bare `if (c) { … }` (no `else`,
	 * non-empty braced then-branch) — either as the EXACT last statement, or followed
	 * only by a hoistable tail of independent literal assignments — and every gate
	 * holds (tail-hoist safety, name-collision, glue-comment), return that `if`, its
	 * then-branch, its condition and the tail; else null.
	 */
	private static function match(
		loop: QueryNode, root: QueryNode, source: String, s: Seams, shielded: Bool, ?types: (QueryNode) -> Null<String>
	): Null<Candidate> {
		final body: Null<QueryNode> = LoopScan.loopBody(loop, s.doWhileKinds);
		if (body == null || !s.blockKinds.contains(body.kind)) return null;
		final stmts: Array<QueryNode> = body.children;
		var ifIndex: Int = stmts.length - 1;
		while (ifIndex >= 0 && isHoistableTailStmt(stmts[ifIndex], s)) ifIndex--;
		if (ifIndex < 0) return null;
		final tail: Array<QueryNode> = stmts.slice(ifIndex + 1);
		// A SOLE trailing if (no preceding statement, no tail) is the positive
		// `for (…) if (cond) …` combine form — loop-guard's territory.
		if (ifIndex == 0 && tail.length == 0) return null;
		// …and so is a body that OPENS with a liftable `if (g) continue;` guard, which is the other
		// half of the same claim and was missing. `loop-guard` lifts that guard into the header, and
		// the trailing `if` then sits inside the emitted header's block — no longer a direct child of
		// the loop's own body, so this check could never reach it again. Both rules therefore
		// reported one loop body and told the reader opposite things, and MEASURED, the one that won
		// was whichever came first: the registry order in a full run, the `--rule` FLAG order under a
		// filtered one (`--rule loop-guard --rule guard-continue` lifted the header, the two flags
		// swapped produced the `continue` cascade, same input, same engine). Neither pair could
		// CYCLE — each rule's output is the other's fixed point — so this is non-confluence, not
		// oscillation, and the fix is to make the claim single. A CASCADE (a second `if`-continue
		// right after the first) stays THIS rule's, which is exactly what the shared predicate
		// excludes.
		if (loopGuardClaims(loop, body, source, s, shielded, types)) return null;
		final ifNode: QueryNode = stmts[ifIndex];
		if (!s.ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final cond: QueryNode = ifNode.children[0];
		final thenBlock: QueryNode = ifNode.children[1];
		if (!s.blockKinds.contains(thenBlock.kind) || thenBlock.children.length == 0) return null;
		if (tail.length != 0 && !tailHoistSafe(loop, ifNode, thenBlock, tail, source, s)) return null;
		if (headerHasComment(source, ifNode, cond, thenBlock)) return null;
		final renames: Null<Array<LocalRename>> = collisionRenames(loop, root, body, ifNode, thenBlock, source, s);
		return renames == null ? null : {
			ifNode: ifNode,
			thenBlock: thenBlock,
			cond: cond,
			tail: tail,
			renames: renames
		};
	}

	/**
	 * Whether `stmt` is shaped like a hoistable tail statement: an expression
	 * statement holding a plain `=` assignment of a READ-FREE literal (bool /
	 * null / numeric — never a string, whose interpolation could read state the
	 * then-branch writes) to a bare identifier. Shape only — the semantic gates
	 * live in `tailHoistSafe`. A grammar without the hoist seams never matches.
	 */
	private static function isHoistableTailStmt(stmt: QueryNode, s: Seams): Bool {
		final h: Null<HoistSeams> = s.hoist;
		if (h == null) return false;
		if (stmt.kind != h.exprStmtKind || stmt.children.length != 1) return false;
		final assign: QueryNode = stmt.children[0];
		return assign.kind == h.assignKind && assign.children.length == 2 && assign.children[0].kind == h.identKind
			&& h.literalKinds.contains(assign.children[1].kind);
	}

	/**
	 * Whether hoisting `tail` above the flagged `if` is semantics-preserving:
	 * no assigned name is the loop iterator or is mentioned ANYWHERE in the `if`
	 * (condition or then-branch, including string-interpolation reads and nested
	 * functions — a capture reads the hoisted value too), the then-branch cannot
	 * escape the iteration early (a `return` / `throw`, or a `break` / `continue`
	 * outside a nested loop, would have SKIPPED the tail on that path), and no
	 * comment sits in the dropped gaps between the `if` and the tail statements.
	 */
	private static function tailHoistSafe(
		loop: QueryNode, ifNode: QueryNode, thenBlock: QueryNode, tail: Array<QueryNode>, source: String, s: Seams
	): Bool {
		final iter: Null<String> = loop.name;
		for (t in tail) {
			final name: Null<String> = t.children[0].children[0].name;
			if (name == null || name == '' || name == iter || mentionsName(ifNode, name, s)) return false;
		}
		if (thenEscapesIteration(thenBlock, s, false)) return false;
		final ifSpan: Null<Span> = ifNode.span;
		if (ifSpan == null) return false;
		var prevTo: Int = ifSpan.to;
		for (t in tail) {
			final ts: Null<Span> = t.span;
			if (ts == null || CheckScan.hasCommentMarker(source, prevTo, ts.from)) return false;
			prevTo = ts.to;
		}
		return true;
	}

	/**
	 * Whether `node`'s subtree mentions the identifier `name` — an `identKind` or
	 * `stringInterpIdentKind` leaf with that name. Deliberately descends into
	 * nested functions (a lambda capturing the name reads the hoisted value).
	 */
	private static function mentionsName(node: QueryNode, name: String, s: Seams): Bool {
		final h: Null<HoistSeams> = s.hoist;
		return h == null || (node.kind == h.identKind || node.kind == h.interpIdentKind) && node.name == name
			|| node.children.exists(c -> mentionsName(c, name, s));
	}

	/**
	 * Whether the then-branch can leave the loop iteration early — a `return` /
	 * `throw` / grammar-specific exit anywhere (outside nested function scopes),
	 * or a `break` / `continue` NOT nested in an inner loop (an inner loop's own
	 * jumps never escape it). Such a path skipped the tail statements in the
	 * original, so hoisting them above the guard would newly execute them.
	 */
	private static function thenEscapesIteration(node: QueryNode, s: Seams, inInnerLoop: Bool): Bool {
		final h: Null<HoistSeams> = s.hoist;
		return h == null || LoopScan.escapesIteration(node, {
			loopKinds: s.loopKinds,
			doWhileKinds: s.doWhileKinds,
			opaqueKinds: s.opaqueKinds,
			nestedScopeKinds: h.nestedScopeKinds,
			hardExitKinds: h.hardExitKinds,
			loopJumpKinds: h.loopJumpKinds
		}, inInnerLoop);
	}

	/**
	 * The renames that resolve every then-branch top-level local whose name is already bound
	 * in the loop body scope at the `if` — a preceding sibling local or the loop iterator —
	 * and which de-nesting would therefore same-scope re-declare. Empty when nothing collides;
	 * null when a collision cannot be renamed away, which refuses the whole de-nest. Both
	 * sides resolve declarations through `declaredNode`, so an expression-position declaration
	 * under a metadata wrapper (`@:nullSafety(Off) var x = …`) counts too.
	 */
	private static function collisionRenames(
		loop: QueryNode, root: QueryNode, body: QueryNode, ifNode: QueryNode, thenBlock: QueryNode, source: String, s: Seams
	): Null<Array<LocalRename>> {
		final scopeNames: Array<String> = [];
		final iter: Null<String> = loop.name;
		if (iter != null && iter != '') scopeNames.push(iter);
		for (stmt in body.children) {
			if (stmt == ifNode) break;
			final n: Null<String> = declaredNode(stmt, s)?.name;
			if (n != null && n != '') scopeNames.push(n);
		}
		final renames: Array<LocalRename> = [];
		for (stmt in thenBlock.children) {
			final decl: Null<QueryNode> = declaredNode(stmt, s);
			if (decl == null) continue;
			final name: Null<String> = decl.name;
			if (name == null || name == '' || !scopeNames.contains(name)) continue;
			final rename: Null<LocalRename> = renameFor(decl, stmt, name, root, thenBlock, renames, source, s);
			if (rename == null) return null;
			renames.push(rename);
		}
		return renames;
	}

	/**
	 * The rename that moves the colliding declaration `decl` (binding `name`, declared by the
	 * top-level statement `stmt`) out of the way, or null when renaming would be unsound and
	 * the de-nest must be refused: the grammar cannot see string-interpolation reads, `name` is
	 * re-declared deeper inside the then-branch (including as a nested loop's iterator), a
	 * nested function subtree mentions it (an inner scope may own it), no `<name>2`…`<name>99`
	 * is free, an occurrence sits AHEAD of `stmt`'s end (where the name still resolves to the
	 * OUTER binding — `final path = path + '/sub';` reads the outer `path`), or the then-branch
	 * holds a standalone textual `name` no rewritten span accounts for — an invisible binder (a
	 * `catch` variable, a `k => v` value iterator, a lambda parameter) or a mention in a comment
	 * or plain string, any of which the rename would leave behind.
	 */
	private static function renameFor(
		decl: QueryNode, stmt: QueryNode, name: String, root: QueryNode, thenBlock: QueryNode, done: Array<LocalRename>, source: String,
		s: Seams
	): Null<LocalRename> {
		final h: Null<HoistSeams> = s.hoist;
		if (h == null || h.interpIdentKind == null) return null;
		if (bindsName(thenBlock, name, s, decl) || nestedScopeMentions(thenBlock, name, s)) return null;
		final newName: Null<String> = freshName(name, root, done);
		final binder: Null<Span> = binderSpan(source, decl, name);
		final thenSpan: Null<Span> = thenBlock.span;
		final stmtSpan: Null<Span> = stmt.span;
		if (newName == null || binder == null || thenSpan == null || stmtSpan == null) return null;
		final spans: Array<Span> = [binder];
		collectOccurrenceSpans(thenBlock, name, source, h, spans);
		// Everything ahead of the declaring STATEMENT's end still resolves to the OUTER
		// binding — the shadow only starts after it — so an occurrence there (the
		// initializer's own reads included) must not be renamed. Both nets: the collected
		// occurrence spans, and the raw text, which also catches a pre-binder mention the
		// grammar hides (a comment, a plain string, an invisible binder).
		for (i in 1...spans.length) if (spans[i].from < stmtSpan.to) return null;
		final innerFrom: Int = thenSpan.from + 1;
		final inner: String = source.substring(innerFrom, thenSpan.to - 1);
		final headLength: Int = stmtSpan.to - innerFrom;
		return headLength >= 0 && standaloneCount(inner.substring(0, headLength), name) == 1 && standaloneCount(inner, name) == spans.length
			? {
				name: name,
				newName: newName,
				spans: spans
			}
			: null;
	}

	/**
	 * The first `<name>2`…`<name>99` that appears NOWHERE in the parse tree as a node label and
	 * that no earlier rename in this de-nest already claimed, or null when all are taken. The
	 * scan spans the WHOLE tree, not just the loop: a class field is invisible to any local
	 * scan, yet an unqualified read of a same-named field binds to it silently.
	 */
	private static function freshName(name: String, root: QueryNode, done: Array<LocalRename>): Null<String> {
		for (k in FRESH_NAME_FIRST ... FRESH_NAME_LIMIT) {
			final candidate: String = '$name$k';
			if (!namedAnywhere(root, candidate) && !done.exists(r -> r.newName == candidate)) return candidate;
		}
		return null;
	}

	/**
	 * Whether ANY node in `node`'s subtree carries `name` as its label — a declaration, a
	 * loop iterator, an identifier, a field name, even literal text. Deliberately blunt:
	 * declaration labels are not `identKind` leaves, so an identifier scan alone would miss
	 * a class field a renamed local could silently capture.
	 */
	private static function namedAnywhere(node: QueryNode, name: String): Bool {
		return node.name == name || node.children.exists(c -> namedAnywhere(c, name));
	}

	/**
	 * Whether `node`'s subtree BINDS `name` — a local declaration (statement or
	 * expression position) or a loop iterator of that name, ignoring `except` (the
	 * declaration being renamed). Name-carrying occurrence nodes (identifiers, field
	 * names, literal text) are reads, not bindings, and never match.
	 */
	private static function bindsName(node: QueryNode, name: String, s: Seams, ?except: QueryNode): Bool {
		final binds: Bool = s.localDeclKinds.contains(node.kind) || s.localDeclExprKinds.contains(node.kind) || isLoop(node, s);
		return binds && node.name == name && node != except || node.children.exists(c -> bindsName(c, name, s, except));
	}

	/** Whether a nested function / lambda subtree inside `node` mentions `name` — that inner scope may own it. */
	private static function nestedScopeMentions(node: QueryNode, name: String, s: Seams): Bool {
		final h: Null<HoistSeams> = s.hoist;
		return h == null
			|| node.children.exists(c -> h.nestedScopeKinds.contains(c.kind) ? mentionsName(c, name, s) : nestedScopeMentions(c, name, s));
	}

	/**
	 * The span of the binder token inside a declaration node — `RefactorSupport.binderTokenSpan`
	 * over the declaration's own span. The declaration node starts at the `var` / `final`
	 * keyword — a metadata wrapper projects as a separate sibling — so nothing ahead of the
	 * binder can hold the name. Null when the grammar's span does not cover it.
	 */
	private static function binderSpan(source: String, decl: QueryNode, name: String): Null<Span> {
		final span: Null<Span> = decl.span;
		return span == null ? null : OccurrenceScan.binderTokenSpan(source, span.from, span.to, name);
	}

	/** Append the span of every `name` read in `node`'s subtree — a plain identifier, or the identifier of a `$name` interpolation. */
	private static function collectOccurrenceSpans(node: QueryNode, name: String, source: String, h: HoistSeams, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		if (span != null && node.name == name) {
			if (node.kind == h.identKind)
				out.push(span);
			else if (node.kind == h.interpIdentKind)
				out.push(interpNameSpan(source, span, name));
		}
		for (c in node.children) collectOccurrenceSpans(c, name, source, h, out);
	}

	/**
	 * The identifier-only span of a `$name` string-interpolation read, whose node span
	 * INCLUDES the `$` sigil (`'x/$p'` projects the interpolation over `$p`, not `p`) —
	 * narrowing it keeps the sigil in place when the name is spliced. A grammar whose span
	 * already excludes the sigil is returned unchanged.
	 */
	private static function interpNameSpan(source: String, span: Span, name: String): Span {
		return span.to - span.from == name.length + 1 && source.charAt(span.from) == '$' ? new Span(span.from + 1, span.to) : span;
	}

	/** How many standalone `name` tokens (a non-word character or the text edge on both sides) `text` holds. */
	private static function standaloneCount(text: String, name: String): Int {
		var count: Int = 0;
		var at: Int = text.indexOf(name);
		while (at != -1) {
			if (isStandaloneAt(text, at, name.length)) count++;
			at = text.indexOf(name, at + 1);
		}
		return count;
	}

	/** Whether the `length` characters of `text` at `at` are flanked by non-word characters (or the text edge). */
	private static function isStandaloneAt(text: String, at: Int, length: Int): Bool {
		return !isWordCode(text.charCodeAt(at - 1)) && !isWordCode(text.charCodeAt(at + length));
	}

	/** Whether `code` is an identifier character; a null code (out of range) is a boundary, not a word character. */
	private static function isWordCode(code: Null<Int>): Bool {
		return code != null
			&& (code >= '0'.code && code <= '9'.code || code >= 'A'.code && code <= 'Z'.code || code >= 'a'.code && code <= 'z'.code
				|| code == '_'.code);
	}

	/** Whether a comment sits in the dropped `if (` or `) {` glue (a comment in the condition or the then-body is preserved and does NOT refuse). */
	private static function headerHasComment(source: String, ifNode: QueryNode, cond: QueryNode, thenBlock: QueryNode): Bool {
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = cond.span;
		final thenSpan: Null<Span> = thenBlock.span;
		if (ifSpan == null || condSpan == null || thenSpan == null) return true;
		final headerGap: Bool = CheckScan.hasCommentMarker(source, ifSpan.from, condSpan.from);
		return headerGap || CheckScan.hasCommentMarker(source, condSpan.to, thenSpan.from);
	}

	/**
	 * Replace the flagged `if` (and its hoisted tail, when present) with the tail
	 * statements, an `if (!cond) continue;` guard, and the then-branch's inner
	 * statements (the writer re-indents the de-nested run).
	 */
	private static function editFor(
		m: Candidate, source: String, s: Seams, ?types: (QueryNode) -> Null<String>
	): Null<{ span: Span, text: String }> {
		final ifSpan: Null<Span> = m.ifNode.span;
		final thenSpan: Null<Span> = m.thenBlock.span;
		if (ifSpan == null || thenSpan == null) return null;
		final neg: String = NegationScan.negateConditionText(m.cond, source, s.negation, s.support, types);
		final innerFrom: Int = thenSpan.from + 1;
		final inner: String = StringTools.rtrim(applyRenames(source.substring(innerFrom, thenSpan.to - 1), innerFrom, m.renames));
		var to: Int = ifSpan.to;
		final hoisted: StringBuf = new StringBuf();
		for (t in m.tail) {
			final span: Null<Span> = t.span;
			if (span == null) return null;
			hoisted.add(source.substring(span.from, span.to));
			hoisted.add('\n');
			to = span.to;
		}
		return { span: new Span(ifSpan.from, to), text: '${hoisted.toString()}if ($neg) continue;$inner' };
	}

	/**
	 * Splice each rename's new name over its spans inside `inner`, whose first character sits
	 * at absolute offset `from`. Rightmost first, so the earlier offsets stay valid.
	 */
	private static function applyRenames(inner: String, from: Int, renames: Array<LocalRename>): String {
		final edits: Array<{ span: Span, text: String }> = [
			for (r in renames) for (span in r.spans) if (span.from >= from && span.to <= from + inner.length)
				{ span: span, text: r.newName }
		];
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = inner;
		for (e in edits) out = out.substring(0, e.span.from - from) + e.text + out.substring(e.span.to - from);
		return out;
	}

	/**
	 * Whether `loop-guard` CLAIMS this loop — its leading `if (g) continue;` guard is one that rule
	 * LIFTS into the loop header. Where it does, this check must stay silent: the lift moves the
	 * trailing `if` inside the emitted header's block, out of the loop's own statement list, so this
	 * check could never reach it again, and reporting both told the reader to do opposite things.
	 *
	 * FIVE conjuncts, and the list is meant to be exhaustive — a missing one silences BOTH rules on a
	 * site, which is the failure this predicate exists to prevent and which it shipped with twice in
	 * review. Two are about REACH: `loop-guard` reads `loopStatementKinds` only, so a `do … while` is
	 * never its business (measured — deferring on one left the site reported by nobody), and its LIFT
	 * arm demands the body be exactly `blockStmtKind` where this check accepts any block kind. Three
	 * are about the SITE: `LoopScan.leadingContinueGuard` for the body-level shape (guard first, no
	 * cascade after it, no comment before or inside it), `IfExpressionChain.childShielded`'s flag for
	 * the dangling-`else` position gate, and `NegationScan.negationIsClean` for the inversion the
	 * lifted header has to emit. Dropping either of the last two makes this check defer where
	 * `loop-guard` declines — measured at 14 such sites over 13251 external files, every one an
	 * ordered-comparison guard whose flip the negation engine refuses.
	 *
	 * What it does NOT ask is whether `loop-guard` is ENABLED. A config that disables it, or a
	 * `--rule guard-continue` run, therefore silences this shape entirely. That is the same trade every
	 * rule-to-rule deferral in the tree makes; the alternative is reading another rule's enablement,
	 * which no check does.
	 */
	private static function loopGuardClaims(
		loop: QueryNode, body: QueryNode, source: String, s: Seams, shielded: Bool, ?types: (QueryNode) -> Null<String>
	): Bool {
		if (!s.loopKinds.contains(loop.kind) || body.kind != s.blockStmtKind || !shielded) return false;
		final guard: Null<QueryNode> = LoopScan.leadingContinueGuard(body, source, s.ifKinds, s.blockStmtKind, s.continueKind);
		return guard != null && NegationScan.negationIsClean(guard.children[0], source, s.support, types);
	}

}

/** The `RefShape` kinds `GuardContinue` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var loopKinds: Array<String>;
	var doWhileKinds: Array<String>;
	var ifKinds: Array<String>;
	var blockKinds: Array<String>;

	/**
	 * The block kind `loop-guard`'s LIFT arm demands EXACTLY — narrower than `blockKinds`, which is
	 * what this check accepts — and the one `LoopScan.leadingContinueGuard` reads for a braced
	 * `{ continue; }`. Nullable because this check works without it; `loop-guard` does not.
	 */
	var blockStmtKind: Null<String>;

	/** The `continue` statement kind, required: without it this check has no guard form to emit. */
	var continueKind: String;
	var localDeclKinds: Array<String>;
	var localDeclExprKinds: Array<String>;
	var metaKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var hoist: Null<HoistSeams>;
	var negation: NegationSeams;

	/** The dangling-`else` position gate's inputs — read only to mirror `loop-guard`'s own claim. */
	var shield: ShieldSeams;

	var support: Null<BooleanLogicSupport>;
}

/**
 * The optional seams the hoistable-tail extension reads; null disables the hoist (strict tail position only).
 */
private typedef HoistSeams = {
	var exprStmtKind: String;
	var assignKind: String;
	var identKind: String;
	var interpIdentKind: Null<String>;
	var literalKinds: Array<String>;
	var hardExitKinds: Array<String>;
	var loopJumpKinds: Array<String>;
	var nestedScopeKinds: Array<String>;
}

/**
 * A matched loop guard: the trailing `if` statement, its braced then-branch, its
 * condition, the hoistable tail statements following the `if` (empty when it is the
 * exact last statement), and the collision renames the de-nested block needs (empty
 * when no de-nested local clashes with the surrounding scope).
 */
private typedef Candidate = {
	var ifNode: QueryNode;
	var thenBlock: QueryNode;
	var cond: QueryNode;
	var tail: Array<QueryNode>;
	var renames: Array<LocalRename>;
}

/**
 * One de-nested local renamed out of a scope collision: the name it binds, the
 * mechanically fresh replacement, and every absolute span to splice that replacement
 * over — the declaration's binder token plus each read, a plain identifier or the
 * identifier of a `$name` interpolation (the `$` itself is outside the span).
 */
private typedef LocalRename = {
	var name: String;
	var newName: String;
	var spans: Array<Span>;
}
