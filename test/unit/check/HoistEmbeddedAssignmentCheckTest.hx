package unit.check;

import anyparse.check.Check;
import anyparse.check.HoistEmbeddedAssignment;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `hoist-embedded-assignment` check: an assignment written inside an array / object literal
 * is lifted in front of the statement that builds it.
 *
 * The fixtures are built around ONE separating gate -- DEPTH. `testArgumentPositionNotFlagged` and
 * `testNestedCallArgumentNotFlagged` are the living idiom the rule must leave alone, and they
 * differ from the flagged fixtures only in whether a container literal sits on the path; every
 * refusal fixture keeps a genuinely hoistable sibling assignment in the same statement, so it
 * fails only for the gate it names and not because there was nothing to hoist.
 */
class HoistEmbeddedAssignmentCheckTest extends Test {

	public function testAssignmentInsideArrayLiteralFlagged(): Void {
		final vs: Array<Violation> =
			violations('class C {\n\tfunction f() {\n\t\tcontent = new Col([new Row([a, _h = new L(2)])]);\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('hoist-embedded-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('_h') >= 0);
	}

	/**
	 * THE living idiom the rule exists to spare. `_container.addChild(_dot = create(x))` is an
	 * assignment in value position exactly as the flagged fixture is; only the container literal
	 * separates them.
	 */
	public function testArgumentPositionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tc.addChild(_d = mk(1));\n\t}\n}').length);
	}

	/** Depth alone is not the gate: any number of plain call frames still has no data structure in it. */
	public function testNestedCallArgumentNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tc.addChild(wrap(outer(_d = mk(1))));\n\t}\n}').length);
	}

	public function testAssignmentInsideObjectLiteralFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f() {\n\t\tg({k: _h = new L(2), j: 3});\n\t}\n}').length);
	}

	/** The hoisted assignment lands before the statement and the literal keeps the bare name. */
	public function testFixHoistsInFrontOfStatement(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t_h = new L(2);\n\t\tcontent = new Col([new Row([a, _h])]);\n\t}\n}\n',
			applyFix('class C {\n\tfunction f() {\n\t\tcontent = new Col([new Row([a, _h = new L(2)])]);\n\t}\n}')
		);
	}

	/** Several handles in one literal all hoist, in source order — asserted as one string so neither half passes alone. */
	public function testSeveralAssignmentsHoistInSourceOrder(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t_pro = new P(1);\n\t\t_premier = new P(2);\n'
			+ '\t\tcontent = new Row([_pro, new S(3), _premier]);\n\t}\n}\n',
			applyFix('class C {\n\tfunction f() {\n\t\tcontent = new Row([_pro = new P(1), new S(3), _premier = new P(2)]);\n\t}\n}')
		);
	}

	/**
	 * A conditional-compilation region inside the literal: hoisting would lift the write out of its
	 * `#if` guard, so a build excluding the branch would gain a write it never had. The sibling
	 * `_h` is hoistable on its own, so this fixture can only fail for the guard.
	 */
	public function testConditionalRegionInsideLiteralRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f() {\n\t\tcontent = new Row([\n\t\t\t_h = new L(1),\n'
				+ '\t\t\t#if desktop\n\t\t\t_u = new B(2),\n\t\t\t#end\n\t\t\tc\n\t\t]);\n\t}\n}'
			).length
		);
	}

	/** A lambda body defers its write to call time; hoisting would run it at construction time. */
	public function testAssignmentUnderLambdaRefused(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tcontent = new Row([_h = new L(1), () -> _x = 2]);\n\t}\n}').length);
	}

	/** A ternary arm's write is conditional; hoisting would make it unconditional. */
	public function testAssignmentUnderTernaryRefused(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f() {\n\t\tcontent = new Row([_h = new L(1), c ? (_x = a) : b]);\n\t}\n}').length
		);
	}

	/** A neighbour reading the handle would read it before the write moved — refuse. */
	public function testTargetReadElsewhereInStatementRefused(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tcontent = new Row([_h = new L(1), use(_h)]);\n\t}\n}').length);
	}

	/** An argument-position assignment beside a hoistable one would be reordered against it. */
	public function testArgumentAssignmentBesideCandidateRefused(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tf(_d = mk(1), new Row([_h = new L(2)]));\n\t}\n}').length);
	}

	/** A brace-less branch body has nowhere to put a second statement. */
	public function testBracelessIfBodyRefused(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tif (c) content = new Col([_h = new L(1)]);\n\t}\n}').length);
	}

	/** The statement's own root assignment is the spine, never a finding of its own. */
	public function testRootAssignmentNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tcontent = new Col([a, b]);\n\t}\n}').length);
	}

	/**
	 * A local declaration is a host too: `final col = new Col([_p = …]);` binds `col` only after its
	 * initializer is fully evaluated, so the hoisted write already ran ahead of that binding. This is
	 * the shape the TM `PremierPlan` / `ProPlan` sites have.
	 */
	public function testLocalDeclarationInitializerHoisted(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t_p = new P(1);\n\t\tfinal col:Col = new Col([_p]);\n\t}\n}\n',
			applyFix('class C {\n\tfunction f() {\n\t\tfinal col:Col = new Col([_p = new P(1)]);\n\t}\n}')
		);
	}

	/**
	 * `RiskyFix` is load-bearing, not decoration: the hoist is structurally sound and still not
	 * type-neutral (see the check's doc for the measured null-safety narrowing loss), so the edit
	 * must go through the oracle's verify-and-revert path.
	 */
	public function testRegisteredAsDefaultOffRiskyBuiltin(): Void {
		final check: Null<Check> = Linter.byId('hoist-embedded-assignment');
		Assert.notNull(check);
		Assert.isTrue(check is DefaultOff);
		Assert.isTrue(check is RiskyFix);
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('hoist-embedded-assignment'));
	}

	private function violations(src: String): Array<Violation> {
		return new HoistEmbeddedAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer — layout of the hoisted statement is its job. */
	private function applyFix(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: HoistEmbeddedAssignment = new HoistEmbeddedAssignment();
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, found, plugin);
		return switch CanonicalEdit.canonicalize(src, edits, true, plugin) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
