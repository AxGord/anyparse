package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeMemberGap;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.query.GrammarPlugin.MemberGapHead;
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
		Assert.equals(1, policy.docBlanks(head([]), head(['/** e */'])));
		Assert.isNull(policy.docBlanks(head([]), head(['/** d */', '// foo', '/** e */'])));
	}

	/**
	 * Under `metadataCountsAsDocComment` a member whose head carries metadata is doc-led for the policy, as the writer's
	 * body Star reads it; with the key off it is not. Killed by `M-MEMBER-GAP-POLICY-META-UNREAD`.
	 */
	@:pin('control')
	@:killer('M-MEMBER-GAP-POLICY-META-UNREAD')
	public function testAMetadataMemberIsDocLedUnderTheKey(): Void {
		final on: HxModuleWriteOptions = new HxModuleWriteOptions();
		on.metadataCountsAsDocComment = true;
		final off: HxModuleWriteOptions = new HxModuleWriteOptions();
		final plain: MemberGapHead = head([]);
		final meta: MemberGapHead = { leading: [], metaOwnLine: true };
		Assert.equals(1, HaxeMemberGap.policy(on).docBlanks(plain, meta));
		Assert.equals(1, HaxeMemberGap.policy(on).docBlanks(meta, plain));
		Assert.isNull(HaxeMemberGap.policy(off).docBlanks(plain, meta));
		Assert.isNull(HaxeMemberGap.policy(off).docBlanks(meta, plain));
	}

	private static function head(leading: Array<String>): MemberGapHead {
		return { leading: leading, metaOwnLine: false };
	}

}
