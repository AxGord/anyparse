package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.MisplacedTypeDoc;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * A `#if … #end` region holding nothing but declaration PREFIX material — metadata, modifiers,
 * or a bare `enum` / `abstract` / `final` keyword — is part of a type's LEADING RUN, not a
 * declaration standing between the doc and the type.
 *
 * Counting it as an ordinary top-level declaration puts it in the "first import" slot, so a doc
 * block written directly above it reads as stranded between the package statement and the
 * imports. For a METADATA region the fix then moved the doc BELOW the metadata, which is exactly
 * where the compiler stops attaching it (`haxe -D dox -xml` emits no `haxe_doc` for that shape) —
 * the documentation silently stopped existing: no writer, linter or compiler diagnostic.
 *
 * The KEYWORD region is the same defect one grammar seam over, and it fails differently: the doc
 * stays attached either way (`-D dox -xml` reports `haxe_doc` on both forms), so what `--fix`
 * produced was a wrong NORMALISATION — the region hoisted ABOVE the doc, inverting the tree's
 * accepted order of doc, then metadata and modifiers, then the type.
 */
class MisplacedTypeDocGuardedMetaTest extends Test {

	/** The `enum abstract` compatibility prefix, verbatim from `pony.db.mysql.Const` — the reported shape. */
	private static inline final ENUM_REGION: String = '#if (haxe_ver >= 4.2) enum #else @:enum #end\n';

	/** The `final class` compatibility prefix, verbatim from `remote.client.actions.RemoteActionGet`. */
	private static inline final FINAL_REGION: String = '#if (haxe_ver >= 4.2) final #else @:final #end\n';

	public function testDocAboveAGuardedMetaRunIsNotStranded(): Void {
		Assert.equals(0, run('package p;\n\n/**\n * Doc\n */\n#if !macro\n@:keep\n#end\nclass C {}\n').length);
	}

	public function testAGenuinelyStrandedDocIsStillFlagged(): Void {
		Assert.equals(1, run('package p;\n\n/**\n * Doc\n */\nimport p.Other;\n\n#if !macro\n@:keep\n#end\nclass C {}\n').length);
	}

	public function testTheFixAnchorsAboveTheGuardedMetaRun(): Void {
		// The doc has to land above `#if`, not between the region and the class: the compiler
		// attaches a type's doc only when nothing but whitespace separates the two.
		final source: String = 'package p;\n\n/**\n * Doc\n */\nimport p.Other;\n\n#if !macro\n@:keep\n#end\nclass C {}\n';
		final edits: Array<{ span: anyparse.runtime.Span, text: String }> = new MisplacedTypeDoc().fix(
			source, run(source), new HaxeQueryPlugin()
		);
		final insertion: Null<{ span: anyparse.runtime.Span, text: String }> = edits.length == 2 ? edits[1] : null;
		Assert.notNull(insertion);
		if (insertion != null) Assert.equals(source.indexOf('#if !macro'), insertion.span.from);
	}

	/** An EMPTY region guards nothing, so it must not read as annotation trivia the doc may sit above. */
	public function testAnEmptyGuardedRegionIsNotAnAnnotationRun(): Void {
		Assert.equals(1, run('package p;\n\n/**\n * Doc\n */\n#if !macro\n#end\nimport p.Other;\n\nclass C {}\n').length);
	}

	/**
	 * The keyword half of the same defect: the region carries no metadata at all in its true
	 * branch, so an annotation-only test read it as the module's first import.
	 */
	public function testDocAboveAGuardedEnumKeywordRunIsNotStranded(): Void {
		Assert.equals(0, run('package p;\n\n/**\n * Doc\n */\n${ENUM_REGION}abstract A(Int) {}\n').length);
	}

	/** A `@:meta` line and a keyword region are ONE leading run, not two header declarations. */
	public function testDocAboveAMetaThenGuardedFinalKeywordRunIsNotStranded(): Void {
		Assert.equals(0, run('package p;\n\n/**\n * Doc\n */\n@:nullSafety(Strict)\n${FINAL_REGION}class C {}\n').length);
	}

	/**
	 * A region holding a real DECLARATION is a sibling, not prefix material — the whitelist is
	 * what keeps the two apart, and a blanket "any region is prefix" rule would lose this doc.
	 */
	public function testAGuardedRegionHoldingADeclarationIsStillASibling(): Void {
		Assert.equals(1, run('package p;\n\n/**\n * Doc\n */\n#if !macro\nclass B {}\n#end\nclass C {}\n').length);
	}

	/** A genuinely stranded doc still moves — and lands above the keyword region, not between it and the type. */
	public function testTheFixAnchorsAboveTheGuardedKeywordRun(): Void {
		final source: String = 'package p;\n\n/**\n * Doc\n */\nimport p.Other;\n\n${ENUM_REGION}abstract A(Int) {}\n';
		final violations: Array<Violation> = run(source);
		Assert.equals(1, violations.length);
		final edits: Array<{ span: anyparse.runtime.Span, text: String }> = new MisplacedTypeDoc().fix(
			source, violations, new HaxeQueryPlugin()
		);
		final insertion: Null<{ span: anyparse.runtime.Span, text: String }> = edits.length == 2 ? edits[1] : null;
		Assert.notNull(insertion);
		if (insertion != null) Assert.equals(source.indexOf('#if'), insertion.span.from);
	}

	private function run(source: String): Array<Violation> {
		return new MisplacedTypeDoc().run([{ file: 'p/C.hx', source: source }], new HaxeQueryPlugin());
	}

}
