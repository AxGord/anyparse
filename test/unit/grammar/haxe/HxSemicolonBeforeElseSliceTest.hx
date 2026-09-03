package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-semi-before-else (`whitespace.semicolonBeforeElse`): the optional `;` Haxe accepts between
 * a value-`if`'s then-branch and its `else` (`final x = if (c) a; else b;`).
 *
 * A separate key from `whitespace.optionalSemicolon` because the two answer different questions
 * about the same character. A statement's own terminator is a real style choice; a `;` before
 * `else` is an editing leftover from a statement-`if` that became a value-`if`. A config wants
 * `always` for the first and `never` for the second, which one shared key cannot express -- the
 * composition test below is what that claim rests on.
 *
 * The `;` is inert: `if (c) var x = 1 else var y = 2` and a semicolon-less chain both compile,
 * checked against the compiler rather than argued from the grammar. What is NOT inert is dropping
 * it when there is NO `else`: the value-`if` absorbs the ENCLOSING statement's terminator into the
 * same slot, so every policy value falls back to source presence in that shape.
 */
@:nullSafety(Strict)
final class HxSemicolonBeforeElseSliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final NEVER: String = '$BASE, "whitespace": {"semicolonBeforeElse": "never"}}';
	private static final ALWAYS: String = '$BASE, "whitespace": {"semicolonBeforeElse": "always"}}';
	private static final PRESERVE: String = '$BASE, "whitespace": {}}';
	private static final NEVER_WITH_STMT_ALWAYS: String =
		'$BASE, "whitespace": {"optionalSemicolon": "always", "semicolonBeforeElse": "never"}}';

	public function new(): Void {
		super();
	}

	/** `never` drops the `;` that sits before an `else`. */
	public function testNeverDropsSemiBeforeElse(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal x:Int = if (c) 1; else 2;\n\t}\n}';
		final out: String = 'class C {\n\tfunction test() {\n\t\tfinal x:Int = if (c) 1 else 2;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, NEVER));
	}

	/** Every member of an `else if` chain drops it, not just the outermost. */
	public function testNeverDropsSemiThroughChain(): Void {
		final src: String = 'class C {\n\tfunction test():Int {\n\t\treturn if (a) 1; else if (b) 2; else 3;\n\t}\n}';
		final out: String = 'class C {\n\tfunction test():Int {\n\t\treturn if (a) 1 else if (b) 2 else 3;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, NEVER));
	}

	/** An arrow-lambda body is a value position too. */
	public function testNeverDropsSemiInArrowBody(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\txs.map(x -> if (c) x; else 0);\n\t}\n}';
		final out: String = 'class C {\n\tfunction test() {\n\t\txs.map(x -> if (c) x else 0);\n\t}\n}';
		Assert.equals(out, triviaWrite(src, NEVER));
	}

	/**
	 * ★ The correctness gate: with no `else`, that same slot holds the terminator of the enclosing
	 * statement, so `never` must NOT touch it. Dropping it here emits code that does not compile.
	 */
	public function testNeverKeepsSemiWithoutElse(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal x = if (c) 1;\n\t}\n}';
		Assert.equals(src, triviaWrite(src, NEVER));
	}

	/**
	 * A statement-position `if/else` never routes through this slot at all -- there the `;` belongs
	 * to the inner `ExprStmt`, so `never` cannot reach it and BOTH terminators survive. (The
	 * branches split because this minimal config leaves `sameLine.ifElse` at its default; what the
	 * test pins is the two `;`, not the placement.)
	 */
	public function testStatementIfSemicolonsUntouched(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tif (c) doA(); else doB();\n\t}\n}';
		final out: String = 'class C {\n\tfunction test() {\n\t\tif (c)\n\t\t\tdoA();\n\t\telse\n\t\t\tdoB();\n\t}\n}';
		Assert.equals(out, triviaWrite(src, NEVER));
	}

	/** `always` writes the `;` on a chain the source wrote without one. */
	public function testAlwaysAddsSemiBeforeElse(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal x:Int = if (c) 1 else 2;\n\t}\n}';
		final out: String = 'class C {\n\tfunction test() {\n\t\tfinal x:Int = if (c) 1; else 2;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, ALWAYS));
	}

	/** Absent key -- source presence decides, in both directions. Byte-inert against every existing config. */
	public function testPreserveKeepsBothForms(): Void {
		final withSemi: String = 'class C {\n\tfunction test() {\n\t\tfinal x:Int = if (c) 1; else 2;\n\t}\n}';
		final noSemi: String = 'class C {\n\tfunction test() {\n\t\tfinal x:Int = if (c) 1 else 2;\n\t}\n}';
		Assert.equals(withSemi, triviaWrite(withSemi, PRESERVE));
		Assert.equals(noSemi, triviaWrite(noSemi, PRESERVE));
	}

	/**
	 * ★ The reason the key exists: `optionalSemicolon: always` (write every statement terminator)
	 * composes with `semicolonBeforeElse: never` (write none before `else`). One shared key would
	 * have to answer both with one value.
	 */
	public function testComposesWithStatementSemicolonAlways(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal x:Int = if (c) 1; else 2\n\t}\n}';
		final out: String = 'class C {\n\tfunction test() {\n\t\tfinal x:Int = if (c) 1 else 2;\n\t}\n}';
		Assert.equals(out, triviaWrite(src, NEVER_WITH_STMT_ALWAYS));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}
