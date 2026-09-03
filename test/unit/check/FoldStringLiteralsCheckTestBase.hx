package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Test;

/**
 * Fixture scaffolding shared by the `fold-adjacent-string-literals` test parts: the
 * source builders, the width probes, the fold / fix drivers and the idempotence
 * assertion.
 *
 * Width comes from the file's own `hxformat.json`, and every fixture names its path
 * `C.hx`: the suite runs from the repository root, so that resolves to the
 * repository's OWN config (`maxLineLength` 140, tab width 4) — the constants the
 * boundary fixtures are written against.
 *
 * Every part asserts both the fix's emitted text and the finding count; the two must
 * agree, since `run` and `fix` share one planner.
 */
class FoldStringLiteralsCheckTestBase extends Test {

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = $expr;\n\t}\n}';
	}

	/** A `g(<literal>);` statement at two tabs — the plain host every `\n`-seam fixture measures at. */
	private function rawSource(literal: String): String {
		return 'class C {\n\tfunction f() {\n\t\tg($literal);\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new FoldStringLiterals().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The canonical text the fix emits for `src`'s first flagged construct (empty if none). */
	private function foldOf(src: String): String {
		final check: FoldStringLiterals = new FoldStringLiterals();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length > 0 ? edits[0].text : '';
	}

}
