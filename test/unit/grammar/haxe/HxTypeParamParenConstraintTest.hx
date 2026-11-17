package unit.grammar.haxe;

import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.format.Text;
import anyparse.runtime.Span;
import anyparse.util.Compare;
import utest.Assert;
import utest.Test;

/**
 * The parenthesised multi-constraint form of a declare-site type parameter (`<T:(A, B)>`) parses, writes canonically
 * and reaches the writer's fixed point, with and without a comment after the constraint colon or inside the list; its
 * bounds reach the span-info walk as one entry per listed type. A parenthesised type or function type after `:` stays a
 * single bound.
 */
@:nullSafety(Strict)
final class HxTypeParamParenConstraintTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-PAREN-BOUNDS-SEP')
	public function testParenConstraintListRoundTrips(): Void {
		assertCanonical('class C<T:(Int, String)> {}\n');
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-PAREN-BOUNDS-SEP')
	public function testParenConstraintListBeforeADefault(): Void {
		assertCanonical('class C<T:(Int, String) = Foo, S> {}\n');
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-PAREN-BOUNDS-SEP')
	public function testParenConstraintListOnAFunction(): Void {
		assertCanonical('class C {\n\tfunction f<T:(Foo, Bar<Int>)>(x:T):Void {}\n}\n');
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-PAREN-BOUNDS-SEP', 'M-TYPEPARAM-CONSTRAINT-AFTER-LEAD-OFF')
	public function testCommentAfterTheColonBeforeAParenList(): Void {
		final written: Null<String> = roundTrip('class D<T:/*k*/(Int, String)> {}\n');
		Assert.equals('class D<T:/*k*/ (Int, String)> {}\n', written);
		if (written != null) Assert.equals(written, roundTrip(written));
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-PAREN-BOUNDS-COMMENT-OFF')
	public function testCommentInsideAParenListIsKept(): Void {
		final written: Null<String> = roundTrip('class C<T:(Int, // k\n\tString)> {}\n');
		Assert.equals('class C<T:(\n\tInt, // k\n\tString\n)> {}\n', written);
		if (written != null) Assert.equals(written, roundTrip(written));
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-PAREN-BOUNDS-FIRST')
	public function testParenthesisedSingleTypesStayOneBound(): Void {
		assertCanonical('class C<T:(Int), U:(Int, String) -> Void> {}\n');
	}

	@:pin('control')
	@:killer('M-SPANINFO-BOUND-ALT', 'M-SPANINFO-BOUND-ALT-LIST')
	public function testParenConstraintListBoundsReachSpanInfo(): Void {
		final src: String = 'class C<T:(Int, Array<String>), U:Foo> {}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final bounds: Map<Int, Map<String, Array<String>>> = plugin.spanTypeInfo(src).typeParamConstraints;
		final seen: Array<String> = [];
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			final own: Null<Map<String, Array<String>>> = span == null ? null : bounds[span.from];
			if (own != null) {
				final names: Array<String> = [ for (name in own.keys()) name ];
				names.sort(Compare.compareString);
				for (name in names) seen.push('${node.kind}:$name=${(own[name] ?? []).join('|')}');
			}
			for (c in node.children) walk(c);
		}
		walk(plugin.parseFile(src));
		Assert.same(['ClassDecl:T=Int|Array<String>', 'ClassDecl:U=Foo'], seen);
	}

	/** Neither alternative of the constraint is a query node: the type parameter's bounds are children of the declaration. */
	@:pin('control')
	@:killer('M-QUERY-TRANSPARENT-CTOR')
	public function testABoundProjectsAsItsTypes(): Void {
		Assert.equals(
			'(module (ClassDecl C (Named Int) (Named Foo) (Named Bar)))\n',
			Text.render(new HaxeQueryPlugin().parseFile('class C<T:(Int, Foo), U:Bar> {}'))
		);
	}

	private function assertCanonical(source: String): Void {
		Assert.equals(source, roundTrip(source));
	}

	private function roundTrip(source: String): Null<String> {
		try {
			return new HaxeQueryPlugin().writeRoundTrip(source);
		} catch (exception: haxe.Exception) {
			Assert.fail('${exception.message}: $source');
			return null;
		}
	}

}
