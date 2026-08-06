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
 * either does nothing extra or never stops. Two arms, opposite outcomes:
 *
 * - **Arm A — `B` does NOT contain `S`.** After one `replace`, `x` has zero
 *   occurrences of `S` left, so the guard is false and the loop would have run
 *   at most once anyway. `Severity.Info`, with an autofix that collapses the
 *   whole loop to the single unconditional assignment `x = x.replace(S, B);` —
 *   sound even when the ORIGINAL string had zero occurrences of `S` to begin
 *   with, since `replace` on a no-match input returns the string unchanged.
 * - **Arm B — `B` CONTAINS `S`.** Every replacement reinserts `S` into `x`, so
 *   the guard is true again on the next check — the loop is INFINITE for any
 *   input that ever contains `S`. This is a real bug, not a style nit:
 *   `Severity.Warning`, report-only (there is no mechanical fix for "the author
 *   meant something else").
 *
 * ## What is matched
 *
 * The guard accepts three spellings of "does `x` contain `S`": `x.indexOf(S) !=
 * -1`, its reversed operand order `-1 != x.indexOf(S)`, and `x.contains(S)`.
 * `S` and `B` must both be PLAIN string literals (`StringFoldSupport.literalOf`
 * — no interpolation), and the loop's `indexOf`/`contains` argument must be the
 * SAME literal (by raw content) as `replace`'s first argument — anything else is
 * not this pattern and is left alone. The receiver `x` must be a single
 * identifier — never `this.x` / `obj.x` / an index access — bound to the SAME
 * local/parameter declaration in the guard call, the `replace` call and the
 * assignment target (`TypeResolver.identBindingFrom`, so a same-named variable
 * from an unrelated scope never falsely qualifies), and that declaration must
 * carry an explicit `:String` annotation (`TypeInfoProvider.declaredTypes`) — an
 * untyped or non-`String` receiver is a silent miss, never a wrong flag.
 *
 * The loop body must be EXACTLY the one assignment statement — braced with a
 * single statement, or the bare unbraced form Haxe allows for a single-statement
 * `while`. Any additional statement (a second assignment, a `trace`, …) means the
 * loop is doing more than a redundant replace and is skipped entirely.
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
 * subtrees.
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
		return 'a while (x.indexOf(S) != -1) x = x.replace(S, B); loop — replace() already replaces every occurrence in one call';
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
			if (m != null && m.armA && wanted.contains('${m.whileSpan.from}:${m.whileSpan.to}'))
				out.push({ span: m.whileSpan, text: source.substring(m.stmtSpan.from, m.stmtSpan.to) });
		}
		for (c in node.children) fixWalk(c, root, source, declaredTypes, s, wanted, out);
	}

	/**
	 * If `whileNode` is a qualifying redundant-replace loop, its match (spans, arm, and the
	 * receiver/literal text for the message); else null. See the type doc for the full gate list.
	 */
	private static function matchWhile(whileNode: QueryNode, root: QueryNode, source: String, declaredTypes: Map<Int, String>, s: Seams):
		Null<Match> {
		if (whileNode.children.length != WHILE_CHILD_COUNT) return null;
		var cond: QueryNode = whileNode.children[0];
		if (s.parenKind != null && cond.kind == s.parenKind && cond.children.length == 1) cond = cond.children[0];
		final guard: Null<{ receiver: QueryNode, search: QueryNode }> = matchGuard(cond, source, s);
		if (guard == null) return null;
		final receiver: QueryNode = guard.receiver;
		if (receiver.kind != s.identKind) return null;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(receiver, root, s.shape);
		if (bindingFrom == null || declaredTypes[bindingFrom] != STRING_TYPE) return null;
		final searchLit: Null<StringLiteral> = s.strings.literalOf(guard.search, source);
		if (searchLit == null) return null;

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
		final searchLit2: Null<StringLiteral> = s.strings.literalOf(value.children[1], source);
		if (searchLit2 == null || searchLit2.content != searchLit.content) return null;
		final replaceLit: Null<StringLiteral> = s.strings.literalOf(value.children[2], source);
		if (replaceLit == null) return null;

		final whileSpan: Null<Span> = whileNode.span;
		final stmtSpan: Null<Span> = stmt.span;
		final searchSpan: Null<Span> = guard.search.span;
		final replaceSpan: Null<Span> = value.children[2].span;
		if (whileSpan == null || stmtSpan == null || searchSpan == null || replaceSpan == null) return null;
		return {
			whileSpan: whileSpan,
			stmtSpan: stmtSpan,
			armA: replaceLit.content.indexOf(searchLit.content) == -1,
			receiverName: receiver.name ?? '',
			// The literal's OWN verbatim source (delimiters included), not a hand-rewrapped
			// `.content` — content may itself carry a quote character (`"'"`), and rewrapping
			// it in a hardcoded delimiter would mis-render (`':', '''`).
			searchSrc: source.substring(searchSpan.from, searchSpan.to),
			replacementSrc: source.substring(replaceSpan.from, replaceSpan.to)
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
		return call != null && call.method == CONTAINS_METHOD && cond.children.length == ONE_ARG_CALL_CHILD_COUNT
			? { receiver: call.recv, search: cond.children[1] }
			: null;
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
		if (body.kind == s.blockStmtKind && body.children.length == 1 && body.children[0].kind == s.exprStmtKind)
			return body.children[0];
		return null;
	}

	/** `m` as its `Info` (arm A, autofixable) or `Warning` (arm B, infinite-loop hazard, report-only) `Violation`. */
	private static function toViolation(file: String, m: Match): Violation {
		final search: String = excerpt(m.searchSrc);
		final replacement: String = excerpt(m.replacementSrc);
		return m.armA ? {
			file: file,
			span: m.whileSpan,
			rule: RULE_ID,
			severity: Severity.Info,
			message: 'this while (${m.receiverName}.indexOf($search) != -1) loop runs at most once — replace() already replaces every occurrence; collapses to ${m.receiverName} = ${m.receiverName}.replace($search, $replacement);'
		} : {
			file: file,
			span: m.whileSpan,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: 'this loop never terminates for any ${m.receiverName} containing $search — replace($search, $replacement) reintroduces it every time, since $replacement itself contains $search'
		};
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
	final parenKind: Null<String>;
	final strings: StringFoldSupport;
	final opaqueKinds: Array<String>;
};

/** A destructured `x.method(...)` call: its receiver node and method name. */
private typedef MethodCall = {
	final recv: QueryNode;
	final method: String;
};

/** A matched redundant-replace loop: both spans, which arm it is, and the text for the message. */
private typedef Match = {
	final whileSpan: Span;
	final stmtSpan: Span;
	final armA: Bool;
	final receiverName: String;
	final searchSrc: String;
	final replacementSrc: String;
};
