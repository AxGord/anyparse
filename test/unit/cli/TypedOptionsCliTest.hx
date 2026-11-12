package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;

using StringTools;
#end

import anyparse.query.Cli;
import anyparse.query.ExitCode.EXIT_OK;
import anyparse.query.ExitCode.EXIT_RUNTIME;
import anyparse.query.ExitCode.EXIT_USAGE;

/**
 * `apq typed-options` through the dispatcher on a real file: the write tail, the preview that writes nothing, a refusal that leaves the
 * file as it was, and the usage error. The rewrite itself is `HxTypedOptionsRewriteTest`'s.
 */
@:nullSafety(Strict)
final class TypedOptionsCliTest extends Test {

	#if (sys || nodejs)
	private static final KIT: String = 'unit.grammar.haxe.HxWriteOptionsKit';
	private static final CALL: String = 'package other;\n\nclass S {\n\n\tfunction f() {\n'
		+ '\t\tfinal opts = loadHxFormatJson(\'{"emptyLines": {"afterPackage": 2}}\');\n\t}\n\n}\n';
	private static final VARIABLE: String =
		'package other;\n\nclass S {\n\n\tfunction f() {\n\t\tfinal opts = loadHxFormatJson(cfg);\n\t}\n\n}\n';
	#end

	public function testWriteRewritesTheCallsInPlaceAndCountsThem(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('typed_options_write', CALL);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['typed-options', '--kit', KIT, '--write', '--reformat', path]));
		final after: String = File.getContent(path);
		FileSystem.deleteFile(path);
		Assert.equals(EXIT_OK, exit, err);
		Assert.isTrue(after.contains('HxWriteOptionsKit.forkWith(edited -> edited.afterPackage = 2)'), after);
		Assert.isFalse(after.contains('loadHxFormatJson'), after);
		Assert.isTrue(err.contains('rewrote 1 file(s), 1 call(s)'), err);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testWithoutWriteTheFileIsLeftAlone(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('typed_options_preview', CALL);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['typed-options', '--kit', KIT, '--reformat', path]));
		final after: String = File.getContent(path);
		FileSystem.deleteFile(path);
		Assert.equals(EXIT_OK, exit, err);
		Assert.equals(CALL, after);
		Assert.isTrue(err.contains('would rewrite 1 file(s), 1 call(s)'), err);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testARefusedFileIsReportedAndLeftAsItWas(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('typed_options_refused', VARIABLE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['typed-options', '--kit', KIT, '--write', '--reformat', path]));
		final after: String = File.getContent(path);
		FileSystem.deleteFile(path);
		Assert.equals(EXIT_RUNTIME, exit, err);
		Assert.equals(VARIABLE, after);
		Assert.isTrue(err.contains('not a constant string'), err);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTheKitIsRequired(): Void {
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['typed-options', 'S.hx']));
		Assert.equals(EXIT_USAGE, exit, err);
		Assert.isTrue(err.contains('--kit'), err);
	}

}
