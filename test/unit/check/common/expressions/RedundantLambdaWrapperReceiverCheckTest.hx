package unit.check.common.expressions;

import anyparse.check.common.expressions.RedundantLambdaWrapper;
import anyparse.query.CachingGrammarPlugin;

/**
 * `redundant-lambda-wrapper` over a call through a receiver: `o.m` as a value evaluates `o` once, the lambda on every
 * call, so only a receiver that reads the same object every time reduces — `this`, or a chain of final fields with no
 * getter (`StableChain`), a field typed by the type's own parameter read as its bound.
 */
class RedundantLambdaWrapperReceiverCheckTest extends Test {

	private static final FW: String = 'class Fw {\n\tpublic function new() {}\n\tpublic function abs(x:Int):Int return x;\n\t'
		+ 'public inline function absInline(x:Int):Int return x;\n\textern inline public function ext(x:Int):Int return x;\n}\n';
	private static final HEAD: String = 'class B<W:Fw> {\n\tpublic final fw:Fw;\n\tpublic final watcher:W;\n\tpublic var v:Fw;\n\t'
		+ 'public var vw:W;\n\tpublic var p(get, never):Fw;\n\tfunction get_p():Fw return v;\n\tfunction own(x:Int):Int return x;\n\t'
		+ 'function mk():Fw return fw;\n\tfunction f(xs:Array<Int>, o:Null<Fw>):Void {\n\t\t';

	@:pin('control')
	@:killer('M-RLW-RECEIVER-NEVER')
	public function testFinalFieldReceiverFlagged(): Void {
		Assert.equals(1, count('xs.map(x -> fw.abs(x));'));
		Assert.equals(1, count('xs.map(x -> this.fw.abs(x));'));
	}

	@:pin('control')
	@:killer('M-RLW-TYPE-PARAM-UNBOUND')
	public function testTypeParamFieldInlineMethodFlagged(): Void {
		Assert.equals(1, count('xs.map(x -> watcher.absInline(x));'));
	}

	@:pin('control')
	@:killer('M-RLW-OWN-FIELD-UNSTABLE')
	public function testVarFieldOfTypeParamNotFlagged(): Void {
		Assert.equals(0, count('xs.map(x -> vw.abs(x));'));
	}

	/** A constructor may build the lambda before it assigns the field: the method value would read the field unassigned. */
	@:pin('control')
	@:killer('M-RLW-CONSTRUCTION-BLIND')
	public function testFieldReceiverInConstructorNotFlagged(): Void {
		final ctor: String = '${FW}class D {\n\tfinal h:Fw;\n\tfinal cb:Int->Int;\n\tfinal init:Int->Int = x -> this.own(x);\n\t'
			+ 'public function new() {\n\t\tcb = x -> h.abs(x);\n\t\th = new Fw();\n\t}\n\tfunction own(x:Int):Int return x;\n}\n';
		Assert.equals(1, CheckFixture.violations(new RedundantLambdaWrapper(), ctor, scoped(ctor)).length, 'only the `this` one');
	}

	@:pin('guard')
	public function testThisMemberFlagged(): Void {
		Assert.equals(1, count('xs.map(x -> this.own(x));'));
	}

	@:pin('guard')
	public function testUnstableReceiversNotFlagged(): Void {
		Assert.equals(0, count('xs.map(x -> v.abs(x));'), 'var field');
		Assert.equals(0, count('xs.map(x -> p.abs(x));'), 'property with get');
		Assert.equals(0, count('xs.map(x -> mk().abs(x));'), 'call');
		Assert.equals(0, count('xs.map(x -> o?.abs(x));'), 'safe navigation');
	}

	@:pin('guard')
	public function testExternInlineThroughReceiverNotFlagged(): Void {
		Assert.equals(0, count('xs.map(x -> fw.ext(x));'));
	}

	@:pin('guard')
	public function testFixPassesTheReceiverClosure(): Void {
		final src: String = source('xs.map(x -> fw.abs(x));');
		Assert.equals(src.split('x -> fw.abs(x)').join('fw.abs'), CheckFixture.fixedSource(new RedundantLambdaWrapper(), src, scoped(src)));
	}

	private function count(stmt: String): Int {
		final src: String = source(stmt);
		return CheckFixture.violations(new RedundantLambdaWrapper(), src, scoped(src)).length;
	}

	/** A plugin whose resolution scope is the fixture, so the receiver's type is read through the project index. */
	private function scoped(src: String): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		plugin.setResolutionScope({ declared: true, sources: () -> { report: report, projectRoots: [], library: new LibrarySources([]) } });
		return plugin;
	}

	private function source(stmt: String): String {
		return '$FW$HEAD$stmt\n\t}\n}\n';
	}

}
