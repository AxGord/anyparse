package unit.query;

import anyparse.query.Address;

/**
 * `--nth k` counts EVERY match of a selector in document order, a nested one included, so the
 * k-th is not the k-th TOP-LEVEL region. The ambiguity listing that offers `--nth` must say which
 * row lies inside an earlier row, or a caller picking by ordinal addresses the nested one unawares.
 */
class AddressNestedNthTest extends Test {

	private static final SRC: String = '#if a\nclass A {\n\t#if b\n\tvar x:Int;\n\t#end\n}\n#end\n#if c\nclass B {}\n#end\n';

	public function testNthCountsTheNestedRegionInDocumentOrder(): Void {
		switch resolveIn({ select: 'Conditional', nth: 2 }) {
			case Ok(_, node):
				Assert.equals(3, node?.span?.lineCol(SRC).line);
			case Err(message):
				Assert.fail(message);
		}
		switch resolveIn({ select: 'Conditional', nth: 3 }) {
			case Ok(_, node):
				Assert.equals(8, node?.span?.lineCol(SRC).line);
			case Err(message):
				Assert.fail(message);
		}
	}

	@:pin('control')
	@:killer('M-NTH-NESTED-INSIDE-MARK')
	public function testTheListingMarksARowInsideAnEarlierRow(): Void {
		switch resolveIn({ select: 'Conditional' }) {
			case Ok(_, _):
				Assert.fail('three regions resolved as one');
			case Err(message):
				Assert.stringContains("#2 3:2 Conditional  --select 'ClassDecl:A >> Conditional'  (inside #1)", message);
				Assert.stringContains('#3 8:1 Conditional', message);
				Assert.equals(1, message.split('(inside').length - 1, message);
		}
	}

	private function resolveIn(spec: AddressSpec): AddressResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return Address.resolve(plugin.parseFile(SRC), SRC, plugin, spec);
	}

}
