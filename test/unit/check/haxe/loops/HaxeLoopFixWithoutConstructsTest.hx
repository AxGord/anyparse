package unit.check.haxe.loops;

import anyparse.check.Check;
import anyparse.check.haxe.loops.IdentityMap;
import anyparse.check.haxe.loops.PreferExists;
import anyparse.check.haxe.loops.PreferFind;
import anyparse.check.haxe.loops.PreferMap;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

/**
 * The Haxe loop fixes that fold a loop into a `Lambda` call, a comprehension into a `map` or an identity map into the array
 * ask the grammar's `Constructs` for the call and the statement they write; a grammar that builds none gets no edit from
 * them instead of text the rule spelled itself.
 */
@:nullSafety(Strict)
class HaxeLoopFixWithoutConstructsTest extends Test {

	private static final CASES: Array<{ name: String, rule: Check, source: String }> = [
		{
			name: 'prefer-exists',
			rule: new PreferExists(),
			source: 'class C {\n\tfunction f(xs:Array<Int>):Bool {\n\t\tfor (x in xs) if (x > 2) return true;\n\t\treturn false;\n\t}\n}\n'
		},
		{
			name: 'prefer-find',
			rule: new PreferFind(),
			source: 'class C {\n\tfunction f(xs:Array<Int>):Null<Int> {\n\t\tfor (x in xs) if (x > 2) return x;\n\t\treturn null;\n\t}\n}\n'
		},
		{
			name: 'prefer-map',
			rule: new PreferMap(),
			source: 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfinal ys = [for (x in xs) x + 1];\n\t}\n}\n'
		},
		{
			name: 'identity-map',
			rule: new IdentityMap(),
			source: 'class P {}\n\nclass C {\n\tfunction f(ps:Array<P>):Void {\n\t\tfinal ys = ps.map(p -> p);\n\t}\n}\n'
		}
	];

	/** Under the real grammar each fix writes an edit; under a grammar with no constructs, none. */
	@:pin('control')
	@:killer('M-LAMBDA-LOOP-FOLD-SPELLED')
	@:killer('M-PREFER-FIND-SPELLED')
	@:killer('M-PREFER-MAP-SPELLED')
	@:killer('M-IDENTITY-MAP-SPELLED')
	public function testALoopFixWritesNothingWhereTheGrammarBuildsNoConstruct(): Void {
		for (entry in CASES) {
			final found: Array<Violation> = CheckFixture.violations(entry.rule, entry.source);
			final id: String = entry.name;
			Assert.equals(1, found.length, '$id flags its fixture');
			Assert.isTrue(CheckFixture.fixOf(entry.rule, entry.source, found).length > 0, '$id fixes its fixture');
			Assert.equals(0, CheckFixture.fixOf(entry.rule, entry.source, found, new RefusingConstructsPlugin(_ -> null)).length, id);
		}
	}

	/**
	 * A grammar that builds no construct still gets every finding: the report never waits on an edit. `prefer-map` is not
	 * among them, because its message quotes the rewrite and so a grammar that builds none gets no finding from it.
	 */
	@:pin('control')
	@:killer('M-IDENTITY-MAP-RUN-NEEDS-EDIT')
	public function testALoopRuleReportsWhereTheGrammarBuildsNoConstruct(): Void {
		for (entry in CASES) if (entry.name != 'prefer-map')
			Assert.equals(1, CheckFixture.violations(entry.rule, entry.source, new RefusingConstructsPlugin(_ -> null)).length, entry.name);
	}

}
