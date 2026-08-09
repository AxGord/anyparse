package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.TypeOracle;
import anyparse.check.Check.Violation;
import anyparse.check.ExplicitLocalType;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `explicit-local-type` oracle autofix riding on the shared `TypeRefPrinter`: a compiler
 * type name is turned into a reference that RESOLVES in the annotated file. The three routes
 * with a canned oracle and no compiler — an imported secondary type prints short, an
 * unimported type in a conflict-free file gets its import inserted, and a genuine short-name
 * collision falls back to the fully-qualified path (module-qualified for a sub-type, never the
 * `pack.SubType` hybrid the compiler prints).
 */
class ExplicitLocalTypePrinterTest extends Test {

	public function testImportedSecondaryTypePrintsShortName(): Void {
		// The compiler names the sub-type `pkg.model.ContentEntity` — the hybrid. The file's
		// `import pkg.model.Content.ContentEntity;` IS that type, so the short name is correct.
		final src: String = 'package app;\n\nimport pkg.model.Content.ContentEntity;\n\nclass C {\n\n\tpublic function f():Void {\n'
			+ '\t\tvar result = load();\n\t}\n\n}\n';
		final out: String = annotate(src, 'pkg.model.ContentEntity');
		Assert.isTrue(out.indexOf('var result:ContentEntity = load();') != -1, 'short name used, got: $out');
		Assert.equals(1, occurrences(out, 'import '), 'no import added, got: $out');
	}

	public function testUnimportedTypeInConflictFreeFileGetsImport(): Void {
		final src: String =
			'package app;\n\nimport app.other.Alpha;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tvar result = load();\n\t}\n\n}\n';
		final out: String = annotate(src, 'pkg.deep.Widget');
		Assert.isTrue(out.indexOf('var result:Widget = load();') != -1, 'short name used, got: $out');
		Assert.isTrue(out.indexOf('import pkg.deep.Widget;') != -1, 'import inserted, got: $out');
	}

	public function testCollidingShortNameStaysQualified(): Void {
		// `Entity` is already bound to a DIFFERENT type — the annotation must not retarget it.
		final src: String =
			'package app;\n\nimport app.other.Entity;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tvar result = load();\n\t}\n\n}\n';
		final out: String = annotate(src, 'pkg.model.Entity');
		Assert.isTrue(out.indexOf('var result:pkg.model.Entity = load();') != -1, 'qualified on collision, got: $out');
		Assert.equals(1, occurrences(out, 'import '), 'no import added, got: $out');
	}

	public function testBuiltinStillShortensWithNoImport(): Void {
		final src: String = 'class C {\n\n\tpublic function f():Void {\n\t\tvar result = load();\n\t}\n\n}\n';
		final out: String = annotate(src, 'haxe.ds.Map<String, Int>');
		Assert.isTrue(out.indexOf('var result:Map<String, Int> = load();') != -1, 'builtin shortened, got: $out');
		Assert.equals(0, occurrences(out, 'import '), 'no import added, got: $out');
	}

	public function testRejectedTypeYieldsNoEdit(): Void {
		final src: String = 'package app;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tvar result = load();\n\t}\n\n}\n';
		Assert.equals(src, annotate(src, 'Array<Unknown<0>>'), 'a monomorph must leave the file untouched');
	}

	public function testTwoLocalsOfOneTypeShareOneImport(): Void {
		// One printer serves the whole file, so a second annotation of the same type must reuse
		// the first one's import rather than splice a duplicate.
		final src: String =
			'package app;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tvar a = load();\n\t\tvar b = load();\n\t}\n\n}\n';
		final out: String = annotate(src, 'pkg.deep.Widget');
		Assert.isTrue(out.indexOf('var a:Widget = load();') != -1, 'first annotated, got: $out');
		Assert.isTrue(out.indexOf('var b:Widget = load();') != -1, 'second annotated, got: $out');
		Assert.equals(1, occurrences(out, 'import pkg.deep.Widget;'), 'one import only, got: $out');
	}

	// --- helpers -------------------------------------------------------------------

	/** Run the oracle autofix over `src` with `inferred` as the compiler's answer everywhere, and apply the edits. */
	private function annotate(src: String, inferred: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ExplicitLocalType = new ExplicitLocalType();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fixWithOracle(src, violations, plugin, new CannedTypeOracle(inferred));
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function occurrences(haystack: String, needle: String): Int {
		var count: Int = 0;
		var i: Int = haystack.indexOf(needle);
		while (i >= 0) {
			count++;
			i = haystack.indexOf(needle, i + needle.length);
		}
		return count;
	}

}

/** A `TypeOracle` that answers every position with one canned type — the compiler-free stand-in for the display server. */
private class CannedTypeOracle implements TypeOracle {

	private final _type: String;

	public function new(type: String) {
		_type = type;
	}

	public function typeAt(file: String, bytePos: Int): Null<String> {
		return _type;
	}

}
