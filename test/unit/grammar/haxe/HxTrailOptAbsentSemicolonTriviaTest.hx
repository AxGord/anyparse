package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A `@:trailOpt(';')` that is absent from the source, or dropped by the policy, hands the trivia that
 * follows the body to the next declaration or statement: its blank lines and the comment between the
 * body and the `;` survive, in one writer pass.
 */
@:nullSafety(Strict)
final class HxTrailOptAbsentSemicolonTriviaTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final PRESERVE: String = '$BASE, "whitespace": {}}';
	private static final TYPEDEF_NEVER: String = '$BASE, "whitespace": {"typedefSemicolon": "never"}}';
	private static final STMT_NEVER: String = '$BASE, "whitespace": {"optionalSemicolon": "never"}}';

	public function new(): Void {
		super();
	}

	/** A non-brace typedef written without `;` keeps the blank lines after it. */
	@:pin('guard')
	public function testNoSemicolonNonBraceTypedefKeepsBlankLines(): Void {
		final src: String = 'typedef B = Base & Other\n\ntypedef X = Int\n\nclass K {}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, PRESERVE));
	}

	/** The same loss for a module-level `var` without `;`: the path is the shared optional-`;` one. */
	@:pin('control')
	@:killer('M-RESTORE-GAP-LINE-BREAK-IGNORED')
	public function testNoSemicolonModuleVarKeepsBlankLine(): Void {
		final src: String = 'var a = 1\n\nvar b = 2;';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, PRESERVE));
	}

	/** A comment between the body and a `;` the policy drops stays on the line, and the blank after it stays. */
	@:pin('guard')
	public function testNeverKeepsTheCommentAndTheBlankLineOfATypedef(): Void {
		final src: String = 'typedef A = {a:Int} /* c */ ;\n\nclass K {}';
		final once: String = HxWriteFixture.triviaWrite(src, TYPEDEF_NEVER);
		Assert.equals('typedef A = {a:Int} /* c */\n\nclass K {}', once);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, TYPEDEF_NEVER));
	}

	/** The statement lowering shares the path: `optionalSemicolon: never` after a brace-ended body. */
	@:pin('control')
	@:killer('M-RESTORE-GAP-LINE-BREAK-IGNORED')
	public function testNeverKeepsTheCommentAndTheBlankLineOfAStatement(): Void {
		final src: String = 'class K {\n\tfunction f() {\n\t\tvar a = function() {} /* c */ ;\n\n\t\tvar b = 2;\n\t}\n}';
		final once: String = HxWriteFixture.triviaWrite(src, STMT_NEVER);
		Assert.equals('class K {\n\tfunction f() {\n\t\tvar a = function() {} /* c */\n\n\t\tvar b = 2;\n\t}\n}', once);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, STMT_NEVER));
	}

}
