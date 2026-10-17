package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.EmptyBlock;
import anyparse.check.Linter;
import anyparse.check.Severity;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

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

	@:pin('control')
	@:killer('M-EMPTY-BLOCK-DRAIN-LOOP')
	public function testDrainLoopNotFlagged(): Void {
		// The condition does the work: each test evaluates a call, so the empty body is the idiom, not a forgotten one.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\twhile (gl.getError() != 0) {}\n\t}\n}').length);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\twhile (client.input.readLine() != \'\') {}\n\t}\n}').length);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\twhile (i++ < n) {}\n\t}\n}').length);
	}

	public function testEmptyForWithCallNotExempt(): Void {
		// A `for` iterates its iterable; the exemption is for a condition loop only.
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tfor (x in items()) {}\n\t}\n}').length);
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

	@:pin('control')
	@:killer('M-EMPTY-BLOCK-NO-DECLINE')
	public function testDeclinedSitesSayWhy(): Void {
		// Every flagged site the fix leaves alone names its gate, so the `--fix` ledger does not report a bare "returned no edit".
		Assert.equals('a loop body: removing it removes the loop', declineOf('while (a) {}'));
		Assert.equals('a try / catch body: the construct needs it', declineOf('try { a(); } catch (e:Dynamic) {}'));
		Assert.equals('the if condition may have a side effect', declineOf('if (compute()) {}'));
		Assert.equals('the if is a single-statement branch body', declineOf('if (a) b(); else if (c) {}'));
	}

	public function testFixedSiteHasNoDecline(): Void {
		Assert.isNull(declineOf('if (a) {}'));
		Assert.isNull(declineOf('if (a) b(); else {}'));
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
		return CheckFixture.violations(new EmptyBlock(), src);
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new EmptyBlock(), src);
	}

	/** The decline note the fix leaves on the one finding of `body` as the body of `f`, or null when it took an edit. */
	private function declineOf(body: String): Null<String> {
		final run: FixRun = CheckFixture.fixRun(
			new EmptyBlock(), [{ file: 'C.hx', source: 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}' }]
		);
		Assert.equals(1, run.violations.length);
		return run.violations[0].declineReason;
	}

}
