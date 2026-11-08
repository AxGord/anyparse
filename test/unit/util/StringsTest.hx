package unit.util;

import anyparse.util.Strings;

using StringTools;

/** `Strings`: the behaviour a caller of the one text helper relies on, the contract a re-implementation must meet. */
final class StringsTest extends Test {

	private static final LINES: String = 'ab\ncd\nef';

	@:pin('control')
	@:killer('M-UTIL-LINE-START-PREV')
	public function testALineStartsAfterThePreviousBreak(): Void {
		Assert.equals(0, Strings.lineStart(LINES, 0));
		Assert.equals(0, Strings.lineStart(LINES, 1));
		Assert.equals(3, Strings.lineStart(LINES, 3));
		Assert.equals(3, Strings.lineStart(LINES, 4));
		Assert.equals(6, Strings.lineStart(LINES, 7));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-START-PREV')
	public function testAPositionOnABreakBelongsToTheLineItEnds(): Void {
		Assert.equals(0, Strings.lineStart(LINES, 2));
		Assert.equals(3, Strings.lineStart(LINES, 5));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-START-CLAMP')
	public function testAPositionPastTheTextIsTheLastLine(): Void {
		Assert.equals(6, Strings.lineStart(LINES, 99));
		Assert.equals(6, Strings.lineStart(LINES, LINES.length));
		Assert.equals(0, Strings.lineStart('', 0));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-START-NEGATIVE')
	public function testANegativePositionIsTheTextStart(): Void {
		Assert.equals(0, Strings.lineStart(LINES, -5));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-OF-BASE')
	public function testLinesAreCountedFromOne(): Void {
		Assert.equals(1, Strings.lineOf(LINES, 0));
		Assert.equals(1, Strings.lineOf('', 0));
		Assert.equals(1, Strings.lineOf(LINES, -5));
	}

	@:pin('control')
	@:killer('M-UTIL-LINE-OF-BREAK')
	public function testALineIsCountedAtItsBreak(): Void {
		Assert.equals(1, Strings.lineOf(LINES, 2));
		Assert.equals(2, Strings.lineOf(LINES, 3));
		Assert.equals(3, Strings.lineOf(LINES, 7));
		Assert.equals(1, Strings.lineOf('a\r b', 4));
	}

	public function testALinePastTheTextIsTheLastOne(): Void {
		Assert.equals(3, Strings.lineOf(LINES, 99));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-LINE-CUT')
	public function testTheFirstLineStopsAtTheBreak(): Void {
		Assert.equals('ab', Strings.firstLine(LINES));
		Assert.equals('', Strings.firstLine('\nab'));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-LINE-WHOLE')
	public function testATextWithoutABreakIsItsOwnFirstLine(): Void {
		Assert.equals('ab', Strings.firstLine('ab'));
		Assert.equals('', Strings.firstLine(''));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-LINE-NO-BREAK-CR')
	public function testATrailingCarriageReturnWithoutALineFeedStays(): Void {
		Assert.equals('ab\r', Strings.firstLine('ab\r'));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-LINE-CR')
	public function testTheCarriageReturnOfABreakIsNotPartOfTheLine(): Void {
		Assert.equals('ab', Strings.firstLine('ab\r\ncd'));
		Assert.equals('a\rb', Strings.firstLine('a\rb\ncd'));
		Assert.equals('', Strings.firstLine('\r\ncd'));
	}

	@:pin('control')
	@:killer('M-UTIL-BLANK-RANGE')
	public function testBlankIsWhatTrimStrips(): Void {
		for (c in 0...128) {
			final s: String = String.fromCharCode(c);
			Assert.equals(s.trim() == '', Strings.isBlank(s), 'code $c');
		}
		Assert.isTrue(Strings.isBlank(' \t\r\n\x0B\x0C'));
	}

	@:pin('control')
	@:killer('M-UTIL-BLANK-EMPTY')
	public function testTheEmptyTextIsBlank(): Void {
		Assert.isTrue(Strings.isBlank(''));
	}

	public function testATextWithACharacterIsNotBlank(): Void {
		Assert.isFalse(Strings.isBlank('  a '));
		Assert.isFalse(Strings.isBlank(' '));
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
		Assert.isTrue(Strings.isIdentifier('_a1'));
		Assert.isTrue(Strings.isIdentifier('x'));
		Assert.isFalse(Strings.isIdentifier('1a'));
	}

	@:pin('control')
	@:killer('M-UTIL-IDENTIFIER-REST')
	public function testEveryCharacterOfAnIdentifierIsChecked(): Void {
		Assert.isFalse(Strings.isIdentifier('a-b'));
		Assert.isFalse(Strings.isIdentifier('ab '));
		Assert.isFalse(Strings.isIdentifier('a.b'));
	}

	public function testTheEmptyTextIsNoIdentifier(): Void {
		Assert.isFalse(Strings.isIdentifier(''));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTE-DQ')
	public function testAQuoteInTheTextIsEscaped(): Void {
		Assert.equals('"a\\"b"', Strings.quote('a"b'));
		Assert.equals('""', Strings.quote(''));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTE-BS')
	public function testABackslashInTheTextIsEscaped(): Void {
		Assert.equals('"a\\\\b"', Strings.quote('a\\b'));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTE-NL')
	public function testALineBreakIsWrittenAsAnEscape(): Void {
		Assert.equals('"a\\nb\\rc\\td"', Strings.quote('a\nb\rc\td'));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTE-BACKSPACE')
	public function testABackspaceIsWrittenAsAnEscape(): Void {
		Assert.equals('"\\b"', Strings.quote('\x08'));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTE-FORMFEED')
	public function testAFormFeedIsWrittenAsAnEscape(): Void {
		Assert.equals('"\\f"', Strings.quote('\x0C'));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTE-CONTROL')
	public function testAnotherControlCharacterIsWrittenAsALowerCaseUnicodeEscape(): Void {
		Assert.equals('"\\u0001"', Strings.quote('\x01'));
		Assert.equals('"\\u001f"', Strings.quote('\x1F'));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTE-CONTROL')
	public function testNoControlCharacterSurvivesRaw(): Void {
		for (c in 0...32) {
			final raw: String = String.fromCharCode(c);
			Assert.equals(-1, Strings.quote('a${raw}b').indexOf(raw), 'code $c');
		}
		Assert.equals('"ж €"', Strings.quote('ж €'));
	}

	@:pin('control')
	@:killer('M-UTIL-CHAR-COUNT')
	public function testEveryOccurrenceOfACharacterIsCounted(): Void {
		Assert.equals(2, Strings.charCount(LINES, '\n'.code));
		Assert.equals(1, Strings.charCount(LINES, 'a'.code));
		Assert.equals(0, Strings.charCount(LINES, 'z'.code));
		Assert.equals(0, Strings.charCount('', 'a'.code));
		Assert.equals(3, Strings.charCount('aaa', 'a'.code));
	}

	@:pin('control')
	@:killer('M-UTIL-BEFORE-CUT')
	public function testBeforeTheFirstDelimiterStopsAtIt(): Void {
		Assert.equals('a', Strings.allBeforeOrNull('a::b::c', '::'));
		Assert.equals('', Strings.allBeforeOrNull('::b', '::'));
		Assert.equals('a', Strings.allBefore('a::b::c', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-BEFORE-MISSING')
	public function testWithoutADelimiterTheNullFormIsNull(): Void {
		Assert.isNull(Strings.allBeforeOrNull('abc', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-BEFORE-PLAIN')
	public function testWithoutADelimiterTheBeforePartIsTheWholeText(): Void {
		Assert.equals('abc', Strings.allBefore('abc', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-CUT')
	public function testAfterTheFirstDelimiterSkipsAllOfIt(): Void {
		Assert.equals('b::c', Strings.allAfterOrNull('a::b::c', '::'));
		Assert.equals('', Strings.allAfterOrNull('a::', '::'));
		Assert.equals('b::c', Strings.allAfter('a::b::c', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-MISSING')
	public function testWithoutADelimiterTheAfterNullFormIsNull(): Void {
		Assert.isNull(Strings.allAfterOrNull('abc', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-PLAIN')
	public function testWithoutADelimiterTheAfterPartIsTheWholeText(): Void {
		Assert.equals('abc', Strings.allAfter('abc', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-LAST-CUT')
	public function testAfterTheLastDelimiterSkipsAllOfIt(): Void {
		Assert.equals('c', Strings.allAfterLastOrNull('a::b::c', '::'));
		Assert.equals('', Strings.allAfterLastOrNull('a::b::', '::'));
		Assert.equals('c', Strings.allAfterLast('a::b::c', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-LAST-LAST')
	public function testTheLastDelimiterIsTheOneThatCounts(): Void {
		Assert.equals('b', Strings.allAfterLast('a.b', '.'));
		Assert.equals('c', Strings.allAfterLast('a.b.c', '.'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-LAST-MISSING')
	public function testWithoutADelimiterTheAfterLastNullFormIsNull(): Void {
		Assert.isNull(Strings.allAfterLastOrNull('abc', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-AFTER-LAST-PLAIN')
	public function testWithoutADelimiterTheAfterLastPartIsTheWholeText(): Void {
		Assert.equals('abc', Strings.allAfterLast('abc', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-SPLIT-FIRST')
	public function testAFirstSplitCutsAtTheFirstDelimiter(): Void {
		Assert.same({ before: 'a', after: 'b::c' }, Strings.firstSplit('a::b::c', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-FIRST-SPLIT-MISSING')
	public function testAFirstSplitWithoutADelimiterIsNull(): Void {
		Assert.isNull(Strings.firstSplit('abc', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-LAST-SPLIT-LAST')
	public function testALastSplitCutsAtTheLastDelimiter(): Void {
		Assert.same({ before: 'a::b', after: 'c' }, Strings.lastSplit('a::b::c', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-LAST-SPLIT-MISSING')
	public function testALastSplitWithoutADelimiterIsNull(): Void {
		Assert.isNull(Strings.lastSplit('abc', '::'));
	}

	@:pin('control')
	@:killer('M-UTIL-EXTRACT-START')
	public function testExtractSkipsTheWholeOpeningDelimiter(): Void {
		Assert.equals('b', Strings.extract('a<<b>>c', '<<', '>>'));
		Assert.equals('', Strings.extract('<>', '<', '>'));
	}

	@:pin('control')
	@:killer('M-UTIL-EXTRACT-CLOSE-AFTER')
	public function testExtractClosesAfterTheOpening(): Void {
		Assert.equals('b', Strings.extract(']a[b]', '[', ']'));
	}

	@:pin('control')
	@:killer('M-UTIL-EXTRACT-NO-OPEN')
	public function testExtractWithoutAnOpeningDelimiterIsNull(): Void {
		Assert.isNull(Strings.extract('a]', '[', ']'));
	}

	@:pin('control')
	@:killer('M-UTIL-EXTRACT-NO-CLOSE')
	public function testExtractWithoutAClosingDelimiterIsNull(): Void {
		Assert.isNull(Strings.extract('a[b', '[', ']'));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTED-END-AT-CLOSE')
	public function testAQuotedLiteralEndsJustPastItsClosingQuote(): Void {
		Assert.equals(6, Strings.quotedEnd('x "ab" y', 2));
		Assert.equals(4, Strings.quotedEnd('\'ab\' y', 0));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTED-ESCAPE-OFF')
	public function testAnEscapedQuoteDoesNotEndTheLiteral(): Void {
		Assert.equals(6, Strings.quotedEnd('"a\\"b"', 0));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTED-BREAK-IGNORED')
	@:killer('M-UTIL-QUOTED-UNTERMINATED-LENGTH')
	public function testAnUnterminatedLiteralStopsAtTheLineBreak(): Void {
		Assert.equals(0, Strings.quotedEnd('"abc', 0));
		Assert.equals(0, Strings.quotedEnd('"ab\ncd"', 0));
		Assert.equals(2, Strings.quotedEnd('x "ab\n"', 2));
	}

	@:pin('control')
	@:killer('M-UTIL-QUOTED-ESCAPE-BREAK-OFF')
	public function testADanglingBackslashBeforeALineBreakIsUnterminated(): Void {
		Assert.equals(0, Strings.quotedEnd('"ab\\\n"', 0));
		Assert.equals(0, Strings.quotedEnd('"ab\\', 0));
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

	private static function closing(text: String, open: Int): Int {
		return Strings.closingBrace(text.length, k -> text.charCodeAt(k), open);
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-CLOSE-DEPTH')
	public function testOnePairAroundEverythingIsWrapped(): Void {
		Assert.isTrue(Strings.wrappedInParens('(a)'));
		Assert.isTrue(Strings.wrappedInParens('()'));
		Assert.isTrue(Strings.wrappedInParens('((a))'));
		Assert.isTrue(Strings.wrappedInParens('(a(b)c)'));
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-CLOSE-AT-END')
	public function testTwoSeparatePairsAreNotOneWrap(): Void {
		Assert.isFalse(Strings.wrappedInParens('(a)+(b)'));
		Assert.isFalse(Strings.wrappedInParens('(a)(b)'));
		Assert.isFalse(Strings.wrappedInParens('()()'));
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-UNCLOSED')
	public function testAnUnclosedOpenerIsNotWrapped(): Void {
		Assert.isFalse(Strings.wrappedInParens('(()'));
		Assert.isFalse(Strings.wrappedInParens('((a)'));
		Assert.isFalse(Strings.wrappedInParens('('));
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-OPENER')
	public function testTextNotOpeningWithAParenthesisIsNotWrapped(): Void {
		Assert.isFalse(Strings.wrappedInParens('a(b)'));
		Assert.isFalse(Strings.wrappedInParens(')('));
		Assert.isFalse(Strings.wrappedInParens('a'));
		Assert.isFalse(Strings.wrappedInParens(''));
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-STRIP-ALL')
	public function testEveryWrappingPairIsStripped(): Void {
		Assert.equals('a', Strings.stripOuterParens('((a))'));
		Assert.equals('a', Strings.stripOuterParens('a'));
		Assert.equals('(a)+(b)', Strings.stripOuterParens('(a)+(b)'));
		Assert.equals('(a)+(b)', Strings.stripOuterParens('((a)+(b))'));
	}

	@:pin('control')
	@:killer('M-UTIL-PARENS-STRIP-TRIM')
	public function testWhiteSpaceInsideAPairIsTrimmedAtEachStep(): Void {
		Assert.equals('a', Strings.stripOuterParens('( (a) )'));
	}

}
