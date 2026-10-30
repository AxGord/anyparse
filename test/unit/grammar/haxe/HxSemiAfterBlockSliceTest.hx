package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A `;` after a block-terminated statement or member is a source token the formatter keeps, glued to
 * the `}` it follows (`};`): removing it is the `empty-statement` lint's job, never the writer's. Under
 * brace removal a kept `;` keeps the braces it follows, so a de-braced body never reads `x;;`.
 */
@:nullSafety(Strict)
final class HxSemiAfterBlockSliceTest extends Test {

	private static final DEFAULT: String = '{}';
	private static final REMOVE: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "remove" } } }';

	public function new(): Void {
		super();
	}

	/** `if` / `if … else` / `for` / `while` bodies, and the `;` written between a block and its `else`. */
	@:pin('control')
	@:killer('M-TRAILOPT-KEEP-OFF')
	public function testControlFlowBodiesKeepGluedSemi(): Void {
		assertKept('if (c) {\n\t\t\ta();\n\t\t};');
		assertKept('if (c) {\n\t\t\ta();\n\t\t} else {\n\t\t\tb();\n\t\t};');
		assertKept('if (c) {\n\t\t\ta();\n\t\t}; else {\n\t\t\tb();\n\t\t}');
		assertKept('for (i in xs) {\n\t\t\ta();\n\t\t};');
		assertKept('while (c) {\n\t\t\ta();\n\t\t};');
	}

	/** `try … catch`: the `;` lands in the last catch body's optional `@:trailOpt` slot. */
	@:pin('control')
	@:killer('M-CATCH-TRAILOPT-OFF')
	public function testCatchBodyKeepsGluedSemi(): Void {
		assertKept('try {\n\t\t\ta();\n\t\t} catch (e:Dynamic) {\n\t\t\tb();\n\t\t};');
	}

	/** Brace removal leaves an if/else chain braced when its last body carries a `;`. */
	@:pin('control')
	@:killer('M-SSB-CHAIN-TRAILSEMI-OFF')
	public function testElseSemiKeepsBracesUnderRemove(): Void {
		final src: String = wrap('if (c) { a(); } else { b(); };');
		Assert.equals(wrap('if (c) {\n\t\t\ta();\n\t\t} else {\n\t\t\tb();\n\t\t};'), HxWriteFixture.triviaWrite(src, REMOVE));
	}

	/** Brace removal leaves a `try` group braced when its last catch body carries a `;`. */
	@:pin('control')
	@:killer('M-TRY-TRAILSEMI-GATE-OFF')
	public function testCatchSemiKeepsBracesUnderRemove(): Void {
		final src: String = wrap('try { a(); } catch (e:Dynamic) { b(); };');
		Assert.equals(wrap('try {\n\t\t\ta();\n\t\t} catch (e:Dynamic) {\n\t\t\tb();\n\t\t};'), HxWriteFixture.triviaWrite(src, REMOVE));
	}

	/** A block the writer SYNTHESIZES around a bare `if` gains no `;`: none was written in the source. */
	@:pin('control')
	@:killer('M-WRAP-SEPAFTER-ALWAYS')
	public function testSynthesizedBlockGainsNoSemi(): Void {
		final src: String = wrap('if (r) if (b) {\n\t\t\tone();\n\t\t\ttwo();\n\t\t} else {\n\t\t\tthree();\n\t\t\tfour();\n\t\t}');
		final out: String = HxWriteFixture.triviaWrite(src, REMOVE);
		Assert.isTrue(out.indexOf('};') == -1, 'expected no `};` in: <$out>');
	}

	/** A member's stray `;` is glued to its body and the usual blank line still follows it. */
	@:pin('control')
	@:killer('M-GLUE-TO-PREVIOUS-OFF')
	public function testMemberSemiGluedWithBlankLines(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tSys.println(1);\n\t};\n\tstatic function main() {\n\t\tf();\n'
			+ '\t}\n\t;\n\tstatic var x = 1;\n}';
		final expected: String = 'class Main {\n\tstatic function f() {\n\t\tSys.println(1);\n\t};\n\n\tstatic function main() {\n'
			+ '\t\tf();\n\t};\n\n\tstatic var x = 1;\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(src, DEFAULT));
	}

	/** The same glue inside a `macro class` quotation. */
	@:pin('control')
	@:killer('M-GLUE-TO-PREVIOUS-OFF')
	public function testMacroClassMemberSemiGlued(): Void {
		assertKept('var c = macro class X {\n\t\t\tfunction f() {};\n\n\t\t\tvar y = 1;\n\t\t};');
	}

	/** A comment between the member and its `;` keeps them apart: gluing would move the `;` into the comment. */
	@:pin('guard')
	public function testMemberSemiAfterTrailingCommentStaysOnItsLine(): Void {
		final src: String = 'class C {\n\tfunction f() {} // c\n\t;\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, DEFAULT));
	}

	private static function assertKept(body: String): Void {
		final src: String = wrap('$body\n\t\tx();');
		Assert.equals(src, HxWriteFixture.triviaWrite(src, DEFAULT));
	}

	private static function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

}
