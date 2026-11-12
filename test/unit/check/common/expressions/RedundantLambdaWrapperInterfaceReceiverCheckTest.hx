package unit.check.common.expressions;

import anyparse.check.common.expressions.RedundantLambdaWrapper;
import anyparse.query.CachingGrammarPlugin;

/**
 * `redundant-lambda-wrapper` over a receiver typed by an interface: a method value read through an interface receiver is a
 * Dynamic field read on hxcpp, so the lambda is what keeps the static type there and the rule stays silent on it.
 */
class RedundantLambdaWrapperInterfaceReceiverCheckTest extends Test {

	private static final HEAD: String = 'interface Iw {\n\tfunction abs(x:Int):Int;\n}\nclass Cw {\n\tpublic function new() {}\n\t'
		+ 'public function abs(x:Int):Int return x;\n}\nclass B<W:Iw> {\n\tpublic final iw:Iw;\n\tpublic final cw:Cw;\n\t'
		+ 'public final bound:W;\n\tfunction f(xs:Array<Int>):Void {\n\t\t';

	@:pin('control')
	@:killer('M-RLW-INTERFACE-RECEIVER-REDUCED')
	public function testInterfaceReceiverNotFlagged(): Void {
		Assert.equals(0, count('xs.map(x -> iw.abs(x));'), 'final field typed by an interface');
		Assert.equals(0, count('xs.map(x -> this.iw.abs(x));'), 'through this');
		Assert.equals(0, count('xs.map(x -> bound.abs(x));'), 'field typed by a parameter bounded by an interface');
		Assert.equals(0, count('final l:Iw = iw;\n\t\txs.map(x -> l.abs(x));'), 'final local typed by an interface');
	}

	/** The interface declared in another file the run lints: the answer is the same as with it in the linted file. */
	@:pin('control')
	@:killer('M-RLW-INTERFACE-RECEIVER-REDUCED')
	public function testInterfaceInAnotherFileNotFlagged(): Void {
		final other: Array<{ file: String, source: String }> =
			[{ file: 'D.hx', source: 'interface Id {\n\tfunction abs(x:Int):Int;\n}\n' }];
		final src: String =
			'import D.Id;\n\nclass E {\n\tpublic final id:Id;\n\tfunction f(xs:Array<Int>):Void {\n\t\txs.map(x -> id.abs(x));\n\t}\n}\n';
		Assert.equals(0, countFile(src, other));
	}

	@:pin('guard')
	public function testClassReceiverFlagged(): Void {
		Assert.equals(1, count('xs.map(x -> cw.abs(x));'));
	}

	private function count(stmt: String): Int return countFile('$HEAD$stmt\n\t}\n}\n', []);

	/** The findings in `src` when the scope also holds `others`, a file the receiver's type may be declared in. */
	private function countFile(src: String, others: Array<{ file: String, source: String }>): Int {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }].concat(others);
		plugin.setResolutionScope({ declared: true, sources: () -> { report: report, projectRoots: [], library: new LibrarySources([]) } });
		return new RedundantLambdaWrapper().run(report, plugin).length;
	}

}
