package unit;

import anyparse.check.Check.Violation;
import anyparse.check.EmptyDocTag;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `empty-doc-tag` check: a doc-comment tag with no description - a name-only
 * `@param str`, or a bare `@return` / `@returns` / `@throws` / `@exception` / `@see` -
 * is flagged `Warning`. A tag with any text, on its own line or on a continuation
 * line, is documentation and is kept, and so is `@throws SomeType`. `fix` deletes the
 * flagged lines, or the whole comment when nothing but gutter stars would survive.
 */
class EmptyDocTagCheckTest extends Test {

	public function testNameOnlyParamFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t/**\n\t * Dumps.\n\t * @param x\n\t */\n\tfunction f(x:Int):Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('empty-doc-tag', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('empty @param tag - it documents nothing', vs[0].message);
	}

	public function testTabSeparatedParamNameFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/**\n\t * Dumps.\n\t * @param\tstr\n\t */\n}').length);
	}

	public function testBareParamFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/**\n\t * Dumps.\n\t * @param\n\t */\n}').length);
	}

	public function testBareReturnFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t/**\n\t * Dumps.\n\t * @return\n\t */\n}');
		Assert.equals(1, vs.length);
		Assert.equals('empty @return tag - it documents nothing', vs[0].message);
	}

	public function testBareReturnsFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/**\n\t * Dumps.\n\t * @returns\n\t */\n}').length);
	}

	public function testDescribedParamKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * Dumps.\n\t * @param x the input\n\t */\n}').length);
	}

	public function testParamWithContinuationTextKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * @param x\n\t * the input value\n\t */\n}').length);
	}

	public function testDescribedReturnKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * @return the parsed value\n\t */\n}').length);
	}

	public function testThrowsWithTypeKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * Dumps.\n\t * @throws IOError\n\t */\n}').length);
	}

	public function testBareThrowsFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/**\n\t * Dumps.\n\t * @throws\n\t */\n}').length);
	}

	public function testBareSeeFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t/**\n\t * Dumps.\n\t * @see\n\t */\n}').length);
	}

	public function testUnknownTagKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * Dumps.\n\t * @since\n\t */\n}').length);
	}

	public function testMidLineTagKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * Dumps. @return\n\t */\n}').length);
	}

	public function testPlainBlockCommentKept(): Void {
		Assert.equals(0, violations('class C {\n\t/* @param x */\n}').length);
	}

	public function testUnclosedDocKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * @return\n').length);
	}

	public function testFixKeepsProseAndRemovesTagLines(): Void {
		final src: String =
			'class C {\n\t/**\n\t * Dumps a string.\n\t * @param\tstr\n\t * @return\n\t */\n\tfunction f(str:String):Void {}\n}';
		Assert.equals('class C {\n\t/**\n\t * Dumps a string.\n\t */\n\tfunction f(str:String):Void {}\n}', applyFix(src));
	}

	public function testFixLeavesNoGutterResidue(): Void {
		final src: String = 'class C {\n\t/**\n\t * Dumps.\n\t *\n\t * @return\n\t */\n}';
		Assert.equals('class C {\n\t/**\n\t * Dumps.\n\t */\n}', applyFix(src));
	}

	public function testFixRemovesTagOnlyDoc(): Void {
		final src: String = 'class C {\n\t/**\n\t * @param x\n\t * @return\n\t */\n\tfunction f(x:Int):Void {}\n}';
		Assert.equals('class C {\n\tfunction f(x:Int):Void {}\n}', applyFix(src));
	}

	public function testFixRemovesOneLineDoc(): Void {
		final src: String = 'class C {\n\t/** @return */\n\tfunction f():Int return 0;\n}';
		Assert.equals('class C {\n\tfunction f():Int return 0;\n}', applyFix(src));
	}

	public function testDocumentedTagNotFixed(): Void {
		final src: String = 'class C {\n\t/**\n\t * @param x the input\n\t */\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testParamWithTabDescriptionKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * @param x\tthe input\n\t */\n}').length);
	}

	public function testDigitSuffixedTagKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * Prose.\n\t * @param2\n\t */\n}').length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { /* ').length);
	}

	public function testFixKeepsDividerAfterProse(): Void {
		final src: String = 'class C {\n\t/**\n\t * Prose.\n\t * ***********\n\t * @return\n\t */\n}';
		Assert.equals('class C {\n\t/**\n\t * Prose.\n\t * ***********\n\t */\n}', applyFix(src));
	}

	public function testFixKeepsDividerBeforeTag(): Void {
		final src: String = 'class C {\n\t/**\n\t * ***********\n\t * @return\n\t */\n}';
		Assert.equals('class C {\n\t/**\n\t * ***********\n\t */\n}', applyFix(src));
	}

	public function testFixKeepsDividerAfterTag(): Void {
		final src: String = 'class C {\n\t/**\n\t * @return\n\t * *********\n\t */\n}';
		Assert.equals('class C {\n\t/**\n\t * *********\n\t */\n}', applyFix(src));
	}

	public function testFixKeepsCloserSharingTheTagLine(): Void {
		final src: String = 'class C {\n\t/**\n\t * Prose.\n\t * @return */\n}';
		Assert.equals('class C {\n\t/**\n\t * Prose.\n\t */\n}', applyFix(src));
	}

	public function testFixKeepsCloserAfterATagRun(): Void {
		final src: String = 'class C {\n\t/**\n\t * Prose.\n\t * @param x\n\t * @return */\n}';
		Assert.equals('class C {\n\t/**\n\t * Prose.\n\t */\n}', applyFix(src));
	}

	public function testFixDeletesFirstInteriorLine(): Void {
		final src: String = 'class C {\n\t/** @param x\n\t *\n\t * @return the value\n\t */\n}';
		Assert.equals('class C {\n\t/**\n\t * @return the value\n\t */\n}', applyFix(src));
	}

	public function testFixDeletesFirstInteriorLineCrlf(): Void {
		final src: String = 'class C {\r\n\t/** @param x\r\n\t *\r\n\t * @return the value\r\n\t */\r\n}';
		Assert.equals('class C {\r\n\t/**\r\n\t * @return the value\r\n\t */\r\n}', applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('empty-doc-tag'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('empty-doc-tag'));
	}

	private function violations(src: String): Array<Violation> {
		return new EmptyDocTag().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new EmptyDocTag(), src);
	}

}
