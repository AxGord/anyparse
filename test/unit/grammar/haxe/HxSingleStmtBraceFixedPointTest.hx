package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * Removing a single statement's braces writes, in one pass, the text a second pass leaves alone. The
 * braces come off the AST the writer holds, not off text it reads back, so every question the second
 * pass would answer on the bare shape has to be answered on the first.
 */
final class HxSingleStmtBraceFixedPointTest extends Test {

	private static inline final CONFIG: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "remove" } } }';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-SSB-ELSE-IF-LINK-NONE')
	public function testAnElseBlockHoldingAnIfJoinsTheChain(): Void {
		final statement: String = 'if (c) { for (x in y) { p(); q(); } } else { if (d) { e(); f(); } else { g(); h(); } }';
		settles(statement);
		// The chain keeps braces through the else block's `if`, so no branch of it loses its own.
		Assert.isTrue(
			HxWriteFixture.triviaWrite('class F { function f():Void { $statement } }', CONFIG).indexOf('} else {\n\t\t\tif (d) {') != -1
		);
	}

	@:pin('control')
	@:killer('M-SSB-TRY-STAYS-NEVER')
	public function testATryWhoseCatchClosesOnItsOwnSemicolonLosesItsBraces(): Void {
		final src: String = 'class F { function f():Void { try { foo(); } catch (s: String) { b(); } } }';
		Assert.equals(-1, HxWriteFixture.triviaWrite(src, CONFIG).indexOf('try {'));
		settles('try { foo(); } catch (s: String) { b(); }');
	}

	@:pin('control')
	@:killer('M-SSB-TRY-STAYS-ALWAYS')
	public function testATryWhoseCatchIfEndsOnABrace(): Void {
		settles('try { foo(); } catch (s: String) { if (x) { a(); b(); } else { throw s; } }');
	}

	@:pin('control')
	@:killer('M-SSB-TRY-STAYS-ALWAYS')
	public function testATryWhoseCatchIfHasNoElse(): Void {
		settles('try { foo(); } catch (s: String) { if (x) { b(); } }');
	}

	@:pin('control')
	@:killer('M-SSB-TRY-STAYS-ALWAYS')
	public function testATryWhoseCatchIsALoop(): Void {
		settles('try { foo(); } catch (s: String) { for (x in y) { z(); } }');
	}

	@:pin('control')
	@:killer('M-SSB-TRY-STAYS-ALWAYS')
	public function testATryWhoseCatchIsASwitch(): Void {
		settles('try { foo(); } catch (s: String) { switch a { case 1: b(); } }');
	}

	@:pin('control')
	@:killer('M-SSB-TRY-STAYS-ALWAYS')
	public function testATryWhoseCatchIsATry(): Void {
		settles('try { foo(); } catch (s: String) { try { a(); } catch (t: String) { b(); } }');
	}

	@:pin('control')
	@:killer('M-SSB-TRY-STAYS-ALWAYS')
	public function testATryOfBareBodiesWithABracedHead(): Void {
		settles('try { foo(); } catch (s: String) for (x in y) z();');
	}

	@:pin('control')
	@:killer('M-CATCH-SEAM-OPTIONAL-BODY-BLIND')
	public function testATryOfSeveralCatchesSettles(): Void {
		final statement: String = 'try { foo(); } catch (s: String) { b(); } catch (t: Any) { c(); }';
		settles(statement);
		final out: String = HxWriteFixture.triviaWrite('class F { function f():Void { $statement } }', CONFIG);
		Assert.isTrue(out.indexOf('b()\n\t\tcatch (t:Any)') != -1, out);
	}

	@:pin('control')
	@:killer('M-SSB-TRY-IF-TAIL-NEVER')
	public function testATryWhoseCatchIfElseClosesOnItsOwnSemicolonLosesItsBraces(): Void {
		final statement: String = 'try { foo(); } catch (s: String) { if (x) { a(); } else { b(); } }';
		settles(statement);
		final out: String = HxWriteFixture.triviaWrite('class F { function f():Void { $statement } }', CONFIG);
		Assert.isTrue(
			out.indexOf('try\n\t\t\tfoo()\n\t\tcatch (s:String)\n\t\t\tif (x)\n\t\t\t\ta();\n\t\t\telse\n\t\t\t\tb();') != -1, out
		);
	}

	private function settles(statement: String): Void {
		final once: String = HxWriteFixture.triviaWrite('class F { function f():Void { $statement } }', CONFIG);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, CONFIG));
	}

}
