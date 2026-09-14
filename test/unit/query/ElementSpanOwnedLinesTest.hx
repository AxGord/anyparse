package unit.query;

import anyparse.query.ElementSpan;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * `ElementSpan.ownedLinesSpan` — the whole lines a span owns, indentation and trailing line break
 * included, and null the moment another token shares its first or last line. Green at base by
 * construction: the two inline ops spelled this scan themselves.
 */
@:nullSafety(Strict)
class ElementSpanOwnedLinesTest extends Test {

	public function testASoleOccupantOwnsItsLine(): Void {
		final source: String = 'a;\n\tvar x = 1;\nb;';
		final decl: Span = new Span(source.indexOf('var'), source.indexOf(';', 4) + 1);
		final owned: Null<Span> = ElementSpan.ownedLinesSpan(source, decl);
		Assert.notNull(owned);
		if (owned == null) return;
		Assert.equals('\tvar x = 1;\n', source.substring(owned.from, owned.to));
	}

	public function testAMultiLineMemberOwnsItsEdgeLines(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\treturn 1;\n\t}\n}\n';
		final member: Span = new Span(source.indexOf('function'), source.lastIndexOf('}', source.length - 3) + 1);
		final owned: Null<Span> = ElementSpan.ownedLinesSpan(source, member);
		Assert.notNull(owned);
		if (owned == null) return;
		Assert.equals('\tfunction f() {\n\t\treturn 1;\n\t}\n', source.substring(owned.from, owned.to));
	}

	public function testASharedLineEdgeRefuses(): Void {
		final before: String = 'a; var x = 1;\n';
		Assert.isNull(ElementSpan.ownedLinesSpan(before, new Span(3, before.length - 1)));
		final after: String = 'var x = 1; // note\n';
		Assert.isNull(ElementSpan.ownedLinesSpan(after, new Span(0, 10)));
	}

	public function testTheLastLineOfTheFileNeedsNoBreak(): Void {
		final source: String = 'a;\n\tvar x = 1;';
		final owned: Null<Span> = ElementSpan.ownedLinesSpan(source, new Span(4, source.length));
		Assert.notNull(owned);
		if (owned == null) return;
		Assert.equals(3, owned.from);
		Assert.equals(source.length, owned.to);
	}

}
