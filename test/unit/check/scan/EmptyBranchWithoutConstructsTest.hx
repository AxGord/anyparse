package unit.check.scan;

import anyparse.check.common.nullsafety.DeadNullGuard;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

/**
 * An always-false guard that is the single-statement body of an enclosing `if` becomes the empty block the grammar's
 * `Constructs` builds; a grammar that builds none gets no edit instead of a block the scan spelled itself.
 */
@:nullSafety(Strict)
class EmptyBranchWithoutConstructsTest extends Test {

	private static final SOURCE: String = 'class Foo {\n\tpublic function new() {}\n\tpublic function g():Void {}\n}\n\n'
		+ '@:nullSafety(Strict)\nclass C {\n\tfunction cond():Bool\n\t\treturn true;\n\n\tfunction f():Void {\n\t\tvar x = new Foo();\n'
		+ '\t\tif (cond()) if (x == null) x.g();\n\t\ttrace("keep");\n\t}\n}\n';

	/** Under the real grammar the guard collapses to `{}`; under a grammar with no constructs, or one refusing statements, nothing. */
	@:pin('control')
	@:killer('M-IF-SHAPE-EMPTY-BLOCK-SPELLED')
	public function testAnEmptiedBranchIsBuiltByTheGrammar(): Void {
		final rule: DeadNullGuard = new DeadNullGuard();
		final found: Array<Violation> = CheckFixture.violations(rule, SOURCE);
		Assert.equals(1, found.length);
		Assert.isTrue(CheckFixture.fixedSource(rule, SOURCE).indexOf('if (cond()) {}') >= 0);
		Assert.equals(0, CheckFixture.fixOf(rule, SOURCE, found, new RefusingConstructsPlugin(_ -> null)).length);
		Assert.equals(
			0,
			CheckFixture.fixOf(rule, SOURCE, found, new RefusingConstructsPlugin(c -> new RefusingConstructs(c, [], [], false, true)))
				.length
		);
	}

}
