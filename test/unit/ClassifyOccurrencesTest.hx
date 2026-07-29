package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.RefactorSupport.ClassifiedOccurrence;
import anyparse.query.RefactorSupport.OccurrenceClass;
import anyparse.runtime.Span;

/**
 * `RefactorSupport.classifyOccurrences`: every word-boundary occurrence of an
 * identifier is classified by lexical context — active code, a `#if...#end`
 * region, a plain comment, a string literal, or a `noqa` directive line — with
 * a null fallback when the source does not parse. Drives the naming rule's
 * trivia-aware completeness gate.
 */
class ClassifyOccurrencesTest extends Test {

	public function testClassifiesActiveCode(): Void {
		Assert.equals(OccurrenceClass.ActiveCode, soleClass('class C {\n\tfunction m() {\n\t\treturn foo;\n\t}\n}', 'foo'));
	}

	public function testClassifiesConditionalRaw(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\t#if debug\n\t\ttrace(foo);\n\t\t#end\n\t}\n}';
		Assert.equals(OccurrenceClass.ConditionalRaw, soleClass(src, 'foo'));
	}

	public function testClassifiesConditionalRawMidExpression(): Void {
		// A mid-expression `#if` projects as a CondSpliceTail; an occurrence in its raw
		// tail is still conditional. The head read is excluded as a resolved span.
		final src: String = 'class C {\n\tfunction m() {\n\t\tvar x = a #if cpp + foo #end;\n\t}\n}';
		Assert.equals(OccurrenceClass.ConditionalRaw, soleClass(src, 'foo'));
	}

	public function testClassifiesCommentTrivia(): Void {
		Assert.equals(OccurrenceClass.CommentTrivia, soleClass('class C {\n\tfunction m() {\n\t\t// keep foo here\n\t}\n}', 'foo'));
	}

	public function testClassifiesBlockCommentTrivia(): Void {
		Assert.equals(OccurrenceClass.CommentTrivia, soleClass('class C {\n\t/* legacy foo mention */\n\tfunction m() {}\n}', 'foo'));
	}

	public function testClassifiesStringLiteral(): Void {
		Assert.equals(OccurrenceClass.StringLiteral, soleClass('class C {\n\tfunction m():String {\n\t\treturn "foo";\n\t}\n}', 'foo'));
	}

	public function testClassifiesDirectiveComment(): Void {
		Assert.equals(OccurrenceClass.DirectiveComment, soleClass('class C {\n\tfunction m() {\n\t\t// noqa: foo\n\t}\n}', 'foo'));
	}

	public function testExcludesResolvedSpans(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\treturn foo;\n\t}\n}';
		final at: Int = src.indexOf('foo');
		final list: Null<Array<ClassifiedOccurrence>> = classify(src, 'foo', [new Span(at, at + 3)]);
		if (list == null) {
			Assert.fail('classifyOccurrences returned null');
			return;
		}
		Assert.equals(0, list.length);
	}

	public function testWordBoundaryOnly(): Void {
		// `foobar` and `myfoo` are not word-boundary matches for `foo`.
		final list: Null<Array<ClassifiedOccurrence>> = classify('class C {\n\tfunction m() {\n\t\treturn foobar + myfoo;\n\t}\n}', 'foo');
		if (list == null) {
			Assert.fail('classifyOccurrences returned null');
			return;
		}
		Assert.equals(0, list.length);
	}

	public function testParseFailReturnsNull(): Void {
		// Unbalanced braces -> the plugin throws -> null, so the caller falls back to the raw scan.
		Assert.isNull(classify('class C { function m() { return foo;', 'foo'));
	}

	public function testWriterRoundTripsCommentByteExactly(): Void {
		// The writer preserves comment trivia byte-exactly, so an occurrence renamed inside a
		// comment survives the canonicalize round-trip together with the code.
		final src: String = 'class C {\n\n\t// renamed _foo mention\n\tfunction m() {}\n\n}\n';
		Assert.equals(src, new HaxeQueryPlugin().writeRoundTrip(src));
	}

	/**
	 * `activeCodeIdentTokenOffset` skips a comment mention of the name, so a
	 * comment between a receiver and its member never wins the race for the
	 * member token.
	 */
	public function testActiveCodeOffsetSkipsCommentMention(): Void {
		final src: String = 's\n\t// reset value\n\t.value = 1;';
		Assert.equals(src.lastIndexOf('value'), RefactorSupport.activeCodeIdentTokenOffset(src, new Span(1, src.indexOf(' =')), 'value'));
	}

	/** A block comment between the two spans is skipped the same way. */
	public function testActiveCodeOffsetSkipsBlockCommentMention(): Void {
		final src: String = 's /* value */ .value;';
		Assert.equals(src.lastIndexOf('value'), RefactorSupport.activeCodeIdentTokenOffset(src, new Span(1, src.length), 'value'));
	}

	/** Code interpolated into a string literal stays eligible. */
	public function testActiveCodeOffsetKeepsInterpolatedCode(): Void {
		final src: String = "trace('${s.value}');";
		Assert.equals(src.indexOf('value'), RefactorSupport.activeCodeIdentTokenOffset(src, new Span(0, src.length), 'value'));
	}

	/** A `#if` body is conditional CODE, not trivia — it stays eligible. */
	public function testActiveCodeOffsetKeepsConditionalCode(): Void {
		final src: String = '#if debug\ntrace(s.value);\n#end';
		Assert.equals(src.indexOf('value'), RefactorSupport.activeCodeIdentTokenOffset(src, new Span(0, src.length), 'value'));
	}

	/** A window whose only mention is a comment reports NOT FOUND. */
	public function testActiveCodeOffsetCommentOnlyIsNotFound(): Void {
		final src: String = 's\n\t// reset value\n\t.other;';
		Assert.equals(-1, RefactorSupport.activeCodeIdentTokenOffset(src, new Span(0, src.length), 'value'));
	}

	private function classify(src: String, name: String, ?excluded: Array<Span>): Null<Array<ClassifiedOccurrence>> {
		return RefactorSupport.classifyOccurrences(src, name, new HaxeQueryPlugin(), 0, src.length, excluded == null ? [] : excluded);
	}

	private function soleClass(src: String, name: String): OccurrenceClass {
		final list: Null<Array<ClassifiedOccurrence>> = classify(src, name);
		if (list == null) {
			Assert.fail('classifyOccurrences returned null');
			return OccurrenceClass.ActiveCode;
		}
		Assert.equals(1, list.length);
		return list[0].kind;
	}


	/**
	 * A regex literal is its own lexical region, so a comment OPENER legally
	 * living in its body no longer starts a phantom block comment that runs to
	 * EOF and swallows the rest of the file as trivia.
	 */
	public function testRegexLiteralDoesNotOpenPhantomComment(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\tvar re = ~/[\\/*]/;\n\t\treturn foo;\n\t}\n}';
		Assert.equals(OccurrenceClass.ActiveCode, soleClass(src, 'foo'));
	}

	/** The regex BODY itself is inert literal text, classified like a string. */
	public function testClassifiesRegexBody(): Void {
		Assert.equals(OccurrenceClass.StringLiteral, soleClass('class C {\n\tfunction m() {\n\t\tvar re = ~/foo/;\n\t}\n}', 'foo'));
	}

	/** Trailing flag letters belong to the literal, not to the code after it. */
	public function testRegexFlagsAreInsideTheRegion(): Void {
		final src: String = 'class C {\n\tfunction m() {\n\t\tvar re = ~/[\\/*]/gi;\n\t\treturn foo;\n\t}\n}';
		Assert.equals(OccurrenceClass.ActiveCode, soleClass(src, 'foo'));
	}

	/** `activeCodeIdentTokenOffset` reaches a member token sitting after such a regex. */
	public function testActiveCodeOffsetSurvivesRegexCommentOpener(): Void {
		final src: String = 'var re = ~/[\\/*]/;\ns.value = 1;';
		Assert.equals(src.indexOf('value'), RefactorSupport.activeCodeIdentTokenOffset(src, new Span(0, src.length), 'value'));
	}

	/**
	 * An unterminated `~/` is not a regex literal: the scan falls through, so a
	 * genuine line comment on the same line still registers as trivia.
	 */
	public function testUnterminatedRegexFallsThrough(): Void {
		Assert.equals(OccurrenceClass.CommentTrivia, soleClass('class C {\n\tfunction m() {\n\t\t// ~/ foo\n\t}\n}', 'foo'));
	}

}
