package unit.grammar.haxe;

import anyparse.grammar.haxe.HxCondValue;
import anyparse.grammar.haxe.HxCondValueParser;
import utest.Assert;

/**
 * `HxCondValue` — the generated reader of a `#if` condition's value: its precedence ladder, its single-token operands
 * and the refusal of text it does not read to the end.
 */
@:nullSafety(Strict)
final class HxCondValueTest extends utest.Test {

	@:pin('control')
	@:killer('M-CONDVALUE-AND-LOOSE')
	public function testAndBindsTighterThanOr(): Void {
		Assert.same(Or(flag('a'), And(flag('b'), flag('c'))), HxCondValueParser.parse('a || b && c'));
		Assert.same(Or(And(flag('a'), flag('b')), flag('c')), HxCondValueParser.parse('a && b || c'));
	}

	@:pin('control')
	@:killer('M-CONDVALUE-CMP-LOOSE')
	public function testComparisonBindsTighterThanAndOr(): Void {
		Assert.same(Or(Eq(flag('a'), flag('b')), flag('c')), HxCondValueParser.parse('a == b || c'));
		Assert.same(And(flag('a'), Lt(flag('b'), flag('c'))), HxCondValueParser.parse('a && b < c'));
	}

	@:pin('control')
	@:killer('M-CONDVALUE-NOT-GONE')
	public function testNotBindsTighterThanComparison(): Void {
		Assert.same(Eq(Not(flag('a')), flag('b')), HxCondValueParser.parse('!a == b'));
		Assert.same(Not(Not(flag('a'))), HxCondValueParser.parse('!!a'));
	}

	@:pin('control')
	@:killer('M-CONDVALUE-GTEQ-SHADOWED')
	public function testLongerComparisonOperatorWinsOverItsPrefix(): Void {
		Assert.same(GtEq(flag('a'), flag('b')), HxCondValueParser.parse('a >= b'));
		Assert.same(NotEq(flag('a'), flag('b')), HxCondValueParser.parse('a != b'));
		Assert.same(LtEq(flag('a'), flag('b')), HxCondValueParser.parse('a<=b'));
	}

	@:pin('control')
	@:killer('M-CONDVALUE-VERSION-FLAG')
	@:killer('M-CONDVALUE-GROUP-BRACKET')
	@:killer('M-COND-NUMBER-DOTTED')
	@:killer('M-COND-FLAG-DOTTED')
	public function testOperandsKeepTheirSpelling(): Void {
		Assert.same(VersionCall('"1.2.3"'), HxCondValueParser.parse('version( "1.2.3" )'));
		Assert.same(flag('version'), HxCondValueParser.parse('version'));
		Assert.same(flag('a.b'), HxCondValueParser.parse('a.b'));
		Assert.same(Number('1.2.3'), HxCondValueParser.parse('1.2.3'));
		Assert.same(Quoted('\'x\''), HxCondValueParser.parse('\'x\''));
		Assert.same(Group(flag('a')), HxCondValueParser.parse('(a)'));
	}

	@:pin('control')
	@:killer('M-CONDVALUE-CMP-RIGHT')
	public function testComparisonsChainLeftToRight(): Void {
		Assert.same(Eq(Eq(flag('a'), flag('b')), flag('c')), HxCondValueParser.parse('a == b == c'));
	}

	@:pin('guard')
	public function testTextLeftOverIsRefused(): Void {
		for (text in ['a b', 'a.', '', '(a', '!', 'a ==', 'version(x)', '"x'])
			Assert.raises(() -> HxCondValueParser.parse(text), 'no condition: $text');
	}

	private static function flag(name: String): HxCondValue {
		return Flag(name);
	}

}
