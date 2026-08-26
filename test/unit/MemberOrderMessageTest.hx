package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.MemberOrder;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * What a `member-order` finding SAYS. Its sibling `MemberOrderCheckTest` covers which member is
 * flagged and how `--fix` reorders; this class covers the sentence, which used to be one frozen
 * string on every finding of the rule and named neither the member nor the rule it broke.
 *
 * Each case is a two-member type isolating ONE ordering key, and the message is asserted whole -
 * a substring assertion would pass on a sentence naming the wrong key, which is the failure mode
 * these tests exist to stop. Two of the keys (`inline`, the declaration-site initializer) decide
 * the order WITHIN a rank and no vocabulary of ranks can express them; a third (instance methods
 * before static ones) was simply missing from the old summary.
 */
@:nullSafety(Strict)
final class MemberOrderMessageTest extends Test {

	/**
	 * One plugin and one empty config for every case - the check under test is stateless and the fixtures are one-liners.
	 */
	private final _plugin: HaxeQueryPlugin = new HaxeQueryPlugin();

	/**
	 * The empty config every case runs under - `member-order` reads options only on the FIX path, and these are report-path tests.
	 */
	private final _config: LintConfig = LintConfig.parse('{}');

	/**
	 * The rank key: the advisory names the flagged member and both ranks, in canonical order.
	 */
	public function testAdvisoryNamesTheMemberAndTheRankRule(): Void {
		Assert.equals(
			'type member \'x\' is out of canonical order: a public var field must precede the public instance method \'m\'',
			messageFor('class C { public function m():Void {} public var x:Int = 0; }')
		);
	}

	/** Instance methods lead static ones - a rank rule the old summary's "constants, fields, constructor, methods" never mentioned. */
	public function testAdvisoryNamesTheStaticMethodRule(): Void {
		Assert.equals(
			'type member \'i\' is out of canonical order: a public instance method must precede the public static method \'s\'',
			messageFor('class C { public static function s():Void {} public function i():Void {} }')
		);
	}

	/**
	 * The within-rank sub-order gets its own sentence: `inline` leads its rank group. That is the key
	 * `prefer-inline` moves a member across - marking a method inline re-sorts it - and the one two
	 * campaign workers misread as the check RECLASSIFYING the member.
	 */
	public function testAdvisoryNamesTheInlineSubOrderRule(): Void {
		Assert.equals(
			'type member \'b\' is out of canonical order: an inline member leads its rank group, so it must precede the non-inline '
			+ 'public instance method \'a\'',
			messageFor('class C { public function a():Void {} public inline function b():Void {} }')
		);
	}

	/** The other half of the sub-order: an initialized declaration leads an init-less one of the same rank. */
	public function testAdvisoryNamesTheInitializerSubOrderRule(): Void {
		Assert.equals(
			'type member \'b\' is out of canonical order: a member with a declaration-site initializer leads an init-less one of the '
			+ 'same rank, so it must precede the public var field \'a\'',
			messageFor('class C { public var a:Int; public var b:Int = 1; }')
		);
	}

	/**
	 * The PINNED conditional-block path, which `comparePinned` orders by block ordinal, then branch,
	 * then rank. Both members here sit in ONE branch of one block, so the first two keys tie and RANK
	 * is what decided them - the sentence has to say rank. It said "an earlier branch of the same #if
	 * block" instead, on all four such findings in the Pony corpus, because `OrderKeys` did not carry
	 * the two keys and the reason re-derived a proxy locally.
	 */
	public function testAdvisoryNamesTheRankInsideAPinnedConditionalBlock(): Void {
		Assert.equals(
			'type member \'a\' is out of canonical order: a public var field must precede the private var field \'b\'',
			messageFor('class C {\n\t#if debug\n\tprivate var b:Int;\n\tpublic var a:Int;\n\t#end\n}\n')
		);
	}

	/**
	 * `inline` on a static constant moves it WITHIN its rank, it does not change the rank: both
	 * spellings are a `public constant`, and the sentence says so. The old message could not, which
	 * is how "a non-inline `static final` is classified as a field and an inline one as a constant"
	 * became a working theory on this campaign.
	 */
	public function testInlineMovesAConstantWithinItsRankNotAcrossRanks(): Void {
		Assert.equals(
			'type member \'B\' is out of canonical order: an inline member leads its rank group, so it must precede the non-inline '
			+ 'public constant \'A\'',
			messageFor('class C { public static final A:String = "a"; public static inline final B:String = "b"; }')
		);
		Assert.equals(0, violations('class C { public static inline final B:String = "b"; public static final A:String = "a"; }').length);
	}

	/** The single message of a source that has exactly one order finding. */
	private function messageFor(src: String): String {
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length, 'the fixture must isolate ONE finding, got ${vs.length}');
		return vs.length == 0 ? '' : vs[0].message;
	}

	private function violations(src: String): Array<Violation> {
		final check: MemberOrder = new MemberOrder();
		check.setConfigResolver(_ -> _config);
		return check.run([{ file: 'C.hx', source: src }], _plugin);
	}

}
