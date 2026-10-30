package unit.check.common.nullsafety;

import anyparse.check.Severity;
import anyparse.check.common.nullsafety.GroupSafeNav;

/**
 * The `group-safe-nav` check: two or more consecutive statements null-safe-navigating one local are flagged `Info`
 * and grouped under one `if (r != null) { … }`. A single access, a field receiver, a receiver a write may change while
 * the run executes, a statement not rooted at `r?.` and a receiver already proven non-null are left alone.
 */
class GroupSafeNavCheckTest extends Test {

	public function testRunFlagged(): Void {
		final vs: Array<Violation> = violations(body('r?.push(1);\n\t\tr?.push(2);\n\t\tr?.pop();'));
		Assert.equals(1, vs.length);
		Assert.equals('group-safe-nav', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('3 consecutive statements null-safe-navigate r — one if (r != null) can guard them', vs[0].message);
	}

	/**
	 * Only each root `?.` becomes `.`: a later one, a comment between the statements and the arguments ride along. The
	 * run's text is copied as written; the canonical writer re-indents it under the guard.
	 */
	public function testFixGroupsRun(): Void {
		Assert.equals(
			body('if (r != null) {\nr.push(1);\n\t\t// keep\n\t\tr.concat([2])?.pop();\n}'),
			fixed(body('r?.push(1);\n\t\t// keep\n\t\tr?.concat([2])?.pop();'))
		);
	}

	public function testSingleAccessNotFlagged(): Void {
		Assert.equals(0, violations(body('r?.push(1);\n\t\ttrace(r);\n\t\tr?.push(2);')).length);
	}

	public function testDifferentReceiversNotFlagged(): Void {
		Assert.equals(0, violations(body('r?.push(1);\n\t\ts?.push(2);')).length);
	}

	/** A statement whose `r?.` sits inside a call still runs the call when `r` is null — no member of a run. */
	public function testNestedAccessBreaksRun(): Void {
		Assert.equals(0, violations(body('r?.push(1);\n\t\ttrace(r?.length);')).length);
	}

	/** Any call of the run may change a field between two of its reads. */
	public function testFieldReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tvar fld: Null<Array<Int>>;\n\n\tfunction f(): Void {\n\t\tfld?.push(1);\n\t\tfld?.push(2);\n\t}\n}')
				.length
		);
	}

	public function testWriteInRunNotFlagged(): Void {
		Assert.equals(0, violations(body('r?.push(1);\n\t\tr?.push((r = s).length);')).length);
	}

	/** A function literal of the declaring function may write `r` while the run calls out. */
	@:pin('control')
	@:killer('M-UNCHANGED-LOCAL-CLOSURE-BLIND')
	public function testClosureWriteNotFlagged(): Void {
		Assert.equals(0, violations(body('final reset = () -> r = null;\n\t\tr?.push(1);\n\t\tr?.push(2);')).length);
		Assert.equals(1, violations(body('final reset = () -> s = null;\n\t\tr?.push(1);\n\t\tr?.push(2);')).length);
	}

	/** A write that runs before the run, in the same function, leaves one value across it. */
	public function testWriteBeforeRunFlagged(): Void {
		Assert.equals(1, violations(body('r = s;\n\t\tr?.push(1);\n\t\tr?.push(2);')).length);
	}

	/** A local function writing `r` is as much a callback the run may call as a lambda is. */
	public function testLocalFunctionWriteNotFlagged(): Void {
		Assert.equals(0, violations(body('function kill(): Void r = null;\n\t\tr?.push(1);\n\t\tr?.push(2);')).length);
	}

	/** An assignment of `r?.` still assigns when `r` is null — no member of a run. */
	public function testAssignedAccessNotFlagged(): Void {
		Assert.equals(0, violations(body('var x: Null<Int> = null;\n\t\tx = r?.pop();\n\t\tx = r?.pop();')).length);
	}

	/**
	 * A run ending a block whose value is used is that value: a block expression, an arrow's block body, an if-expression
	 * branch and a statement `if` ending an arrow's body would all become `Void` under the guard.
	 */
	@:pin('control')
	@:killer('M-GSN-VALUE-TAIL')
	public function testValueTailNotFlagged(): Void {
		Assert.equals(0, violations(body('final v: Null<Int> = {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t};')).length);
		Assert.equals(0, violations(body('final h: () -> Null<Int> = () -> {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t};')).length);
		Assert.equals(
			0, violations(body('final w: Null<Int> = if (s != null) {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t} else 0;')).length
		);
		Assert.equals(
			0,
			violations(body('final h = () -> {\n\t\t\tif (s != null) {\n\t\t\t\tr?.push(1);\n\t\t\t\tr?.push(2);\n\t\t\t} else s;\n\t\t};'))
				.length
		);
		// A switch-expression arm, bare and braced, and a try expression: their bodies are the expression's value.
		Assert.equals(
			0,
			violations(body(
				'final v: Null<Int> = switch r?.length {\n\t\t\tcase 1:\n\t\t\t\tr?.push(1);\n\t\t\t\tr?.push(2);\n\t\t\tcase _: null;\n'
				+ '\t\t};'
			)).length
		);
		Assert.equals(
			0,
			violations(body(
				'final v: Null<Int> = switch r?.length {\n\t\t\tcase 1: {\n\t\t\t\tr?.push(1);\n\t\t\t\tr?.push(2);\n\t\t\t}\n'
				+ '\t\t\tcase _: null;\n\t\t};'
			)).length
		);
		Assert.equals(
			0,
			violations(body('final v: Null<Int> = try {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t} catch (e: haxe.Exception) null;'))
				.length
		);
		// A comprehension's body is each element: a `for` or a `while` comprehension is no statement loop.
		Assert.equals(0, violations(body('final a = [for (x in [1]) {\n\t\t\tr?.push(x);\n\t\t\tr?.push(2);\n\t\t}];')).length);
		Assert.equals(0, violations(body('final a = [while (s != null) {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t}];')).length);
		// A ternary branch and a call argument.
		Assert.equals(
			0, violations(body('final v: Null<Int> = s != null ? {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t} : null;')).length
		);
		Assert.equals(0, violations(body('trace({\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t});')).length);
	}

	/** A run followed by another statement of the same arrow body is not its value; a function body's tail never is. */
	public function testNonValueTailFlagged(): Void {
		Assert.equals(1, violations(body('final h = () -> {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t\ttrace(1);\n\t\t};')).length);
		Assert.equals(1, violations(body('if (s != null) {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t}')).length);
		Assert.equals(1, violations(body('final f = function(): Void {\n\t\t\tr?.push(1);\n\t\t\tr?.push(2);\n\t\t};')).length);
	}

	/** A proven non-null receiver is `unnecessary-safe-nav`'s: its `?.` goes, no guard is added. */
	public function testNonNullReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class D {\n\tpublic function m(): Void {}\n}\n\n@:nullSafety(Strict)\nclass C {\n\tfunction f(r: D): Void {\n'
				+ '\t\tr?.m();\n\t\tr?.m();\n\t}\n}'
			).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new GroupSafeNav(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new GroupSafeNav(), src);
	}

	private static function body(statements: String): String {
		return 'class C {\n\tfunction f(r: Null<Array<Int>>, s: Null<Array<Int>>): Void {\n\t\t$statements\n\t}\n}';
	}

}
