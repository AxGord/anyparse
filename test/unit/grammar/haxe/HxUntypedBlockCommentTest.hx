package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A comment between `untyped` and its `{ block }` survives the trivia round trip, as a statement,
 * and as a function body, as one after `macro` does: the written text keeps the comment and writes back unchanged.
 */
class HxUntypedBlockCommentTest extends Test {

	@:pin('control')
	@:killer('M-UNTYPED-BLOCK-KW-COMMENT-DROPPED')
	public function testBlockCommentBeforeUntypedStatementBlockKept(): Void {
		assertKept('class Foo {\n\tfunction bar() {\n\t\tuntyped /* b */ {\n\t\t\tfoo();\n\t\t}\n\t}\n}', '/* b */');
	}

	@:pin('control')
	@:killer('M-OWN-KW-GAP-COMMENT-UNWRITTEN')
	public function testLineCommentBeforeUntypedStatementBlockKept(): Void {
		assertKept('class Foo {\n\tfunction bar() {\n\t\tuntyped // c\n\t\t{\n\t\t\tfoo();\n\t\t}\n\t}\n}', '// c');
	}

	@:pin('control')
	@:killer('M-UNTYPED-BLOCK-KW-COMMENT-DROPPED')
	public function testBlockCommentBeforeUntypedFunctionBodyKept(): Void {
		assertKept('class Foo {\n\tfunction bar() untyped /* c */ {\n\t\tfoo();\n\t}\n}', '/* c */');
	}

	@:pin('control')
	@:killer('M-MACRO-KW-COMMENT-DROPPED')
	public function testBlockCommentAfterMacroKept(): Void {
		assertKept('class Foo {\n\tfunction bar() {\n\t\tvar v = macro /* m */ x;\n\t}\n}', '/* m */');
	}

	@:pin('guard')
	public function testUntypedBlockWithoutCommentUnchanged(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\tuntyped {\n\t\t\tfoo();\n\t\t}\n\t}\n}\n';
		Assert.equals(source, write(source));
	}

	/** `source` writes with `comment` kept, and the written text is a fixed point. */
	private function assertKept(source: String, comment: String): Void {
		final once: String = write(source);
		Assert.isTrue(once.contains(comment), once);
		Assert.equals(once, write(once));
	}

	private function write(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
