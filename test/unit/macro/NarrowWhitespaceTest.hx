package unit.macro;

/** The generated `skipWs` consumes exactly the characters the format's `whitespace` field declares. */
class NarrowWhitespaceTest extends Test {

	public function testDeclaredWhitespaceSeparates(): Void {
		switch NarrowWhitespaceParser.parse('{a \t b}') {
			case Block(items):
				Assert.equals(2, items.length);
		}
	}

	@:pin('control')
	@:killer('M-SKIPWS-FORMAT-WHITESPACE-IGNORED')
	public function testUndeclaredLineBreakIsNotWhitespace(): Void {
		Assert.raises(() -> NarrowWhitespaceParser.parse('{a\nb}'));
	}

}
