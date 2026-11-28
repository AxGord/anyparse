package unit.check.common.control;

import anyparse.check.Check;
import anyparse.check.common.control.GuardContinue;
import anyparse.check.common.control.GuardReturn;
import anyparse.query.GrammarPlugin;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

/**
 * The guard fixes ask the grammar's `Constructs` for the guard, its exit and the run it leads; a grammar that builds none,
 * or refuses statements, gets no edit from them instead of text the rule spelled itself.
 */
@:nullSafety(Strict)
class GuardFixWithoutConstructsTest extends Test {

	private static final CASES: Array<{ name: String, rule: Check, source: String }> = [
		{
			name: 'guard-return',
			rule: new GuardReturn(),
			source: 'class C {\n\tfunction f(ok:Bool):Bool {\n\t\tif (ok) {\n\t\t\tlog(a);\n\t\t\treturn true;\n\t\t}\n\t\treturn false;\n'
				+ '\t}\n}\n'
		},
		{
			name: 'guard-continue',
			rule: new GuardContinue(),
			source: 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) {\n\t\t\tpre();\n\t\t\tif (x != 0) {\n'
				+ '\t\t\t\tbody(x);\n\t\t\t}\n\t\t}\n\t}\n}\n'
		}
	];

	/**
	 * Under the real grammar each guard fix writes an edit; under a grammar with no constructs, or one refusing statements or
	 * the copied run, none: a refused run never leaves the guard alone in place of the body.
	 */
	@:pin('control')
	@:killer('M-GUARD-RETURN-FIX-SPELLED')
	@:killer('M-GUARD-CONTINUE-FIX-SPELLED')
	@:killer('M-GUARD-CONTINUE-REFUSED-RUN-DROPPED')
	public function testAGuardFixWritesNothingWhereTheGrammarBuildsNoStatement(): Void {
		for (entry in CASES) {
			final found: Array<Violation> = CheckFixture.violations(entry.rule, entry.source);
			final id: String = entry.name;
			Assert.equals(1, found.length, '$id flags its fixture');
			Assert.isTrue(CheckFixture.fixOf(entry.rule, entry.source, found).length > 0, '$id fixes its fixture');
			for (plugin in refusing()) Assert.equals(0, CheckFixture.fixOf(entry.rule, entry.source, found, plugin).length, id);
		}
	}

	private static function refusing(): Array<GrammarPlugin> {
		return [
			new RefusingConstructsPlugin(_ -> null),
			new RefusingConstructsPlugin(c -> new RefusingConstructs(c, [], [], false, true)),
			new RefusingConstructsPlugin(c -> new RefusingConstructs(c, [], [], false, false, true))
		];
	}

}
