package unit.macro;

import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The generated `rewindOrStashTrivia` settles the whitespace/comment run an operator loop consumed and matched no
 * operator after, for both the Pratt and the postfix loop: a comment in the run is rewound so the enclosing rule
 * captures it, a blank line in it is stashed so the next sibling keeps it.
 */
@:nullSafety(Strict)
final class RewindOrStashTriviaTest extends Test {

	/** A block comment after the last operand of an argument, a field value and an array element stays where it was. */
	@:pin('control')
	@:killer('M-TRIVIA-RUN-NO-REWIND')
	public function testCommentAfterTheLastOperandIsKept(): Void {
		final source: String = 'class A {\n\n\tfunction f() {\n\t\tfoo(a /* c */);\n\t\tvar o = {\n\t\t\ta: 1 /* d */\n\t\t};\n'
			+ '\t\tvar x = [\n\t\t\ta /* e */\n\t\t];\n\t}\n\n}\n';
		Assert.equals(source, roundTrip(source));
	}

	/** A blank line after a brace-ended value with no terminator survives to the next statement. */
	@:pin('control')
	@:killer('M-TRIVIA-RUN-NO-BLANK')
	public function testBlankLineAfterABraceEndedValueIsKept(): Void {
		final source: String = 'class A {\n\n\tfunction f() {\n\t\tvar c = function() {}\n\n\t\tfinal d = 1;\n\t}\n\n}\n';
		Assert.equals(source, roundTrip(source));
	}

	/** A single line break there stays a single line break. */
	public function testSingleLineBreakAfterABraceEndedValueStaysSingle(): Void {
		final source: String = 'class A {\n\n\tfunction f() {\n\t\tvar c = function() {}\n\t\tfinal d = 1;\n\t}\n\n}\n';
		Assert.equals(source, roundTrip(source));
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
