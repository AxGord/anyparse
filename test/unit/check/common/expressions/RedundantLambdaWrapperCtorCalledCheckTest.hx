package unit.check.common.expressions;

import anyparse.check.common.expressions.RedundantLambdaWrapper;
import anyparse.query.CachingGrammarPlugin;

/**
 * `redundant-lambda-wrapper` in a method the constructor calls: `h.m` as a value reads `h` when the method runs, so a
 * method reached from the constructor before `h` is assigned keeps its lambda.
 */
class RedundantLambdaWrapperCtorCalledCheckTest extends Test {

	private static final H: String = 'class H {\n\tpublic function new() {}\n\tpublic function m(x:Int):Int return x;\n}\n';

	@:pin('control')
	@:killer('M-RLW-CTOR-CALLED-METHOD-BLIND')
	public function testMethodCalledBeforeAssignmentNotFlagged(): Void {
		Assert.equals(0, count('init();\n\t\th = new H();'));
	}

	/** A call reached through another own method counts at the statement that calls the first one. */
	@:pin('control')
	@:killer('M-RLW-CTOR-CALLED-METHOD-BLIND')
	public function testMethodReachedTransitivelyBeforeAssignmentNotFlagged(): Void {
		Assert.equals(0, count('start();\n\t\th = new H();\n\t}\n\tfunction start():Void {\n\t\tthis.init();'));
	}

	@:pin('control')
	@:killer('M-RLW-CTOR-CALLED-METHOD-ALWAYS')
	public function testMethodCalledAfterAssignmentFlagged(): Void {
		Assert.equals(1, count('h = new H();\n\t\tinit();'));
	}

	@:pin('control')
	@:killer('M-RLW-CTOR-CALLED-METHOD-ALWAYS')
	public function testMethodNoConstructorCallsFlagged(): Void {
		Assert.equals(1, count('h = new H();'));
	}

	private function count(ctorBody: String): Int {
		final src: String = '${H}class D {\n\tfinal h:H;\n\tvar cb:Int->Int;\n\tpublic function new() {\n\t\t$ctorBody\n\t}\n\t'
			+ 'function init():Void {\n\t\tcb = x -> h.m(x);\n\t}\n}\n';
		return CheckFixture.violations(new RedundantLambdaWrapper(), src, scoped(src)).length;
	}

	/** A plugin whose resolution scope is the fixture, so the receiver's type is read through the project index. */
	private function scoped(src: String): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		plugin.setResolutionScope({ declared: true, sources: () -> { report: report, projectRoots: [], library: new LibrarySources([]) } });
		return plugin;
	}

}
