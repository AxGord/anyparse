package unit.check.common.nullsafety;

import anyparse.check.common.nullsafety.DeadNullGuard;

/**
 * Which closure writes cost a local its flow facts, read through `dead-null-guard`: the flow asks
 * `UnchangedLocal.reboundByCalls`, so a write counts when it rebinds the local's own binding — through parentheses
 * too — and a closure writing a same-named local of its own leaves the outer one narrowed.
 */
class DeadNullGuardCaptureTest extends Test {

	@:pin('control')
	@:killer('M-UNCHANGED-LOCAL-REBIND-IGNORED')
	public function testParenthesizedClosureWriteNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C { function f(?x:String) { var g = () -> (x) = null; if (x != null) { if (x != null) trace(x); } } }').length
		);
	}

	@:pin('control')
	@:killer('M-UNCHANGED-LOCAL-REBIND-SHADOW')
	public function testClosureWritingItsOwnLocalKeepsTheFact(): Void {
		Assert.equals(
			1,
			violations(
				'class C { function f(?x:String) { var g = () -> { var x = "a"; x = null; }; if (x != null) { if (x != null) trace(x); } '
				+ '} }'
			).length
		);
	}

	/** A closure write BEFORE its own same-named declaration still writes the outer `x`, so the closure's call voids the fact. */
	@:pin('guard')
	public function testClosureWriteBeforeItsShadowStillVoidsTheFact(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function f(?x:String) { var g = () -> { x = null; var x = "a"; trace(x); }; if (x != null) { g(); if ('
				+ 'x != null) trace(x); } } }'
			).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violationsIn(new DeadNullGuard(), CheckFixture.withStd(src));
	}

}
