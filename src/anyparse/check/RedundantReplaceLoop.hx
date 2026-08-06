package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags `while (x.indexOf(S) != -1) x = x.replace(S, B);` — a search-and-replace
 * loop that is redundant BY CONSTRUCTION: `StringTools.replace` already replaces
 * EVERY occurrence of `S` in one call (verified live), so looping on `indexOf`
 * either does nothing extra or never stops. Three arms:
 *
 * - **Arm A — `S` and `B` are both LITERALS and `B` does NOT contain `S`.** After
 *   one `replace`, `x` has zero occurrences of `S` left, so the guard is false and
 *   the loop would have run at most once anyway. `Severity.Info`, with an autofix
 *   that collapses the whole loop to the single unconditional assignment
 *   `x = x.replace(S, B);` — sound even when the ORIGINAL string had zero
 *   occurrences of `S` to begin with, since `replace` on a no-match input returns
 *   the string unchanged.
 * - **Arm B — `S` and `B` are both LITERALS and `B` CONTAINS `S`.** Every
 *   replacement reinserts `S` into `x`, so the guard is true again on the next
 *   check — the loop is INFINITE for any input that ever contains `S`. This is a
 *   real bug, not a style nit: `Severity.Warning`, report-only (there is no
 *   mechanical fix for "the author meant something else").
 * - **Arm C — at least one of `S` / `B` is a PARAMETER of the enclosing
 *   function.** `Severity.Info`, report-only; see its own section below.
 *
 * ## What is matched
 *
 * The guard accepts three spellings of "does `x` contain `S`": `x.indexOf(S) !=
 * -1`, its reversed operand order `-1 != x.indexOf(S)`, and `x.contains(S)`. Each
 * of `S` (the guard's `indexOf` / `contains` argument AND `replace`'s first
 * argument) and `B` (`replace`'s second argument) must be EITHER a plain string
 * literal (`StringFoldSupport.literalOf` — no interpolation) OR a bare identifier
 * bound to a PARAMETER of the function enclosing the loop (a `RefShape.paramKinds`
 * child of the nearest `RefShape.functionKinds` ancestor). Anything else — a field
 * access, a call, an index access, a LOCAL `var`, an unresolvable identifier — is
 * not this pattern and is left alone. The two `S` positions must be the SAME
 * thing: equal literal content, or the same parameter binding; a literal /
 * parameter MIX across the two `S` positions is not a match. The receiver `x` must
 * be a single identifier — never `this.x` / `obj.x` / an index access — bound to
 * the SAME local/parameter declaration in the guard call, the `replace` call and
 * the assignment target (`TypeResolver.identBindingFrom`, so a same-named variable
 * from an unrelated scope never falsely qualifies), and that declaration must
 * carry an explicit `:String` annotation (`TypeInfoProvider.declaredTypes`) — an
 * untyped or non-`String` receiver is a silent miss, never a wrong flag.
 *
 * The loop body must be EXACTLY the one assignment statement — braced with a
 * single statement, or the bare unbraced form Haxe allows for a single-statement
 * `while`. Any additional statement (a second assignment, a `trace`, …) means the
 * loop is doing more than a redundant replace and is skipped entirely.
 *
 * ## Arm C — a parameter pair cannot be decided statically
 *
 * When either operand is a parameter, whether `B` contains `S` is a property of
 * the CALLER's arguments, not of this function: `replaceWord(line, 'a', 'aa')`
 * loops forever, `replaceWord(line, 'a', 'b')` returns. Both readings are live, so
 * the finding is `Severity.Info` and REPORT-ONLY — there is no arm-A collapse to
 * make (the loop is not provably redundant) and no arm-B certainty to claim. The
 * message names both operands' VERBATIM source text, so the reader decides. Note
 * the literal / parameter MIX is deliberately admitted here: `stripWord(line,
 * word)` looping on `line.replace(word, '')` has a parameter `S` and a literal
 * `B`, and is exactly the shape that motivates the arm.
 *
 * The one static proof that the hazard cannot happen is a CONTAINMENT test that
 * RETURNS before the loop — `if (B.indexOf(S) != -1) return …;`, its reversed
 * order, or `if (B.contains(S)) return …;` (read by the same `matchGuard`, held to
 * the same operand identity), anywhere in the enclosing function and ending at or
 * before the `while` begins. That suppresses arm C outright.
 *
 * An EQUALITY guard does NOT: `if (S == B) return …;` rules out only the
 * degenerate `B == S`, while every `B` that merely CONTAINS `S` still loops
 * forever. Such a guard reads like protection, which is precisely why the finding
 * survives it and the message says so. Arms A and B are untouched by either guard
 * — with two literals the verdict is already decided and needs no proof.
 *
 * ## Default OFF — opt-in
 *
 * A brand-new check ships `DefaultOff`: dropped from the default set and from a
 * bare `lint … --all` report until a project opts in via `apqlint.json`
 * (`"rules": { "redundant-replace-loop": { "enabled": true } }`), or an explicit
 * `--rule redundant-replace-loop` selects it (which bypasses enablement).
 *
 * ## Grammar-agnostic
 *
 * Driven by `whileStmtKind`, `notEqKind`, `callKind`, `fieldAccessKind`,
 * `identKind`, `assignKind`, `blockStmtKind`, `exprStatementKind`,
 * `unaryMinusKinds` and `numericLiteralKinds` (any unset, or the plugin's
 * `stringFoldSupport()` null, → the check is a no-op), plus `parenKind`
 * (optional, one guard-condition unwrap) and `opaqueKinds` to skip reification
 * subtrees. Arm C adds `functionKinds` / `paramKinds` (a parameter operand) and
 * `ifStatementKinds` / `returnStatementKind` / `voidReturnKind` / `eqKind` (the
 * two pre-loop guards); each is optional, and leaving them unset costs only arm C
 * — the literals-only arms A / B behave exactly as they did without them.
 */
@:nullSafety(Strict)
final class RedundantReplaceLoop implements Check implements DefaultOff {

	/** This check's stable id — named once so the literal is not itself a repeated string. */
	private static inline final RULE_ID: String = 'redundant-replace-loop';

	/** A `while` node has exactly [condition, body] children. */
	private static inline final WHILE_CHILD_COUNT: Int = 2;

	/** A `!=` comparison node has exactly [left, right] children. */
	private static inline final COMPARISON_CHILD_COUNT: Int = 2;

	/** A unary-minus (`Neg`) node has exactly [operand] children. */
	private static inline final NEG_CHILD_COUNT: Int = 1;

	/** A plain assignment node has exactly [target, value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** `x.indexOf(S)` / `x.contains(S)`: callee + one argument. */
	private static inline final ONE_ARG_CALL_CHILD_COUNT: Int = 2;

	/** `x.replace(S, B)`: callee + two arguments. */
	private static inline final REPLACE_CALL_CHILD_COUNT: Int = 3;

	private static inline final SEARCH_METHOD: String = 'indexOf';
	private static inline final CONTAINS_METHOD: String = 'contains';
	private static inline final REPLACE_METHOD: String = 'replace';
	private static inline final STRING_TYPE: String = 'String';

	/** Longest literal excerpt echoed verbatim in a finding message before it is elided. */
	private static inline final EXCERPT_MAX: Int = 40;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return
			'a while (x.indexOf(S) != -1) x = x.replace(S, B); loop — replace() already replaces every occurrence in one call; a PARAMETER S / B cannot be decided statically and is reported as a potential infinite loop';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final typed: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (typed == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			walk(tree, tree, entry.file, entry.source, declaredTypes, s, violations);
		}
		return violations;
	}

	/** Collapse each ARM-A (fixable) violation's whole `while` loop to its single body statement, verbatim. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final typed: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (typed == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final declaredTypes: Map<Int, String> = typed.declaredTypes(source);
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		fixWalk(tree, tree, source, declaredTypes, s, wanted, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` kinds + `StringFoldSupport`, or null when any is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final whileStmtKind: Null<String> = shape.whileStmtKind;
		if (whileStmtKind == null) return null;
		final notEqKind: Null<String> = shape.notEqKind;
		if (notEqKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final unaryMinusKinds: Array<String> = shape.unaryMinusKinds ?? [];
		if (unaryMinusKinds.length == 0) return null;
		final numericLiteralKinds: Array<String> = shape.numericLiteralKinds ?? [];
		if (numericLiteralKinds.length == 0) return null;
		final strings: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (strings == null) return null;
		final returnKinds: Array<String> = [];
		final returnStatementKind: Null<String> = shape.returnStatementKind;
		if (returnStatementKind != null) returnKinds.push(returnStatementKind);
		final voidReturnKind: Null<String> = shape.voidReturnKind;
		if (voidReturnKind != null) returnKinds.push(voidReturnKind);
		return {
			shape: shape,
			whileStmtKind: whileStmtKind,
			notEqKind: notEqKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			identKind: identKind,
			assignKind: assignKind,
			blockStmtKind: blockStmtKind,
			exprStmtKind: exprStmtKind,
			unaryMinusKinds: unaryMinusKinds,
			numericLiteralKinds: numericLiteralKinds,
			functionKinds: shape.functionKinds ?? [],
			paramKinds: shape.paramKinds ?? [],
			ifStatementKinds: shape.ifStatementKinds ?? [],
			returnKinds: returnKinds,
			eqKind: shape.eqKind,
			parenKind: shape.parenKind,
			strings: strings,
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/** Descend `node`, flagging every qualifying `while` loop. A reification subtree (`opaqueKinds`) is skipped wholesale. */
	private static function walk(
		node: QueryNode, root: QueryNode, file: String, source: String, declaredTypes: Map<Int, String>, s: Seams, out: Array<Violation>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (node.kind == s.whileStmtKind) {
			final m: Null<Match> = matchWhile(node, root, source, declaredTypes, s);
			if (m != null) out.push(toViolation(file, m));
		}
		for (c in node.children) walk(c, root, file, source, declaredTypes, s, out);
	}

	/** Mirror of `walk` for the fix path: emit the collapse edit for each `wanted`, ARM-A loop. */
	private static function fixWalk(
		node: QueryNode, root: QueryNode, source: String, declaredTypes: Map<Int, String>, s: Seams, wanted: Array<String>,
		out: Array<{ span: Span, text: String }>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (node.kind == s.whileStmtKind) {
			final m: Null<Match> = matchWhile(node, root, source, declaredTypes, s);
			if (m != null && m.arm == Arm.A && wanted.contains('${m.whileSpan.from}:${m.whileSpan.to}'))
				out.push({ span: m.whileSpan, text: source.substring(m.stmtSpan.from, m.stmtSpan.to) });
		}
		for (c in node.children) fixWalk(c, root, source, declaredTypes, s, wanted, out);
	}

	/**
	 * If `whileNode` is a qualifying redundant-replace loop, its match (spans, arm, and the
	 * receiver/literal text for the message); else null. See the type doc for the full gate list.
	 */
	private static function matchWhile(
		whileNode: QueryNode, root: QueryNode, source: String, declaredTypes: Map<Int, String>, s: Seams
	): Null<Match> {
		if (whileNode.children.length != WHILE_CHILD_COUNT) return null;
		var cond: QueryNode = whileNode.children[0];
		if (s.parenKind != null && cond.kind == s.parenKind && cond.children.length == 1) cond = cond.children[0];
		final guard: Null<{ receiver: QueryNode, search: QueryNode }> = matchGuard(cond, source, s);
		if (guard == null) return null;
		final receiver: QueryNode = guard.receiver;
		if (receiver.kind != s.identKind) return null;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(receiver, root, s.shape);
		if (bindingFrom == null || declaredTypes[bindingFrom] != STRING_TYPE) return null;
		final whileSpan: Null<Span> = whileNode.span;
		if (whileSpan == null) return null;
		final fn: Null<QueryNode> = enclosingFunction(root, whileSpan, s, null);
		final search: Null<Operand> = operandOf(guard.search, root, fn, source, s);
		if (search == null) return null;

		final body: QueryNode = whileNode.children[1];
		final stmt: Null<QueryNode> = singleStatementOf(body, s);
		if (stmt == null || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != s.assignKind || assign.children.length != ASSIGN_CHILD_COUNT) return null;
		final target: QueryNode = assign.children[0];
		if (target.kind != s.identKind || TypeResolver.identBindingFrom(target, root, s.shape) != bindingFrom) return null;

		final value: QueryNode = assign.children[1];
		final replaceCall: Null<MethodCall> = methodCallParts(value, s);
		if (
			replaceCall == null || replaceCall.method != REPLACE_METHOD || value.children.length != REPLACE_CALL_CHILD_COUNT
			|| replaceCall.recv.kind != s.identKind || TypeResolver.identBindingFrom(replaceCall.recv, root, s.shape) != bindingFrom
		)
			return null;
		final search2: Null<Operand> = operandOf(value.children[1], root, fn, source, s);
		if (search2 == null || !sameOperand(search, search2)) return null;
		final replacement: Null<Operand> = operandOf(value.children[2], root, fn, source, s);
		if (replacement == null) return null;
		final stmtSpan: Null<Span> = stmt.span;
		if (stmtSpan == null) return null;

		final searchContent: Null<String> = search.literal;
		final replacementContent: Null<String> = replacement.literal;
		var arm: Arm = Arm.C;
		var eqGuarded: Bool = false;
		if (searchContent != null && replacementContent != null)
			// Two literals decide the outcome statically — arms A / B, byte-identical to the
			// behaviour from before parameters were admitted as operands.
			arm = replacementContent.indexOf(searchContent) == -1 ? Arm.A : Arm.B;
		else if (fn == null || guardsContainment(fn, whileSpan, search, replacement, root, source, s))
			// ARM C, suppressed: a containment test that returns before the loop is the one static
			// proof that `B` never contains `S`, whatever the caller passes.
			return null;
		else
			eqGuarded = guardsEquality(fn, whileSpan, search, replacement, root, source, s);
		return {
			whileSpan: whileSpan,
			stmtSpan: stmtSpan,
			arm: arm,
			eqGuarded: eqGuarded,
			receiverName: receiver.name ?? '',
			// The operand's OWN verbatim source (delimiters included for a literal), not a
			// hand-rewrapped `.content` — content may itself carry a quote character (`"'"`), and
			// rewrapping it in a hardcoded delimiter would mis-render (`':', '''`).
			searchSrc: search.src,
			replacementSrc: replacement.src
		};
	}

	/**
	 * The guard's receiver + search argument when `cond` is one of the three accepted
	 * shapes (`x.indexOf(S) != -1`, `-1 != x.indexOf(S)`, `x.contains(S)`), else null.
	 */
	private static function matchGuard(cond: QueryNode, source: String, s: Seams): Null<{ receiver: QueryNode, search: QueryNode }> {
		if (cond.kind == s.notEqKind && cond.children.length == COMPARISON_CHILD_COUNT) {
			final left: QueryNode = cond.children[0];
			final right: QueryNode = cond.children[1];
			final leftCall: Null<MethodCall> = indexOfCallParts(left, s);
			if (leftCall != null && isNegativeOneLiteral(right, source, s)) return { receiver: leftCall.recv, search: left.children[1] };
			final rightCall: Null<MethodCall> = indexOfCallParts(right, s);
			if (rightCall != null && isNegativeOneLiteral(left, source, s)) return { receiver: rightCall.recv, search: right.children[1] };
			return null;
		}
		final call: Null<MethodCall> = methodCallParts(cond, s);
		return call != null && call.method == CONTAINS_METHOD && cond.children.length == ONE_ARG_CALL_CHILD_COUNT ? {
			receiver: call.recv,
			search: cond.children[1]
		} : null;
	}

	/**
	 * The `S` / `B` operand `node` denotes, or null when it is neither accepted shape. A plain
	 * string literal (`StringFoldSupport.literalOf`, which answers null for an interpolated one)
	 * carries its content; a bare identifier carries its binding offset, but ONLY when that binding
	 * is a PARAMETER of `fn`, the function enclosing the loop. A field access, a call, an index
	 * access, a LOCAL `var` and an unresolvable identifier all answer null — the loop is then not
	 * this pattern and is left alone, exactly as before parameters were admitted.
	 */
	private static function operandOf(node: QueryNode, root: QueryNode, fn: Null<QueryNode>, source: String, s: Seams): Null<Operand> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final src: String = source.substring(span.from, span.to);
		final literal: Null<StringLiteral> = s.strings.literalOf(node, source);
		if (literal != null) return { literal: literal.content, paramFrom: null, src: src };
		if (node.kind != s.identKind || fn == null) return null;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(node, root, s.shape);
		if (bindingFrom == null || !isParameterOf(fn, bindingFrom, s)) return null;
		return { literal: null, paramFrom: bindingFrom, src: src };
	}

	/** Whether the binding at `bindingFrom` is one of `fn`'s own parameter declarations (`Seams.paramKinds`). */
	private static function isParameterOf(fn: QueryNode, bindingFrom: Int, s: Seams): Bool {
		for (child in fn.children) if (s.paramKinds.contains(child.kind)) {
			final span: Null<Span> = child.span;
			if (span != null && bindingFrom >= span.from && bindingFrom < span.to) return true;
		}
		return false;
	}

	/** Whether two operands denote the SAME thing — equal literal content, or the same parameter binding. A literal / parameter mix never matches. */
	private static function sameOperand(a: Operand, b: Operand): Bool {
		final literal: Null<String> = a.literal;
		if (literal != null) return literal == b.literal;
		final paramFrom: Null<Int> = a.paramFrom;
		return paramFrom != null && paramFrom == b.paramFrom;
	}

	/**
	 * The INNERMOST function declaration (`Seams.functionKinds`) whose span contains `target`, or
	 * null when the loop sits outside any (or the grammar names no function kinds — arm C is then
	 * unreachable and the check keeps its literals-only behaviour). A parameter operand needs one
	 * to be a parameter OF.
	 */
	private static function enclosingFunction(node: QueryNode, target: Span, s: Seams, found: Null<QueryNode>): Null<QueryNode> {
		final span: Null<Span> = node.span;
		if (span != null && (span.from > target.from || span.to < target.to)) return found;
		var best: Null<QueryNode> = s.functionKinds.contains(node.kind) ? node : found;
		for (child in node.children) best = enclosingFunction(child, target, s, best);
		return best;
	}

	/**
	 * Whether `fn` provably tests containment of `search` in `replacement` and RETURNS before the
	 * loop at `whileSpan` — `B.indexOf(S) != -1` / `-1 != B.indexOf(S)` / `B.contains(S)`, the same
	 * three spellings `matchGuard` reads for the loop's own condition, held to the same operand
	 * identity. Such a function never reaches the loop with a `B` that contains `S`, so arm C has
	 * nothing to report.
	 */
	private static function guardsContainment(
		fn: QueryNode, whileSpan: Span, search: Operand, replacement: Operand, root: QueryNode, source: String, s: Seams
	): Bool {
		for (cond in precedingReturnGuards(fn, whileSpan, s)) {
			final guard: Null<{ receiver: QueryNode, search: QueryNode }> = matchGuard(cond, source, s);
			if (guard == null) continue;
			final receiver: Null<Operand> = operandOf(guard.receiver, root, fn, source, s);
			final searched: Null<Operand> = operandOf(guard.search, root, fn, source, s);
			if (receiver != null && searched != null && sameOperand(receiver, replacement) && sameOperand(searched, search)) return true;
		}
		return false;
	}

	/**
	 * Whether `fn` tests `S == B` (either operand order) and RETURNS before the loop. Such a guard
	 * is INSUFFICIENT — it rules out only the degenerate `B == S`, never the `B` that merely
	 * CONTAINS `S` — so it never suppresses the finding; it only sharpens the message.
	 */
	private static function guardsEquality(
		fn: QueryNode, whileSpan: Span, search: Operand, replacement: Operand, root: QueryNode, source: String, s: Seams
	): Bool {
		final eqKind: Null<String> = s.eqKind;
		if (eqKind == null) return false;
		for (cond in precedingReturnGuards(fn, whileSpan, s)) {
			if (cond.kind != eqKind || cond.children.length != COMPARISON_CHILD_COUNT) continue;
			final left: Null<Operand> = operandOf(cond.children[0], root, fn, source, s);
			final right: Null<Operand> = operandOf(cond.children[1], root, fn, source, s);
			if (left == null || right == null) continue;
			if (
				(sameOperand(left, search) && sameOperand(right, replacement))
				|| (sameOperand(left, replacement) && sameOperand(right, search))
			)
				return true;
		}
		return false;
	}

	/**
	 * The CONDITIONS of every `if` inside `fn` that ends at or before `whileSpan` starts and whose
	 * then-branch is a `return` (bare, or the sole statement of a block) — the shapes that make the
	 * function exit before the loop can run. One optional paren layer is unwrapped, as in the
	 * loop's own condition.
	 */
	private static function precedingReturnGuards(fn: QueryNode, whileSpan: Span, s: Seams): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		collectReturnGuards(fn, whileSpan, s, out);
		return out;
	}

	/** `precedingReturnGuards`'s recursion over `node`'s subtree. */
	private static function collectReturnGuards(node: QueryNode, whileSpan: Span, s: Seams, out: Array<QueryNode>): Void {
		final span: Null<Span> = node.span;
		if (
			s.ifStatementKinds.contains(node.kind) && span != null && span.to <= whileSpan.from
			&& node.children.length >= COMPARISON_CHILD_COUNT && returnsImmediately(node.children[1], s)
		) {
			var cond: QueryNode = node.children[0];
			if (s.parenKind != null && cond.kind == s.parenKind && cond.children.length == 1) cond = cond.children[0];
			out.push(cond);
		}
		for (child in node.children) collectReturnGuards(child, whileSpan, s, out);
	}

	/** Whether `branch` is a `return` statement (valued or bare), or a block whose only statement is one. */
	private static function returnsImmediately(branch: QueryNode, s: Seams): Bool {
		if (s.returnKinds.contains(branch.kind)) return true;
		return branch.kind == s.blockStmtKind && branch.children.length == 1 && s.returnKinds.contains(branch.children[0].kind);
	}

	/** `x.METHOD(...)` destructured into its receiver + method name, or null when `node` is not a field-access call. */
	private static function methodCallParts(node: QueryNode, s: Seams): Null<MethodCall> {
		if (node.kind != s.callKind || node.children.length < 1) return null;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != s.fieldAccessKind || method == null || callee.children.length != 1) return null;
		return { recv: callee.children[0], method: method };
	}

	/** `x.indexOf(S)` destructured into its receiver, or null when `node` is not exactly that one-argument call. */
	private static function indexOfCallParts(node: QueryNode, s: Seams): Null<MethodCall> {
		final parts: Null<MethodCall> = methodCallParts(node, s);
		return parts != null && parts.method == SEARCH_METHOD && node.children.length == ONE_ARG_CALL_CHILD_COUNT ? parts : null;
	}

	/** Whether `node` is a unary-minus wrapping the integer literal `1` — the `-1` "not found" sentinel. */
	private static function isNegativeOneLiteral(node: QueryNode, source: String, s: Seams): Bool {
		if (!s.unaryMinusKinds.contains(node.kind) || node.children.length != NEG_CHILD_COUNT) return false;
		final inner: QueryNode = node.children[0];
		if (!s.numericLiteralKinds.contains(inner.kind)) return false;
		final span: Null<Span> = inner.span;
		return span != null && source.substring(span.from, span.to) == '1';
	}

	/** The loop body's single statement (a plain assignment expression statement), or null when the body is not exactly one. */
	private static function singleStatementOf(body: QueryNode, s: Seams): Null<QueryNode> {
		if (body.kind == s.exprStmtKind) return body;
		if (body.kind == s.blockStmtKind && body.children.length == 1 && body.children[0].kind == s.exprStmtKind) return body.children[0];
		return null;
	}

	/** `m` as its `Info` (arm A, autofixable) or `Warning` (arm B, infinite-loop hazard, report-only) `Violation`. */
	private static function toViolation(file: String, m: Match): Violation {
		final search: String = excerpt(m.searchSrc);
		final replacement: String = excerpt(m.replacementSrc);
		if (m.arm == Arm.B) return {
			file: file,
			span: m.whileSpan,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: 'this loop never terminates for any ${m.receiverName} containing $search — replace($search, $replacement) reintroduces it every time, since $replacement itself contains $search'
		};
		return {
			file: file,
			span: m.whileSpan,
			rule: RULE_ID,
			severity: Severity.Info,
			message: m.arm == Arm.A
				? 'this while (${m.receiverName}.indexOf($search) != -1) loop runs at most once — replace() already replaces every occurrence; collapses to ${m.receiverName} = ${m.receiverName}.replace($search, $replacement);'
				: armCMessage(m, search, replacement)
		};
	}

	/**
	 * Arm C's message: the hazard first (`potential infinite loop when <B> contains <S>`), then the
	 * equality-guard caveat when the enclosing function carries one — `S == B` is not containment,
	 * so the guard reads like protection while covering only the degenerate case.
	 */
	private static function armCMessage(m: Match, search: String, replacement: String): String {
		final head: String =
			'potential infinite loop when $replacement contains $search — replace($search, $replacement) reinserts $search on every pass, so the guard never goes false';
		return m.eqGuarded
			? '$head; the $search == $replacement guard does not cover containment — a $replacement that merely CONTAINS $search still loops forever'
			: head;
	}

	/** `text` (a literal's verbatim source, delimiters included), capped to `EXCERPT_MAX` characters (an ellipsis marks the cut) for a finding message. */
	private static function excerpt(text: String): String {
		return text.length <= EXCERPT_MAX ? text : text.substring(0, EXCERPT_MAX) + '…';
	}

}

/** The resolved seams `RedundantReplaceLoop` reads in both `run` and `fix`. */
private typedef Seams = {
	final shape: RefShape;
	final whileStmtKind: String;
	final notEqKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;
	final assignKind: String;
	final blockStmtKind: String;
	final exprStmtKind: String;
	final unaryMinusKinds: Array<String>;
	final numericLiteralKinds: Array<String>;
	final functionKinds: Array<String>;
	final paramKinds: Array<String>;
	final ifStatementKinds: Array<String>;
	final returnKinds: Array<String>;
	final eqKind: Null<String>;
	final parenKind: Null<String>;
	final strings: StringFoldSupport;
	final opaqueKinds: Array<String>;
};

/** A destructured `x.method(...)` call: its receiver node and method name. */
private typedef MethodCall = {
	final recv: QueryNode;
	final method: String;
};
/**
 * One resolved `S` / `B` operand: EITHER a plain string literal, OR a bare identifier bound to a
 * PARAMETER of the enclosing function. Exactly one of the two fields is non-null; `src` is the
 * operand's verbatim source text, which a finding message echoes (never a re-wrapped `.content`).
 */
private typedef Operand = {

	/** The literal content when the operand is a plain string literal, else null. */
	final literal: Null<String>;

	/** The binding offset when the operand is a parameter of the enclosing function, else null. */
	final paramFrom: Null<Int>;

	/** The operand's verbatim source text, delimiters included. */
	final src: String;

};
/**
 * Which arm a matched loop falls in — the three outcomes the type doc describes.
 */
private enum abstract Arm(Int) {

	/** Both operands are literals and `B` does not contain `S`: redundant, `Info`, autofixed. */
	final A = 0;

	/** Both operands are literals and `B` contains `S`: provably infinite, `Warning`, report-only. */
	final B = 1;

	/** At least one operand is a parameter: infinite for some argument, `Info`, report-only. */
	final C = 2;

}

/** A matched redundant-replace loop: both spans, which arm it is, and the text for the message. */
private typedef Match = {
	final whileSpan: Span;
	final stmtSpan: Span;
	final arm: Arm;
	final eqGuarded: Bool;
	final receiverName: String;
	final searchSrc: String;
	final replacementSrc: String;
};
