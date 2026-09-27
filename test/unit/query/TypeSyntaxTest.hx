package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.TypeSyntax;
import utest.Assert;
import utest.Test;

/** `GrammarPlugin.typeSyntax` over the Haxe grammar: how each spelling of a written type reads. */
@:nullSafety(Strict)
class TypeSyntaxTest extends Test {

	private static final PLUGIN: HaxeQueryPlugin = new HaxeQueryPlugin();

	public function testANamedTypeListsItsArgumentsVerbatim(): Void {
		final t: Null<TypeSyntax> = PLUGIN.typeSyntax(' pkg.Map<String, Array<Int -> Void>> ');
		Assert.equals('pkg.Map<String, Array<Int -> Void>>', t?.text);
		Assert.equals(1, t?.span.from);
		Assert.same(['String', 'Array<Int -> Void>'], t?.argumentTexts());
	}

	public function testTheCurriedChainIsOneFunction(): Void {
		switch PLUGIN.typeSyntax('Int -> ?String -> Void')?.shape {
			case Function(params, ret, true):
				Assert.same(['Int', 'String'], [for (p in params) p.type.text]);
				Assert.same([false, true], [for (p in params) p.optional]);
				Assert.equals('Void', ret.text);
			case _:
				Assert.fail('not a curried function');
		}
	}

	public function testAParenthesisedResultEndsTheChain(): Void {
		switch PLUGIN.typeSyntax('Int -> (String -> Void)')?.shape {
			case Function(params, ret, true):
				Assert.equals(1, params.length);
				Assert.equals('(String -> Void)', ret.text);
			case _:
				Assert.fail('not a curried function');
		}
	}

	public function testASpanStopsAtTheTypesLastToken(): Void {
		switch PLUGIN.typeSyntax('(Int) -> (Int) -> Int  ')?.shape {
			case Function(_, ret, false):
				Assert.equals('(Int) -> Int', ret.text);
				Assert.equals(21, ret.span.to);
			case _:
				Assert.fail('not a function');
		}
	}

	public function testAParameterListIsOneFunctionPerList(): Void {
		switch PLUGIN.typeSyntax('(a: Int, ?b: Map<K, V>, ?Int) -> (String) -> Bool')?.shape {
			case Function(params, ret, false):
				Assert.same(['a', 'b', null], [for (p in params) p.name]);
				Assert.same([false, true, true], [for (p in params) p.optional]);
				Assert.same(['Int', 'Map<K, V>', 'Int'], [for (p in params) p.type.text]);
				Assert.equals('(String) -> Bool', ret.text);
			case _:
				Assert.fail('not a function');
		}
	}

	public function testParenthesesAreTransparent(): Void {
		final t: Null<TypeSyntax> = PLUGIN.typeSyntax('(Null<Int>)');
		Assert.equals('(Null<Int>)', t?.text);
		Assert.equals('Int', t?.wrapped(['Null'])?.text);
	}

	public function testAStructureListsItsTypedFields(): Void {
		switch PLUGIN.typeSyntax('{ a: Int, ?b: String, var c: Float; function f(): Void; }')?.shape {
			case Structure(fields):
				Assert.same(['a', 'b', 'c'], [for (f in fields) f.name]);
				Assert.same(['Int', 'String', 'Float'], [for (f in fields) f.type.text]);
				Assert.same([false, true, false], [for (f in fields) f.optional]);
			case _:
				Assert.fail('not a structure');
		}
	}

	public function testAnIntersectionArgumentListsItsMembers(): Void {
		final args: Array<TypeSyntax> = switch PLUGIN.typeSyntax('EitherType<A & B, C>')?.shape {
			case Nominal(_, args): args;
			case _: [];
		};
		Assert.same(['A & B', 'C'], [for (a in args) a.text]);
		switch args[0]?.shape {
			case Intersection(members):
				Assert.same(['A', 'B'], [for (m in members) m.text]);
			case _:
				Assert.fail('not an intersection');
		}
	}

	public function testAConditionalTypeListsItsBranches(): Void {
		switch PLUGIN.typeSyntax('#if js Dynamic #elseif cpp Float #else Int #end')?.shape {
			case Conditional(branches):
				Assert.same(['Dynamic', 'Float', 'Int'], [for (b in branches) b.text]);
			case _:
				Assert.fail('not a conditional type');
		}
	}

	public function testArgumentsSourceKeepsAComment(): Void {
		Assert.equals('/* c */ Int', PLUGIN.typeSyntax('Null</* c */ Int>')?.argumentsSource());
		Assert.isNull(PLUGIN.typeSyntax('Int')?.argumentsSource());
	}

	public function testACommentAroundTheTypeIsTrivia(): Void {
		final t: Null<TypeSyntax> = PLUGIN.typeSyntax('/* a */ Null<Int> // why');
		Assert.equals('Null<Int>', t?.text);
		Assert.equals(8, t?.span.from);
	}

	public function testTextThatIsNotExactlyOneTypeAnswersNull(): Void {
		Assert.isNull(PLUGIN.typeSyntax('Int; class X {}'));
		Assert.isNull(PLUGIN.typeSyntax('Int Int'));
		Assert.isNull(PLUGIN.typeSyntax('Map<String,'));
		Assert.isNull(PLUGIN.typeSyntax(''));
	}

}
