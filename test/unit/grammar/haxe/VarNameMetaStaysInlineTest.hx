package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Metadata between a `var` / `final` keyword and the binding name stays on the declaration's line
 * under the default `After` policy: only metadata that leads a declaration breaks after itself.
 */
class VarNameMetaStaysInlineTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	@:pin('control')
	@:killer('M-META-VARDECL-UNWIRED')
	public function testAMetadataBetweenVarAndItsNameStaysOnTheLine(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tvar @:a @:b z = 1;\n\t}\n}\n',
			defaults('class C {\n\tfunction f() {\n\t\tvar @:a\n\t\t@:b\n\n\t\tz = 1;\n\t}\n}\n')
		);
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tvar @:e z = 1;\n\t}\n}\n',
			defaults('class C {\n\tfunction f() {\n\t\tvar @:e z = 1;\n\t}\n}\n')
		);
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tfinal @:e w = 3;\n\t}\n}\n',
			defaults('class C {\n\tfunction f() {\n\t\tfinal @:e w = 3;\n\t}\n}\n')
		);
		Assert.equals('class C {\n\tvar @:e q = 1;\n}\n', defaults('class C {\n\tvar @:e q = 1;\n}\n'));
	}

	@:pin('control')
	@:killer('M-META-VARNAME-INLINE-SEP')
	public function testTheGapBeforeTheNameIgnoresTheSource(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tvar @:e z = 1;\n\t}\n}\n',
			defaults('class C {\n\tfunction f() {\n\t\tvar @:e\n\t\tz = 1;\n\t}\n}\n')
		);
	}

	@:pin('control')
	@:killer('M-GAP-BLOCK-COMMENT-BREAKS')
	public function testABlockCommentInTheGapReachesItsFixedPointInOneWrite(): Void {
		final once: String = defaults('class C {\n\tfunction f() {\n\t\tvar @:e\n\t\t/* c */\n\t\tx = 1;\n\t}\n}\n');
		Assert.equals('class C {\n\tfunction f() {\n\t\tvar @:e /* c */ x = 1;\n\t}\n}\n', once);
		Assert.equals(once, defaults(once));
	}

	@:pin('guard')
	public function testAMetadataLeadingTheDeclarationStillBreaks(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a\n\t\tvar y = 2;\n\t}\n}\n',
			defaults('class C {\n\tfunction f() {\n\t\t@:a var y = 2;\n\t}\n}\n')
		);
	}

	private static function defaults(src: String): String {
		return HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse(src), new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions)
		);
	}

}
