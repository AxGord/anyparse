package unit.check.common.expressions;

import anyparse.check.Check;
import anyparse.check.common.expressions.JoinDeclarationAssignment;
import anyparse.check.common.expressions.NarrowLocalScope;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

/**
 * The expression fixes that join a declaration to its first assignment or sink a declaration into a block ask the
 * grammar's `Constructs` for the statement they write; a grammar that builds none gets no edit from them instead of text
 * the rule spelled itself.
 */
@:nullSafety(Strict)
class ExpressionFixWithoutConstructsTest extends Test {

	private static final CASES: Array<{ name: String, rule: Check, source: String }> = [
		{
			name: 'join-declaration-assignment',
			rule: new JoinDeclarationAssignment(),
			source: 'class C {\n\tfunction f():Void {\n\t\tvar x:Int;\n\t\tx = 1 + 2;\n\t\ttrace(x);\n\t}\n}\n'
		},
		{
			name: 'narrow-local-scope',
			rule: new NarrowLocalScope(),
			source: 'class C {\n\tfunction f(i:Int):Void {\n\t\tvar m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tg(m);\n\t\t}\n\t}\n}\n'
		}
	];

	/** Under the real grammar each fix writes an edit; under a grammar with no constructs, none. */
	@:pin('control')
	@:killer('M-JDA-JOIN-SPELLED')
	@:killer('M-NLS-MOVE-SPELLED')
	public function testAnExpressionFixWritesNothingWhereTheGrammarBuildsNoConstruct(): Void {
		for (entry in CASES) {
			final found: Array<Violation> = CheckFixture.violations(entry.rule, entry.source);
			final id: String = entry.name;
			Assert.equals(1, found.length, '$id flags its fixture');
			Assert.isTrue(CheckFixture.fixOf(entry.rule, entry.source, found).length > 0, '$id fixes its fixture');
			Assert.equals(0, CheckFixture.fixOf(entry.rule, entry.source, found, new RefusingConstructsPlugin(_ -> null)).length, id);
		}
	}

}
