package unit.cli;

import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.query.Meta;
import anyparse.query.QueryNode;
import anyparse.query.cli.command.GatesCommand;

/**
 * `GatesCommand.extractGate` takes the predicate name from the FIRST argument node of a trail-opt gate call, so a comma
 * inside a quoted literal stays in the predicate, whichever quote opens it.
 */
class GatesCommandTest extends Test {

	@:pin('control')
	@:killer('M-GATES-QUOTE-BLIND')
	public function testCommaInsideASingleQuotedPredicateStaysInIt(): Void {
		Assert.equals('a,b', gateOf("trailOptShapeGate('a,b', 'init')")?.predicate);
	}

	@:pin('control')
	@:killer('M-GATES-QUOTE-BLIND')
	public function testCommaInsideADoubleQuotedPredicateStaysInIt(): Void {
		Assert.equals('a,b', gateOf('trailOptParseGate("a,b")')?.predicate);
	}

	@:pin('guard')
	public function testLaterArgumentsAreNotThePredicate(): Void {
		final gate: Null<GateExtract> = gateOf("trailOptShapeGate('endsWithCloseBrace', 'init')");
		Assert.equals('endsWithCloseBrace', gate?.predicate);
		Assert.equals('trailOptShapeGate', gate?.gateKind);
		Assert.isNull(gateOf('tightLead'));
		Assert.isNull(gateOf("wrapRules('a')"));
	}

	/** A bare identifier as the first argument is the predicate's name too. */
	@:pin('guard')
	public function testABareIdentifierIsThePredicate(): Void {
		Assert.equals('bare', gateOf('trailOptShapeGate(bare)')?.predicate);
	}

	/** The gate of the single `@:fmt` argument `arg`, read off its parsed node. */
	private static function gateOf(arg: String): Null<GateExtract> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = '@:fmt($arg) var x:Int;';
		final tree: QueryNode = plugin.parseFile(source);
		final node: Null<QueryNode> = Meta.find(tree, plugin.metaShape(), source)[0]?.argNodes[0];
		return node == null ? null : GatesCommand.extractGate(node, plugin, source);
	}

}
