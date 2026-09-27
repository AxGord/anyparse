package unit.check;

import anyparse.check.FactsTypeText;
import utest.Assert;
import utest.Test;

/** `FactsTypeText.unwrapNull` over types as the compiler facts spell them. */
@:nullSafety(Strict)
class FactsTypeTextTest extends Test {

	/** Only a `Null<…>` enclosing the whole text is peeled: a function type between two of them keeps both. */
	@:pin('control') @:killer('M-FACTS-NULL-PEEL-UNMATCHED')
	public function testOnlyAWrapperEnclosingTheWholeTypeIsPeeled(): Void {
		Assert.equals('Null<A>->Null<B>', FactsTypeText.unwrapNull('Null<A>->Null<B>'));
		Assert.equals('Map<A,B>', FactsTypeText.unwrapNull('Null<Null<Map<A,B>>>'));
		Assert.equals('(Int)->Null<B>', FactsTypeText.unwrapNull('Null<(Int)->Null<B>>'));
		Assert.equals('pack.T', FactsTypeText.unwrapNull('pack.T'));
	}

}
