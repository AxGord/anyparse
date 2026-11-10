package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/** A source-broken typedef RHS follows the default `anonType` rules: a simple body goes on one line, a complex one wraps by rule. */
final class HxTypedefRhsByRulesTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-TYPEDEF-RHS-KEEPS-SOURCE')
	public function testASimpleBrokenBodyGoesOnOneLine(): Void {
		// Two or more fields go one per line by the typedef rule, so the simple body that collapses holds one field.
		Assert.equals('typedef T = {a:Int}', HxWriteFixture.triviaWrite('typedef T = {\n\ta:Int\n}', '{}'));
		Assert.equals('typedef U = {var a:Int;}', HxWriteFixture.triviaWrite('typedef U = {\n\tvar a:Int;\n}', '{}'));
	}

	@:pin('guard')
	public function testAComplexFlatBodyWrapsByRule(): Void {
		Assert.equals(
			'typedef L = {\n\ta:Int,\n\tb:Int,\n\tc:Int,\n\td:Int,\n\te:Int\n}',
			HxWriteFixture.triviaWrite('typedef L = {a:Int, b:Int, c:Int, d:Int, e:Int}', '{}')
		);
	}

	@:pin('control')
	@:killer('M-TYPEDEF-DOC-LED-IN-CASCADE')
	public function testADocLedFieldTakesItsBlankBeforeTheDoc(): Void {
		Assert.equals(
			'typedef U = {\n\tvar a:Int;\n\n\t/** doc */\n\tvar b:Int;\n}',
			HxWriteFixture.triviaWrite(
				'typedef U = {\n\tvar a:Int;\n\t/** doc */\n\tvar b:Int;\n}',
				'{"emptyLines":{"beforeDocCommentEmptyLines":"one","typedefEmptyLines":{"beginTypeIfDocComments":0,'
				+ '"endTypeIfDocComments":0}}}'
			)
		);
	}

	@:pin('control')
	@:killer('M-TYPEDEF-STRIPPED-BLANK-HOLDS-LINES')
	public function testAStrippedBlankDoesNotHoldTheBodyBroken(): Void {
		// An anon type argument is not forced one field per line, so only the stripped blank could break it.
		Assert.equals(
			'typedef T = Array<{var a:Int; var b:Int;}>',
			HxWriteFixture.triviaWrite(
				'typedef T = Array<{\n\tvar a:Int;\n\n\tvar b:Int;\n}>',
				'{"emptyLines":{"typedefEmptyLines":{"existingBetweenFields":"remove"}}}'
			)
		);
	}

	@:pin('control')
	@:killer('M-TYPEDEF-STATED-BLANKS-IN-CASCADE')
	public function testAStatedBlankCountBreaksTheBody(): Void {
		Assert.equals(
			'typedef T = {\n\ta:Int,\n\n\tb:Int\n}',
			HxWriteFixture.triviaWrite('typedef T = {a:Int, b:Int}', '{"emptyLines":{"typedefEmptyLines":{"betweenFields":1}}}')
		);
		Assert.equals(
			'typedef T = {\n\n\ta:Int,\n\tb:Int\n}',
			HxWriteFixture.triviaWrite('typedef T = {a:Int, b:Int}', '{"emptyLines":{"typedefEmptyLines":{"beginType":1}}}')
		);
	}

}
