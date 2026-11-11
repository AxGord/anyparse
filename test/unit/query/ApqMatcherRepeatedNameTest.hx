package unit.query;

import anyparse.query.Matcher;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;

/**
 * A metavariable repeated between a NAME slot (a lambda parameter) and an expression
 * (the lambda body) is one constraint: both places must spell the same identifier.
 */
class ApqMatcherRepeatedNameTest extends Test {

	private static final SOURCE: String = 'class X {
		function f(xs: Array<Int>) {
			var a = xs.map(group -> group);
			var b = xs.map(group -> (group : Int));
			var c = xs.map(g -> h);
			var d = xs.map(n -> n + 1);
			var e = xs.map(xs -> 1);
var f = xs.map(p -> new p());
var g = new xs().map(xs -> 1);
		}
	}';

	@:pin('control')
	@:killer('M-MATCH-NAME-EXPR-UNEQUAL')
	public function testRepeatedParamAndBodyIdentifierMatches(): Void {
		final matches: Array<Match> = search('$$xs.map($$p -> $$p)');
		Assert.equals(1, matches.length);
		Assert.equals('group', matches[0].bindings.get('p')?.name);
	}

	@:pin('control')
	@:killer('M-MATCH-NAME-EXPR-UNEQUAL')
	public function testRepeatedParamAndTypeCheckedBodyMatches(): Void {
		final matches: Array<Match> = search('$$xs.map($$p -> ($$p : $$t))');
		Assert.equals(1, matches.length);
		Assert.equals('group', matches[0].bindings.get('p')?.name);
	}

	@:pin('control')
	@:killer('M-MATCH-NAME-EXPR-ANY-NAME')
	public function testRepeatedMetavariableWithDifferentNamesDoesNotMatch(): Void {
		final names: Array<Null<String>> = search('$$xs.map($$p -> $$p)').map(m -> m.bindings.get('p')?.name);
		Assert.isFalse(names.contains('g'), 'g -> h is two names');
		Assert.isFalse(names.contains('n'), 'n -> n + 1 is no bare identifier');
		Assert.equals(7, search('$$xs.map($$p -> $$q)').length, 'distinct metavariables still bind independently');
	}

	@:pin('control')
	@:killer('M-MATCH-EXPR-NAME-UNEQUAL')
	public function testExpressionBoundMetavariableRepeatedAsParameterMatches(): Void {
		final matches: Array<Match> = search('$$p.map($$p -> $$_)');
		Assert.equals(1, matches.length);
		Assert.equals('xs', matches[0].bindings.get('p')?.name);
	}

	@:pin('guard')
	public function testRepeatedMetavariableAcrossExpressionsStillMatches(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile('class X { function f() { var n = 0; n = n + 1; n = m + 1; } }');
		Assert.equals(1, Matcher.search(plugin.parsePattern('$$e = $$e + 1'), tree).length);
	}

	@:pin('control')
	@:killer('M-MATCH-IDENT-REF-ANY-NAMED-NODE')
	public function testANamedNodeThatIsNoIdentifierReferenceDoesNotAgree(): Void {
		final names: Array<Null<String>> = search('$$xs.map($$p -> $$p)').map(m -> m.bindings.get('p')?.name);
		Assert.isFalse(names.contains('p'), '`new p()` names p but is not an identifier reference');
		Assert.equals(1, search('$$p.map($$p -> $$_)').length, '`new xs()` is not the identifier xs');
	}

	private static function search(patternSource: String): Array<Match> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern(patternSource);
		final tree: QueryNode = plugin.parseFile(SOURCE);
		return Matcher.search(pattern, tree);
	}

}
