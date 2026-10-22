package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

/**
 * `lint` end to end over a `macro` quotation. The reification gate drops every rule's quoted findings except a
 * `QuotationAware` rule's, and `redundant-parens` is one: a delimited pair inside `macro g((x))` reifies as an
 * `EParenthesis` the typer reads transparently, so the run reports it and `--fix` drops it, exactly as it does
 * outside the quotation. Until B8b the rule was not `QuotationAware` and both answers were empty.
 */
class LintQuotationAwareCliTest extends Test {

	/** The fixture: one quoted delimited pair, the only redundant pair of the file. */
	private static inline final QUOTED: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = macro g((x));\n\t}\n}\n';

	@:pin('control') @:killer('M-PARENS-QUOTED-DROPPED')
	public function testAQuotedRedundantParensFindingReports(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.write('lintquotationaware', QUOTED);
		final out: String = CliFixture.captureStdout(() -> Cli.run(['lint', file, '--rule', 'redundant-parens', '--no-oracle', '--all']));
		FileSystem.deleteFile(file);
		Assert.isTrue(out.indexOf('3:') != -1 && out.indexOf('(redundant-parens)') != -1, out);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-PARENS-QUOTED-DROPPED')
	public function testAQuotedRedundantParensFindingIsFixed(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.write('lintquotationaware', QUOTED);
		CliFixture.captureStdout(() -> Cli.run(['lint', file, '--rule', 'redundant-parens', '--no-oracle', '--fix']));
		final fixed: String = File.getContent(file);
		FileSystem.deleteFile(file);
		Assert.isTrue(fixed.indexOf('var a = macro g(x);') != -1, fixed);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
