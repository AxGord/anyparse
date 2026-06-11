package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddImport;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;

/**
 * `AddImport.addImport` — add an `import` / `using`, WRITER-FORMATTED.
 *
 * The statement is placed (after the last import / using, else after
 * `package`, else file-top) and the whole file is re-emitted through the
 * writer, so the result is canonical (the writer separates the import and
 * using blocks with a blank line). The source must already be canonical
 * unless `reformat` is passed. Each `Ok` asserts the EXACT canonical
 * output and is re-parsed; refusal cases assert `Err`.
 */
class AddImportSliceTest extends Test {

	/** Add an import after an existing one — same-kind imports group. */
	public function testAddAfterExistingImport(): Void {
		final source: String = 'package foo;\n' + '\n' + 'import a.B;\n' + '\n' + 'class C {}\n';
		final expected: String = 'package foo;\n' + '\n' + 'import a.B;\n' + 'import c.D;\n' + '\n' + 'class C {}\n';
		assertAdd(source, 'c.D', false, expected);
	}

	/** With no imports but a `package`, the import opens a block after it. */
	public function testAddAfterPackageOnly(): Void {
		final source: String = 'package foo;\n' + '\n' + 'class C {}\n';
		final expected: String = 'package foo;\n' + '\n' + 'import a.B;\n' + '\n' + 'class C {}\n';
		assertAdd(source, 'a.B', false, expected);
	}

	/** With no package and no imports, the import lands at the file start. */
	public function testAddNoPackageNoImports(): Void {
		final source: String = 'class C {}\n';
		final expected: String = 'import a.B;\n' + '\n' + 'class C {}\n';
		assertAdd(source, 'a.B', false, expected);
	}

	/** A `using` is added with the `using` keyword, in its own block. */
	public function testAddUsing(): Void {
		final source: String = 'package foo;\n' + '\n' + 'import a.B;\n' + '\n' + 'class C {}\n';
		final expected: String = 'package foo;\n' + '\n' + 'import a.B;\n' + '\n' + 'using c.D;\n' + '\n' + 'class C {}\n';
		assertAdd(source, 'c.D', true, expected);
	}

	/** Refuse an import already present as the same kind. */
	public function testRefuseDuplicateImport(): Void {
		final source: String = 'import a.B;\n' + '\n' + 'class C {}\n';
		assertRefused(source, 'a.B', false);
	}

	/** `import a.B` does NOT block `using a.B` — dedup is per-kind. */
	public function testUsingNotBlockedByImportOfSamePath(): Void {
		final source: String = 'import a.B;\n' + '\n' + 'class C {}\n';
		final expected: String = 'import a.B;\n' + '\n' + 'using a.B;\n' + '\n' + 'class C {}\n';
		assertAdd(source, 'a.B', true, expected);
	}

	/** Refuse a non-canonical file (no blank lines) without `--reformat`. */
	public function testRefuseNonCanonicalWithoutReformat(): Void {
		final source: String = 'package foo;\n' + 'import a.B;\n' + 'class C {}\n';
		assertRefused(source, 'c.D', false);
	}

	/** `reformat` proceeds on a non-canonical file, canonicalising it. */
	public function testReformatProceedsOnNonCanonical(): Void {
		final source: String = 'package foo;\n' + 'import a.B;\n' + 'class C {}\n';
		final expected: String = 'package foo;\n' + '\n' + 'import a.B;\n' + 'import c.D;\n' + '\n' + 'class C {}\n';
		assertAdd(source, 'c.D', false, expected, true);
	}

	private function assertAdd(source: String, path: String, isUsing: Bool, expected: String, reformat: Bool = false): Void {
		final result: EditResult = addOf(source, path, isUsing, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, path: String, isUsing: Bool, reformat: Bool = false): Void {
		final result: EditResult = addOf(source, path, isUsing, reformat);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	private function assertReparses(text: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception: Exception) {
			Assert.fail('add-import output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function addOf(source: String, path: String, isUsing: Bool, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddImport.addImport(source, path, isUsing, reformat, plugin);
	}

}
