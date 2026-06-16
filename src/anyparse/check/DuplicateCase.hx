package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a duplicated switch case — a second branch whose pattern repeats an
 * earlier branch's in the same switch, making it dead. Purely structural;
 * report-only. Guarded branches (`case x if (cond):`) are skipped: two branches
 * with the same pattern but different guards are legitimately distinct, and
 * isolating the guard reliably needs more than the pattern node.
 *
 * ## Grammar-agnostic
 *
 * The case-branch kind comes from `RefShape.caseBranchKind` (unset → no-op). A
 * branch's pattern is its first child; a guard, when present, sits between the
 * pattern and the body, introduced by `if` in the intervening source.
 */
@:nullSafety(Strict)
final class DuplicateCase implements Check {

	private static final GUARD: EReg = ~/\bif\b/;

	public function new() {}

	public function id(): String {
		return 'duplicate-case';
	}

	public function description(): String {
		return 'a switch case whose pattern repeats an earlier case in the same switch';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final caseBranchKind: Null<String> = plugin.refShape().caseBranchKind;
		if (caseBranchKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, caseBranchKind);
		}
		return violations;
	}

	/** Duplicate-case has no autofix — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node`; among its DIRECT case-branch children flag a branch whose
	 * pattern source repeats an earlier sibling's. The whole tree is walked so
	 * nested switches are reached.
	 */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, caseBranchKind: String): Void {
		final seen: Array<String> = [];
		for (branch in node.children) if (branch.kind == caseBranchKind) {
			final pattern: Null<String> = patternSource(branch, source);
			if (pattern != null) {
				if (seen.contains(pattern)) {
					final span: Null<Span> = branch.span;
					if (span != null) out.push({
						file: file,
						span: span,
						rule: 'duplicate-case',
						severity: Severity.Warning,
						message: 'duplicate case label'
					});
				} else
					seen.push(pattern);
			}
		}
		for (c in node.children) walk(out, file, source, c, caseBranchKind);
	}

	/**
	 * The trimmed source of `branch`'s pattern (its first child), or null when the
	 * branch is guarded (an `if` appears between the pattern and the next child) or
	 * has no spanned pattern — both are skipped rather than compared.
	 */
	private static function patternSource(branch: QueryNode, source: String): Null<String> {
		final kids: Array<QueryNode> = branch.children;
		if (kids.length == 0) return null;
		final patternSpan: Null<Span> = kids[0].span;
		if (patternSpan == null) return null;
		if (kids.length >= 2) {
			final nextSpan: Null<Span> = kids[1].span;
			if (nextSpan != null && GUARD.match(source.substring(patternSpan.to, nextSpan.from))) return null;
		}
		return StringTools.trim(source.substring(patternSpan.from, patternSpan.to));
	}

}
