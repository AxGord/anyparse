package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.TypeOracle;
import anyparse.check.Check.Violation;
import anyparse.check.ExplicitLocalType;
import anyparse.check.ExplicitType;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The oracle-assisted fixers' IMPORT ACCOUNTING: `ExplicitLocalType.normalizeWith` ends in a
 * print, printing is what promises `TypeRefPrinter` an import, and the promises are materialised
 * once per file on `edits.length > 0`. So a candidate the fixer ABSTAINS from after printing
 * leaves its promise behind, and the next admissible candidate carries it into the file.
 *
 * `explicit-local-type` had that shape — `admissibleLocal` rejects only after `normalizeWith`
 * printed — and now rolls the promise back. `explicit-type` shares the seam but not the defect:
 * every one of `normalizeWith`'s own refusals fires BEFORE the print, so a rejected return type
 * never promised anything. That ordering is what the `explicit-type` test pins.
 *
 * The MARK itself gets its own test: an over-truncating rollback is invisible to every other
 * assertion here.
 */
@:nullSafety(Strict)
final class OracleFixImportLeakTest extends Test {

	/** Two untyped locals, so each test can pick which of the two the oracle refuses to answer for. */
	private static final LOCALS: String =
		'class C {\n\n\tfunction f():Void {\n\t\tvar leak = mk();\n\t\tvar kept = n();\n\t\ttrace(leak, kept);\n\t}\n\n}\n';

	/** Two return types with no annotation, same role as `LOCALS` for the `explicit-type` arm. */
	private static final RETURNS: String =
		'class C {\n\n\tpublic function bad() {\n\t\treturn mk();\n\t}\n\n\tpublic function good() {\n\t\treturn n();\n\t}\n\n}\n';

	// --- explicit-local-type: rejection AFTER the print ---

	/**
	 * `Map<pkg.deep.Foo, Dynamic>` prints to `Map<Foo, Dynamic>` — promising an import — and is
	 * only then refused for the `Dynamic`. The refusal must take the promise back, or `kept`'s
	 * unrelated `:Int` carries an import nothing in the file uses.
	 */
	public function testARejectedLocalLeavesNoImportBehind(): Void {
		final texts: Array<String> = localEditTexts(['leak' => 'Map<pkg.deep.Foo, Dynamic>', 'kept' => 'Int']);
		Assert.isTrue(texts.indexOf(':Int') != -1, 'the admissible candidate is annotated, got: $texts');
		Assert.isTrue(texts.join('|').indexOf('import pkg.deep.Foo;') == -1, 'no import for the rejected candidate, got: $texts');
	}

	/**
	 * The MARK is load-bearing, not decoration: the rollback must drop only what the ABSTAINING
	 * candidate promised. An earlier admissible candidate's promise sits below the mark and has
	 * to survive — `resize(0)` in place of `resize(mark)` passes every other test in this file
	 * and the whole suite, and fails only here.
	 */
	public function testAnEarlierPromiseSurvivesALaterRollback(): Void {
		final texts: Array<String> = localEditTexts(['leak' => 'pkg.deep.Foo', 'kept' => 'Map<pkg.other.Bar, Dynamic>']);
		Assert.isTrue(texts.indexOf(':Foo') != -1, 'the earlier candidate is annotated, got: $texts');
		Assert.isTrue(texts.join('|').indexOf('import pkg.deep.Foo;') != -1, 'its promise survives, got: $texts');
		Assert.isTrue(texts.join('|').indexOf('pkg.other.Bar') == -1, 'the later rejection is rolled back, got: $texts');
	}

	/** The control: an import the SURVIVING annotation needs is still emitted. */
	public function testAnAdmissibleLocalStillGetsItsImport(): Void {
		final texts: Array<String> = localEditTexts(['leak' => 'Int', 'kept' => 'pkg.deep.Foo']);
		Assert.isTrue(texts.indexOf(':Foo') != -1, 'the qualified answer is shortened, got: $texts');
		Assert.isTrue(texts.join('|').indexOf('import pkg.deep.Foo;') != -1, 'its import is emitted, got: $texts');
	}

	// --- explicit-type: rejection BEFORE the print ---

	/**
	 * `normalizeWith` refuses a monomorph before it prints anything, so `bad`'s `pkg.deep.Bar`
	 * never reaches `TypeRefPrinter` and `good`'s edit carries only its own import. Reorder the
	 * refusal behind the print and this goes red.
	 */
	public function testARejectedReturnTypeNeverPromisedAnImport(): Void {
		final texts: Array<String> = returnEditTexts(['bad' => '() -> Array<pkg.deep.Bar<Unknown<0>>>', 'good' => '() -> pkg.deep.Foo']);
		Assert.isTrue(texts.indexOf(':Foo') != -1, 'the admissible return type is annotated, got: $texts');
		Assert.isTrue(texts.join('|').indexOf('import pkg.deep.Foo;') != -1, 'its import is emitted, got: $texts');
		Assert.isTrue(texts.join('|').indexOf('pkg.deep.Bar') == -1, 'the refused return type promised nothing, got: $texts');
	}

	// --- helpers -------------------------------------------------------------------

	/** The edit texts `ExplicitLocalType.fixWithOracle` produces for `LOCALS` under the canned answers. */
	private function localEditTexts(byName: Map<String, String>): Array<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ExplicitLocalType = new ExplicitLocalType();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: LOCALS }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fixWithOracle(
			LOCALS, violations, plugin, new IdentTypeOracle(LOCALS, byName)
		);
		return [for (edit in edits) edit.text];
	}

	/** The edit texts `ExplicitType.fixWithOracle` produces for `RETURNS` under the canned answers. */
	private function returnEditTexts(byName: Map<String, String>): Array<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ExplicitType = new ExplicitType();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: RETURNS }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fixWithOracle(
			RETURNS, violations, plugin, new IdentTypeOracle(RETURNS, byName)
		);
		return [for (edit in edits) edit.text];
	}

}

/**
 * A `TypeOracle` double answering by the IDENTIFIER the queried byte ends on — the position
 * both oracle-assisted fixers query (`ExplicitLocalType.fixWithOracle` asks at
 * `insertPoint - 1`, `ExplicitType.returnEdit` at `nameAt + name.length - 1`; both are the
 * name's last byte). No compiler, no process, no host dependency. Deliberately NOT named
 * `CannedTypeOracle` — `ExplicitLocalTypePrinterTest` already has one under that name, and it
 * answers the SAME type at every position.
 */
@:nullSafety(Strict)
private final class IdentTypeOracle implements TypeOracle {

	private final _source: String;
	private final _byName: Map<String, String>;

	public function new(source: String, byName: Map<String, String>) {
		_source = source;
		_byName = byName;
	}

	public function typeAt(file: String, bytePos: Int): Null<String> {
		var start: Int = bytePos + 1;
		while (start > 0 && RefactorSupport.isIdentChar(_source.fastCodeAt(start - 1))) start--;
		return _byName[_source.substring(start, bytePos + 1)];
	}

}
