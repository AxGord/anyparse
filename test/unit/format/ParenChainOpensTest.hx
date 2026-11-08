package unit.format;

import unit.grammar.haxe.HxWriteFixture;

/**
 * An `+` / `-` or `&&` / `||` chain sitting in a parenthesis that does not fit opens the parenthesis as a container: `(` ends the
 * line, the chain goes one indent deeper with its continuation lines co-indented, `)` takes its own line, whatever
 * `wrapping.expressionWrapping` says. A chain that fits stays glued. Every expected shape is also a fix-point of the writer.
 */
@:nullSafety(Strict)
final class ParenChainOpensTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 40}}';

	public function new(): Void {
		super();
	}

	@:pin('control') @:killer('M-PAREN-CHAIN-OPEN-OFF')
	public function testAddSubChainOpensUnderTheDefaults(): Void {
		assertLaidOut(
			'class C {\n\tfunction add() {\n\t\treturn 1 * (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc + dddddddddddd);\n\t}\n}',
			'class C {\n\tfunction add() {\n\t\treturn 1 * (\n\t\t\taaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc\n'
			+ '\t\t\t+ dddddddddddd\n\t\t);\n\t}\n}'
		);
	}

	@:pin('control') @:killer('M-PAREN-CHAIN-ADD-COINDENT-OFF')
	public function testAddSubContinuationCoIndentsWithItsFirstOperand(): Void {
		assertLaidOut(
			'class C {\n\tfunction add() {\n\t\tvar x = (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc + dddddddddddd);\n\t}\n}',
			'class C {\n\tfunction add() {\n\t\tvar x = (\n\t\t\taaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc\n'
			+ '\t\t\t+ dddddddddddd\n\t\t);\n\t}\n}'
		);
	}

	public function testBoolChainOpens(): Void {
		assertLaidOut(
			'class C {\n\tfunction bool() {\n\t\treturn (aaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccc);\n\t}\n}',
			'class C {\n\tfunction bool() {\n\t\treturn (\n\t\t\taaaaaaaaaaaaaaaaa\n\t\t\t&& bbbbbbbbbbbbbbbbbbbb\n'
			+ '\t\t\t&& cccccccccccccccccccc\n\t\t);\n\t}\n}'
		);
	}

	public function testFittingChainStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction fits() {\n\t\tvar x = 1 * (a + b);\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, CONFIG));
	}

	private function assertLaidOut(flat: String, expected: String, ?config: String): Void {
		final json: String = config ?? CONFIG;
		Assert.equals(expected, HxWriteFixture.triviaWrite(flat, json));
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, json));
	}

}
