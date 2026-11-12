package unit.check.common.expressions;

import anyparse.check.common.expressions.RedundantLambdaWrapper;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin;

using StringTools;

/**
 * `redundant-lambda-wrapper` through a receiver or a `Type.member` callee whose class is declared in another file: the finding
 * is the same whether that file is among the linted files or only in the resolution scope.
 */
class RedundantLambdaWrapperScopeCheckTest extends Test {

	private static final FW: String = 'class Fw {\n\tpublic function new() {}\n\tpublic function abs(x:Int):Int return x;\n}\n';
	private static final FW_STATIC: String = 'class Fw {\n\tpublic static function keep(x:Int):Int return x;\n}\n';
	private static final HOST: String = 'class B {\n\tpublic final fw:Fw;\n\tpublic function new() {\n\t\tfw = new Fw();\n\t}\n'
		+ '\tfunction f(xs:Array<Int>):Void {\n\t\txs.map(x -> fw.abs(x));\n\t\txs.map(x -> this.fw.abs(x));\n\t}\n}\n';
	private static final STATIC_HOST: String = 'class B {\n\tfunction f(xs:Array<Int>):Void {\n\t\txs.map(x -> Fw.keep(x));\n\t}\n}\n';

	@:pin('control')
	@:killer('M-RLW-HOST-MEMBERS-LINTED-ONLY')
	public function testDeclaringFileOutsideTheLintedFilesAnswersAsInsideThem(): Void {
		assertSameInBothScopes(FW, HOST, 2);
	}

	@:pin('control')
	@:killer('M-RLW-HOST-NODE-STARTS-AT-MODIFIER')
	public function testDeclarationWithModifiersOrMetadataIsFound(): Void {
		assertSameInBothScopes(FW.replace('class Fw', 'final class Fw'), HOST, 2);
		assertSameInBothScopes(FW.replace('class Fw', '@:keep final class Fw'), HOST, 2);
	}

	@:pin('control')
	@:killer('M-RLW-STATIC-HOST-LINTED-ONLY')
	public function testStaticCalleeDeclaredOutsideTheLintedFilesAnswersAsInsideThem(): Void {
		assertSameInBothScopes(FW_STATIC, STATIC_HOST, 1);
	}

	@:pin('control')
	@:killer('M-RLW-STD-GUARD-LINTED-ONLY')
	public function testUnimportedSameNameStaysStdInBothScopes(): Void {
		final host: Source = {
			file: 'C.hx',
			source: 'class C {\n\tfunction f(out:Array<String>):Void {\n\t\tout.sort((a, b) -> Reflect.compare(a, b));\n\t}\n}\n'
		};
		final other: Source = {
			file: 'other/Reflect.hx',
			source: 'package other;\n\nclass Reflect {\n\tpublic static function unrelated(a:Int):Int return a;\n}\n'
		};
		final plugin: GrammarPlugin = StdScope.plugin([host, other]);
		final both: Array<Violation> = CheckFixture.violationsIn(new RedundantLambdaWrapper(), [host, other], plugin);
		final alone: Array<Violation> = CheckFixture.violationsIn(new RedundantLambdaWrapper(), [host], plugin);
		Assert.equals(1, both.length, 'both files linted');
		Assert.equals(both.length, alone.length, 'only the host linted');
		Assert.equals(both[0].message, alone[0].message, 'the same arm answers');
	}

	private function assertSameInBothScopes(declaringSource: String, hostSource: String, expected: Int): Void {
		final host: Source = { file: 'B.hx', source: hostSource };
		final declaring: Source = { file: 'Fw.hx', source: declaringSource };
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final report: Array<Source> = [declaring, host];
		plugin.setResolutionScope({ declared: true, sources: () -> { report: report, projectRoots: [], library: new LibrarySources([]) } });
		final both: Int = CheckFixture.violationsIn(new RedundantLambdaWrapper(), [declaring, host], plugin).length;
		final alone: Int = CheckFixture.violationsIn(new RedundantLambdaWrapper(), [host], plugin).length;
		Assert.equals(expected, both, 'both files linted');
		Assert.equals(both, alone, 'only the host linted');
	}

}

private typedef Source = { file: String, source: String };
