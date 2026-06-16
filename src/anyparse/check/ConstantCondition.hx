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
 * Flags a boolean literal used as the condition of an `if` — `if (true) ...` /
 * `if (false) ...` (SonarLint S1145): the branch is always or never taken, so
 * either the condition or a whole branch is dead. Purely structural (no type
 * information needed), so it holds even without a type-checker. Report-only:
 * which branch should survive is the author's call, so there is no mechanical
 * autofix.
 *
 * ## Grammar-agnostic
 *
 * The boolean-literal kind comes from `RefShape.boolLitKind` and the
 * condition-bearing kinds from `RefShape.branchConditionKinds` (the condition is
 * `children[0]`); either unset makes the check a no-op. Loops are deliberately
 * NOT among the branch kinds: `while (true)` is an idiomatic infinite loop, not
 * a smell.
 */
@:nullSafety(Strict)
final class ConstantCondition implements Check {

	public function new() {}

	public function id(): String {
		return 'constant-condition';
	}

	public function description(): String {
		return 'a boolean literal as an if condition (if (true) / if (false))';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final boolLitKind: Null<String> = shape.boolLitKind;
		final branchKinds: Null<Array<String>> = shape.branchConditionKinds;
		if (boolLitKind == null || branchKinds == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, boolLitKind, branchKinds);
		}
		return violations;
	}

	/** Constant-condition is report-only — no autofix. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`, flagging every branch whose condition is a boolean literal. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, boolLitKind: String, branchKinds: Array<String>
	): Void {
		if (branchKinds.contains(node.kind) && node.children.length > 0 && node.children[0].kind == boolLitKind) {
			final cond: QueryNode = node.children[0];
			final span: Null<Span> = cond.span;
			if (span != null) {
				final always: String = source.substring(span.from, span.to) == 'false' ? 'false' : 'true';
				out.push({
					file: file,
					span: span,
					rule: 'constant-condition',
					severity: Severity.Warning,
					message: 'condition is always $always'
				});
			}
		}
		for (c in node.children) walk(out, file, source, c, boolLitKind, branchKinds);
	}

}
