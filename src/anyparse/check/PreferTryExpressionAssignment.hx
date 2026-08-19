package anyparse.check;

import anyparse.check.AssignmentTreeHoist.LvalueRef;
import anyparse.check.Check.Violation;
import anyparse.check.TryExpressionShape.TryParts;
import anyparse.check.TryExpressionShape.TrySeams;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a statement-position `try` / `catch` whose body AND every catch clause is a single
 * plain `=` assignment to the SAME target, collapsing it into one assignment of a
 * try-EXPRESSION -- folding in the target's declaration when it immediately precedes:
 *
 * ```haxe
 * var p:Process = null;
 * try {
 *     p = new Process(commandStr, commandArgs);
 * } catch (msg:String) {
 *     p = null;
 * }
 * // ->
 * var p:Process = try new Process(commandStr, commandArgs) catch (msg:String) null;
 * ```
 *
 * Purely structural (no type information). `Info` -- the code is correct, this is a
 * readability simplification. The `try` member of the expression-collapse family that already
 * has `if` (`prefer-if-expression-assignment`) and `switch`
 * (`prefer-switch-expression-assignment`) rules, and the decl-pairing sibling of
 * `join-declaration-assignment`.
 *
 * The `var` keyword is KEPT: this check does one job (collapsing), and the `var` -> `final`
 * upgrade is `prefer-final`'s, so a full `--fix` composes to
 * `final p:Process = try … catch (…) …;` exactly as `join-declaration-assignment` documents
 * for its own output.
 *
 * ## What is flagged
 *
 * Both arms require a `tryStatementKinds` node (both grammar forms: braced bodies and the
 * bare `try e catch (…) e;` shape) whose body is exactly ONE statement -- bare, or a `{ … }`
 * wrapping exactly one -- that is a PLAIN `=` assignment (`assignKind`), and whose EVERY
 * catch clause body is likewise a single plain `=` to a textually identical (whitespace-
 * normalized) target. One clause that rethrows, logs, falls through, or is EMPTY refuses the
 * whole `try`: after the collapse that path would have to produce a value it does not have.
 *
 * Compound operators are deliberately EXCLUDED for the reasons the family documents: a
 * short-circuit `??=` would change behaviour (its r-value, now holding the whole `try`, is
 * skipped when the l-value is non-null, so the guarded work stops running), and an ordinary
 * compound (`+=`, …) whose branch values do not unify to one type compiles per-branch but not
 * as one expression. Plain `=` flows the target's type into every path, sidestepping both.
 *
 * ### The decl-pairing arm
 *
 * The `try` is preceded IMMEDIATELY (`ControlFlowSupport.blockKinds` statement list, no
 * statement between -- a statement in the gap would be reordered by the fold) by a
 * single-variable mutable local declaration (`mutableLocalDeclKinds`) whose name is exactly
 * the assigned identifier. Its initializer is folded away, so:
 *
 * - it must be SIDE-EFFECT-FREE (`RefactorSupport.isSideEffectFree`) -- dropping an impure
 *   one changes what runs;
 * - the pair must not itself sit INSIDE another `try`. The initializer is dead only because
 *   every path through the `try` writes the target -- which holds unless an exception escapes
 *   uncaught, and only an enclosing catch IN THE SAME FUNCTION can then observe the local. No
 *   enclosing `try`, no observer, and the drop is provably sound; inside one it is not, so the
 *   pair falls back to the l-value arm (which drops nothing);
 * - the target must not be READ anywhere in the `try` (`x = x + 1` in a catch) -- after the
 *   fold that is a self-reference in `x`'s own initializer, which the compiler rejects. The
 *   scan is `Refs`-based, so it counts a `$x` string-interpolation read as a read like any
 *   other.
 *
 * The written `:type` is preserved verbatim, being copied along with the keyword as the
 * declaration's own prefix.
 *
 * ### The l-value arm
 *
 * No declaration to pair with (or the decl arm refused): the `try` alone is rewritten,
 * hoisting the target out of the bodies. The target must be a plain identifier or a
 * field-access path whose RECEIVER is side-effect-free (`RefactorSupport.isSideEffectFree`) --
 * after the collapse the receiver is evaluated BEFORE the guarded work instead of after, so an
 * unprovable receiver is conservatively skipped. Nothing is dropped by this arm, so it needs
 * none of the decl arm's initializer gates.
 *
 * ### Comments and `#if`
 *
 * No comment may sit in a region the rebuild drops -- the `try` keyword, the braces, each
 * `return`-less body's `target =` prefix, and (decl arm) the declaration's `= init`. Each `catch (…)` header and each r-value is copied verbatim, so a comment inside one rides along; anything else leaves the `try` unflagged rather than silently lost. One exception to "inside a copied region rides along": a DANGLING line comment, one with no newline after it within its own slice, refuses the site (`TryExpressionShape.danglingLineComment`) -- whatever the rebuild appends after that slice, the next `catch (…)` header or the terminating `;`, would land behind the `//`. Every copied slice is checked, the declaration prefix and the hoisted target included.
 *
 * Both arms read the BRANCH-AWARE projection (`CheckScan.parseBranchAwareOrNull`): a
 * declaration and its `try` inside a `#if sys` region are children of a conditional node, not
 * of a block, so on the plain tree the adjacency the decl arm needs is invisible.
 *
 * ## Autofix
 *
 * `fix` replaces the matched region with
 * `<target> = try <value> catch (…) <value> …;` (the decl arm replacing the declaration
 * through the `try`, with the declaration's keyword and `:type` as the target prefix). Each
 * `catch (…)` header is sliced verbatim from the source -- so the exception variable's type
 * annotation, which the default projection folds into trivia, survives exactly as written --
 * and each r-value from its span; the `try` keyword is emitted. Needs `tryStatementKinds`,
 * `catchClauseKind`, `assignKind`, `exprStatementKind`, `mutableLocalDeclKinds` and
 * `controlFlowSupport` (any unset makes the check a no-op); `blockStmtKind` is optional
 * (without it only bare bodies are recognised) and `fieldAccessKind` is optional -- without
 * it the l-value arm handles only plain-identifier targets.
 */
@:nullSafety(Strict)
final class PreferTryExpressionAssignment implements Check {

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** The finding message for the decl-pairing arm (a `var` and its following try/catch). */
	private static inline final DECL_MESSAGE: String =
		'this declaration and its following try/catch assignment can be a single try-expression assignment';

	/** The finding message for the l-value arm (a standalone try/catch assigning one target in every path). */
	private static inline final LVALUE_MESSAGE: String =
		'this try/catch that assigns the same target in every path can be a single try-expression assignment';

	public function new() {}

	public function id(): String {
		return 'prefer-try-expression-assignment';
	}

	public function description(): String {
		return 'a try/catch that assigns the same target in the body and every catch clause ('
			+ 'optionally paired with its preceding local declaration), collapsible to a single try-expression assignment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		return seams == null ? [] : [
			for (entry in files) for (m in collect(plugin, entry.source, seams))
				{
					file: entry.file,
					span: m.keySpan,
					rule: 'prefer-try-expression-assignment',
					severity: Severity.Info,
					message: m.message
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final byKey: Map<String, Match> = [];
		for (m in collect(plugin, source, seams)) byKey['${m.keySpan.from}:${m.keySpan.to}'] = m;
		return RefactorSupport.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.editSpan, text: m.text }))
		);
	}

	/** Every collapsible `try` in `source`, read off the branch-aware projection (empty when it does not parse). */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final out: Array<Match> = [];
		collectMatches(tree, tree, source, comments, s, out, false);
		return out;
	}

	/** Bundle the required + optional kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final tryKinds: Null<Array<String>> = shape.tryStatementKinds;
		if (tryKinds == null || tryKinds.length == 0) return null;
		final catchKind: Null<String> = shape.catchClauseKind;
		final assignKind: Null<String> = shape.assignKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (catchKind == null || assignKind == null || exprStmtKind == null) return null;
		final mutableKinds: Null<Array<String>> = shape.mutableLocalDeclKinds;
		if (mutableKinds == null || mutableKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		// A `try` nested in a try-EXPRESSION is inside a handled region just as much as one
		// nested in a try STATEMENT — both make an escaping exception observable — and both
		// are also what an emitted value must be parenthesised for.
		final allTryKinds: Array<String> = tryKinds.concat(shape.tryExpressionKinds ?? []);
		return support == null ? null : {
			tryKinds: tryKinds,
			nestingKinds: allTryKinds,
			tryShape: { catchKind: catchKind, blockStmtKind: shape.blockStmtKind, tryKinds: allTryKinds },
			assignKind: assignKind,
			exprStmtKind: exprStmtKind,
			mutableKinds: mutableKinds,
			fieldAccessKind: shape.fieldAccessKind,
			identKind: shape.identKind,
			stringInterpKind: shape.stringInterpIdentKind,
			localDeclContinuationKinds: shape.localDeclContinuationKinds ?? [],
			blockKinds: support.blockKinds(),
			shape: shape
		};
	}

	/**
	 * Collect every collapsible `try` reachable under `node`. `insideTry` tracks whether the
	 * walk has descended through a `try` construct — the decl arm's initializer drop is only
	 * provably sound outside one (see the class doc).
	 */
	private static function collectMatches(
		node: QueryNode, root: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		out: Array<Match>, insideTry: Bool
	): Void {
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) if (s.tryKinds.contains(kids[i].kind)) {
				final decl: Null<Match> = insideTry || i == 0 ? null : matchDeclPair(kids[i - 1], kids[i], root, source, comments, s);
				if (decl != null) {
					out.push(decl);
					continue;
				}
				final standalone: Null<Match> = matchLvalueTry(kids[i], source, comments, s);
				if (standalone != null) out.push(standalone);
			}
		}
		final nested: Bool = insideTry || s.nestingKinds.contains(node.kind);
		for (c in node.children) collectMatches(c, root, source, comments, s, out, nested);
	}

	/**
	 * The collapse match for a `decl` immediately followed by `tryStmt`, or null when they are
	 * not a single mutable local and a following `try` assigning that local on every path (see
	 * the class doc for every gate).
	 */
	private static function matchDeclPair(
		decl: QueryNode, tryStmt: QueryNode, root: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams
	): Null<Match> {
		if (!s.mutableKinds.contains(decl.kind) || decl.children.length > 1) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final trySpan: Null<Span> = tryStmt.span;
		if (name == null || declSpan == null || trySpan == null) return null;
		if (RefactorSupport.isMultiDeclarator(decl, s.localDeclContinuationKinds)) return null; // `var a, b;`
		final init: Null<QueryNode> = decl.children.length == 1 ? decl.children[0] : null;
		if (init != null && !RefactorSupport.isSideEffectFree(init)) return null; // an impure init cannot be dropped

		final ref: LvalueRef = { lvalue: null };
		final targets: Array<Span> = [];
		final parts: Null<TryParts> = decompose(tryStmt, ref, targets, source, comments, s);
		final lvalue: Null<QueryNode> = ref.lvalue;
		if (parts == null || lvalue == null) return null;
		if (lvalue.kind != s.identKind || lvalue.name != name) return null;
		// Any occurrence beyond the assignments' own l-values self-references the folded initializer.
		if (!assignedOnlyByTargets(name, tryStmt, targets, s)) return null;

		final prefix: Null<{ text: String, keptTo: Int }> = TryExpressionShape.declPrefix(declSpan, init, source);
		final value: Null<String> = TryExpressionShape.buildValue(parts, source, s.tryShape);
		if (prefix == null || value == null) return null;
		final prefixSpan: Span = new Span(declSpan.from, declSpan.from + prefix.text.length);
		// The declaration prefix is copied too, so it needs the same dangling-`//` guard the
		// `try`'s own slices get — a comment there would sit in front of the whole `= try …;`.
		if (TryExpressionShape.danglingLineComment(source, prefixSpan, comments)) return null;
		final kept: Array<Span> = TryExpressionShape.keptSpans(parts);
		kept.push(new Span(declSpan.from, prefix.keptTo));
		final region: Span = new Span(declSpan.from, trySpan.to);
		return IfExpressionChain.droppedComment(region, kept, comments) ? null : {
			keySpan: declSpan,
			editSpan: region,
			text: '${prefix.text} = $value;',
			message: DECL_MESSAGE
		};
	}

	/**
	 * The collapse match for a standalone `tryStmt` whose every path assigns the SAME already-
	 * declared target, or null when a gate fails. Nothing is dropped here, so the decl arm's
	 * initializer gates do not apply.
	 */
	private static function matchLvalueTry(
		tryStmt: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final trySpan: Null<Span> = tryStmt.span;
		if (trySpan == null) return null;
		final ref: LvalueRef = { lvalue: null };
		final parts: Null<TryParts> = decompose(tryStmt, ref, [], source, comments, s);
		final lvalue: Null<QueryNode> = ref.lvalue;
		// Split, not `||`-chained: Haxe strict null-safety carries a narrowing fact into a
		// later `||` operand from the FIRST operand only, so `lvalue` is still nullable there.
		if (parts == null || lvalue == null) return null;
		if (!lvalueAccepted(lvalue, s)) return null;
		final lvalueSrc: Null<String> = TryExpressionShape.slice(source, lvalue);
		final lvalueSpan: Null<Span> = lvalue.span;
		final value: Null<String> = TryExpressionShape.buildValue(parts, source, s.tryShape);
		if (lvalueSrc == null || lvalueSpan == null || value == null) return null;
		if (TryExpressionShape.danglingLineComment(source, lvalueSpan, comments)) return null; // the copied target
		final kept: Array<Span> = TryExpressionShape.keptSpans(parts);
		kept.push(lvalueSpan);
		return IfExpressionChain.droppedComment(trySpan, kept, comments) ? null : {
			keySpan: trySpan,
			editSpan: trySpan,
			text: '$lvalueSrc = $value;',
			message: LVALUE_MESSAGE
		};
	}

	/**
	 * Decompose `tryStmt` into the r-values of its body and catch clauses, recording the common
	 * target in `ref`. Null unless every body is a single plain `=` and all their l-values have
	 * identical whitespace-normalized source — the first one seen (the try body's) becomes the
	 * target every later one is compared against.
	 */
	private static function decompose(
		tryStmt: QueryNode, ref: LvalueRef, targets: Array<Span>, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams
	): Null<TryParts> {
		return TryExpressionShape.decompose(tryStmt, source, comments, s.tryShape, (body, clause) -> {
			final assign: Null<QueryNode> = plainAssignment(body, s);
			if (assign == null) return null;
			final lvalue: QueryNode = assign.children[0];
			// The target is unified by SOURCE TEXT, so a catch whose exception variable shadows
			// the target reads as "the same target" while writing the shadow — a write the
			// original DISCARDS and the collapse would promote to the outer assignment's value
			// (`try { m = f(); } catch (m:String) { m = 'e'; }` keeps `m` as `f()`'s value or
			// the declaration's, never `'e'`). Refuse any clause that binds a name the target
			// path mentions.
			if (clause != null && shadowsTarget(clause, lvalue, s)) return null;
			final seen: Null<QueryNode> = ref.lvalue;
			if (seen == null)
				ref.lvalue = lvalue
			else if (!IfExpressionChain.sameSource(seen, lvalue, source))
				return null;
			final lvalueSpan: Null<Span> = lvalue.span;
			if (lvalueSpan == null) return null;
			targets.push(lvalueSpan);
			return assign.children[1];
		});
	}

	/** Whether `clause`'s exception variable is a name the l-value path references (a shadowed target). */
	private static function shadowsTarget(clause: QueryNode, lvalue: QueryNode, s: Seams): Bool {
		final bound: Null<String> = clause.name;
		return bound != null && TryExpressionShape.referencesName(lvalue, bound, s.identKind, s.stringInterpKind);
	}

	/** The plain `=` assignment a body holds — bare, or wrapped in an expression statement. Null for anything else. */
	private static function plainAssignment(body: QueryNode, s: Seams): Null<QueryNode> {
		final expr: QueryNode = body.kind == s.exprStmtKind && body.children.length == 1 ? body.children[0] : body;
		return expr.kind == s.assignKind && expr.children.length == ASSIGN_CHILD_COUNT ? expr : null;
	}

	/**
	 * Whether the hoisted target is acceptable for the l-value arm: a bare identifier, or a
	 * field-access path whose receiver is side-effect-free (after the collapse that receiver is
	 * evaluated before the guarded work rather than after).
	 */
	private static function lvalueAccepted(lvalue: QueryNode, s: Seams): Bool {
		if (lvalue.kind == s.identKind) return true;
		final fieldAccessKind: Null<String> = s.fieldAccessKind;
		if (fieldAccessKind == null || lvalue.kind != fieldAccessKind) return false;
		final receiver: Null<QueryNode> = lvalue.children.length > 0 ? lvalue.children[0] : null;
		return receiver != null && RefactorSupport.isSideEffectFree(receiver);
	}

	/**
	 * Whether EVERY occurrence of `name` inside `tryStmt` is one of the decomposed assignments'
	 * OWN l-values (`targets`, by span). After the decl-pairing fold the whole `try` becomes
	 * `name`'s initializer, so any other occurrence is a self-reference the compiler rejects --
	 * and "other" has to mean any occurrence, not just any READ: a write nested somewhere else
	 * (`p = go(() -> p = 5)`) is equally a use of a not-yet-initialized `p`. An earlier version
	 * asked only "is it a read", which let exactly that shape through and emitted code that did
	 * not compile. `Refs` is scope-correct, so a same-named binding introduced inside the `try`
	 * projects as a `[decl]` occurrence and is refused here too -- conservative, never unsound.
	 */
	private static function assignedOnlyByTargets(name: String, tryStmt: QueryNode, targets: Array<Span>, s: Seams): Bool {
		for (h in Refs.find(name, tryStmt, s.shape)) {
			if (h.kind != RefKind.Write) return false;
			// Matched on START offset alone: a node span can carry trailing trivia, which a
			// `Refs` hit span does not, and a mismatch there would silently decline the arm.
			if (!targets.exists(t -> h.span.from == t.from)) return false;
		}
		return true;
	}

}

/** The kinds `PreferTryExpressionAssignment` reads. */
private typedef Seams = {
	var tryKinds: Array<String>;
	var nestingKinds: Array<String>;
	var tryShape: TrySeams;
	var assignKind: String;
	var exprStmtKind: String;
	var mutableKinds: Array<String>;
	var fieldAccessKind: Null<String>;
	var identKind: String;
	var stringInterpKind: Null<String>;
	var localDeclContinuationKinds: Array<String>;
	var blockKinds: Array<String>;
	var shape: RefShape;
}

/** A collapsible `try`: the finding key span, the replaced span, the built replacement, and the arm's message. */
private typedef Match = {
	var keySpan: Span;
	var editSpan: Span;
	var text: String;
	var message: String;
}
