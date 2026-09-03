package unit.check;

import anyparse.check.AvoidDynamic;
import anyparse.check.Check;
import anyparse.check.CheckScan;
import anyparse.check.Linter;
import anyparse.check.ReificationScan;
import anyparse.check.Severity;
import anyparse.check.StringLiteralDup;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The CENTRAL reification gate: a finding whose span sits inside a `macro …` quotation is dropped
 * for EVERY check, at the three points a check's own findings enter the pipeline, and no check has
 * to know about it.
 *
 * The rules exercised here carry NO gate of their own — that is the point. `string-literal-dup`
 * and `avoid-dynamic` are the two the real-tree measurement found still reporting inside
 * quotations before this gate existed, so they are the honest witnesses for it; each is paired
 * with the same shape written as ordinary code, which must survive.
 *
 * `QuotationAware` is covered by a pair of test doubles rather than a builtin, because nothing
 * builtin implements it — the marker exists so the drop is a policy a future check can decline.
 */
class ReificationGateTest extends Test {

	/** Three occurrences of one literal — `string-literal-dup`'s trigger — written inside a quotation. */
	private static inline final DUP_QUOTED: String = 'class C {\n\tfunction f():Void {\n\t\tfinal e = macro {\n'
		+ '\t\t\tg(\'marker\');\n\t\t\tg(\'marker\');\n\t\t\tg(\'marker\');\n\t\t};\n\t}\n}\n';

	/** The same three occurrences as ordinary code. */
	private static inline final DUP_PLAIN: String =
		'class C {\n\tfunction f():Void {\n\t\tg(\'marker\');\n\t\tg(\'marker\');\n\t\tg(\'marker\');\n\t}\n}\n';

	/** An annotated `Dynamic` local — `avoid-dynamic`'s trigger — written inside a quotation. */
	private static inline final DYNAMIC_QUOTED: String = 'class C {\n\tfunction f():Void {\n\t\tfinal e = macro {\n'
		+ '\t\t\tvar eff:Dynamic = source;\n\t\t\ttrace(eff);\n\t\t};\n\t}\n}\n';

	/** The same local as ordinary code. */
	private static inline final DYNAMIC_PLAIN: String =
		'class C {\n\tfunction f():Void {\n\t\tvar eff:Dynamic = source;\n\t\ttrace(eff);\n\t}\n}\n';

	/** One `MARK` identifier inside a quotation and one outside — what the test doubles report on. */
	private static inline final MARKED: String =
		'class C {\n\tfunction f():Void {\n\t\tfinal e = macro {\n\t\t\tMARK;\n\t\t};\n\t\tMARK;\n\t}\n}\n';

	public function testUngatedRuleLosesItsQuotedFinding(): Void {
		Assert.equals(0, linted(new StringLiteralDup(), DUP_QUOTED).length);
	}

	/** The same shape as real code survives — so the drop is the QUOTATION, not the shape. */
	public function testUngatedRuleKeepsItsPlainFinding(): Void {
		Assert.equals(1, linted(new StringLiteralDup(), DUP_PLAIN).length);
	}

	/** The check ITSELF still reports it: the gate lives in the pipeline, not in the rule. */
	public function testCheckItselfStillSeesTheQuotedFinding(): Void {
		Assert.equals(1, new StringLiteralDup().run(entry(DUP_QUOTED), new HaxeQueryPlugin()).length);
	}

	public function testDynamicRuleLosesItsQuotedFinding(): Void {
		Assert.equals(0, linted(new AvoidDynamic(), DYNAMIC_QUOTED).length);
		Assert.equals(1, linted(new AvoidDynamic(), DYNAMIC_PLAIN).length);
	}

	/**
	 * `avoid-dynamic` is the one auto-fixable rule the measurement caught reporting inside a
	 * quotation, and it is a `RiskyFix` — a path whose compiler oracle cannot help, since an edited
	 * quotation still typechecks. This is that path in miniature: `Linter.collect` is what
	 * `FixVerifier.verify` calls, and the fix it would be handed is empty. The real verifier with a
	 * real oracle behind it is covered by `AvoidDynamicRiskyFixE2ETest`.
	 */
	public function testDynamicRuleYieldsNoQuotedEdit(): Void {
		final check: AvoidDynamic = new AvoidDynamic();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final own: Array<Violation> = check.run(entry(DYNAMIC_QUOTED), plugin);
		Assert.equals(1, own.length, 'the check itself must still find it, else the gate is untested');
		final gated: Array<Violation> = Linter.collect(entry(DYNAMIC_QUOTED), plugin, [check]);
		Assert.equals(0, gated.length);
		Assert.equals(0, check.fix(DYNAMIC_QUOTED, gated, plugin).length);
	}

	/** A plain check loses the quoted MARK and keeps the one below the quotation. */
	public function testDoubleLosesItsQuotedFinding(): Void {
		final vs: Array<Violation> = linted(new PlainMarkerCheck(), MARKED);
		Assert.equals(1, vs.length);
		final span: Null<Span> = vs[0].span;
		Assert.isTrue(span != null && span.from > MARKED.lastIndexOf('};'), 'the surviving MARK must be the one outside');
	}

	/** The SAME double, opting out through `QuotationAware`, keeps both. */
	public function testQuotationAwareDoubleKeepsItsQuotedFinding(): Void {
		Assert.equals(2, linted(new AwareMarkerCheck(), MARKED).length);
	}

	/**
	 * BOTH doubles in ONE pass: the exemption is per CHECK, not per run — the gated double loses its
	 * quoted MARK while the opted-out one beside it keeps both, so 3 of the 4 findings survive.
	 */
	public function testExemptionIsPerCheckWithinOnePass(): Void {
		final mixed: Array<Violation> = Linter.run(entry(MARKED), new HaxeQueryPlugin(), [new PlainMarkerCheck(), new AwareMarkerCheck()]);
		Assert.equals(3, mixed.length);
		Assert.equals(1, mixed.filter(v -> v.rule == 'marker-plain').length);
		Assert.equals(2, mixed.filter(v -> v.rule == 'marker-aware').length);
	}

	/** The exemption is read from the marker, not from the rule id. */
	public function testExemptIdsOfReadsTheMarker(): Void {
		Assert.equals(0, ReificationScan.exemptIdsOf([new PlainMarkerCheck()]).length);
		Assert.equals('marker-aware', ReificationScan.exemptIdsOf([new AwareMarkerCheck()]).join(','));
	}

	/**
	 * A finding whose span CONTAINS a quotation is not inside one, and stays — an `if`/`else` chain
	 * with a `macro { … }` branch body is ordinary code, and rewriting it relocates the quotation
	 * without touching what it builds. Asserted on a hand-built whole-file span, the only shape that
	 * pins the containment direction on its own.
	 */
	public function testFindingContainingAQuotationSurvives(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final wrapping: Violation = {
			file: 'C.hx',
			span: new Span(0, MARKED.length),
			rule: 'wrapping',
			severity: Severity.Info,
			message: 'spans the whole file, quotation included'
		};
		Assert.equals(1, ReificationScan.withoutQuoted([wrapping], entry(MARKED), plugin).length);
	}

	private function entry(source: String): Array<{ file: String, source: String }> {
		return [{ file: 'C.hx', source: source }];
	}

	/** `check`'s findings for `source` as `Linter.run` reports them — the altitude the gate lives at. */
	private function linted(check: Check, source: String): Array<Violation> {
		return Linter.run(entry(source), new HaxeQueryPlugin(), [check]);
	}

}

/**
 * A test double that reports one finding per identifier named `MARK`. Two copies exist: this one
 * takes the central gate, `AwareMarkerCheck` declines it. Everything but the marker interface and
 * the rule id is shared, so a verdict difference between them can only come from the marker.
 */
private class PlainMarkerCheck implements Check {

	public function new() {}

	public function id(): String {
		return 'marker-plain';
	}

	public function description(): String {
		return 'a test double flagging every MARK identifier';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return MarkerScan.findings(id(), files, plugin);
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

}

/** `PlainMarkerCheck`'s opted-out twin — the ONLY difference is `QuotationAware`. */
private class AwareMarkerCheck implements Check implements QuotationAware {

	public function new() {}

	public function id(): String {
		return 'marker-aware';
	}

	public function description(): String {
		return 'a test double flagging every MARK identifier, quotations included';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return MarkerScan.findings(id(), files, plugin);
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

}

/** The scan both doubles share: one finding per `MARK` identifier, quotations included. */
private class MarkerScan {

	public static function findings(rule: String, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(out, entry.file, rule, tree);
		}
		return out;
	}

	private static function walk(out: Array<Violation>, file: String, rule: String, node: QueryNode): Void {
		final span: Null<Span> = node.span;
		if (node.name == 'MARK' && span != null) out.push({
			file: file,
			span: span,
			rule: rule,
			severity: Severity.Info,
			message: 'MARK'
		});
		for (child in node.children) walk(out, file, rule, child);
	}

}
