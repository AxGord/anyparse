package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Naming;
import anyparse.grammar.haxe.HaxeNamingSupport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;

/**
 * Fixture scaffolding shared by the `naming` check test parts: the violation run
 * over a real `HaxeNamingSupport` + `HaxeQueryPlugin`, and the canonicalisation /
 * rename assertions.
 */
class NamingCheckTestBase extends Test {

	private function violations(src: String, ?policy: NamingPolicy): Array<Violation> {
		final support: HaxeNamingSupport = new HaxeNamingSupport();
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(src);
		return Naming.violationsFor('C.hx', support.project(tree), policy ?? HaxeNamingSupport.defaults());
	}

	private function assertCanonicalized(src: String, edits: Array<{ span: Span, text: String }>, present: String, absent: String): Void {
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixCanonicalWithIndex(src: String, present: String, absent: String): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin(), index), present, absent);
	}

	/** Assert the naming autofix emits NO edit for `targetFile`, which must still carry at least one finding. */
	private function assertFixSkipped(files: Array<{ file: String, source: String }>, targetFile: String, targetSrc: String): Void {
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == targetFile);
		Assert.isTrue(vs.length >= 1);
		Assert.equals(0, check.fix(targetSrc, vs, new HaxeQueryPlugin(), index).length);
	}

	/** Fix the single flagged decl of `src` at `path` and assert on the canonicalized result. */
	private function assertRenamedIn(path: String, src: String, present: String, absent: String): Void {
		final files: Array<{ file: String, source: String }> = [{ file: path, source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == path);
		Assert.isTrue(vs.length >= 1);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin(), index), present, absent);
	}

	/** The flagged decl in `src` (single file `pkg/C.hx`) yields no edits — the rename is refused. */
	private function assertNotRenamed(src: String): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.isTrue(vs.length >= 1);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	private function assertLocalRenamed(
		files: Array<{ file: String, source: String }>, targetFile: String, targetSrc: String, present: String, absent: String
	): Void {
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == targetFile);
		Assert.isTrue(vs.length >= 1);
		assertCanonicalized(targetSrc, check.fix(targetSrc, vs, new HaxeQueryPlugin(), index), present, absent);
	}

}
