package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags the result of a `Null<T>`-returning call used directly as a non-null
 * number with no null check in between — the classic silent-null bug. Slice 1
 * of the nullable-source family recognises `Std.parseInt` / `Std.parseFloat`
 * (both return `Null<Int>` / `Null<Float>`): their result feeding a numeric
 * operator (`- * / % < > <= >= & | ^ << >> >>>`, unary `-` / `~`, or `+` in a
 * non-string context) or an array-index position assumes non-null, yet the
 * parse can fail and yield `null`. Report-only — there is no single safe edit
 * (a guard restructures the surrounding code), so `fix` yields nothing.
 *
 * ## Grammar-agnostic
 *
 * Every construct comes from `RefShape`, so the check holds for any grammar
 * that populates the seams (all optional; unset → no-op):
 *
 * - `nullableNumericReturnCalls` — dotted `Receiver.method` signatures whose
 *   result is a nullable number (`Std.parseInt`, `Std.parseFloat`).
 * - `numericOperatorKinds` — operator node kinds that consume their operands as
 *   non-null numbers.
 * - `indexAccessKind` — an index-access node; its index child (`children[1]`)
 *   is a numeric position.
 * - `stringLiteralKinds` — string-literal node kinds. A numeric-operator node
 *   with a string-literal operand is a string context (`n + "x"` concatenates),
 *   so it is skipped — `+` is the one operator that doubles as concatenation.
 *
 * Only the LITERAL string case is spared; `parseInt(s) + strVar` (a `Null<T>`
 * value that happens to be a `String`) still flags — telling those apart needs
 * a typechecker.
 */
@:nullSafety(Strict)
final class UncheckedNullable implements Check {

	public function new() {}

	public function id(): String {
		return 'unchecked-nullable';
	}

	public function description(): String {
		return 'a Null<T>-returning call (Std.parseInt / Std.parseFloat) whose result is used directly as a number, with no null check';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final numericOps: Array<String> = shape.numericOperatorKinds ?? [];
		final signatures: Array<String> = shape.nullableNumericReturnCalls ?? [];
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final identKind: Null<String> = shape.identKind;
		if (numericOps.length == 0 || signatures.length == 0 || callKind == null || fieldAccessKind == null || identKind == null) return [];
		final callKindValue: String = callKind;
		final fieldAccessKindValue: String = fieldAccessKind;
		final identKindValue: String = identKind;
		final sigs: Array<{ receiver: String, method: String }> = [];
		for (s in signatures) {
			final dot: Int = s.lastIndexOf('.');
			if (dot > 0 && dot < s.length - 1) sigs.push({ receiver: s.substring(0, dot), method: s.substring(dot + 1) });
		}
		if (sigs.length == 0) return [];
		final ctx: Ctx = {
			numericOps: numericOps,
			indexAccessKind: shape.indexAccessKind,
			stringLiteralKinds: shape.stringLiteralKinds ?? [],
			callKind: callKindValue,
			fieldAccessKind: fieldAccessKindValue,
			identKind: identKindValue,
			sigs: sigs
		};
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, ctx);
		}
		return violations;
	}

	/** No safe single edit — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`, flagging a nullable-numeric call in any non-null numeric position. */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, ctx: Ctx): Void {
		if (ctx.numericOps.contains(node.kind)) {
			final stringContext: Bool = node.children.exists(c -> ctx.stringLiteralKinds.contains(c.kind));
			if (!stringContext) for (c in node.children) flagIfNullable(out, file, c, ctx);
		} else if (ctx.indexAccessKind != null && node.kind == ctx.indexAccessKind && node.children.length >= 2)
			flagIfNullable(out, file, node.children[1], ctx);
		for (c in node.children) walk(out, file, c, ctx);
	}

	/** Flag `node` when it is a recognised nullable-numeric call. */
	private static function flagIfNullable(out: Array<Violation>, file: String, node: QueryNode, ctx: Ctx): Void {
		final matched: Null<String> = matchedSignature(node, ctx);
		final span: Null<Span> = node.span;
		if (matched == null || span == null) return;
		out.push({
			file: file,
			span: span,
			rule: 'unchecked-nullable',
			severity: Severity.Warning,
			message: 'result of $matched can be null; it is used as a number here with no null check'
		});
	}

	/** The `Receiver.method` signature `node` matches, or null when it is not a recognised call. */
	private static function matchedSignature(node: QueryNode, ctx: Ctx): Null<String> {
		if (node.kind != ctx.callKind || node.children.length < 1) return null;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != ctx.fieldAccessKind || method == null || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		final receiverName: Null<String> = receiver.name;
		if (receiver.kind != ctx.identKind || receiverName == null) return null;
		for (sig in ctx.sigs) if (sig.receiver == receiverName && sig.method == method) return '${sig.receiver}.${sig.method}';
		return null;
	}

}

/** Resolved per-run constants threaded through the recursive walk. */
private typedef Ctx = {
	var numericOps: Array<String>;
	var indexAccessKind: Null<String>;
	var stringLiteralKinds: Array<String>;
	var callKind: String;
	var fieldAccessKind: String;
	var identKind: String;
	var sigs: Array<{ receiver: String, method: String }>;
};
