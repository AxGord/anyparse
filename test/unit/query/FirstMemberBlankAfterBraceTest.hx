package unit.query;

import anyparse.query.ElementSpan;
import anyparse.runtime.Span;

/**
 * A whole-line deletion of the first member under a body's `{` owns the blank line below it:
 * no blank stays between `{` and the next member. A middle member keeps its one blank, and
 * the last member before `}` has nothing to give back.
 */
class FirstMemberBlankAfterBraceTest extends Test {

	@:pin('control')
	@:killer('M-BLANK-AFTER-BRACE-KEPT')
	public function testFirstMemberTakesTheBlankBelow(): Void {
		final head: String = 'enum abstract E(Int) {\n';
		final plain: String = '\tvar FIRST = 0;\n';
		final doc: String = '\t/** doc */\n$plain';
		final tail: String = '\n\tvar B = 1;\n}\n';
		for (member in [plain, doc]) {
			final source: String = head + member + tail;
			final cut: Span = ElementSpan.blankExtendedSpan(source, new Span(head.length, head.length + member.length));
			Assert.equals('$head\tvar B = 1;\n}\n', source.substr(0, cut.from) + source.substr(cut.to));
		}
	}

	public function testMiddleMemberKeepsOneBlank(): Void {
		final source: String = 'class C {\n\tvar a = 1;\n\n\tvar b = 2;\n\n\tvar c = 3;\n}\n';
		final from: Int = source.indexOf('\tvar b');
		final cut: Span = ElementSpan.blankExtendedSpan(source, new Span(from, from + '\tvar b = 2;\n'.length));
		Assert.equals('class C {\n\tvar a = 1;\n\n\tvar c = 3;\n}\n', source.substr(0, cut.from) + source.substr(cut.to));
	}

	public function testLastMemberLeavesNoBlank(): Void {
		final source: String = 'class C {\n\tvar a = 1;\n\tvar c = 3;\n}\n';
		final from: Int = source.indexOf('\tvar c');
		final cut: Span = ElementSpan.blankExtendedSpan(source, new Span(from, from + '\tvar c = 3;\n'.length));
		Assert.equals('class C {\n\tvar a = 1;\n}\n', source.substr(0, cut.from) + source.substr(cut.to));
	}

}
