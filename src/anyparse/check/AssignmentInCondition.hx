package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an assignment (`=`) used as a condition — `if (a = b)`, `while (a = b)`,
 * `do … while (a = b)` — which almost always means `==` was intended. A genuine
 * assign-in-condition (`while ((line = next()) != null)` factored to a bare assign)
 * is rare in Haxe, where a condition must be `Bool`, so this only fires for a
 * `Bool`-typed assignment that compiles — a high-signal typo. `Warning`,
 * report-only (no autofix: `=` vs `==` is the user's intent to resolve).
 *
 * ## Grammar-agnostic
 *
 * The condition position differs per construct, so two kind-sets pin it exactly:
 * `RefShape.conditionFirstChildKinds` (condition is `children[0]` — `if` / `while`)
 * and `conditionLastChildKinds` (condition is the LAST child — `do … while`). The
 * condition node is matched against `assignKind`, unwrapping one `parenKind` layer
 * first (`if ((a = b))`). Targeting the condition slot by position — not scanning
 * all children — avoids a false positive on a branch whose value is itself an
 * assignment (`if (c) x = y else z`). Any optional kind unset → no-op.
 */
@:nullSafety(Strict)
final class AssignmentInCondition implements Check {

	public function new() {}

	public function id(): String {
		return 'assignment-in-condition';
	}

	public function description(): String {
		return 'an assignment (=) used as a condition — likely a == typo';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return [];
		final firstKinds: Array<String> = shape.conditionFirstChildKinds ?? [];
		final lastKinds: Array<String> = shape.conditionLastChildKinds ?? [];
		if (firstKinds.length == 0 && lastKinds.length == 0) return [];
		final parenKind: Null<String> = shape.parenKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, assignKind, parenKind, firstKinds, lastKinds);
		}
		return violations;
	}

	/** Report-only: `=` vs `==` is the author's intent, not ours to rewrite. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, assignKind: String, parenKind: Null<String>, firstKinds: Array<String>,
		lastKinds: Array<String>
	): Void {
		final cond: Null<QueryNode> = conditionOf(node, firstKinds, lastKinds);
		if (cond != null) {
			final assign: Null<QueryNode> = unwrapToAssign(cond, assignKind, parenKind);
			if (assign != null) {
				final span: Null<Span> = assign.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'assignment-in-condition',
					severity: Severity.Warning,
					message: 'assignment in a condition — did you mean ==?'
				});
			}
		}
		for (c in node.children) walk(out, file, c, assignKind, parenKind, firstKinds, lastKinds);
	}

	/** The condition child of `node`, or null when `node` is not a condition holder. */
	private static function conditionOf(node: QueryNode, firstKinds: Array<String>, lastKinds: Array<String>): Null<QueryNode> {
		return node.children.length == 0
			? null
			: firstKinds.contains(node.kind)
				? node.children[0]
				: lastKinds.contains(node.kind) ? node.children[node.children.length - 1] : null;
	}

	/** `cond` itself (or its single parenthesized inner) when it is an assignment; else null. */
	private static function unwrapToAssign(cond: QueryNode, assignKind: String, parenKind: Null<String>): Null<QueryNode> {
		var n: QueryNode = cond;
		if (parenKind != null && n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return n.kind == assignKind ? n : null;
	}

}
