package unit.grammar.tightlead;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/** A lead the format declares tight stays tight under `keyValueSpace` though it is the format's key-value separator. */
class TightLeadPairTest extends Test {

	@:pin('control')
	@:killer('M-KEY-VALUE-LEAD-IGNORES-TIGHT')
	public function testATightKeyValueLeadIgnoresKeyValueSpace(): Void {
		final options: TightLeadPairWriteOptions = cast new HxModuleWriteOptions();
		options.keyValueSpace = true;
		Assert.equals('a:Int\n', TightLeadPairWriter.write({ name: 'a', type: 'Int' }, options));
	}

}
