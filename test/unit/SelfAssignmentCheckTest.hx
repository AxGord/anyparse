package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.SelfAssignment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `self-assignment` check: a LOCAL variable assigned to itself (`x = x`) is
 * flagged `Warning`. A bare field / property self-assign (`p = p` where `p` is a
 * field) is NOT flagged — it may invoke a property setter — nor is a distinct
 * assignment or a field-access self-assign (`this.x = this.x`). `fix` deletes a
 * flagged local self-assignment.
 */
class SelfAssignmentCheckTest extends Test {

	public function testLocalSelfAssignFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar x = 0;\n\t\tx = x;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('self-assignment', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('this local variable is assigned to itself', vs[0].message);
	}

	public function testDistinctAssignNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tx = y;\n\t}\n}').length);
	}

	public function testFieldAccessSelfAssignNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tthis.x = this.x;\n\t}\n}').length);
	}

	public function testBareFieldSelfAssignNotFlagged(): Void {
		// `p` is a field, not a local — a property setter may run, so it is left alone.
		Assert.equals(0, violations('class C {\n\tvar p:Int;\n\tfunction f():Void {\n\t\tp = p;\n\t}\n}').length);
	}

	public function testPropertySetterSelfAssignNotFlagged(): Void {
		// `p = p` on a `(default, set)` property forces `set_p` — a real side effect.
		final src: String = 'class C {\n\tpublic var p(default, set):Int;\n\tfunction set_p(v:Int):Int { return v; }\n\tfunction f():Void {\n\t\tp = p;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testShadowingLocalFlagged(): Void {
		// A local `p` shadows the field — `p = p` binds to the local, a no-op.
		Assert.equals(1, violations('class C {\n\tvar p:Int;\n\tfunction f():Void {\n\t\tvar p = 1;\n\t\tp = p;\n\t}\n}').length);
	}

	public function testSiblingScopeNotFlagged(): Void {
		// The local `p` lives in the inner block; the `p = p` outside it binds to the field.
		Assert.equals(
			0, violations('class C {\n\tvar p:Int;\n\tfunction f():Void {\n\t\t{\n\t\t\tvar p = 1;\n\t\t}\n\t\tp = p;\n\t}\n}').length
		);
	}

	public function testFixDeletesLocalSelfAssign(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = 0;\n\t\tx = x;\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tvar x = 0;\n\t}\n}', applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('self-assignment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('self-assignment'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testInlineIfSelfAssignReportedNotAutofixed(): Void {
		// Flagged (a local no-op), but `fix` leaves it: deleting a single-statement
		// `if` body would leave a dangling `if`. Reported, not autofixed.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = 0;\n\t\tif (c) x = x;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testUseBeforeDeclNotFlagged(): Void {
		// `x = x` precedes the `var x` declaration, so the name still binds to the
		// property field (forcing `set_x`), not the later local — must NOT be flagged.
		final src: String = 'class C {\n\tpublic var x(default, set):Int;\n\tfunction set_x(v:Int):Int return v;\n\tfunction f():Void {\n\t\tx = x;\n\t\tvar x = 1;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	private function violations(src: String): Array<Violation> {
		return new SelfAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: SelfAssignment = new SelfAssignment();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
