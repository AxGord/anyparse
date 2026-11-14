package unit.util;

using anyparse.util.Strings;
using StringTools;

/** `Strings`: the behaviour a caller of the one text helper relies on, the contract a re-implementation must meet. */
final class StringsTest extends Test {

	private static final LINES: String = 'ab\ncd\nef';

	@:pin('control')
	@:killer('M-UTIL-LINE-START-PREV')
	public function testALineStartsAfterThePreviousBreak(): Void {
		Assert.equals(0, LINES.lineStart(0));
		Assert.equals(0, LINES.lineStart(1));
		Assert.equals(3, LINES.lineStart(3));
		Assert.equals(3, LINES.lineStart(4));
		Assert.equals(6, LINES.lineStart(7));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-START-PREV')
	public function testAPositionOnABreakBelongsToTheLineItEnds(): Void {
		Assert.equals(0, LINES.lineStart(2));
		Assert.equals(3, LINES.lineStart(5));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-START-CLAMP')
	public function testAPositionPastTheTextIsTheLastLine(): Void {
		Assert.equals(6, LINES.lineStart(99));
		Assert.equals(6, LINES.lineStart(LINES.length));
		Assert.equals(0, ''.lineStart(0));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-START-NEGATIVE')
	public function testANegativePositionIsTheTextStart(): Void {
		Assert.equals(0, LINES.lineStart(-5));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-OF-BASE')
	public function testLinesAreCountedFromOne(): Void {
		Assert.equals(1, LINES.lineOf(0));
		Assert.equals(1, ''.lineOf(0));
		Assert.equals(1, LINES.lineOf(-5));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-OF-BREAK')
	public function testALineIsCountedAtItsBreak(): Void {
		Assert.equals(1, LINES.lineOf(2));
		Assert.equals(2, LINES.lineOf(3));
		Assert.equals(3, LINES.lineOf(7));
		Assert.equals(1, 'a\r b'.lineOf(4));
	}

	public function testALinePastTheTextIsTheLastOne(): Void {
		Assert.equals(3, LINES.lineOf(99));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-LINE-CUT')
	public function testTheFirstLineStopsAtTheBreak(): Void {
		Assert.equals('ab', LINES.firstLine());
		Assert.equals('', '\nab'.firstLine());
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-LINE-WHOLE')
	public function testATextWithoutABreakIsItsOwnFirstLine(): Void {
		Assert.equals('ab', 'ab'.firstLine());
		Assert.equals('', ''.firstLine());
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-LINE-NO-BREAK-CR')
	public function testATrailingCarriageReturnWithoutALineFeedStays(): Void {
		Assert.equals('ab\r', 'ab\r'.firstLine());
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-LINE-CR')
	public function testTheCarriageReturnOfABreakIsNotPartOfTheLine(): Void {
		Assert.equals('ab', 'ab\r\ncd'.firstLine());
		Assert.equals('a\rb', 'a\rb\ncd'.firstLine());
		Assert.equals('', '\r\ncd'.firstLine());
	}

	@:pin('control')
	@:killer('M-UTIL-BLANK-RANGE')
	public function testBlankIsWhatTrimStrips(): Void {
		for (c in 0...128) {
			final s: String = String.fromCharCode(c);
			Assert.equals(s.trim() == '', s.isBlank(), 'code $c');
		}
		Assert.isTrue(' \t\r\n\x0B\x0C'.isBlank());
	}

	@:pin('control')
	@:killer('M-UTIL-BLANK-EMPTY')
	public function testTheEmptyTextIsBlank(): Void {
		Assert.isTrue(''.isBlank());
	}

	public function testATextWithACharacterIsNotBlank(): Void {
		Assert.isFalse('  a '.isBlank());
		Assert.isFalse(' '.isBlank());
	}

	@:pin('control')
	@:killer('M-UTIL-IDENT-START-UNDERSCORE')
	public function testAnIdentifierStartsWithALetterOrUnderscore(): Void {
		Assert.isTrue(Strings.isIdentStart('_'.code));
		Assert.isTrue(Strings.isIdentStart('a'.code));
		Assert.isTrue(Strings.isIdentStart('Z'.code));
		Assert.isFalse(Strings.isIdentStart('1'.code));
		Assert.isFalse(Strings.isIdentStart("$".code));
		Assert.isFalse(Strings.isIdentStart('@'.code));
		Assert.isFalse(Strings.isIdentStart('['.code));
	}

	@:pin('control')
	@:killer('M-UTIL-IDENT-CHAR-DIGIT')
	public function testAnIdentifierContinuesWithADigit(): Void {
		Assert.isTrue(Strings.isIdentChar('0'.code));
		Assert.isTrue(Strings.isIdentChar('9'.code));
		Assert.isTrue(Strings.isIdentChar('_'.code));
		Assert.isFalse(Strings.isIdentChar('-'.code));
		Assert.isFalse(Strings.isIdentChar(':'.code));
		Assert.isFalse(Strings.isIdentChar('/'.code));
	}

	@:pin('control')
	@:killer('M-UTIL-IDENTIFIER-START')
	public function testAnIdentifierDoesNotStartWithADigit(): Void {
		Assert.isTrue('_a1'.isIdentifier());
		Assert.isTrue('x'.isIdentifier());
		Assert.isFalse('1a'.isIdentifier());
	}

	@:pin('control')
	@:killer('M-UTIL-IDENTIFIER-REST')
	public function testEveryCharacterOfAnIdentifierIsChecked(): Void {
		Assert.isFalse('a-b'.isIdentifier());
		Assert.isFalse('ab '.isIdentifier());
		Assert.isFalse('a.b'.isIdentifier());
	}

	public function testTheEmptyTextIsNoIdentifier(): Void {
		Assert.isFalse(''.isIdentifier());
	}

	@:pin('control')
	@:killer('M-UTIL-CHAR-COUNT')
	public function testEveryOccurrenceOfACharacterIsCounted(): Void {
		Assert.equals(2, LINES.charCount('\n'.code));
		Assert.equals(1, LINES.charCount('a'.code));
		Assert.equals(0, LINES.charCount('z'.code));
		Assert.equals(0, ''.charCount('a'.code));
		Assert.equals(3, 'aaa'.charCount('a'.code));
	}

	@:pin('control')
	@:killer('M-UTIL-BEFORE-CUT')
	public function testBeforeTheFirstDelimiterStopsAtIt(): Void {
		Assert.equals('a', 'a::b::c'.allBeforeOrNull('::'));
		Assert.equals('', '::b'.allBeforeOrNull('::'));
		Assert.equals('a', 'a::b::c'.allBefore('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-BEFORE-MISSING')
	public function testWithoutADelimiterTheNullFormIsNull(): Void {
		Assert.isNull('abc'.allBeforeOrNull('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-BEFORE-PLAIN')
	public function testWithoutADelimiterTheBeforePartIsTheWholeText(): Void {
		Assert.equals('abc', 'abc'.allBefore('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-CUT')
	public function testAfterTheFirstDelimiterSkipsAllOfIt(): Void {
		Assert.equals('b::c', 'a::b::c'.allAfterOrNull('::'));
		Assert.equals('', 'a::'.allAfterOrNull('::'));
		Assert.equals('b::c', 'a::b::c'.allAfter('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-MISSING')
	public function testWithoutADelimiterTheAfterNullFormIsNull(): Void {
		Assert.isNull('abc'.allAfterOrNull('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-PLAIN')
	public function testWithoutADelimiterTheAfterPartIsTheWholeText(): Void {
		Assert.equals('abc', 'abc'.allAfter('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-LAST-CUT')
	public function testAfterTheLastDelimiterSkipsAllOfIt(): Void {
		Assert.equals('c', 'a::b::c'.allAfterLastOrNull('::'));
		Assert.equals('', 'a::b::'.allAfterLastOrNull('::'));
		Assert.equals('c', 'a::b::c'.allAfterLast('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-LAST-LAST')
	public function testTheLastDelimiterIsTheOneThatCounts(): Void {
		Assert.equals('b', 'a.b'.allAfterLast('.'));
		Assert.equals('c', 'a.b.c'.allAfterLast('.'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-LAST-MISSING')
	public function testWithoutADelimiterTheAfterLastNullFormIsNull(): Void {
		Assert.isNull('abc'.allAfterLastOrNull('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-LAST-PLAIN')
	public function testWithoutADelimiterTheAfterLastPartIsTheWholeText(): Void {
		Assert.equals('abc', 'abc'.allAfterLast('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-SPLIT-FIRST')
	public function testAFirstSplitCutsAtTheFirstDelimiter(): Void {
		Assert.same({ before: 'a', after: 'b::c' }, 'a::b::c'.firstSplit('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-SPLIT-MISSING')
	public function testAFirstSplitWithoutADelimiterIsNull(): Void {
		Assert.isNull('abc'.firstSplit('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-LAST-SPLIT-LAST')
	public function testALastSplitCutsAtTheLastDelimiter(): Void {
		Assert.same({ before: 'a::b', after: 'c' }, 'a::b::c'.lastSplit('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-LAST-SPLIT-MISSING')
	public function testALastSplitWithoutADelimiterIsNull(): Void {
		Assert.isNull('abc'.lastSplit('::'));
	}

	@:pin('control')
	@:killer('M-UTIL-EXTRACT-START')
	public function testExtractSkipsTheWholeOpeningDelimiter(): Void {
		Assert.equals('b', 'a<<b>>c'.extract('<<', '>>'));
		Assert.equals('', '<>'.extract('<', '>'));
	}

	@:pin('control')
	@:killer('M-UTIL-EXTRACT-CLOSE-AFTER')
	public function testExtractClosesAfterTheOpening(): Void {
		Assert.equals('b', ']a[b]'.extract('[', ']'));
	}

	@:pin('control')
	@:killer('M-UTIL-EXTRACT-NO-OPEN')
	public function testExtractWithoutAnOpeningDelimiterIsNull(): Void {
		Assert.isNull('a]'.extract('[', ']'));
	}

	@:pin('control')
	@:killer('M-UTIL-EXTRACT-NO-CLOSE')
	public function testExtractWithoutAClosingDelimiterIsNull(): Void {
		Assert.isNull('a[b'.extract('[', ']'));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTED-END-AT-CLOSE')
	public function testAQuotedLiteralEndsJustPastItsClosingQuote(): Void {
		Assert.equals(6, 'x "ab" y'.quotedEnd(2));
		Assert.equals(4, '\'ab\' y'.quotedEnd(0));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTED-ESCAPE-OFF')
	public function testAnEscapedQuoteDoesNotEndTheLiteral(): Void {
		Assert.equals(6, '"a\\"b"'.quotedEnd(0));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTED-BREAK-IGNORED')
	@:killer('M-UTIL-QUOTED-UNTERMINATED-LENGTH')
	public function testAnUnterminatedLiteralStopsAtTheLineBreak(): Void {
		Assert.equals(0, '"abc'.quotedEnd(0));
		Assert.equals(0, '"ab\ncd"'.quotedEnd(0));
		Assert.equals(2, 'x "ab\n"'.quotedEnd(2));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTED-ESCAPE-BREAK-OFF')
	public function testADanglingBackslashBeforeALineBreakIsUnterminated(): Void {
		Assert.equals(0, '"ab\\\n"'.quotedEnd(0));
		Assert.equals(0, '"ab\\'.quotedEnd(0));
	}

	@:pin('control')
	@:killer('M-UTIL-CLOSING-BRACE-NEST')
	public function testANestedBlockClosesTheOuterBraceNotTheInnerOne(): Void {
		Assert.equals(1, closing('{}', 0));
		Assert.equals(6, closing('{a{b}c}', 0));
		Assert.equals(6, closing('{a{b}c}d}', 0));
	}

	@:pin('control')
	@:killer('M-UTIL-CLOSING-BRACE-NAIVE')
	public function testABraceInsideANestedStringStillCounts(): Void {
		Assert.equals(4, closing("{f('}')}", 0));
		Assert.equals(-1, closing("{f('{')}", 0));
	}

	@:pin('control')
	@:killer('M-UTIL-CLOSING-BRACE-UNCLOSED')
	public function testABlockThatNeverClosesIsMinusOne(): Void {
		Assert.equals(-1, closing('{a{b}', 0));
		Assert.equals(-1, closing('{', 0));
	}

	@:pin('control')
	@:killer('M-UTIL-CLOSING-BRACE-OPEN')
	public function testTheScanStartsAtTheOpeningBrace(): Void {
		Assert.equals(5, closing('x}y{a}b', 3));
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-CLOSE-DEPTH')
	public function testOnePairAroundEverythingIsWrapped(): Void {
		Assert.isTrue('(a)'.wrappedInParens());
		Assert.isTrue('()'.wrappedInParens());
		Assert.isTrue('((a))'.wrappedInParens());
		Assert.isTrue('(a(b)c)'.wrappedInParens());
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-CLOSE-AT-END')
	public function testTwoSeparatePairsAreNotOneWrap(): Void {
		Assert.isFalse('(a)+(b)'.wrappedInParens());
		Assert.isFalse('(a)(b)'.wrappedInParens());
		Assert.isFalse('()()'.wrappedInParens());
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-UNCLOSED')
	public function testAnUnclosedOpenerIsNotWrapped(): Void {
		Assert.isFalse('(()'.wrappedInParens());
		Assert.isFalse('((a)'.wrappedInParens());
		Assert.isFalse('('.wrappedInParens());
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-OPENER')
	public function testTextNotOpeningWithAParenthesisIsNotWrapped(): Void {
		Assert.isFalse('a(b)'.wrappedInParens());
		Assert.isFalse(')('.wrappedInParens());
		Assert.isFalse('a'.wrappedInParens());
		Assert.isFalse(''.wrappedInParens());
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-STRIP-ALL')
	public function testEveryWrappingPairIsStripped(): Void {
		Assert.equals('a', '((a))'.stripOuterParens());
		Assert.equals('a', 'a'.stripOuterParens());
		Assert.equals('(a)+(b)', '(a)+(b)'.stripOuterParens());
		Assert.equals('(a)+(b)', '((a)+(b))'.stripOuterParens());
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-STRIP-TRIM')
	public function testWhiteSpaceInsideAPairIsTrimmedAtEachStep(): Void {
		Assert.equals('a', '( (a) )'.stripOuterParens());
	}

	@:pin('control')
	@:killer('M-UTIL-SPACE-OR-TAB-SPACE')
	public function testASpaceIsABlankWithinALine(): Void {
		Assert.isTrue(Strings.isSpaceOrTab(' '.code));
	}

	@:pin('control')
	@:killer('M-UTIL-SPACE-OR-TAB-TAB')
	public function testATabIsABlankWithinALine(): Void {
		Assert.isTrue(Strings.isSpaceOrTab('\t'.code));
	}

	@:pin('control')
	@:killer('M-UTIL-SPACE-OR-TAB-CR')
	public function testNothingElseIsABlankWithinALine(): Void {
		for (c in 0...128) if (c != ' '.code && c != '\t'.code) Assert.isFalse(c.isSpaceOrTab(), 'code $c');
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-END-BREAK')
	public function testALineEndsAtItsBreak(): Void {
		Assert.equals(2, LINES.lineEnd(0));
		Assert.equals(2, LINES.lineEnd(1));
		Assert.equals(2, LINES.lineEnd(2));
		Assert.equals(5, LINES.lineEnd(3));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-END-LAST')
	public function testTheLastLineEndsAtTheTextEnd(): Void {
		Assert.equals(8, LINES.lineEnd(6));
		Assert.equals(8, LINES.lineEnd(7));
		Assert.equals(8, LINES.lineEnd(8));
		Assert.equals(0, ''.lineEnd(0));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-END-LAST')
	public function testAPositionPastTheTextEndsAtTheTextEnd(): Void {
		Assert.equals(8, LINES.lineEnd(99));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-END-BREAK')
	public function testTheCarriageReturnOfABreakStaysInTheLine(): Void {
		Assert.equals(2, 'a\r\nb'.lineEnd(0));
		Assert.equals(2, 'a\r\nb'.lineEnd(1));
		Assert.equals(4, 'a\r\nb'.lineEnd(3));
	}

	private static function closing(text: String, open: Int): Int {
		return Strings.closingBrace(text.length, k -> text.charCodeAt(k), open);
	}

}
