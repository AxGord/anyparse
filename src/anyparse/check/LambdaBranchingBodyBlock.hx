package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Flags an ARROW lambda whose body BRANCHES INTERNALLY — an `if` with an `else`, or a
 * `switch` — and is written WITHOUT a block, and wraps it back in `{ }`:
 *
 * ```haxe
 * post(payload, success -> if (success) finish(); else abort());
 * // ->
 * post(payload, success -> {
 *     if (success) finish();
 *     else abort();
 * });
 * ```
 *
 * `Info` — the code is correct; this is the ADD half of the brace policy whose REMOVE half
 * is `prefer-lambda-expression-body`. That check drops the braces around a body holding one
 * statement, and refuses exactly the population this one claims (`branchesInternally`), so
 * the two agree on the boundary and a `lint --fix` fixpoint cannot oscillate across it.
 *
 * ## Why a branching body keeps its braces
 *
 * The remove half's own criterion is that de-bracing must change nothing on the head line
 * except the `{` leaving it. That holds for a body with ONE arm. A body with several arms
 * puts its branch keywords into whatever syntactic position the lambda occupies, and in the
 * dominant position — a call argument — the result reads as one run of punctuation:
 * `success -> if (success) API.login(…); else LoadView.hideAsyncMask(),` ends a line on `;`,
 * `else`, and the argument comma, and nothing but indentation tells the reader where the
 * lambda body stops and the argument list resumes. The braces are the delimiter that
 * information needs.
 *
 * ## What is flagged
 *
 * A node of one of the ARROW lambda kinds — every `lambdaKinds` entry except `fnExprKind`,
 * the same set the remove half matches, for the same reason: the `function` literal is
 * `prefer-arrow-callback`'s to normalise first — whose BODY (its last child) is
 *
 * - NOT one of `ControlFlowSupport.blockKinds()` (a block body already has its braces), and
 * - a CONDITIONAL with an else-branch (`conditionalKinds` + the `IF_ELSE_CHILD_COUNT` child
 *   test `IfExpressionChain.isElseLessConditional` uses from the other side, so an
 *   `else if` chain is caught by its outer `if`) or a `switch` (`switchKinds`).
 *
 * An else-LESS `if`, a loop, a `throw`, a bare expression, a `return` — anything with one arm
 * — is left alone: that is the shape the remove half is allowed to produce, and re-bracing it
 * would be the oscillation this pair is designed not to have.
 *
 * So is a lambda in the TRAILING argument slot of its invocation, whatever its body branches
 * into (`isTrailingCallArg`). Nothing follows such a body but the closing `)`, so the run of
 * punctuation the braces exist to separate — `;`, `else`, and an argument comma on one line —
 * cannot form there. The remove half de-braces that slot for the same reason, and the two
 * predicates are one question asked twice: if they ever disagree, `lint --fix` de-braces and
 * re-braces the same site forever.
 *
 * ## The wrap
 *
 * `fix` replaces the body's span with `{ <body> }`, adding a `;` when the body does not
 * already end on one (an `if`/`switch` in expression position carries no terminator of its
 * own, and a block statement needs one). Trivia OUTSIDE the body span is untouched, so a
 * comment trailing the lambda stays outside the new braces; a comment INSIDE the body rides
 * along. The whole-file re-emit through `RefactorSupport.canonicalize` formats the result and
 * re-parse-validates it, so a wrap that would not parse fails loudly instead of landing.
 *
 * The wrap is semantics-preserving in both directions Haxe cares about: a block's value is
 * its last expression, and the block here holds exactly the one construct whose value the
 * body already was, so an `if`-expression body keeps its value and a `Void` body stays
 * `Void`. Nothing about the enclosing expected type has to be known — the same argument the
 * remove half documents for the opposite edit.
 *
 * ## Grammar-agnostic
 *
 * `lambdaKinds` minus `fnExprKind` are the matched kinds, `blockKinds` the bodies to skip,
 * and `conditionalKinds` / `switchKinds` the branching bodies to claim. With `conditionalKinds`
 * and `switchKinds` both unset the check is a no-op, which is the correct behaviour for a
 * grammar that declares no branching constructs.
 */
@:nullSafety(Strict)
final class LambdaBranchingBodyBlock implements Check {

	/** The rule id, spelled once — `run`, `fix` and the registry all quote it. */
	private static inline final RULE_ID: String = 'lambda-branching-body-braces';

	/** A conditional node with this many children carries an else-branch. */
	private static inline final IF_ELSE_CHILD_COUNT: Int = 3;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return
			'an arrow lambda OUTSIDE the trailing argument slot whose body branches internally (if/else, switch) but carries no block — '
				+ 'the braces delimit the branches from what follows the lambda';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		return seams == null ? [] : [
			for (entry in files) for (span in collect(plugin, entry.source, seams))
				{
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'this branching lambda body needs its block braces'
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final found: Array<String> = [for (span in collect(plugin, source, seams)) '${span.from}:${span.to}'];
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null || !found.contains('${vspan.from}:${vspan.to}')) continue;
			final body: String = source.substring(vspan.from, vspan.to);
			edits.push({ span: vspan, text: '{\n${terminated(body)}\n}' });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * The body text as a STATEMENT, for splicing into the block that is about to wrap it — an
	 * `if` / `switch` in expression position carries no terminator of its own. A body already
	 * ending on `;` or on a closing `}` (a `switch`, or an `if` whose last branch is a block)
	 * needs none.
	 */
	private static inline function terminated(body: String): String {
		final trimmed: String = body.trim();
		return trimmed.endsWith(';') || trimmed.endsWith('}') ? body : '$body;';
	}

	/** Every brace-less branching lambda body in `source`, as the span the wrap replaces. */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams): Array<Span> {
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final out: Array<Span> = [];
		walk(tree, s, out, false);
		return out;
	}

	private static function walk(node: QueryNode, s: Seams, out: Array<Span>, tailArg: Bool): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (!tailArg && s.arrowKinds.contains(node.kind) && node.children.length > 0) {
			final body: QueryNode = node.children[node.children.length - 1];
			final span: Null<Span> = body.span;
			if (span != null && !s.blockKinds.contains(body.kind) && branchesInternally(body, s)) out.push(span);
		}
		for (i => child in node.children) walk(child, s, out, isTrailingCallArg(node, i, s));
	}

	/**
	 * Is child `index` of `parent` the TRAILING argument of an invocation?
	 *
	 * The SAME question `PreferLambdaExpressionBody.isTrailingCallArg` asks, and it has to stay
	 * the same: that check de-braces a branching body in this slot, so claiming it here would
	 * put the braces straight back and `lint --fix` would never reach a fixpoint. The pair is
	 * pinned by `testFixpointWithTheRemoveHalf` in BOTH slots.
	 */
	private static function isTrailingCallArg(parent: QueryNode, index: Int, s: Seams): Bool {
		return s.callKinds.contains(parent.kind) && index == parent.children.length - 1;
	}

	/** The SAME boundary `PreferLambdaExpressionBody.branchesInternally` refuses on. */
	private static function branchesInternally(body: QueryNode, s: Seams): Bool {
		return s.switchKinds.contains(body.kind) || s.conditionalKinds.contains(body.kind) && body.children.length >= IF_ELSE_CHILD_COUNT;
	}

	/** `callKind` + `newExprKind` — the invocation kinds whose last child is the trailing argument. */
	private static function callKindsOf(shape: RefShape): Array<String> {
		final kinds: Array<String> = [];
		final callKind: Null<String> = shape.callKind;
		if (callKind != null) kinds.push(callKind);
		final newExprKind: Null<String> = shape.newExprKind;
		if (newExprKind != null) kinds.push(newExprKind);
		return kinds;
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final fnExprKind: Null<String> = shape.fnExprKind;
		if (fnExprKind == null) return null;
		final arrowKinds: Array<String> = (shape.lambdaKinds ?? []).filter(k -> k != fnExprKind);
		final conditionalKinds: Array<String> = (shape.ifStatementKinds ?? []).concat(shape.ifExpressionKinds ?? []);
		final switchKinds: Array<String> = shape.switchKinds ?? [];
		return arrowKinds.length == 0 || (conditionalKinds.length == 0 && switchKinds.length == 0) ? null : {
			arrowKinds: arrowKinds,
			blockKinds: support.blockKinds(),
			conditionalKinds: conditionalKinds,
			switchKinds: switchKinds,
			callKinds: callKindsOf(shape),
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

}

/** The kinds `LambdaBranchingBodyBlock` reads, bundled once so the walker takes one argument. */
private typedef Seams = {
	var arrowKinds: Array<String>;
	var blockKinds: Array<String>;
	var conditionalKinds: Array<String>;
	var switchKinds: Array<String>;
	var callKinds: Array<String>;
	var opaqueKinds: Array<String>;
}
