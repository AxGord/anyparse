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
 * Flags functions whose cyclomatic complexity exceeds a threshold — a metric
 * the formatter cannot fix, surfacing refactor hotspots. The first METRIC check
 * (every other check flags a defect to delete or rename); report-only, so `fix`
 * produces no edits.
 *
 * ## The metric
 *
 * Cyclomatic complexity = 1 + the number of decision points in a function. A
 * decision point is any node whose kind the grammar lists in
 * `RefShape.branchKinds` — for Haxe: `if` / `else-if`, `while` / `do-while`,
 * `for` (incl. comprehensions), each `switch` case, each `catch`, the boolean
 * `&&` / `||`, the ternary `?:`, and `??`. (`&&` / `||` are counted, matching
 * checkstyle's `CyclomaticComplexity`; the `case _` default is counted too — a
 * consistent +1 per switch, kept for grammar-neutrality.)
 *
 * Each function unit (`RefShape.functionKinds`) is measured independently: when
 * counting a function's branches the walk descends through nested local functions and
 * lambdas, counting their branches toward the enclosing function. Only
 * top-level and member functions are measured on their own, so a block
 * cannot evade the metric by being wrapped in a local function.
 *
 * ## Grammar-agnostic
 *
 * Both kind-sets come from the plugin; a grammar that declares neither
 * (`functionKinds` empty) makes the check a no-op.
 * The threshold is the built-in default unless a discovered
 * `checkstyle.json` configures `CyclomaticComplexity`, read via the
 * grammar plugin maxComplexity seam.
 */
@:nullSafety(Strict)
final class Complexity implements Check {

	/**
	 * The complexity above which a function is flagged — the conventional checkstyle
	 * onset, raised above McCabe's stricter 10 since a parser / codegen codebase legitimately
	 * exceeds it; used unless a `checkstyle.json` configures a different `CyclomaticComplexity` max.
	 */
	private static inline final DEFAULT_MAX_COMPLEXITY: Int = 20;

	public function new() {}

	public function id(): String {
		return 'complexity';
	}

	public function description(): String {
		return 'function cyclomatic complexity exceeds the threshold';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final localFunctionKinds: Array<String> = shape.localFunctionKinds ?? [];
		// A nested local function is NOT an independent complexity unit: its branches
		// count toward the enclosing measured function. Otherwise a block could be
		// hidden from the metric by wrapping it in a local function. Only top-level /
		// member functions are measured (and reported) on their own.
		final measured: Array<String> = [for (k in functionKinds) if (!localFunctionKinds.contains(k)) k];
		final branchKinds: Array<String> = shape.branchKinds ?? [];
		if (measured.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) {
				final max: Int = LintConfig.discover(entry.file)
					.intOption('complexity', 'max') ?? plugin.maxComplexity(entry.file) ?? DEFAULT_MAX_COMPLEXITY;
				walk(violations, entry.file, tree, measured, branchKinds, max);
			}
		}
		return violations;
	}

	/** Complexity has no mechanical autofix — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node`; for every function-unit descendant emit a `Warning` when its
	 * cyclomatic score exceeds the threshold. The whole tree is walked so nested
	 * functions are each reached and measured on their own.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, functionKinds: Array<String>, branchKinds: Array<String>, max: Int
	): Void {
		if (functionKinds.contains(node.kind)) checkFunction(out, file, node, functionKinds, branchKinds, max);
		for (c in node.children) walk(out, file, c, functionKinds, branchKinds, max);
	}

	/**
	 * Append a `Warning` if `fn`'s cyclomatic score exceeds the threshold. Bails
	 * (no finding) when the function node has no span to report.
	 */
	private static function checkFunction(
		out: Array<Violation>, file: String, fn: QueryNode, functionKinds: Array<String>, branchKinds: Array<String>, max: Int
	): Void {
		final span: Null<Span> = fn.span;
		if (span == null) return;
		final score: Int = 1 + countBranches(fn, functionKinds, branchKinds);
		if (score <= max) return;
		final name: String = fn.name ?? '<anonymous>';
		out.push({
			file: file,
			span: span,
			rule: 'complexity',
			severity: Severity.Warning,
			message: 'function \'$name\' has cyclomatic complexity $score (max $max)'
		});
	}

	/**
	 * The number of decision points in `fn`'s body — every descendant whose kind
	 * is in `branchKinds`, NOT descending into a nested function unit (which is
	 * measured on its own). Counts the function node's descendants, not the node.
	 */
	private static function countBranches(fn: QueryNode, functionKinds: Array<String>, branchKinds: Array<String>): Int {
		var count: Int = 0;
		for (child in fn.children) count += countIn(child, functionKinds, branchKinds);
		return count;
	}

	/** Branch count of the subtree rooted at `node`, stopping at nested function units. */
	private static function countIn(node: QueryNode, functionKinds: Array<String>, branchKinds: Array<String>): Int {
		if (functionKinds.contains(node.kind)) return 0;
		var count: Int = branchKinds.contains(node.kind) ? 1 : 0;
		for (child in node.children) count += countIn(child, functionKinds, branchKinds);
		return count;
	}

}
