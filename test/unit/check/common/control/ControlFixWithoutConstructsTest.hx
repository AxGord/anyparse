package unit.check.common.control;

import anyparse.check.Check;
import anyparse.check.common.control.ComparisonToBoolean;
import anyparse.check.common.control.ConstantCondition;
import anyparse.check.common.control.PreferIfExpressionAssignment;
import anyparse.check.common.control.PreferTryExpressionReturn;
import anyparse.check.common.control.SimplifyBooleanReturnChain;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

/**
 * The control fixes that write a return, a declaration, an empty block or a folded boolean ask the grammar's `Constructs`
 * for it; a grammar that builds none gets no edit from them instead of text the rule spelled itself.
 */
@:nullSafety(Strict)
class ControlFixWithoutConstructsTest extends Test {

	private static final CASES: Array<{ name: String, rule: Check, source: String }> = [
		{
			name: 'prefer-try-expression-return',
			rule: new PreferTryExpressionReturn(),
			source: 'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn g();\n\t\t} catch (e:Dynamic) {\n\t\t\treturn 0;\n\t\t}\n'
				+ '\t}\n}\n'
		},
		{
			name: 'simplify-boolean-return-chain',
			rule: new SimplifyBooleanReturnChain(),
			source: 'class C {\n\tfunction f(a:Bool, b:Bool):Bool {\n\t\tif (a) return false;\n\t\tif (b) return false;\n\t\treturn true;\n'
				+ '\t}\n}\n'
		},
		{
			name: 'comparison-to-boolean',
			rule: new ComparisonToBoolean(),
			source: 'class C {\n\tfunction f():Void {\n\t\tvar b = true == false;\n\t}\n}\n'
		},
		{
			name: 'prefer-if-expression-assignment',
			rule: new PreferIfExpressionAssignment(),
			source: 'class C {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tvar x:Int = 0;\n\t\tif (a)\n\t\t\tx = 1;\n\t\telse if (b)\n'
				+ '\t\t\tx = 2;\n\t\tuse(x);\n\t}\n}\n'
		},
		{
			name: 'constant-condition',
			rule: new ConstantCondition(),
			source: 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) if (false) ;\n\t\tg();\n\t}\n}\n'
		}
	];

	/** Under the real grammar each fix writes an edit; under a grammar with no constructs, none. */
	@:pin('control')
	@:killer('M-TRY-RETURN-FIX-SPELLED')
	@:killer('M-BOOLEAN-RETURN-CHAIN-FIX-SPELLED')
	@:killer('M-COMPARISON-TO-BOOLEAN-FOLD-SPELLED')
	@:killer('M-DECL-CHAIN-FIX-SPELLED')
	@:killer('M-CONSTANT-CONDITION-EMPTY-BLOCK-SPELLED')
	public function testAControlFixWritesNothingWhereTheGrammarBuildsNoConstruct(): Void {
		for (entry in CASES) {
			final found: Array<Violation> = CheckFixture.violations(entry.rule, entry.source);
			final id: String = entry.name;
			Assert.equals(1, found.length, '$id flags its fixture');
			Assert.isTrue(CheckFixture.fixOf(entry.rule, entry.source, found).length > 0, '$id fixes its fixture');
			Assert.equals(0, CheckFixture.fixOf(entry.rule, entry.source, found, new RefusingConstructsPlugin(_ -> null)).length, id);
		}
	}

}
