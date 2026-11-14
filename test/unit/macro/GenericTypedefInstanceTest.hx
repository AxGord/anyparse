package unit.macro;

/** A `@:peg` typedef applied to type arguments is shaped once per argument list, each instance carrying the generic's field metadata. */
class GenericTypedefInstanceTest extends Test {

	@:pin('control')
	@:killer('M-GENERIC-INSTANCE-FIELD-META')
	public function testEachInstanceParsesItsOwnArgumentAfterTheGenericLead(): Void {
		final pair: GenericPair = GenericPairParser.parse('a:b,c:@d');
		Assert.equals('a', (pair.bare.name: String));
		Assert.equals('b', (pair.bare.value.word: String));
		Assert.equals('c', (pair.marked.name: String));
		Assert.equals('d', (pair.marked.value.word: String));
		Assert.raises(() -> GenericPairParser.parse('a:b,c:d'));
	}

}
