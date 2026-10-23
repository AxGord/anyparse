package unit.query;

import anyparse.query.Cli;
import anyparse.query.RemoveImport;
import sys.io.File;
import unit.cli.CliFixture;

/**
 * `RemoveImport.removeImport` — remove an `import` / `using` by its exposed
 * module path, the by-name wrapper over `RemoveElement` and the backend of
 * `lint --fix`. The removal itself is covered exactly by
 * `RemoveElementSliceTest`; here the focus is path resolution: the right
 * statement is removed, the others survive, and a path that names zero or
 * many statements is refused.
 */
class RemoveImportSliceTest extends Test {

	/** Remove one import by path; the sibling import and the type survive. */
	public function testRemoveImport(): Void {
		final source: String = 'import a.Used;\nimport a.Gone;\nclass C {\n\tvar x:Used;\n}\n';
		final text: String = okText(source, 'a.Gone');
		Assert.isTrue(text.indexOf('a.Gone') == -1);
		Assert.isTrue(text.indexOf('import a.Used;') >= 0);
	}

	/** Remove a sub-type import addressed by its full `module.Sub` path. */
	public function testRemoveSubTypeImport(): Void {
		final source: String = 'import a.M.Sub;\nimport a.Used;\nclass C {\n\tvar x:Used;\n}\n';
		final text: String = okText(source, 'a.M.Sub');
		Assert.isTrue(text.indexOf('a.M.Sub') == -1);
		Assert.isTrue(text.indexOf('import a.Used;') >= 0);
	}

	/** Remove a `using` statement by its path. */
	public function testRemoveUsing(): Void {
		final source: String = 'using a.Helper;\nimport a.Used;\nclass C {\n\tvar x:Used;\n}\n';
		final text: String = okText(source, 'a.Helper');
		Assert.isTrue(text.indexOf('a.Helper') == -1);
		Assert.isTrue(text.indexOf('using') == -1);
		Assert.isTrue(text.indexOf('import a.Used;') >= 0);
	}

	/** A path that names no import is refused. */
	public function testNotFound(): Void {
		final source: String = 'import a.Used;\nclass C {\n\tvar x:Used;\n}\n';
		assertErr(source, 'a.Nope');
	}

	/** A path naming both an `import` and a `using` is ambiguous — refused. */
	public function testAmbiguous(): Void {
		final source: String = 'import a.B;\nusing a.B;\nclass C {}\n';
		assertErr(source, 'a.B');
	}

	/**
	 * A `#if`-guarded import is refused — and the refusal says WHICH world it is in.
	 *
	 * The guarded statement is a child of the `Conditional` node, not of the module, so the
	 * top-level filter cannot see it and the old message ("no import of X found") described a
	 * file that does not exist: the import is right there, one line under the `#if`. The op
	 * still declines to remove it — the last statement out of a region leaves the condition
	 * standing around nothing — so the message hands the work to `remove-element --match`,
	 * which is the op that DOES delete it and is the one the caller addressed deliberately.
	 */
	public function testGuardedImportIsRefusedByName(): Void {
		final source: String = '#if sys\nimport a.Used;\n#end\nclass C {}\n';
		Assert.isTrue(errText(source, 'a.Used').indexOf('conditional-compilation region') >= 0, errText(source, 'a.Used'));
		Assert.isTrue(errText(source, 'a.Used').indexOf('apq remove-element') >= 0, errText(source, 'a.Used'));
	}

	/** And a path that really is absent keeps the plain wording — the two refusals must not merge. */
	public function testAbsentPathKeepsThePlainWording(): Void {
		final source: String = '#if sys\nimport a.Used;\n#end\nclass C {}\n';
		Assert.equals('no import of "a.Missing" found', errText(source, 'a.Missing'));
	}

	/**
	 * A whole `using x.Y;` statement names the `using` alone, so the path an `import` of the same module
	 * shares no longer makes the request ambiguous — the keyword is the disambiguation `testAmbiguous`
	 * had no way to spell.
	 */
	@:pin('control')
	@:killer('M-REMOVEIMPORT-KEYWORD-IGNORED')
	public function testUsingStatementPicksTheUsing(): Void {
		final text: String = okText('import a.B;\nusing a.B;\nclass C {}\n', 'using a.B;');
		Assert.isTrue(text.indexOf('import a.B;') >= 0, text);
		Assert.isTrue(text.indexOf('using') == -1, text);
	}

	/** And `import x.Y;` names the import alone, leaving the `using` of the same module standing. */
	public function testImportStatementPicksTheImport(): Void {
		final text: String = okText('import a.B;\nusing a.B;\nclass C {}\n', 'import a.B;');
		Assert.isTrue(text.indexOf('using a.B;') >= 0, text);
		Assert.isTrue(text.indexOf('import') == -1, text);
	}

	/** A `using` statement does not match an `import` of the same path: the kind is part of the request. */
	public function testUsingStatementDoesNotRemoveAnImport(): Void {
		assertErr('import a.B;\nclass C {}\n', 'using a.B;');
	}

	#if (sys || nodejs)
	/** The CLI's `--using` is the flag spelling of the same request, mirroring `add-import --using`. */
	@:pin('control')
	@:killer('M-REMOVEIMPORT-CLI-USING-FLAG-DROPPED')
	public function testCliUsingFlagRemovesTheUsing(): Void {
		final dir: String = CliFixture.writeTree('removeimportusing', [
			{ name: 'src/q/Target.hx', source: 'package q;\n\nimport a.B;\n\nusing a.B;\n\nclass Target {}\n' }
		]);
		final target: String = '$dir/src/q/Target.hx';
		Assert.equals(0, Cli.run(['remove-import', target, 'a.B', '--using', '--write']));
		Assert.equals('package q;\n\nimport a.B;\n\nclass Target {}\n', File.getContent(target));
		CliFixture.removeDir(dir);
	}
	#end

	private function okText(source: String, path: String): String {
		switch RemoveImport.removeImport(source, path, true, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private function assertErr(source: String, path: String): Void {
		switch RemoveImport.removeImport(source, path, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	/** The refusal text, so an arm can assert what it SAYS and not merely that it refused. */
	private function errText(source: String, path: String): String {
		return switch RemoveImport.removeImport(source, path, true, new HaxeQueryPlugin()) {
			case Ok(text): 'expected Err, got Ok:\n$text';
			case Err(message): message;
		};
	}

}
