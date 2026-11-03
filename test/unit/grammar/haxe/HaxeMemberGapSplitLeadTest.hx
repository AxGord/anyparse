package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeMemberGap;
import anyparse.query.GrammarPlugin.MemberGapPolicy;
import utest.Assert;
import utest.Test;

/** The policy `member-order` reads holds the writer's split-lead rule: no blank is demanded above a member `fmt` writes none above. */
@:nullSafety(Strict)
class HaxeMemberGapSplitLeadTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-MEMBER-GAP-POLICY-NO-SPLIT-LEAD')
	public function testASplitLedNextMemberIsDemandedNoDocBlank(): Void {
		final policy: MemberGapPolicy = HaxeMemberGap.policy(HaxeFormat.instance.defaultWriteOptions);
		Assert.equals(1, policy.docBlanks([], ['/** e */']));
		Assert.isNull(policy.docBlanks([], ['/** d */', '// foo', '/** e */']));
	}

}
