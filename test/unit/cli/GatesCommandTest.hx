package unit.cli;

import anyparse.query.cli.command.GatesCommand;

/**
 * `GatesCommand.extractGate` takes the predicate name from the FIRST argument of a trail-opt gate call. The argument
 * ends at the first comma outside a quoted literal, whichever quote opens it.
 */
class GatesCommandTest extends Test {

	@:pin('control') @:killer('M-GATES-QUOTE-BLIND')
	public function testCommaInsideASingleQuotedPredicateStaysInIt(): Void {
		Assert.equals('a,b', GatesCommand.extractGate("trailOptShapeGate('a,b', 'init')")?.predicate);
	}

	@:pin('control') @:killer('M-GATES-QUOTE-BLIND')
	public function testCommaInsideADoubleQuotedPredicateStaysInIt(): Void {
		Assert.equals('a,b', GatesCommand.extractGate('trailOptParseGate("a,b")')?.predicate);
	}

	@:pin('guard')
	public function testLaterArgumentsAreNotThePredicate(): Void {
		final gate: Null<GateExtract> = GatesCommand.extractGate("trailOptShapeGate('endsWithCloseBrace', 'init')");
		Assert.equals('endsWithCloseBrace', gate?.predicate);
		Assert.equals('trailOptShapeGate', gate?.gateKind);
		Assert.isNull(GatesCommand.extractGate('tightLead'));
	}

}
