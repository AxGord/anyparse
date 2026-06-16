package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.EmptyBlock;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `empty-block` check: an `if` / `else` / `while` / `for` / `try` / `catch`
 * body written as `{}` with no statements is flagged `Warning`. A function body,
 * a non-empty block, and a comment-only block are not. Report-only — `fix`
 * yields no edits.
 */
class EmptyBlockCheckTest extends Test {

	public function testEmptyIfFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (a) {}\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('empty-block', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('empty block', vs[0].message);
	}

	public function testEmptyElseFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif (a) b(); else {}\n\t}\n}').length);
	}

	public function testEmptyWhileFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\twhile (a) {}\n\t}\n}').length);
	}

	public function testEmptyForFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tfor (i in 0...n) {}\n\t}\n}').length);
	}

	public function testEmptyCatchFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\ttry { a(); } catch (e:Dynamic) {}\n\t}\n}').length);
	}

	public function testNonEmptyBlockNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) { b(); }\n\t}\n}').length);
	}

	public function testEmptyFunctionBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function new() {}\n\tfunction f():Void {}\n}').length);
	}

	public function testCommentOnlyBlockNotFlagged(): Void {
		// A block holding only a comment has no statement children but non-blank inner source.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) { /* todo */ }\n\t}\n}').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (a) {}\n\t}\n}';
		final check: EmptyBlock = new EmptyBlock();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('empty-block'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('empty-block'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new EmptyBlock().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
