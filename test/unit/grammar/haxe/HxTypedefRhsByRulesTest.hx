package unit.grammar.haxe;

import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/** A source-broken typedef RHS follows the default `anonType` rules: a simple body goes on one line, a complex one wraps by rule. */
final class HxTypedefRhsByRulesTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('guard')
	public function testASimpleBrokenBodyGoesOnOneLine(): Void {
		Assert.equals(
			'typedef T = {a:Int, b:Int}',
			HxWriteFixture.triviaWrite('typedef T = {\n\ta:Int,\n\tb:Int\n}', HaxeFormatConfigLoader.loadHxFormatJson('{}'))
		);
		Assert.equals(
			'typedef U = {var a:Int; var b:Int;}',
			HxWriteFixture.triviaWrite('typedef U = {\n\tvar a:Int;\n\tvar b:Int;\n}', HaxeFormatConfigLoader.loadHxFormatJson('{}'))
		);
	}

	@:pin('guard')
	public function testAComplexFlatBodyWrapsByRule(): Void {
		Assert.equals(
			'typedef L = {\n\ta:Int,\n\tb:Int,\n\tc:Int,\n\td:Int,\n\te:Int\n}',
			HxWriteFixture.triviaWrite('typedef L = {a:Int, b:Int, c:Int, d:Int, e:Int}', HaxeFormatConfigLoader.loadHxFormatJson('{}'))
		);
	}

	@:pin('control')
	@:killer('M-TYPEDEF-DOC-LED-IN-CASCADE')
	public function testADocLedFieldTakesItsBlankBeforeTheDoc(): Void {
		Assert.equals(
			'typedef U = {\n\tvar a:Int;\n\n\t/** doc */\n\tvar b:Int;\n}',
			HxWriteFixture.triviaWrite(
				'typedef U = {\n\tvar a:Int;\n\t/** doc */\n\tvar b:Int;\n}', HxWriteOptionsKit.forkWith(edited -> {
					edited.typedefBeginTypeIfDocComments = 0;
					edited.typedefEndTypeIfDocComments = 0;
				})
			)
		);
	}

	@:pin('control')
	@:killer('M-TYPEDEF-STRIPPED-BLANK-HOLDS-LINES')
	public function testAStrippedBlankDoesNotHoldTheBodyBroken(): Void {
		Assert.equals(
			'typedef T = {var a:Int; var b:Int;}',
			HxWriteFixture.triviaWrite(
				'typedef T = {\n\tvar a:Int;\n\n\tvar b:Int;\n}',
				HxWriteOptionsKit.forkWith(edited -> edited.typedefExistingBetweenFields = KeepEmptyLinesPolicy.Remove)
			)
		);
	}

	@:pin('control')
	@:killer('M-TYPEDEF-STATED-BLANKS-IN-CASCADE')
	public function testAStatedBlankCountBreaksTheBody(): Void {
		Assert.equals(
			'typedef T = {\n\ta:Int,\n\n\tb:Int\n}',
			HxWriteFixture.triviaWrite('typedef T = {a:Int, b:Int}', HxWriteOptionsKit.forkWith(edited -> edited.typedefBetweenFields = 1))
		);
		Assert.equals(
			'typedef T = {\n\n\ta:Int,\n\tb:Int\n}',
			HxWriteFixture.triviaWrite('typedef T = {a:Int, b:Int}', HxWriteOptionsKit.forkWith(edited -> edited.typedefBeginType = 1))
		);
	}

	@:pin('control')
	@:killer('M-TYPEDEF-RHS-KEEPS-SOURCE')
	public function testAGluedBlockCommentRidesTheCascade(): Void {
		Assert.equals(
			'typedef T = {/* c */ a:Int, b:Int}',
			HxWriteFixture.triviaWrite('typedef T = {\n\t/* c */ a:Int,\n\tb:Int\n}', HaxeFormatConfigLoader.loadHxFormatJson('{}'))
		);
	}

}
