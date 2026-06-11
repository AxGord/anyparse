package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RemoveImport;
import anyparse.query.RefactorSupport.EditResult;

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

}
