package unit.cli;

import anyparse.query.Cli;

using StringTools;

/**
 * `apq ast <TypeName> <path>` is a common miss — `ast` reads one file — and its refusal routes the user to the multi-file
 * walkers when the second argument reads as a path: it holds a slash, or an extension a registered grammar claims.
 */
@:nullSafety(Strict)
final class ApqAstTwoFilesHintCliTest extends Test {

	/** A name with a registered grammar's extension reads as a path, whether or not the file exists. */
	@:killer('M-AST-PATH-EXTENSION-IGNORED')
	@:pin('control')
	public function testAnExtensionAGrammarClaimsReadsAsAPath(): Void {
		Assert.isTrue(refusal('nothere.json').contains('"Foo" looks like a TypeName and "nothere.json" like a path'));
	}

	/** A name with a slash reads as a path. */
	@:killer('M-AST-PATH-SLASH-IGNORED')
	@:pin('control')
	public function testASlashReadsAsAPath(): Void {
		Assert.isTrue(refusal('no/such').contains('"Foo" looks like a TypeName and "no/such" like a path'));
	}

	/** A bare word that names nothing gets the plain refusal. */
	@:pin('guard')
	public function testABareWordGetsThePlainRefusal(): Void {
		final err: String = refusal('nothere');
		Assert.isTrue(err.contains('only one file argument supported (got "Foo" and "nothere")'), err);
		Assert.isFalse(err.contains('looks like a TypeName'), err);
	}

	/** What `apq ast Foo <second> --lang haxe` says on stderr. */
	private function refusal(second: String): String {
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['ast', 'Foo', second, '--lang', 'haxe']));
		Assert.equals(2, exit, err);
		return err;
	}

}
