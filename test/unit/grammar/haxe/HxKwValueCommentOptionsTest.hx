package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * The kw-trivia slots of `try` and `return` compose with the options that shape the gap after the
 * keyword: empty slots still take the `tryPolicy` separator, and a comment after `return` survives
 * the object-literal indent layout `indentObjectLiteral` with `leftCurly` before selects.
 */
class HxKwValueCommentOptionsTest extends Test {

	@:pin('control')
	@:killer('M-KW-SLOT-POLICY-SEP-IGNORED')
	public function testTryPolicyNoneCollapsesGapOnTriviaWriter(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\ttry {\n\t\t\tfoo();\n\t\t} catch (e:Dynamic) {}\n\t}\n}';
		final expected: String = 'class Foo {\n\tfunction bar() {\n\t\ttry{\n\t\t\tfoo();\n\t\t} catch (e:Dynamic) {}\n\t}\n}\n';
		Assert.equals(expected, write(source, '{"whitespace":{"tryPolicy":"none"}}'));
	}

	@:pin('control')
	@:killer('M-KW-SLOT-POLICY-SEP-IGNORED')
	public function testTryPolicyOnlyBeforeCollapsesGapOnTriviaWriter(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\ttry {\n\t\t\tfoo();\n\t\t} catch (e:Dynamic) {}\n\t}\n}';
		final expected: String = 'class Foo {\n\tfunction bar() {\n\t\ttry{\n\t\t\tfoo();\n\t\t} catch (e:Dynamic) {}\n\t}\n}\n';
		Assert.equals(expected, write(source, '{"whitespace":{"tryPolicy":"onlyBefore"},"sameLine":{"tryBody":"same"}}'));
	}

	@:pin('control')
	@:killer('M-KW-REF-OBJLIT-BYPASS-DROPS-SLOTS')
	public function testCommentAfterReturnBeforeIndentedObjectLiteralRoundTrip(): Void {
		final source: String = 'class Foo\n{\n\tfunction bar()\n\t{\n\t\treturn // c\n\t\t\t{a: 1, b: 2};\n\t}\n}';
		Assert.equals('$source\n', write(source, '{"indentation":{"indentObjectLiteral":true},"lineEnds":{"leftCurly":"before"}}'));
	}

	private function write(source: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), HxWriteOptionsKit.strictJson(json));
	}

}
