package unit.cli;

import anyparse.query.Cli;

/**
 * `apq ast <missing file>` refuses with exit 1 (a runtime refusal) instead of
 * letting the file-read exception escape as a stack trace.
 */
@:nullSafety(Strict)
class ApqAstMissingFileCliTest extends Test {

	public function testMissingFileIsARefusalNotACrash(): Void {
		Assert.equals(1, Cli.run(['ast', '/no/such/dir/Missing.hx']));
	}

}
