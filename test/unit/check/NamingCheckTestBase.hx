package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Naming;
import anyparse.grammar.haxe.HaxeNamingSupport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

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
		switch CanonicalEdit.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
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

	/**
	 * The `declineReason` the naming autofix wrote on `targetFile`'s single finding, or `''` when it
	 * wrote none — after the fix paths have been asked in the order `lint --fix` asks them: the
	 * cross-file rename FIRST, against pristine sources, when `crossFirst`, then the per-file one.
	 * Neither may emit an edit.
	 *
	 * `crossFirst` is the whole reason this lives here rather than once per test part. First writer
	 * wins, so which path runs decides WHICH gate's sentence comes back — and a per-file-only run
	 * reports the per-file path's answer even for a declaration that path does not own.
	 */
	private function refusalFor(files: Array<{ file: String, source: String }>, targetFile: String, crossFirst: Bool = false): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, plugin).filter(v -> v.file == targetFile);
		Assert.equals(1, vs.length);
		if (crossFirst) Assert.equals(0, check.crossFileFix(files, vs, plugin, index).length, 'the cross-file rename is refused');
		final source: String = files.filter(f -> f.file == targetFile)[0].source;
		Assert.equals(0, check.fix(source, vs, plugin, index).length, 'the rename is refused');
		return vs[0].declineReason ?? '';
	}

}
