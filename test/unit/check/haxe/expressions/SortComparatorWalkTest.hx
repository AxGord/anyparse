package unit.check.haxe.expressions;

import anyparse.check.haxe.expressions.SortComparatorWalk;
import anyparse.query.GrammarPlugin;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;

/** The sort-call walk, the two-parameter callback test and the element resolver every sort-callback rule reads. */
class SortComparatorWalkTest extends Test {

	private static final PROGRAM: String =
		'class C { function f(xs:Array<Int>):Void { xs.sort((a, b) -> a - b); xs.push((c, d) -> c - d); xs.sort(xs.sort(cmp)); } }';

	@:pin('control')
	@:killer('M-SCW-WALK-ANY-CALL')
	public function testWalkVisitsEveryArgumentOfEverySortCallOnly(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = parsed(plugin, PROGRAM);
		final visited: Array<String> = [];
		SortComparatorWalk.each(tree, kinds(plugin), (callee, arg) -> visited.push('${callee.children[0].name}:${arg.kind}'));
		Assert.same(['xs:ThinParenLambdaExpr', 'xs:Call', 'xs:IdentExpr'], visited);
	}

	@:pin('control')
	@:killer('M-SCW-COMPARATOR-ARITY')
	public function testComparatorIsAFunctionLiteralOfTwoParameters(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final sortKinds: SortKinds = kinds(plugin);
		final seen: Array<Bool> = [];
		for (src in ['(a, b) -> 0', '(a) -> 0', '(a, b, c) -> 0', 'cmp']) {
			final tree: QueryNode = parsed(plugin, 'class C { function f():Void { xs.sort($src); } }');
			SortComparatorWalk.each(tree, sortKinds, (_, arg) -> seen.push(SortComparatorWalk.isComparator(arg, sortKinds)));
		}
		Assert.same([true, false, false, false], seen);
	}

	@:pin('control')
	@:killer('M-SCW-ELEMENT-INNER')
	public function testElementResolverAnswersTheOuterNameOfTheElementType(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final receiver: QueryNode = parsed(plugin, PROGRAM);
		final elementOf: (String) -> Null<String> = written ->
			SortComparatorWalk.elementResolver(_ -> written, plugin.refShape(), plugin)(receiver);
		Assert.equals('Item', elementOf('Array<Item>'));
		Assert.equals('Null', elementOf('Array<Null<Item>>'));
		Assert.equals('Array', elementOf('Array<Array<Item>>'));
		Assert.isNull(elementOf('Item'));
	}

	private function parsed(plugin: GrammarPlugin, source: String): QueryNode {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) throw 'does not parse: $source';
		return tree;
	}

	private function kinds(plugin: GrammarPlugin): SortKinds {
		final found: Null<SortKinds> = SortComparatorWalk.kindsOf(plugin.refShape());
		if (found == null) throw 'grammar names no sort kinds';
		return found;
	}

}
