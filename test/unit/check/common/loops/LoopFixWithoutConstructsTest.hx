package unit.check.common.loops;

import anyparse.check.Check;
import anyparse.check.common.loops.PreferArrayLiteral;
import anyparse.check.common.loops.PreferModuloWrap;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

/**
 * The loop fixes that write an empty array literal or a modulo wrap ask the grammar's `Constructs` for it; a grammar that
 * builds none gets no edit from them instead of text the rule spelled itself.
 */
@:nullSafety(Strict)
class LoopFixWithoutConstructsTest extends Test {

	private static final CASES: Array<{ name: String, rule: Check, source: String }> = [
		{
			name: 'prefer-array-literal',
			rule: new PreferArrayLiteral(),
			source: 'class C {\n\tfunction f():Void {\n\t\tvar xs:Array<Int> = new Array();\n\t}\n}\n'
		},
		{
			name: 'prefer-modulo-wrap',
			rule: new PreferModuloWrap(),
			source: 'class C {\n\tfunction f(v:Int):Void {\n\t\twhile (v >= 360) v -= 360;\n\t\twhile (v < 0) v += 360;\n\t}\n}\n'
		}
	];

	/** Under the real grammar each fix writes an edit; under a grammar with no constructs, none. */
	@:pin('control')
	@:killer('M-NEW-LITERAL-EMPTY-ARRAY-SPELLED')
	@:killer('M-PMW-WRAP-SPELLED')
	public function testALoopFixWritesNothingWhereTheGrammarBuildsNoConstruct(): Void {
		for (entry in CASES) {
			final found: Array<Violation> = CheckFixture.violations(entry.rule, entry.source);
			final id: String = entry.name;
			Assert.equals(1, found.length, '$id flags its fixture');
			Assert.isTrue(CheckFixture.fixOf(entry.rule, entry.source, found).length > 0, '$id fixes its fixture');
			Assert.equals(0, CheckFixture.fixOf(entry.rule, entry.source, found, new RefusingConstructsPlugin(_ -> null)).length, id);
		}
	}

}
