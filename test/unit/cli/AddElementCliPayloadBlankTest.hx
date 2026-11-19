package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

/**
 * `apq add-element --from-file` hands the payload to the op with its trailing
 * newlines intact: a file ending in a blank line keeps that blank line between
 * the inserted element and the member that follows.
 */
class AddElementCliPayloadBlankTest extends Test {

	@:pin('control')
	@:killer('M-ADD-ELEMENT-CLI-STRIPS-PAYLOAD')
	public function testBeforeFromFileKeepsTrailingBlankLine(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('apq_blank', 'class A {\n\tpublic var a:Int;\n\n\tpublic var b:Int;\n}\n');
		final payload: String = CliFixture.write('apq_blank_payload', 'public var x:Int;\n\n');
		Assert.equals(0, Cli.run(['add-element', fixture, '--before', '4:2', '--from-file', payload, '--write']));
		Assert.equals('class A {\n\tpublic var a:Int;\n\n\tpublic var x:Int;\n\n\tpublic var b:Int;\n}\n', File.getContent(fixture));
		FileSystem.deleteFile(fixture);
		FileSystem.deleteFile(payload);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBeforeFromFileWithOneTrailingNewlineAddsNoBlankLine(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('apq_noblank', 'class A {\n\tpublic var a:Int;\n\tpublic var b:Int;\n}\n');
		final payload: String = CliFixture.write('apq_noblank_payload', 'public var x:Int;\n');
		Assert.equals(0, Cli.run(['add-element', fixture, '--before', '3:2', '--from-file', payload, '--write']));
		Assert.equals('class A {\n\tpublic var a:Int;\n\tpublic var x:Int;\n\tpublic var b:Int;\n}\n', File.getContent(fixture));
		FileSystem.deleteFile(fixture);
		FileSystem.deleteFile(payload);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
