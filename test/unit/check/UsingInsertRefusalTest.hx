package unit.check;

import anyparse.check.BoolLoopScan;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.Violation;
import anyparse.check.CheckScan;
import anyparse.check.PreferStaticExtension;
import anyparse.check.Severity;
import anyparse.check.UsingScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `using`-insert seam's second refusal: the anchor byte is already covered by an accepted
 * rewrite, so the declaration cannot be spliced at all.
 *
 * ## Why this is pinned
 *
 * All three implementations answered that case by inserting NOTHING and reporting SUCCESS —
 * `UsingScan.appendUsingInsert` returned `true`, `BoolLoopScan.withUsingInsert` handed back the
 * ungrouped rewrites, `PreferStaticExtension.appendUsingInserts` returned `Void`. The caller then
 * KEPT its rewrites, and the file it wrote spelled an extension call with no `using` to bind it:
 * output that does not compile, reported as a clean fix. That is precisely the outcome the
 * `Guarded` branch beside each of them refuses, so the fix is to give the covered anchor the same
 * answer — a refusal, by name, with the whole edit set dropped.
 *
 * ## What the fixtures are, and why they are not end-to-end
 *
 * The overlap is UNREACHABLE through the six rules that share the seam today: every insert anchor
 * is a zero-width offset inside the module header, `editsOverlapAny` needs an accepted edit to
 * contain it STRICTLY, and every edit those rules build sits inside a type member's body. Measured
 * over 2649 files (this project's `src` + `test`, the `haxe-formatter` fork, Pony's `src` +
 * `tools`): 7 (rule, file) pairs produce edits at all, 6 of them carry a `using` insert, and the
 * overlap branch is taken ZERO times. So these fixtures address the three implementations at their
 * own API rather than through a source file — the contract is what shipped wrong, and a caller one
 * refactor away from a header-spanning edit is what it protects.
 *
 * Each `control` is paired with a `guard` on the SAME entry point and the SAME header, differing
 * only in whether the rewrite covers the anchor: a fix that turned every insert into a refusal
 * would pass the controls and fail the guards.
 */
@:nullSafety(Strict)
class UsingInsertRefusalTest extends Test {

	/** A module whose header declares one `using`, so the insert anchor is that declaration's first byte. */
	private static inline final SRC: String = 'package p;\n\nusing StringTools;\n\nclass C {\n\tfunction f() {}\n}\n';

	/**
	 * `appendUsingInsert` must answer `false` when the anchor is covered — `true` told the caller
	 * the module was in scope, and every one of the four rules sharing this helper keeps its edits
	 * on `true`. The edit array is asserted UNCHANGED: "did not insert" must never look like
	 * "inserted". Killed by arm `M-USING-INSERT-COVERED-SILENT`.
	 */
	@:pin('control')
	@:killer('M-USING-INSERT-COVERED-SILENT')
	public function testCoveredAnchorRefusesAndAppendsNothing(): Void {
		final header: UsingHeader = headerOf();
		final anchor: Int = anchorOf(header);
		final edits: Array<{ span: Span, text: String }> = [{ span: new Span(anchor - 1, anchor + 1), text: 'ZZ' }];
		final found: Array<Violation> = [violation(anchor - 1, anchor + 1)];
		Assert.isFalse(UsingScan.appendUsingInsert(header, 'Lambda', edits, found));
		Assert.equals(1, edits.length);
		Assert.equals('ZZ', edits[0].text);
		final reason: Null<String> = found[0].declineReason;
		Assert.notNull(reason);
		Assert.isTrue(reason != null && reason.indexOf('using Lambda;') >= 0);
	}

	/** The same call with a rewrite that does NOT cover the anchor still inserts — the refusal is about the overlap, not the module. */
	@:pin('guard')
	public function testUncoveredAnchorStillInserts(): Void {
		final header: UsingHeader = headerOf();
		final anchor: Int = anchorOf(header);
		final edits: Array<{ span: Span, text: String }> = [{ span: new Span(SRC.length - 4, SRC.length - 2), text: 'ZZ' }];
		final found: Array<Violation> = [violation(SRC.length - 4, SRC.length - 2)];
		Assert.isTrue(UsingScan.appendUsingInsert(header, 'Lambda', edits, found));
		Assert.equals(2, edits.length);
		Assert.equals(anchor, edits[1].span.from);
		Assert.equals(anchor, edits[1].span.to);
		Assert.isTrue(edits[1].text.indexOf('using Lambda;') >= 0);
		Assert.isNull(found[0].declineReason);
	}

	/**
	 * The second instance of the same contract, in the seam `prefer-exists` / `prefer-foreach` own:
	 * an EMPTY grouped-edit list is the refusal, and handing back the ungrouped rewrites is exactly
	 * the "calls without their `using`" the atomic group exists to forbid. Killed by arm
	 * `M-BOOL-LOOP-USING-COVERED-KEPT`.
	 */
	@:pin('control')
	@:killer('M-BOOL-LOOP-USING-COVERED-KEPT')
	@:access(anyparse.check.BoolLoopScan)
	public function testBoolLoopCoveredAnchorDropsTheWholeSet(): Void {
		final header: UsingHeader = headerOf();
		final anchor: Int = anchorOf(header);
		final rewrites: Array<{ span: Span, text: String }> = [{ span: new Span(anchor - 1, anchor + 1), text: 'ZZ' }];
		final found: Array<Violation> = [violation(anchor - 1, anchor + 1)];
		final out: Array<GroupedEdit> = BoolLoopScan.withUsingInsert(rewrites, [true], header, found);
		Assert.equals(0, out.length);
		Assert.notNull(found[0].declineReason);
	}

	/** The uncovered twin: the rewrite and the `using` come back as ONE atomic group. */
	@:pin('guard')
	@:access(anyparse.check.BoolLoopScan)
	public function testBoolLoopUncoveredAnchorGroupsTheInsert(): Void {
		final header: UsingHeader = headerOf();
		final rewrites: Array<{ span: Span, text: String }> = [{ span: new Span(SRC.length - 4, SRC.length - 2), text: 'ZZ' }];
		final found: Array<Violation> = [violation(SRC.length - 4, SRC.length - 2)];
		final out: Array<GroupedEdit> = BoolLoopScan.withUsingInsert(rewrites, [true], header, found);
		Assert.equals(2, out.length);
		Assert.equals(out[0].group, out[1].group);
		Assert.notNull(out[1].group);
		Assert.isTrue(out[1].text.indexOf('using Lambda;') >= 0);
	}

	/**
	 * The third instance: `prefer-static-extension` merges every module it owes into ONE edit, and
	 * a `Void` return made a merged edit that could not be appended indistinguishable from one that
	 * was. Killed by arm `M-PSE-USING-INSERT-SILENT`.
	 */
	@:pin('control')
	@:killer('M-PSE-USING-INSERT-SILENT')
	@:access(anyparse.check.PreferStaticExtension)
	public function testStaticExtensionCoveredAnchorRefuses(): Void {
		final header: UsingHeader = headerOf();
		final anchor: Int = anchorOf(header);
		final edits: Array<{ span: Span, text: String }> = [{ span: new Span(anchor - 1, anchor + 1), text: 'ZZ' }];
		Assert.isFalse(PreferStaticExtension.appendUsingInserts(header, ['Lambda', 'StringTools'], edits));
		Assert.equals(1, edits.length);
	}

	/** The uncovered twin: both modules land as one merged zero-width edit at the anchor. */
	@:pin('guard')
	@:access(anyparse.check.PreferStaticExtension)
	public function testStaticExtensionUncoveredAnchorAppendsOneEdit(): Void {
		final header: UsingHeader = headerOf();
		final anchor: Int = anchorOf(header);
		final edits: Array<{ span: Span, text: String }> = [{ span: new Span(SRC.length - 4, SRC.length - 2), text: 'ZZ' }];
		Assert.isTrue(PreferStaticExtension.appendUsingInserts(header, ['Lambda', 'StringTools'], edits));
		Assert.equals(2, edits.length);
		Assert.equals(anchor, edits[1].span.from);
		Assert.isTrue(edits[1].text.indexOf('using Lambda;') >= 0);
		Assert.isTrue(edits[1].text.indexOf('using StringTools;') >= 0);
	}

	/** The header of `SRC`, built the way every rule sharing the seam builds it. */
	private function headerOf(): UsingHeader {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, SRC);
		if (tree == null) throw 'the fixture must parse';
		return UsingScan.headerOf(tree, SRC, plugin);
	}

	/** The zero-width byte the insert would go at — derived, never spelled, so a header change cannot make the fixture lie. */
	private function anchorOf(header: UsingHeader): Int {
		return UsingScan.usingInsertEdit(header, 'Lambda').span.from;
	}

	private function violation(from: Int, to: Int): Violation {
		return {
			file: 'C.hx',
			span: new Span(from, to),
			rule: 'probe',
			severity: Severity.Info,
			message: 'probe'
		};
	}

}
