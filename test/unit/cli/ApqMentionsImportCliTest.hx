package unit.cli;

import anyparse.query.Cli;

/**
 * `apq mentions <Name>` answers the IMPORT that makes a simple name resolve.
 *
 * A dotted import path is ONE leaf (`import openfl.Assets;` projects as one `ImportDecl` named
 * `openfl.Assets`), so the lit section's exact compare saw the uses and NOT the import — and a client agent
 * read "no import" off that answer. A simple-name query now also answers an `import` / `using` whose LAST
 * segment is the name, printing the full path, through the same last-segment test `uses` reads for a
 * qualified type reference (`SourceText.answersSimpleName`). A dotted query stays an exact compare.
 */
@:nullSafety(Strict)
class ApqMentionsImportCliTest extends Test {

	private static final SOURCE: String = 'package a;\n\nimport openfl.Assets;\nimport my.OtherAssets;\n\nusing tools.StringTools;\n\n'
		+ 'class M {\n\n\tpublic function new() {\n\t\tAssets.getText(\'x\');\n\t}\n\n}\n';

	/** The import whose last segment is the queried simple name is a hit, printed with its full path. */
	@:pin('control')
	@:killer('M-MENTIONS-IMPORT-KINDS-UNPASSED')
	public function testSimpleNameAnswersTheDottedImport(): Void {
		final out: String = mentions('Assets');
		Assert.isTrue(out.indexOf("ImportDecl 'openfl.Assets'") >= 0, out);
		Assert.isTrue(out.indexOf('OtherAssets') == -1, 'a last segment that merely ENDS with the name is no hit:\n$out');
	}

	/** A `using` is answered the same way. */
	@:pin('control')
	@:killer('M-LIT-QUALIFIED-KINDS-IGNORED')
	public function testSimpleNameAnswersTheDottedUsing(): Void {
		final out: String = mentions('StringTools');
		Assert.isTrue(out.indexOf("UsingDecl 'tools.StringTools'") >= 0, out);
	}

	/** A dotted query stays an exact compare: `other.Assets` does not answer `openfl.Assets`. */
	public function testDottedQueryStaysExact(): Void {
		Assert.isTrue(mentions('openfl.Assets').indexOf("ImportDecl 'openfl.Assets'") >= 0);
		Assert.isTrue(mentions('other.Assets').indexOf('ImportDecl') == -1);
	}

	private static function mentions(name: String): String {
		#if (sys || nodejs)
		final file: String = CliFixture.write('mentionsimport', SOURCE);
		final out: String = CliFixture.captureStdout(() -> Cli.run(['mentions', name, file]));
		sys.FileSystem.deleteFile(file);
		return out;
		#else
		return "ImportDecl 'openfl.Assets' UsingDecl 'tools.StringTools'";
		#end
	}

}
