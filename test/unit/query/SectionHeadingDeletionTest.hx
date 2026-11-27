package unit.query;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.query.ElementSpan;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.RemoveMember;
import anyparse.query.SafeDelete;

/**
 * A member deletion takes a lone `//` section heading with the section it leads, when every member
 * of that section goes: the heading is one own-line `//` comment above the section's first
 * member, with at most one blank line between them, and the section runs
 * to the next comment, a blank line or the end of the body. A section
 * that keeps a live member keeps its heading; a heading of several lines or a block comment is left
 * to the comment guard, which refuses the weld as before.
 */
class SectionHeadingDeletionTest extends Test {

	/** Three one-member sections; only the middle one is dead. */
	private static final THREE_SECTIONS: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta\n'
		+ '\tpublic static inline final B_UNUSED:Int = 2;\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n';

	/** `THREE_SECTIONS` with the middle section gone, heading included. */
	private static final WITHOUT_BETA: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Gamma\n'
		+ '\tpublic static inline final C_USED:Int = 3;\n}\n';

	/** A reader of the live constants, so `unused-public-member` reports only the dead ones. */
	private static final USER: String = 'class U {\n\tpublic static function main():Void {\n\t\ttrace(K.A_USED + K.C_USED);\n\t}\n}\n';

	@:pin('control')
	@:killer('M-SECTION-RUNS-PAST-A-HEADING')
	public function testRemoveMemberTakesTheHeadingOfItsOnlyMember(): Void {
		Assert.equals(WITHOUT_BETA, okRemove(THREE_SECTIONS));
	}

	@:pin('control')
	@:killer('M-SECTION-HEADING-NEVER-TAKEN')
	public function testUnusedPublicMemberFixTakesTheHeading(): Void {
		Assert.equals(WITHOUT_BETA + USER, fixed(THREE_SECTIONS + USER));
	}

	/** Two dead members under one heading, deleted in one fix: the section is all dead, so its heading goes too. */
	@:pin('control')
	@:killer('M-DELETE-MEMBERS-SECTION-ONE-AT-A-TIME')
	public function testFixTakesTheHeadingOfASectionWhoseMembersAllGo(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\tpublic static inline final B2_UNUSED:Int = 2;\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(WITHOUT_BETA + USER, fixed(src + USER));
	}

	/** The section of the last member runs to the end of the body: its heading goes rather than dangle above the brace. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-NEVER-TAKEN')
	public function testHeadingOfTheLastSectionGoes(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n}\n';
		Assert.equals('class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n}\n', okRemove(src));
	}

	/** Blank-separated sections: the blank line after the dead member closes its section, and one blank line stays. */
	public function testBlankSeparatedSectionGoesWithItsHeading(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Beta\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n',
			okRemove(src)
		);
	}

	/** `unused-private` deletes through the same cut: the heading of a section whose members it all deletes goes too. */
	@:pin('control')
	@:killer('M-UNUSED-PRIVATE-SECTION-UNSEEN')
	public function testUnusedPrivateFixTakesTheHeading(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tprivate static inline final A_USED:Int = 1;\n\t// Beta\n'
			+ '\tprivate static inline final B_UNUSED:Int = 2;\n\tprivate static inline final B2_UNUSED:Int = 2;\n\t// Gamma\n\tprivate '
			+ 'static inline final C_USED:Int = 3;\n\n\tpublic static function main():Void {\n\t\ttrace(A_USED + C_USED);\n\t}\n}\n';
		final check: Null<Check> = Linter.byId('unused-private');
		Assert.notNull(check);
		Assert.equals(
			'class K {\n\t// Alpha\n\tprivate static inline final A_USED:Int = 1;\n\t// Gamma\n\tprivate static inline final C_USED:Int '
			+ '= 3;\n\n\tpublic static function main():Void {\n\t\ttrace(A_USED + C_USED);\n\t}\n}\n',
			check == null ? src : CheckFixture.fixedSource(check, src)
		);
	}

	/** A blank line ends a section: the heading of a dead member goes though a live member follows after the blank line. */
	@:pin('control')
	@:killer('M-SECTION-RUNS-PAST-A-BLANK')
	public function testBlankLineEndsTheSectionOfItsHeading(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\n\tpublic static inline final B_LIVE:Int = 2;\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\tpublic static inline final B_LIVE:Int = 2;\n'
			+ '\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n',
			okRemove(src)
		);
	}

	/** A `@:meta` sibling rides with the declaration under it: two dead members, one annotated, deleted together take the heading. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-META-SIBLING-LIVE')
	public function testAnAnnotatedDeadMemberLeavesTheSectionDead(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\t@:noCompletion\n\tpublic static inline final B2_UNUSED:Int = 2;\n'
			+ '\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(WITHOUT_BETA, deleteNamed(src, ['B_UNUSED', 'B2_UNUSED']));
	}

	/** A block comment glued above the heading makes a comment run, not a lone heading: the run stays where it was. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-GLUED-RUN-TAKEN')
	public function testHeadingGluedUnderABlockCommentStays(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t/* block */\n\t// Beta\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n}\n';
		Assert.equals('class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t/* block */\n\t// Beta\n}\n', okRemove(src));
	}

	/** A section that keeps a live member keeps its heading; only the dead member goes. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-IGNORES-LIVE-MEMBER')
	public function testSectionWithALiveMemberKeepsItsHeading(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\tpublic static inline final B_LIVE:Int = 2;\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta\n\tpublic static inline final B_LIVE:Int = 2;\n'
			+ '\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n',
			okRemove(src)
		);
	}

	/** A heading of two lines is not a lone heading: the weld refusal stands. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-TAKES-A-RUN')
	public function testTwoLineHeadingIsRefused(): Void {
		assertWeldRefused(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta one\n\t// Beta two\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n'
		);
	}

	/** A block-comment heading is not a `//` line: the weld refusal stands. */
	@:pin('guard')
	public function testBlockCommentHeadingIsRefused(): Void {
		assertWeldRefused(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t/* Beta */\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n'
		);
	}

	/** A doc comment directly above a member is that member's own doc and goes with it, as before. */
	@:pin('guard')
	public function testDocCommentGoesAsTheMembersOwnDoc(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t/** Beta */\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n',
			okRemove(src)
		);
	}

	/** A lone heading with ONE blank line under it still leads its section: it goes with the section's last dead member. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-STOPS-AT-A-BLANK')
	public function testHeadingAcrossOneBlankLineGoesWithItsSection(): Void {
		Assert.equals(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n',
			okRemove(
				'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Beta\n\n'
				+ '\tpublic static inline final B_UNUSED:Int = 2;\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n'
			)
		);
	}

	/** The reported shape: blank lines on both sides of the lone heading; the lint fix takes heading, its blank and the member. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-STOPS-AT-A-BLANK')
	public function testFixTakesAHeadingSeparatedFromItsSectionByABlank(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Beta\n\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n';
		final expected: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(expected + USER, fixed(src + USER));
		Assert.equals(expected, okRemove(src));
		Assert.equals(expected, safeDeleted(src));
	}

	/**
	 * A `//` note glued under the previous member, then a blank line, is
	 * that member's trailing note: it stays when the next member goes.
	 */
	@:pin('control')
	@:killer('M-SECTION-HEADING-ACROSS-BLANK-TAKES-TRAILING-NOTE')
	public function testTrailingNoteUnderThePreviousMemberStays(): Void {
		final src: String = 'class K {\n\tpublic static inline final A_USED:Int = 1;\n\t// keep A_USED in sync with C_USED\n\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\n\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(
			'class K {\n\tpublic static inline final A_USED:Int = 1;\n\t// keep A_USED in sync with C_USED\n\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n',
			okRemove(src)
		);
	}

	/** A heading right under the body's `{`, with one blank line under it, leads the first section. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-ACROSS-BLANK-NEEDS-NO-OPENER')
	public function testHeadingUnderTheBodyBraceAcrossABlankGoes(): Void {
		final src: String = 'class K {\n\t// Beta\n\n\tpublic static inline final B_UNUSED:Int = 2;\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals('class K {\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n', okRemove(src));
	}

	/** A live member of the section keeps the heading and the blank line under it. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-IGNORES-LIVE-MEMBER')
	public function testLiveMemberKeepsAHeadingAcrossABlank(): Void {
		final src: String = 'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Beta\n\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\tpublic static inline final B_LIVE:Int = 2;\n\t// Gamma\n'
			+ '\tpublic static inline final C_USED:Int = 3;\n}\n';
		Assert.equals(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Beta\n\n'
			+ '\tpublic static inline final B_LIVE:Int = 2;\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n',
			okRemove(src)
		);
	}

	/** Two blank lines set a comment apart from the member: it is not that member's heading, the weld refusal stands. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-TAKES-TWO-BLANKS')
	public function testHeadingTwoBlankLinesAboveIsRefused(): Void {
		assertWeldRefused(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t// Beta\n\n\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n'
		);
	}

	/** A block comment above the blank line is not a `//` heading: the weld refusal stands. */
	@:pin('control')
	@:killer('M-SECTION-HEADING-ACROSS-BLANK-TAKES-BLOCK')
	public function testBlockCommentAboveABlankLineIsRefused(): Void {
		assertWeldRefused(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\n\t/* Beta */\n\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n'
		);
	}

	/** A run of `//` lines above the blank line is not a lone heading: the weld refusal stands. */
	@:pin('guard')
	public function testTwoLineHeadingAboveABlankLineIsRefused(): Void {
		assertWeldRefused(
			'class K {\n\t// Alpha\n\tpublic static inline final A_USED:Int = 1;\n\t// Beta one\n\t// Beta two\n\n'
			+ '\tpublic static inline final B_UNUSED:Int = 2;\n\t// Gamma\n\tpublic static inline final C_USED:Int = 3;\n}\n'
		);
	}

	/** `remove-member K.B_UNUSED` on `source`, or a test failure and an empty string. */
	private function okRemove(source: String): String {
		switch RemoveMember.removeMember(source, 'K', 'B_UNUSED', true, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private function assertWeldRefused(source: String): Void {
		switch RemoveMember.removeMember(source, 'K', 'B_UNUSED', true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('welded to') >= 0, 'unexpected message: $message');
		}
	}

	/** `source` after the `unused-public-member` fix. */
	private function fixed(source: String): String {
		final check: Null<Check> = Linter.byId('unused-public-member');
		Assert.notNull(check);
		return check == null ? source : CheckFixture.fixedSource(check, source);
	}

	/** `source` after one `ElementSpan.deleteNodes` call over every member named in `names`, or a test failure and an empty string. */
	private function deleteNamed(source: String, names: Array<String>): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		final targets: Array<{ node: QueryNode, parent: Null<QueryNode> }> = [];
		function walk(node: QueryNode): Void {
			for (child in node.children)
				if (names.contains(child.name))
					targets.push({ node: child, parent: node })
				else
					walk(child);
		}
		if (tree != null) walk(tree);
		Assert.equals(names.length, targets.length);
		switch ElementSpan.deleteNodes(source, targets, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private function safeDeleted(source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		switch SafeDelete.safeDelete('K.hx', 'K', 'B_UNUSED', true, [{ file: 'K.hx', source: source }], plugin, plugin.refShape()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

}
