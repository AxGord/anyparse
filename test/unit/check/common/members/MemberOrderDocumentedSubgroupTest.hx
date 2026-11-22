package unit.check.common.members;

import anyparse.check.LintConfig;
import anyparse.check.common.members.MemberOrder;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;

using StringTools;

/**
 * The opt-in `separateDocumentedSubgroup` option of `member-order`: inside one rank group the fields headed by a doc block
 * form a subgroup that leads, one blank line below it the undocumented run follows, and a doc that also names the next
 * same-kind field keeps its member in the run (reported, never moved).
 */
@:nullSafety(Strict)
class MemberOrderDocumentedSubgroupTest extends Test {

	/** An undocumented field, a blank, a documented one, a blank: what the writer's doc rule leaves a compact run as. */
	private static final DOC_AFTER_RUN: String =
		'class C {\n\tprivate final a:Int = 1;\n\n\t/** Explained. */\n\tprivate final b:Int = 2;\n\n\tprivate final c:Int = 3;\n}';

	/** `DOC_AFTER_RUN` as the option wants it: the documented field leads, one blank, the undocumented run. */
	private static final DOC_FIRST: String =
		'class C {\n\t/** Explained. */\n\tprivate final b:Int = 2;\n\n\tprivate final a:Int = 1;\n\tprivate final c:Int = 3;\n}\n';

	private static final DOC_BOUNDARY_MESSAGE: String =
		'the documented members of a rank group are not separated from the rest of it by a blank line';

	/** A doc naming the next constant, which has no doc of its own, below an undocumented one the doc would otherwise pass. */
	private static final SHARED_DOC: String = 'class C {\n\tprivate static inline final X:Int = 1;\n\n'
		+ '\t/** Where the label and its caption sit. */\n\tprivate static inline final LABEL_CENTER:Float = 0.42;\n\n'
		+ '\tprivate static inline final CAPTION_CENTER:Float = 0.62;\n}';

	/** The option off, the order is the old one: a documented field in the middle of a run stays there. */
	@:killer('M-MO-DOC-OPTION-IGNORED')
	@:pin('control')
	public function testOptionOffKeepsOrder(): Void {
		Assert.equals(0, violations(DOC_AFTER_RUN, emptyConfigResolver()).length, 'nothing reported without the option');
		Assert.equals(0, edits(DOC_AFTER_RUN, emptyConfigResolver()).length, 'and nothing fixed');
	}

	/** Under the option the documented field is reported against the undocumented one above it, with the reason in the message. */
	@:killer('M-MO-DOC-REPORT-UNREAD', 'M-MO-DOC-SORT-OFF', 'M-MO-DOC-REASON-DROPPED')
	@:pin('control')
	public function testDocumentedFieldReportedBelowUndocumented(): Void {
		final vs: Array<Violation> = violations(DOC_AFTER_RUN, documentedResolver());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('headed by a doc comment leads its inline part of the rank group'), vs[0].message);
		Assert.isTrue(vs[0].message.contains('\'b\''), vs[0].message);
	}

	/** The fix moves the documented field first and leaves one blank before the compact undocumented run; the result converges. */
	@:killer('M-MO-DOC-FIX-UNREAD', 'M-MO-DOC-SORT-OFF')
	@:pin('control')
	public function testFixPlacesDocumentedFieldFirst(): Void {
		final fixed: String = canonicalizedFix(DOC_AFTER_RUN, documentedResolver());
		Assert.equals(DOC_FIRST, fixed);
		Assert.equals(0, violations(fixed, documentedResolver()).length, 'converges');
	}

	/** The compact input of the request: the doc'd field leaves the run and the run closes up. */
	@:killer('M-MO-DOC-FIX-UNREAD', 'M-MO-DOC-SORT-OFF')
	@:pin('control')
	public function testCompactRunSplitsIntoSubgroups(): Void {
		final src: String =
			'class C {\n\tprivate final a:Int = 1;\n\t/** Explained. */\n\tprivate final b:Int = 2;\n\tprivate final c:Int = 3;\n}';
		Assert.equals(DOC_FIRST, canonicalizedFix(src, documentedResolver()));
	}

	/** A documented field already first but glued to the run is flagged with its own boundary message, and one blank is inserted. */
	@:killer('M-MO-DOC-BOUNDARY-OFF', 'M-MO-DOC-BOUNDARY-MESSAGE-AS-RANK')
	@:pin('control')
	public function testBoundaryBlankDemanded(): Void {
		final glued: String = 'class C {\n\t/** Explained. */\n\tprivate final b:Int = 2;\n\tprivate final a:Int = 1;\n}';
		final vs: Array<Violation> = violations(glued, documentedResolver());
		Assert.equals(1, vs.length);
		Assert.equals(DOC_BOUNDARY_MESSAGE, vs[0].message);
		Assert.equals(
			'class C {\n\t/** Explained. */\n\tprivate final b:Int = 2;\n\n\tprivate final a:Int = 1;\n}\n',
			canonicalizedFix(glued, documentedResolver())
		);
	}

	/** A doc naming the next constant keeps its member in the run: no move, and one finding the fix leaves for a human. */
	@:killer('M-MO-DOC-SHARED-DOC-MOVES', 'M-MO-DOC-SHARED-UNREPORTED')
	@:pin('control')
	public function testSharedDocStaysInItsRunAndIsReported(): Void {
		final vs: Array<Violation> = violations(SHARED_DOC, documentedResolver());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('also names the next field \'CAPTION_CENTER\''), vs[0].message);
		Assert.equals(0, edits(SHARED_DOC, documentedResolver()).length, 'the reorder is refused');
	}

	/** The finding of a shared doc is report-only: the fix pass produces no edit for it, not even a respelling of the same text. */
	@:killer('M-MO-DOC-REPORT-ONLY-EDITS')
	@:pin('control')
	public function testSharedDocFindingProducesNoEdit(): Void {
		Assert.equals(0, edits(SHARED_DOC, documentedResolver()).length);
		Assert.equals(SHARED_DOC, fixedSource(SHARED_DOC, documentedResolver()));
		final check: MemberOrder = new MemberOrder();
		check.setConfigResolver(documentedResolver());
		final vs: Array<Violation> = CheckFixture.violations(check, SHARED_DOC);
		CheckFixture.fixOf(check, SHARED_DOC, vs, new HaxeQueryPlugin());
		Assert.notNull(vs[0].declineReason, 'and the finding says why it stays');
	}

	/** Without the option the same shared doc is no business of the rule. */
	@:killer('M-MO-DOC-SHARED-UNGATED')
	@:pin('control')
	public function testSharedDocSilentWithoutOption(): Void {
		Assert.equals(0, violations(SHARED_DOC, emptyConfigResolver()).length);
	}

	/** A word the two names share is no mention: the doc of `WIDGET_COUNT` talks about its own count, so it still leads. */
	@:killer('M-MO-DOC-OWN-WORD-MENTION')
	@:pin('control')
	public function testWordSharedByBothNamesIsNotAMention(): Void {
		final src: String = 'class C {\n\tprivate static final A:Int = 1;\n\n\t/** The count of widgets. */\n'
			+ '\tprivate static final WIDGET_COUNT:Int = 2;\n\n\tprivate static final GADGET_COUNT:Int = 3;\n}';
		final fixed: String = canonicalizedFix(src, documentedResolver());
		Assert.isTrue(fixed.indexOf('WIDGET_COUNT') < fixed.indexOf('A:Int'), 'the documented constant leads: $fixed');
	}

	/** A side-effecting initializer pins the documented field under the field above it: the existing init guard, reused. */
	@:pin('guard')
	public function testSideEffectingInitializerKeepsItsPlace(): Void {
		final src: String = 'class C {\n\tprivate final a:Int = 1;\n\n\t/** Explained. */\n\tprivate final b:Foo = new Foo(make());\n}';
		Assert.equals(src, fixedSource(src, documentedResolver()));
		Assert.equals(1, violations(src, documentedResolver()).length, 'and the finding stays reported');
	}

	/** Methods are no subgroup: a documented method does not lead the undocumented ones of its rank. */
	@:pin('guard')
	public function testDocumentedMethodsAreExempt(): Void {
		final src: String = 'class C {\n\tpublic function a():Void {}\n\n\t/** Explained. */\n\tpublic function b():Void {}\n}\n';
		Assert.equals(0, violations(src, documentedResolver()).length);
	}

	/**
	 * The inline key outweighs the documented one: a documented non-inline field
	 * leads only within the non-inline part, behind an undocumented inline field.
	 */
	@:killer('M-MO-DOC-BEFORE-INLINE')
	@:pin('control')
	public function testInlinePartStaysFirstAndDocumentedLeadsWithinEachPart(): Void {
		final src: String = 'class C {\n\tprivate static inline final I:Int = 1;\n\n\tprivate static final A:Int = 2;\n\n'
			+ '\t/** Explained. */\n\tprivate static final B:Int = 3;\n}';
		Assert.equals(
			'class C {\n\tprivate static inline final I:Int = 1;\n\n\t/** Explained. */\n\tprivate static final B:Int = 3;\n\n'
			+ '\tprivate static final A:Int = 2;\n}\n',
			canonicalizedFix(src, documentedResolver())
		);
	}

	/** The inline seam is no documented boundary: it keeps the writer's own doc-gap message. */
	@:killer('M-MO-DOC-BOUNDARY-ACROSS-INLINE')
	@:pin('control')
	public function testInlineSeamIsNotADocumentedBoundary(): Void {
		final src: String =
			'class C {\n\t/** Explained. */\n\tprivate static inline final X:Int = 1;\n\tprivate static final Y:Int = 2;\n}';
		final vs: Array<Violation> = violations(src, documentedResolver());
		Assert.equals(1, vs.length);
		Assert.equals(
			'a doc-commented member is not separated from its neighbour by one blank line, as the formatter writes it', vs[0].message
		);
	}

}

/** A config resolver that enables the opt-in `separateDocumentedSubgroup` member-order option for every file. */
private function documentedResolver(): (String) -> LintConfig {
	final cfg: LintConfig = LintConfig.parse('{"rules": {"member-order": {"separateDocumentedSubgroup": true}}}');
	return _ -> cfg;
}

/** A resolver pinning the EMPTY config, so a verdict cannot depend on an `apq.json` discovered from the process cwd. */
private function emptyConfigResolver(): (String) -> LintConfig {
	final cfg: LintConfig = LintConfig.parse('{}');
	return _ -> cfg;
}

private function violations(src: String, resolve: (String) -> LintConfig): Array<Violation> {
	final check: MemberOrder = new MemberOrder();
	check.setConfigResolver(resolve);
	return CheckFixture.violations(check, src);
}

private function edits(src: String, resolve: (String) -> LintConfig): Array<{ span: Span, text: String }> {
	final check: MemberOrder = new MemberOrder();
	check.setConfigResolver(resolve);
	return CheckFixture.edits(check, src, new HaxeQueryPlugin());
}

private function fixedSource(src: String, resolve: (String) -> LintConfig): String {
	return CanonicalEdit.applyEdits(src, edits(src, resolve));
}

/** The fix applied and round-tripped through the writer, as the CLI lands it. */
private function canonicalizedFix(src: String, resolve: (String) -> LintConfig): String {
	final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
	final check: MemberOrder = new MemberOrder();
	check.setConfigResolver(resolve);
	final vs: Array<Violation> = CheckFixture.violations(check, src, plugin);
	return switch CanonicalEdit.canonicalize(src, CheckFixture.fixOf(check, src, vs, plugin), true, plugin) {
		case Ok(text): text;
		case Err(message):
			Assert.fail(message);
			src;
	};
}
