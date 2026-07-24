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

}
