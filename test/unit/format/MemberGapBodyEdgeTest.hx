package unit.format;

import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.MemberGap;

/** `MemberGap.bodyEdge`: a stated count is exact whatever the source holds; an unstated one keeps the source blank only under `Keep`. */
@:nullSafety(Strict)
class MemberGapBodyEdgeTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-BODY-EDGE-STATED-IGNORED')
	public function testAStatedCountWinsOverTheSource(): Void {
		Assert.equals(0, MemberGap.bodyEdge(0, KeepEmptyLinesPolicy.Keep, true));
		Assert.equals(2, MemberGap.bodyEdge(2, KeepEmptyLinesPolicy.Remove, false));
	}

	@:pin('guard')
	public function testAnUnstatedCountFollowsThePolicyAndTheSource(): Void {
		Assert.equals(1, MemberGap.bodyEdge(null, KeepEmptyLinesPolicy.Keep, true));
		Assert.equals(0, MemberGap.bodyEdge(null, KeepEmptyLinesPolicy.Keep, false));
		Assert.equals(0, MemberGap.bodyEdge(null, KeepEmptyLinesPolicy.Remove, true));
	}

}
