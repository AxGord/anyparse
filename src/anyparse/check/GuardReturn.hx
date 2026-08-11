package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags a trailing `if (cond) { BLOCK }` (no `else`) whose fall-through is a `return`, and
 * INVERTS it into an early-return guard so the bulk of the work sheds an indentation level.
 * Two arms, one rewrite:
 *
 *  - the EXPLICIT PAIR - the block's LAST TWO statements are the `if` and a lone
 *    `return TAIL;`: `if (cond) { BLOCK } return TAIL;` -> `if (!cond) return TAIL; BLOCK`;
 *  - the IMPLICIT TAIL - the `if` is the LAST statement of a provably-Void FUNCTION BODY, so
 *    the fall-through is the end of the function: `if (cond) { BLOCK }` ->
 *    `if (!cond) return; BLOCK`.
 *
 * The user's rule (preferences): a guard clause reads better than a positive branch
 * wrapping the whole body. `Severity.Info`, with an autofix. Runs to a fixpoint, so a
 * two-level `if (p) { if (q) { … return 1; } return 2; } return 3;` flattens over two
 * `--fix` passes - and so does a nested pair of Void tails, the outer `if` becoming a guard on
 * the first pass and exposing the inner one as the new tail for the second.
 *
 * The check reads the BRANCH-AWARE projection (`CheckScan.parseBranchAwareOrNull`), so one
 * conditional-compilation branch is a statement list of its own and a trailing `if` + `return`
 * guarded by `#if` inverts like any other. Only statements of the SAME branch are ever
 * siblings, so the rewritten span can never splice across a `#else` / `#end` directive. On the
 * explicit-pair arm no tail-position gate is needed on top: the then-branch is TERMINAL by gate
 * and the inverted guard either returns or falls into that terminal run, so BOTH forms exit
 * unconditionally and whatever follows the `#end` is exactly as unreachable after the fix as it
 * was before it. The implicit-tail arm carries a tail-position model of its own, below.
 *
 * ## The `if (!cond)` inversion - De Morgan when possible, order-safe
 *
 * `cond` is negated by `NegationScan.negateConditionText`, the engine `loop-guard` and
 * `guard-continue` share, two-tier. When the grammar exposes a `BooleanLogicSupport` and
 * the condition span is comment-free, the negation is pushed inward by De Morgan
 * (`a && b` -> `!a || !b`, `!(a || b)` -> `a && b`, `==` / `!=` flipped NaN-safely), with the
 * ordered comparisons `< <= > >=` deliberately KEPT wrapped `!(a < b)` - flipped only where
 * the operand types prove both totally ordered, since `!(a < b)` and `a >= b` differ whenever
 * an operand is a NaN or a `null`. Falling back - a seam-less grammar, or a comment in the
 * condition the De Morgan rewrite would drop - the text engine wraps `!(cond)` VERBATIM.
 * Either tier is sound and compiles.
 *
 * ### Stranded narrowings REGROUP on the De Morgan path
 *
 * De Morgan turns an `&&` chain into an `||` chain, and Haxe's strict null-safety carries a
 * narrowing fact into a later `||` operand from the chain's FIRST operand ONLY. So a flat
 * `a == null || b == null || p(a.length, b.length)` does not compile - `b` is no longer
 * narrowed - while the right-nested `a == null || (b == null || p(a.length, b.length))`
 * narrows fine (both measured on the compiler, including a fact crossing INTO a later
 * group). The shared engine therefore right-nests a parenthesised group at every operand
 * whose fact a flat chain would strand (`HaxeBooleanLogicSupport.negateAndChain`), so
 * `loop-guard`, `guard-continue` and this check all emit the grouped De Morgan instead of
 * falling back to a verbatim wrap.
 *
 * ## The implicit-tail arm
 *
 * A bare `if (cond) { BLOCK }` that is the LAST statement of a function's block body becomes
 * `if (<negated cond>) return;` plus the de-nested `BLOCK`. There is no `return` to move, so
 * the rewritten span ends at the `if` and the inserted guard returns no value - the literal
 * `return;`, the same convention `guard-continue` follows for `continue;`.
 *
 * ### Tail position
 *
 * `childTailFn` threads the enclosing function down the tree, and only along the chain that
 * really is a tail. A function opens the chain at its block body; a statement list keeps it
 * only for a `#if` region that is its LAST statement, and a region hands it to every one of
 * its `CondBranch`es - the branches of a region are MUTUALLY EXCLUSIVE configurations, so each
 * is the tail in its own configuration, while a region that is NOT last is no tail at all
 * (the statements after its `#end` would be skipped by the inserted `return`). Everything else
 * - a loop body, a nested `{ … }` block, an `if`'s own then-branch - drops the chain, which is
 * why a trailing `if` inside a `while` stays `guard-continue`'s turf and why nested Void tails
 * flatten one level per `--fix` pass rather than all at once.
 *
 * ### The Void proof
 *
 * `returnsNothing` proves that a bare `return;` compiles in the function whose tail the `if`
 * sits in. A function with no declared return type qualifies when its OWN scope holds no
 * value-`return` (nested functions and lambdas excluded): that infers `Void`, a block body does
 * not yield its last expression's value, and a `throw`-only body infers `Void` too - so, unlike
 * `explicit-type`'s `: Void` inference, no throw guard is needed. A function that DOES declare
 * a return type qualifies only when that annotation's source text is exactly `voidTypeName`,
 * and that branch is the safety gate rather than a shortcut:
 * `function f(): Int { throw 'x'; if (c) { a(); b(); } }` COMPILES, has no value-`return`, and
 * a `return;` spliced into it does not. Constructors qualify through the inference branch.
 *
 * Whether a function declares one at all is `CheckScan.returnAnnotationText`, shared with
 * `redundant-cast-type`: a type-parameter CONSTRAINT projects the same node kind in the same
 * child slot, so the two are told apart by POSITION relative to the parameter list. Reading a
 * constraint as an annotation is not a harmless miss here - `<T: Void>` is legal Haxe and would
 * PROVE Void on a function that is not one.
 *
 * LAMBDAS ARE DELIBERATELY EXCLUDED - `functionKinds` names none of them, and `childTailFn`
 * opens a tail only at a `functionKinds` node. An arrow function with a block body DOES yield
 * its last expression's value (`var g = () -> { 42; }; var x: Int = g();` compiles), so
 * de-nesting could silently change its inferred return type from `Void` to the last statement's
 * and make the inserted `return;` illegal. `FnExpr` (`function() { … }`) measurably does NOT
 * carry that hazard, but is left out with the rest of the lambda family for one uniform rule.
 *
 * ## Gates
 *
 * On the explicit-pair arm the two statements must be the block's last two, in that order - a
 * statement BETWEEN the `if` and the `return` means the `return` is not the `if`'s
 * fall-through, and the inversion would reorder it. The `if` must be statement-position
 * (`ifStatementKinds` excludes an expression-position `if`) with NO `else` (an `else` branch
 * the guard form would lose) and a BRACED then-branch that
 *
 *  - is TERMINAL - its last statement unconditionally exits the block
 *    (`ControlFlowSupport.isTerminal`: `return` / `throw` / `break` / `continue`). Without
 *    it, falling off the end of the then-branch reached the trailing `return` in the
 *    original and would fall out of the enclosing block after the de-nest. A `break` /
 *    `continue` is sound too: de-nesting out of an `if` crosses no loop or `switch`
 *    boundary, so the jump keeps its target. This is the ONE gate the implicit-tail arm does
 *    not share: there the "tail" IS falling off the end of the function body, which is exactly
 *    where the de-nested run now ends, so both forms exit identically and the gate has nothing
 *    to protect - and a `break` / `continue` hazard cannot arise, a function body (or a
 *    `CondBranch` in its tail) never being inside a loop of that same function;
 *  - holds at least TWO statements. A one-statement then-branch
 *    (`if (c) { return a; } return b;`) is `prefer-ternary-return`'s shape - a turf split,
 *    not a correctness gate - and this check does not fight it.
 *
 * Additionally refused:
 *
 *  - a conditional-compilation region (`RefactorSupport.isConditionalKind`) anywhere in the
 *    rewritten span, or a `#` directive in the gap between the `if` and the `return`: the
 *    de-nested run changes indentation level, and a `#if` interior is preserved raw. A
 *    `CondBranch` is not such a region - it is the statement list the pair sits IN, and the
 *    splitter guarantees no directive falls between the statements of one run;
 *  - a comment in the dropped `if (` or `) {` glue, or in the gap between the `if` and the
 *    trailing `return`, or trailing the rewritten span's last node on its own line - each
 *    would move away from what it documents. On the implicit-tail arm that last check is what
 *    refuses a `} // note` on the `if`'s closing brace, a comment that would otherwise end up
 *    documenting the last de-nested statement. A comment INSIDE the condition, INSIDE the
 *    then-branch or INSIDE the returned expression rides along verbatim and does NOT refuse;
 *  - a top-level then-branch local whose name is already bound where the de-nested run would
 *    land: de-nesting would turn a nested shadow into a same-scope re-declaration (a
 *    `-D no-shadowing` hazard). `ScopeFrames` supplies that set - the enclosing function's
 *    parameters plus the frame of every enclosing statement list the de-nest cannot shadow -
 *    so inside a `#if` branch the enclosing block's locals and a local declared in a
 *    DIFFERENT `#if` region of the same block both count, while a SIBLING branch's never do
 *    (mutually exclusive configurations). The `if`'s own preceding siblings are unioned on
 *    separately, through `declaredNode`, which also sees an expression-position declaration
 *    under a metadata wrapper. Unlike `guard-continue` this check refuses rather than
 *    auto-renaming - the shape has no tail to hoist and the collision is rare here.
 *
 * Every OTHER binding stays where it was: the de-nested statements land at the END of the
 * enclosing statement list, so nothing after them can bind to a widened local, and the moved
 * `return TAIL` sits AHEAD of every then-branch declaration, so it still reads the outer
 * binding it read before.
 *
 * ## Grammar-agnostic
 *
 * Driven by `ifStatementKinds`, the return kinds (`returnStatementKind` /
 * `valueReturnKinds` / `voidReturnKind`) and `ControlFlowSupport` (any unset -> no-op),
 * plus `localDeclKinds` / `localDeclExprKinds` and `MetaShape.metaKinds` (the collision
 * gate), `scopeKinds` / `functionKinds` / `conditionalMemberKind` (the `ScopeFrames` set it
 * gates against, and the tail-position chain), `opaqueKinds` (skip macro reification),
 * `logicalAndKind` / `logicalOrKind` (the stranded-narrowing gate), and the `notKind` /
 * `eqKind` / `notEqKind` / `parenKind` and atomic-expression kinds that shape the inversion.
 * The implicit-tail arm adds `blockBodyKind` and `voidTypeName` (the Void proof), `paramKinds` /
 * `typeAnnotationKinds` (through `CheckScan.returnAnnotationText`, telling a return annotation
 * from a type-parameter constraint) and `localFunctionKinds` / `inlineFunctionKinds` /
 * `lambdaKinds` (the scope stop of the value-return scan); it is disabled outright unless
 * `voidReturnKind`, `blockBodyKind` and `valueReturnKinds` are all set, the explicit-pair arm
 * staying live regardless.
 */
@:nullSafety(Strict)
final class GuardReturn implements Check {

	/** A guard `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/**
	 * The fewest statements a de-nestable then-branch may hold. A ONE-statement branch is
	 * `prefer-ternary-return`'s shape (`if (c) return a;` + `return b;` → `return c ? a : b;`),
	 * left to that check.
	 */
	private static inline final MIN_THEN_STATEMENTS: Int = 2;

	/**
	 * The enclosing block must hold at least the flagged `if` and the trailing `return`. The
	 * implicit-tail arm has no trailing `return` and so needs only the `if` - it checks for that
	 * one statement directly rather than through this constant.
	 */
	private static inline final MIN_BLOCK_STATEMENTS: Int = 2;

	public function new() {}

	public function id(): String {
		return 'guard-return';
	}

	public function description(): String {
		return 'a trailing if whose braced branch precedes a lone return, or ends a Void body, invertible to an early-return guard';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final read: Null<Seams> = readSeams(plugin);
		if (read == null) return [];
		final s: Seams = read;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, entry.source);
			if (tree == null) continue;
			final file: String = entry.file;
			final source: String = entry.source;
			final types: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, file);
			walk(tree, source, s, [], null, m -> {
				// An inversion that cannot shed its `!( … )` wrap reads worse than the positive
				// branch it replaces — the whole point of the guard form is lost, so skip the site.
				final span: Null<Span> = m.ifNode.span;
				if (span != null && NegationScan.negationIsClean(m.cond, source, s.logic, types)) violations.push({
					file: file,
					span: span,
					rule: 'guard-return',
					severity: Severity.Info,
					message: 'this trailing if can invert into an early-return guard'
				});
			});
		}
		return violations;
	}

	/** Invert each flagged trailing `if` into an `if (!cond) return TAIL;` guard, de-nesting its then-branch. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) return [];
		final byIf: Map<String, Candidate> = [];
		walk(tree, source, seams, [], null, m -> {
			final span: Null<Span> = m.ifNode.span;
			if (span != null) byIf['${span.from}:${span.to}'] = m;
		});
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
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return null;
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (flow == null) return null;
		final voidReturnKind: Null<String> = shape.voidReturnKind;
		final blockBodyKind: Null<String> = shape.blockBodyKind;
		final valueReturnKinds: Array<String> = shape.valueReturnKinds ?? [];
		final returnKinds: Array<String> = [];
		for (k in [
			(shape.returnStatementKind: Null<String>),
			voidReturnKind
		]) if (k != null && !returnKinds.contains(k)) returnKinds.push(k);
		for (k in valueReturnKinds) if (!returnKinds.contains(k)) returnKinds.push(k);
		return returnKinds.length == 0 ? null : {
			ifKinds: ifKinds,
			returnKinds: returnKinds,
			blockKinds: flow.blockKinds(),
			flow: flow,
			localDeclKinds: shape.localDeclKinds ?? [],
			localDeclExprKinds: shape.localDeclExprKinds ?? [],
			metaKinds: plugin.metaShape().metaKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			scopeKinds: shape.scopeKinds,
			functionKinds: shape.functionKinds ?? [],
			voidTypeName: shape.voidTypeName,
			blockBodyKind: blockBodyKind,
			valueReturnKinds: valueReturnKinds,
			returnScopeStop: (shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []).concat(shape.lambdaKinds ?? []),
			shape: shape,
			implicitTailEnabled: voidReturnKind != null && blockBodyKind != null && valueReturnKinds.length > 0,
			condKind: shape.conditionalMemberKind,
			negation: NegationScan.negationSeams(shape),
			logic: plugin.booleanLogicSupport()
		};
	}

	/**
	 * Walk `node`, handing every matched candidate to `sink`. `run` and `fix` differ only in what
	 * they do with one — push a violation or index it by span — so the traversal, the `ScopeFrames`
	 * threading and the `childTailFn` chain live here once.
	 */
	private static function walk(
		node: QueryNode, source: String, s: Seams, inherited: Array<String>, tailFn: Null<QueryNode>, sink: (Candidate) -> Void
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		final scopeNames: Array<String> = ScopeFrames.ownScopeNames(node, s, inherited);
		if (s.blockKinds.contains(node.kind)) {
			final m: Null<Candidate> = match(node, source, s, scopeNames, tailFn);
			if (m != null) sink(m);
		}
		final ownParams: Null<Array<String>> = ScopeFrames.ownParamNames(node, s);
		for (i in 0...node.children.length) {
			final c: QueryNode = node.children[i];
			walk(
				c, source, s, ScopeFrames.childScopeNames(node, c, s, inherited, scopeNames, ownParams),
				childTailFn(node, c, i, s, tailFn), sink
			);
		}
	}

	/**
	 * The enclosing function to thread down to `child`, or null: non-null exactly when `child`
	 * is a statement list occupying that function's IMPLICIT-TAIL position, where `tailFn` is
	 * the function whose tail `node` itself sits in (null when it sits in none).
	 *
	 * A function opens a chain at its block body and nowhere else, and `functionKinds` is
	 * tested FIRST, so a nested function RESETS the chain instead of inheriting its host's.
	 * In the branch-aware projection a `#if` region is `Conditional > CondBranch > statements`,
	 * and the branches of one region are MUTUALLY EXCLUSIVE configurations - so EVERY branch of
	 * a tail-position region is itself a tail, while a region that is NOT the block's last
	 * statement is not (the statements after its `#end` would be skipped by the inserted
	 * `return`).
	 *
	 * A region only hands the chain on when EVERY one of its children is a statement list. That is
	 * how a PROJECTED region looks (all `CondBranch`); when the projection's splitter refuses a
	 * shape the region keeps its raw statement children, and handing the tail to one of those that
	 * happened to be a nested `{ … }` block would let the inserted `return` skip its siblings.
	 */
	private static function childTailFn(node: QueryNode, child: QueryNode, index: Int, s: Seams, tailFn: Null<QueryNode>): Null<QueryNode> {
		return if (s.functionKinds.contains(node.kind))
			child.kind == s.blockBodyKind ? node : null
		else if (tailFn == null)
			null
		else if (node.kind == s.condKind)
			node.children.foreach(c -> s.blockKinds.contains(c.kind)) ? tailFn : null
		else if (s.blockKinds.contains(node.kind) && index == node.children.length - 1 && child.kind == s.condKind)
			tailFn
		else
			null;
	}

	/**
	 * The invertible candidate `block` holds, or null. Two arms, tried in order:
	 *
	 *  - the EXPLICIT PAIR - `block`'s last two statements are a bare `if (c) { … }` (no `else`,
	 *    braced, terminal, >= 2 statements) and a lone trailing `return`;
	 *  - the IMPLICIT TAIL - `block` IS the implicit-tail statement list of `tailFn`, that
	 *    function provably returns nothing (`returnsNothing`), and `block`'s LAST statement is
	 *    such an `if`. The candidate's `tail` is then null and the guard returns no value.
	 *
	 * Every gate but the terminal one is shared between the arms - see `gatedCandidate`.
	 */
	private static function match(
		block: QueryNode, source: String, s: Seams, scopeNames: Array<String>, tailFn: Null<QueryNode>
	): Null<Candidate> {
		final stmts: Array<QueryNode> = block.children;
		if (stmts.length >= MIN_BLOCK_STATEMENTS && s.returnKinds.contains(stmts[stmts.length - 1].kind)) {
			final pair: Null<Candidate> = gatedCandidate(block, stmts[stmts.length - 2], stmts[stmts.length - 1], s, source, scopeNames);
			if (pair != null) return pair;
		}
		// The implicit-tail arm needs ONE statement, the `if` itself — `MIN_BLOCK_STATEMENTS`
		// counts the explicit pair.
		if (!s.implicitTailEnabled || tailFn == null || stmts.length == 0) return null;
		// The gates are pure predicates, so the Void proof runs LAST: it walks the whole body
		// looking for a value `return`, and every tail-position block would pay for that walk
		// even when its last statement is not an `if` at all.
		final solo: Null<Candidate> = gatedCandidate(block, stmts[stmts.length - 1], null, s, source, scopeNames);
		return solo != null && returnsNothing(tailFn, s, source) ? solo : null;
	}

	/**
	 * The candidate `ifNode` (paired with `tail`, or null on the implicit-tail arm) once every
	 * SHARED gate holds, else null: a statement-position `if` with no `else`, a braced
	 * then-branch of at least `MIN_THEN_STATEMENTS`, no conditional-compilation region in the
	 * rewritten span, no comment the rewrite would strand, and no de-nested local that would
	 * same-scope re-declare a name already bound where the run lands.
	 *
	 * The TERMINAL gate is the one that is NOT shared - it applies only when there IS a `tail`.
	 * The explicit-pair arm needs it because falling off the end of the then-branch reached that
	 * trailing `return` in the original and would fall out of the enclosing block after the
	 * de-nest. On the implicit-tail arm the "tail" IS falling off the end of the function body,
	 * which is exactly where the de-nested run now ends - both forms exit identically and the
	 * gate has nothing left to protect (keeping it would reject the arm's own reference shape,
	 * whose then-branch ends in a plain call). No `break` / `continue` hazard takes its place: a
	 * function body - or a `CondBranch` in its tail - is never inside a loop of that same
	 * function.
	 */
	private static function gatedCandidate(
		block: QueryNode, ifNode: QueryNode, tail: Null<QueryNode>, s: Seams, source: String, scopeNames: Array<String>
	): Null<Candidate> {
		if (!s.ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final cond: QueryNode = ifNode.children[0];
		final thenBlock: QueryNode = ifNode.children[1];
		if (!s.blockKinds.contains(thenBlock.kind) || thenBlock.children.length < MIN_THEN_STATEMENTS) return null;
		if (tail != null && !s.flow.isTerminal(thenBlock.children[thenBlock.children.length - 1])) return null;
		if (hasConditionalRegion(ifNode) || (tail != null && hasConditionalRegion(tail))) return null;
		final blocked: Bool = spanCommentBlocked(source, ifNode, cond, thenBlock, tail ?? ifNode)
			|| redeclaresSibling(block, ifNode, thenBlock, s, scopeNames);
		return blocked ? null : {
			ifNode: ifNode,
			thenBlock: thenBlock,
			cond: cond,
			tail: tail
		};
	}

	/**
	 * Whether `fn` provably returns NO value, so inserting a bare `return;` into its body
	 * compiles. Two branches, and the DECLARED one is the safety gate rather than a shortcut:
	 *
	 *  - no declared return type -> the function's OWN scope (nested functions and lambdas
	 *    excluded via `returnScopeStop`) must hold no value-`return`. A block-bodied function
	 *    with none infers `Void`, and a block body does NOT yield its last expression's value,
	 *    so the inference is safe; a `throw`-only body infers `Void` too (measured), which is
	 *    why - unlike `explicit-type`, which ANNOTATES rather than inserting a return - no
	 *    throw guard is needed;
	 *  - a declared return type -> its SOURCE TEXT must be exactly `voidTypeName`. Without this
	 *    branch `function f(): Int { throw 'x'; if (c) { a(); b(); } }` would qualify: it
	 *    COMPILES (the trailing `if` is unreachable) and holds no value-`return`, and a
	 *    `return;` spliced into it does not.
	 *
	 * "Declared" is `CheckScan.returnAnnotationText`, shared with `redundant-cast-type`, which asks
	 * the same question and had already paid for the answer: the grammar projects a type-parameter
	 * CONSTRAINT (`function f<T: Foo>()`) as the very same node kind in the very same child slot,
	 * always ahead of the parameter list, so the annotation is told from it by POSITION. That is
	 * load-bearing here rather than cosmetic - `<T: Void>` is legal Haxe, and reading that
	 * constraint as an annotation would PROVE Void on a function that is not one.
	 *
	 * A constructor qualifies through the inference branch - it carries no return-type child
	 * and no value return, and a bare `return;` is legal in one.
	 */
	private static function returnsNothing(fn: QueryNode, s: Seams, source: String): Bool {
		final body: Null<QueryNode> = fn.children.find(c -> c.kind == s.blockBodyKind);
		if (body == null) return false;
		final declared: Null<String> = CheckScan.returnAnnotationText(fn, s.shape, source);
		return declared == null
			? !RefactorSupport.subtreeContainsKindStopping(body, s.valueReturnKinds, s.returnScopeStop)
			: declared == s.voidTypeName;
	}

	/** Whether `node`'s subtree holds a `#if … #end` region, whose raw-preserved interior the re-indenting de-nest must not move. */
	private static function hasConditionalRegion(node: QueryNode): Bool {
		if (RefactorSupport.isConditionalKind(node.kind)) return true;
		for (c in node.children) if (hasConditionalRegion(c)) return true;
		return false;
	}

	/**
	 * Whether a comment (or a `#` directive) sits anywhere the rewrite would move it away from
	 * what it documents: the dropped `if (` / `) {` glue, the gap between the `if` and `endNode`,
	 * or the rest of `endNode`'s own line. Comments INSIDE the condition, the then-branch or the
	 * returned expression ride along verbatim.
	 *
	 * `endNode` is the node whose end terminates the rewritten span - the trailing `return` on the
	 * explicit-pair arm, the `if` itself on the implicit-tail arm. On the latter the gap check is
	 * empty, while the rest-of-the-line check still refuses a `} // note` trailing the `if`'s
	 * closing brace, a comment that would otherwise end up documenting the last de-nested
	 * statement.
	 */
	private static function spanCommentBlocked(
		source: String, ifNode: QueryNode, cond: QueryNode, thenBlock: QueryNode, endNode: QueryNode
	): Bool {
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = cond.span;
		final thenSpan: Null<Span> = thenBlock.span;
		final endSpan: Null<Span> = endNode.span;
		if (ifSpan == null || condSpan == null || thenSpan == null || endSpan == null) return true;
		if (CheckScan.hasCommentMarker(source, ifSpan.from, condSpan.from)) return true;
		if (CheckScan.hasCommentMarker(source, condSpan.to, thenSpan.from)) return true;
		// On the implicit-tail arm `endNode` IS the `if`, so the gap degenerates to an empty
		// range and both checks fall away — nothing sits between the `if` and itself. Guarded
		// rather than sliced: `String.substring` SWAPS a reversed pair and would hand back the
		// whole `if`.
		if (endSpan.from > ifSpan.to) {
			final gap: String = source.substring(ifSpan.to, endSpan.from);
			if (gap.indexOf('#') != -1 || CheckScan.hasCommentMarker(source, ifSpan.to, endSpan.from)) return true;
		}
		final lineEnd: Int = source.indexOf('\n', endSpan.to);
		return CheckScan.hasCommentMarker(source, endSpan.to, lineEnd == -1 ? source.length : lineEnd);
	}

	/**
	 * Whether a top-level then-branch local re-declares a name already bound where the de-nested
	 * run would land - de-nesting would widen the nested shadow into a same-scope re-declaration.
	 *
	 * `scopeNames` is what `ScopeFrames` threaded down to this statement list: the enclosing
	 * function's parameters plus the frame of every enclosing list the de-nest cannot shadow. In
	 * the branch-aware tree that is what lets a `CondBranch` see the enclosing block's locals and
	 * a local declared in a DIFFERENT `#if` region of the same block, neither of which is a
	 * sibling of the flagged `if`. The `if`'s own PRECEDING siblings are unioned on separately
	 * because they resolve through `declaredNode`, which also sees an expression-position
	 * declaration under a metadata wrapper that the frame scan does not.
	 */
	private static function redeclaresSibling(
		block: QueryNode, ifNode: QueryNode, thenBlock: QueryNode, s: Seams, scopeNames: Array<String>
	): Bool {
		final names: Array<String> = scopeNames.copy();
		for (stmt in block.children) {
			if (stmt == ifNode) break;
			final n: Null<String> = declaredNode(stmt, s)?.name;
			if (n != null && n != '' && !names.contains(n)) names.push(n);
		}
		if (names.length == 0) return false;
		for (stmt in thenBlock.children) {
			final n: Null<String> = declaredNode(stmt, s)?.name;
			if (n != null && names.contains(n)) return true;
		}
		return false;
	}

	/** The local declaration node a top-level statement holds, or null — see `RefactorSupport.topLevelDeclaredNode`. */
	private static inline function declaredNode(stmt: QueryNode, s: Seams): Null<QueryNode> {
		return RefactorSupport.topLevelDeclaredNode(stmt, s.localDeclKinds, s.localDeclExprKinds, s.metaKinds);
	}

	/**
	 * Replace the flagged `if` - together with the trailing `return` when there is one - with an
	 * `if (!cond) return …;` guard followed by the then-branch's inner statements (the writer
	 * re-indents the de-nested run).
	 *
	 * The implicit-tail arm emits the literal `return;`, the family convention: `guard-continue`
	 * likewise gates on a seam (`continueStatementKind`) and then emits the literal `continue;`.
	 */
	private static function editFor(
		m: Candidate, source: String, s: Seams, ?types: (QueryNode) -> Null<String>
	): Null<{ span: Span, text: String }> {
		final ifSpan: Null<Span> = m.ifNode.span;
		final thenSpan: Null<Span> = m.thenBlock.span;
		if (ifSpan == null || thenSpan == null) return null;
		final neg: String = NegationScan.negateConditionText(m.cond, source, s.negation, s.logic, types);
		final inner: String = source.substring(thenSpan.from + 1, thenSpan.to - 1).rtrim();
		final tail: Null<QueryNode> = m.tail;
		if (tail == null) return { span: new Span(ifSpan.from, ifSpan.to), text: 'if ($neg) return;$inner' };
		final tailSpan: Null<Span> = tail.span;
		if (tailSpan == null) return null;
		final tailSource: String = source.substring(tailSpan.from, tailSpan.to);
		return { span: new Span(ifSpan.from, tailSpan.to), text: 'if ($neg) $tailSource$inner' };
	}

}

/** The `RefShape` kinds `GuardReturn` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	final ifKinds: Array<String>;
	final returnKinds: Array<String>;
	final blockKinds: Array<String>;
	final flow: ControlFlowSupport;
	final localDeclKinds: Array<String>;
	final localDeclExprKinds: Array<String>;
	final metaKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final scopeKinds: Array<String>;
	final functionKinds: Array<String>;
	final voidTypeName: Null<String>;
	final blockBodyKind: Null<String>;
	final valueReturnKinds: Array<String>;
	final returnScopeStop: Array<String>;
	final shape: RefShape;
	final implicitTailEnabled: Bool;
	final condKind: Null<String>;
	final negation: NegationSeams;
	final logic: Null<BooleanLogicSupport>;
}

/**
 * A matched guard: the flagged `if` statement, its braced then-branch, its condition, and the
 * `return` it inverts into - the lone `return` that FOLLOWS the `if` on the explicit-pair arm,
 * or null on the implicit-tail arm, where the guard returns no value and the rewritten span
 * ends at the `if` itself.
 */
private typedef Candidate = {
	var ifNode: QueryNode;
	var thenBlock: QueryNode;
	var cond: QueryNode;
	var tail: Null<QueryNode>;
}
