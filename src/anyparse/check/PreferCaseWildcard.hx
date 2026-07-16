package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a `default:` switch branch the idiomatic Haxe `case _:` should replace
 * — consistent with pattern-matching syntax; `Severity.Info` (a modernization
 * cleanup), with an autofix that swaps the `default` keyword token for `case _`,
 * leaving the trailing `:` and the branch body untouched. Grammar-agnostic over
 * `RefShape.defaultBranchKind` (unset -> no-op).
 *
 * ## Equivalence — why the swap is always safe
 *
 * In Haxe a `default:` branch and an unguarded `case _:` are equivalent: both
 * match every subject the earlier cases did not. `default` is also
 * position-independent, but is written last in practice; a `case _:` in the
 * same slot matches everything the remaining branches would have the same way
 * `default` does, so the rewrite is textual and safe regardless of the branch's
 * position. Only the keyword is spliced, so a multi-statement or block body is
 * carried through verbatim.
 */
@:nullSafety(Strict)
final class PreferCaseWildcard implements Check {

	private static final KEYWORD: String = 'default';

	private static final REPLACEMENT: String = 'case _';

	public function new() {}

	public function id(): String {
		return 'prefer-case-wildcard';
	}

	public function description(): String {
		return 'a switch default: replaceable with the idiomatic case _:';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final defaultBranchKind: Null<String> = plugin.refShape().defaultBranchKind;
		if (defaultBranchKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, tree, defaultBranchKind);
		}
		return violations;
	}

	/**
	 * Swap each flagged `default` keyword for `case _`. The edit fires only when
	 * the bytes at the reported span are literally the keyword (a guard against
	 * any unexpected span — `substring` clamps, so a span near EOF simply fails
	 * the equality), so the trailing `:` and the body stay intact.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final end: Int = span.from + KEYWORD.length;
			if (source.substring(span.from, end) != KEYWORD) continue;
			edits.push({ span: new Span(span.from, end), text: REPLACEMENT });
		}
		return edits;
	}

	/**
	 * Walk `node` and flag every `default:` branch, reporting the `default`
	 * keyword region (the branch's span start — a `DefaultBranch` always opens
	 * with the keyword). The whole tree is walked so nested switches are reached.
	 */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, defaultBranchKind: String): Void {
		if (node.kind == defaultBranchKind) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: new Span(span.from, span.from + KEYWORD.length),
				rule: 'prefer-case-wildcard',
				severity: Severity.Info,
				message: 'use case _: instead of default:'
			});
		}
		for (c in node.children) walk(out, file, c, defaultBranchKind);
	}

}
