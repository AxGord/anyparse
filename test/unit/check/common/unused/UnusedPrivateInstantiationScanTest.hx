package unit.check.common.unused;

import anyparse.check.common.unused.UnusedPrivate;
import anyparse.query.CachingGrammarPlugin;

/** How `unused-private` reads a construction `new C` of a private constructor's class: from the file's code tokens. */
class UnusedPrivateInstantiationScanTest extends Test {

	private static inline final DECL_FILE: String = 'pkg/A.hx';

	/**
	 * A construction spelled only in a comment constructs nothing, so the private constructor is still reported; the
	 * same class built in code is kept (the control).
	 */
	@:pin('control')
	@:killer('M-INSTANTIATION-TEXT-COUNTED')
	public function testAConstructionInACommentDoesNotKeepThePrivateConstructor(): Void {
		for (mention in ['// new A()', '/* new A() */', 'new A();']) {
			final decl: String = 'package pkg;\n\nclass A {\n\n\tprivate function new() {}\n\n\tpublic static function make(): Void {\n'
				+ '\t\t$mention\n\t}\n\n}\n';
			Assert.equals(mention == 'new A();' ? 0 : 1, privateConstructorFindings(decl).length, mention);
		}
	}

	/** The construction scan sees inside an inactive `#if` branch, so a conditionally built class stays. */
	@:pin('guard')
	public function testAConstructionInAnInactiveConditionalBranchKeepsThePrivateConstructor(): Void {
		final decl: String = 'package pkg;\n\nclass A {\n\n\tprivate function new() {}\n\n\tpublic static function make(): Void {\n'
			+ '\t\t#if neverDefined\n\t\tnew A();\n\t\t#end\n\t}\n\n}\n';
		Assert.equals(0, privateConstructorFindings(decl).length);
	}

	/** A construction written as code inside a string-interpolation hole builds the class: the private constructor stays. */
	@:pin('control')
	@:killer('M-INSTANTIATION-HOLE-UNSEEN')
	public function testAConstructionInAnInterpolationHoleKeepsThePrivateConstructor(): Void {
		final decl: String = 'package pkg;\n\nclass A {\n\n\tprivate function new() {}\n\n\tpublic static function make(): String {\n'
			+ '\t\treturn \'$${new A()}\';\n\t}\n\n}\n';
		Assert.equals(0, privateConstructorFindings(decl).length);
	}

	private static function privateConstructorFindings(decl: String): Array<Violation> {
		final files: Array<{ file: String, source: String }> = [{ file: DECL_FILE, source: decl }];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({ declared: true, sources: () -> { report: files, projectRoots: [], library: new LibrarySources([]) } });
		return CheckFixture.violationsIn(new UnusedPrivate(), files, plugin).filter(v -> v.file == DECL_FILE);
	}

}
