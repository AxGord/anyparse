package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.EmptyBlock;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `empty-block` check: an `if` / `else` / `while` / `for` / `try` / `catch`
 * body written as `{}` with no statements is flagged `Warning`. A function body,
 * a non-empty block, and a comment-only block are not. `fix` removes the
 * provably-safe subset (an empty `else {}`, and an empty no-else `if (cond) {}`
 * with a side-effect-free condition); an empty loop / `try` / `catch` body stays
 * report-only.
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

	public function testFixEmptyElseRemoved(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (a) b(); else {}\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (a) b();\n\t}\n}', applyFix(src));
	}

	public function testFixEmptyIfNoElseDeleted(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (a) {}\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t}\n}', applyFix(src));
	}

	public function testFixSideEffectingConditionNotFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (compute()) {}\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixEmptyWhileNotFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\twhile (a) {}\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixEmptyCatchNotFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\ttry { a(); } catch (e:Dynamic) {}\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixEmptyElseIfNotFixed(): Void {
		// An empty no-else `if` that is the else-branch of an enclosing `if` must
		// NOT be deleted — dropping it would leave a dangling `else`.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (a) b(); else if (c) {}\n\t}\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testFixEmptyIfAsBranchBodyNotFixed(): Void {
		// An empty no-else `if` that is the single-statement body of an enclosing
		// `if` must NOT be deleted — it would strand the enclosing branch.
		final src: String = 'class C {\n\tfunction f(x:Bool):Void {\n\t\tif (x) if (c) {}\n\t}\n}';
		Assert.equals(src, applyFix(src));
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

	private function applyFix(src: String): String {
		final check: EmptyBlock = new EmptyBlock();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
