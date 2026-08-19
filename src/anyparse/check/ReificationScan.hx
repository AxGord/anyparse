package anyparse.check;

import anyparse.check.Check.QuotationAware;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * The REIFICATION gate every source-rewriting check owes the `macro …` quotation.
 *
 * Source inside a quotation is not code the file runs — it is the AST the surrounding program
 * BUILDS. A rewrite that is equivalent everywhere else is therefore not equivalent there: it hands
 * the macro different data, and nothing rejects the result. Two measured examples, both of which
 * were live `--fix` bugs before this gate: `macro switch x { case A | B: … }` reifies its label as
 * ONE `EBinop(OpOr, …)` value while `case A, B:` reifies as TWO, and `default:` reifies as
 * `ESwitch.edef` where `case _:` becomes another entry of `cases`. A finding there is also
 * un-actionable even report-only — the reader cannot act on it without changing what the macro
 * emits.
 *
 * ## Two altitudes, one kind set
 *
 * The kinds come from `RefShape.opaqueKinds` (Haxe `MacroExpr`), the same slot reference analysis
 * reads for the other half of the same fact: uses inside a quotation may be spliced in from
 * anywhere, so a source scan cannot see them.
 *
 * A check whose collector is a plain recursive walk may gate AT THE DESCENT, one line in its own
 * walker — `if (seams.opaqueKinds.contains(node.kind)) return;` — which is what
 * `redundant-case-body`, `empty-case-arm`, `unused-case-binder`, `collapse-nested-switch` and
 * `case-pattern-separator` do. That is an optimisation and a structural convenience, not the
 * policy: it keeps the walk from descending at all, so the quoted subtree costs nothing and this
 * class never has to parse the file a second time. Removing one would not change any verdict.
 *
 * The POLICY is `withoutQuoted`, applied CENTRALLY so that it covers every check at once —
 * present and future — instead of being a rule each new check has to remember. It runs at the
 * three points where a check's own findings enter the pipeline:
 *
 *  - `Linter.run`, which every report and the whole safe `--fix` loop (and its cross-file arm)
 *    flow through;
 *  - `FixVerifier.verify`, the `RiskyFix` path, which calls `Check.run` itself. The compiler
 *    oracle guarding that path cannot substitute for the gate: an edited quotation still
 *    typechecks, so a rewrite of reified data passes verification untouched;
 *  - `Cli`'s oracle-assisted batch, which likewise calls `Check.run` itself.
 *
 * That the drop is enough to gate the FIXES as well is a property of the pipeline, not an
 * assumption: every fix path re-derives its edits from the violations it is handed, so a finding
 * that never appears produces no edit. `QuotationAware` is the opt-out, and nothing carries it.
 */
@:nullSafety(Strict)
final class ReificationScan {

	/**
	 * `violations` minus every finding that sits INSIDE a reification subtree of its own file.
	 *
	 * A finding whose span CONTAINS a quotation is KEPT: an `if`/`else` chain with a `macro { … }`
	 * branch body is ordinary code, and rewriting it relocates the quotation without touching what
	 * it builds. Only being contained counts.
	 *
	 * A grammar that leaves `opaqueKinds` unset has no reification construct, so the input comes
	 * back untouched and no file is parsed.
	 */
	public static function withoutQuoted(
		violations: Array<Violation>, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?exemptRules: Array<String>
	): Array<Violation> {
		final opaqueKinds: Array<String> = plugin.refShape().opaqueKinds ?? [];
		if (opaqueKinds.length == 0 || violations.length == 0) return violations;
		final exempt: Array<String> = exemptRules ?? [];
		final sourceByFile: Map<String, String> = [for (entry in files) entry.file => entry.source];
		final spansByFile: Map<String, Array<Span>> = [];
		final kept: Array<Violation> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span == null || exempt.contains(violation.rule)) {
				kept.push(violation);
				continue;
			}
			if (!insideAny(spansFor(spansByFile, sourceByFile, plugin, opaqueKinds, violation.file), span)) kept.push(violation);
		}
		return kept;
	}

	/**
	 * The rule ids among `checks` that DECLINE the quotation drop (`QuotationAware`) — the
	 * `exemptRules` every enforcement point passes alongside the findings it is filtering. Empty
	 * for every builtin today, which is what makes the gate's cost one `contains` per finding.
	 */
	public static function exemptIdsOf(checks: Array<Check>): Array<String> {
		return [for (check in checks) if (check is QuotationAware) check.id()];
	}

	/** Whether `span` sits inside one of `regions` — containing one does not count, only being contained by it. */
	private static function insideAny(regions: Array<Span>, span: Span): Bool {
		return regions.exists(region -> region.from <= span.from && span.to <= region.to);
	}

	/** `file`'s quotation spans, computed on first ask and memoised in `cache` for the rest of the run. */
	private static function spansFor(
		cache: Map<String, Array<Span>>, sources: Map<String, String>, plugin: GrammarPlugin, opaqueKinds: Array<String>, file: String
	): Array<Span> {
		final cached: Null<Array<Span>> = cache[file];
		if (cached != null) return cached;
		final source: Null<String> = sources[file];
		final spans: Array<Span> = source == null ? [] : spansOf(plugin, source, opaqueKinds);
		cache[file] = spans;
		return spans;
	}

	/** The spans of every `opaqueKinds` subtree in `source`; empty when it does not parse. */
	private static function spansOf(plugin: GrammarPlugin, source: String, opaqueKinds: Array<String>): Array<Span> {
		final out: Array<Span> = [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree != null) collectSpans(tree, opaqueKinds, out);
		return out;
	}

	/** Append the span of every `kinds` node at or under `node`, nested matches included. */
	private static function collectSpans(node: QueryNode, kinds: Array<String>, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		if (span != null && kinds.contains(node.kind)) out.push(span);
		for (c in node.children) collectSpans(c, kinds, out);
	}

}
