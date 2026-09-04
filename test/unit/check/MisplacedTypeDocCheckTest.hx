package unit.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.MisplacedTypeDoc;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `misplaced-type-doc` check: a `/** … *\/` doc block written between the `package`
 * statement and the module's imports never reaches the type it describes, because the
 * imports sit between the two. The check flags that dead doc and `--fix` MOVES the block
 * verbatim into the type declaration's leading trivia. Covers the live shape, the fix's
 * byte-identity and writer survival, and one negative fixture per gate.
 */
class MisplacedTypeDocCheckTest extends Test {

	/**
	 * The live incident shape (anonymised from a TM module): package, a dead author doc,
	 * the import block, then the sole type.
	 */
	private static inline final DEAD_DOC: String = 'package widgets.canvas.parts.helpers;\n\n'
		+ '/**\n * ...\n * @author Aaaaa Bbbbbbbbbbbb, https://www.example.org/aa\n */\n'
		+ 'import motion.Actuate;\nimport openfl.display.Sprite;\nimport openfl.geom.Point;\n\n'
		+ 'class GaugeStrip extends Sprite {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n';

	/** The same module with the doc where the compiler would actually read it. */
	private static inline final DEAD_DOC_FIXED: String = 'package widgets.canvas.parts.helpers;\n\n'
		+ 'import motion.Actuate;\nimport openfl.display.Sprite;\nimport openfl.geom.Point;\n\n'
		+ '/**\n * ...\n * @author Aaaaa Bbbbbbbbbbbb, https://www.example.org/aa\n */\n'
		+ 'class GaugeStrip extends Sprite {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n';

	public function testDocBetweenPackageAndImportsFlagged(): Void {
		final vs: Array<Violation> = violations(DEAD_DOC);
		Assert.equals(1, vs.length);
		Assert.equals('misplaced-type-doc', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'GaugeStrip'"), 'names the type the doc belongs to: ${vs[0].message}');
	}

	/** The finding points at the doc block itself, so the report coordinate is the dead comment. */
	public function testFindingSpansTheDocBlock(): Void {
		final span: Null<Span> = violations(DEAD_DOC)[0].span;
		Assert.notNull(span);
		if (span != null) Assert.equals('/**', DEAD_DOC.substring(span.from, span.from + 3));
	}

	public function testFixMovesDocToTypeDeclaration(): Void {
		Assert.equals(DEAD_DOC_FIXED, fixed(DEAD_DOC));
	}

	/** The moved block is BYTE-IDENTICAL — the fix relocates trivia, it never rewrites a doc body. */
	public function testMovedBlockIsByteIdentical(): Void {
		final out: String = fixed(DEAD_DOC);
		Assert.equals(1, countOccurrences(out, '/**'));
		Assert.isTrue(out.indexOf('/**\n * ...\n * @author Aaaaa Bbbbbbbbbbbb, https://www.example.org/aa\n */') >= 0, out);
	}

	/** The whole point: after the fix the doc is the last thing before the type declaration. */
	public function testFixedDocDirectlyPrecedesTheType(): Void {
		final out: String = fixed(DEAD_DOC);
		Assert.isTrue(out.indexOf(' */\nclass GaugeStrip') >= 0, out);
	}

	public function testFixOutputSurvivesTheWriter(): Void {
		switch CanonicalEdit.canonicalize(DEAD_DOC, edits(DEAD_DOC), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(' */\nclass GaugeStrip') >= 0, text);
				Assert.equals(1, countOccurrences(text, '/**'), text);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/** The fixed source is a writer FIXED POINT — a second canonicalisation changes nothing. */
	public function testFixedSourceIsWriterIdempotent(): Void {
		switch CanonicalEdit.canonicalize(DEAD_DOC, edits(DEAD_DOC), true, new HaxeQueryPlugin()) {
			case Ok(text):
				switch CanonicalEdit.canonicalize(text, [], true, new HaxeQueryPlugin()) {
					case Ok(again): Assert.equals(text, again);
					case Err(message): Assert.fail('re-canonicalize Err: $message');
				}
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/** The doc anchors ABOVE the `@:meta` / modifier run, where the compiler reads a type's doc. */
	public function testDocLandsAboveTheMetadataRun(): Void {
		final src: String =
			'package p;\n\n/**\n * doc.\n */\nimport a.B;\n\n@:nullSafety(Strict)\nfinal class C {\n\n\tpublic function new() {}\n\n}\n';
		Assert.isTrue(fixed(src).indexOf(' */\n@:nullSafety(Strict)\nfinal class C') >= 0, fixed(src));
	}

	/** No blank line before the type? The fix supplies one, so the moved doc is spaced like every other doc. */
	public function testFixInsertsTheSeparatingBlankLine(): Void {
		final src: String = 'package p;\n\n/**\n * doc.\n */\nimport a.B;\nclass C {}\n';
		Assert.equals('package p;\n\nimport a.B;\n\n/**\n * doc.\n */\nclass C {}\n', fixed(src));
	}

	// --- gates: one negative fixture each -------------------------------------------------

	/** A plain `/* … *\/` banner is a license header, not a doc — never moved. */
	public function testPlainBlockCommentNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\n/*\n * (c) Example Ltd.\n */\nimport a.B;\n\nclass C {}\n').length);
	}

	/** A `//` banner is a license header too. */
	public function testLineCommentBannerNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\n// (c) Example Ltd.\nimport a.B;\n\nclass C {}\n').length);
	}

	/** The type already carries its own doc — the two are never merged. */
	public function testTypeWithItsOwnDocNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\n/**\n * stray.\n */\nimport a.B;\n\n/**\n * real.\n */\nclass C {}\n').length);
	}

	/** Two top-level types: which one the doc was written for is a guess, so the rule declines. */
	public function testTwoTopLevelTypesNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\n/**\n * doc.\n */\nimport a.B;\n\nclass C {}\n\nclass D {}\n').length);
	}

	/** A block ABOVE the `package` statement is a FILE header — it belongs to the file, not the type. */
	public function testDocAbovePackageNotFlagged(): Void {
		Assert.equals(0, violations('/**\n * File header.\n */\npackage p;\n\nimport a.B;\n\nclass C {}\n').length);
	}

	/** Nothing between the doc and the type: the compiler already attaches it. */
	public function testDocDirectlyBeforeTypeNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\nimport a.B;\n\n/**\n * doc.\n */\nclass C {}\n').length);
	}

	/** No imports at all — the doc after `package` already reaches the type. */
	public function testNoImportsNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\n/**\n * doc.\n */\nclass C {}\n').length);
	}

	/** Two doc blocks in the header: `fragmented-doc-comment` merges them first; this rule declines. */
	public function testTwoDocBlocksInHeaderNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\n/**\n * one.\n */\n/**\n * two.\n */\nimport a.B;\n\nclass C {}\n').length);
	}

	/**
	 * No `package` statement: the top-of-file block is a file header, so there is nothing to
	 * move. TWO imports deliberately — with one, the header is a single decl and the
	 * `MIN_HEADER_DECLS` gate rejects the fixture before the package-kind gate is reached.
	 */
	public function testModuleWithoutPackageNotFlagged(): Void {
		Assert.equals(0, violations('/**\n * header.\n */\nimport a.B;\nimport c.D;\n\nclass C {}\n').length);
	}

	/** The empty `/**` `*\/` and `/***\/` forms carry no documentation. */
	public function testEmptyDocBlockNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\n/**/\nimport a.B;\n\nclass C {}\n').length);
		Assert.equals(0, violations('package p;\n\n/***/\nimport a.B;\n\nclass C {}\n').length);
	}

	/** A `/**` block with a whitespace-only body documents nothing either. */
	public function testWhitespaceOnlyDocBlockNotFlagged(): Void {
		Assert.equals(0, violations('package p;\n\n/**\n *\n */\nimport a.B;\n\nclass C {}\n').length);
	}

	/** A doc sharing its line with code cannot move as whole lines — reported, never fixed. */
	public function testDocSharingALineIsReportOnly(): Void {
		final src: String = 'package p;\n\n/** doc. */ import a.B;\n\nclass C {}\n';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/**
	 * An `enum abstract` is a second top-level type even though it is absent from
	 * `RefShape.typeDeclKinds` — `resolveSeams` folds `enumAbstractDeclKind` in so the
	 * exactly-one-type gate cannot be walked past.
	 */
	public function testEnumAbstractCountsAsASecondType(): Void {
		Assert.equals(
			0,
			violations('package p;\n\n/**\n * doc.\n */\nimport a.B;\n\nclass C {}\n\nenum abstract E(Int) {\n\n\tfinal X = 1;\n\n}\n')
				.length
		);
	}

	// --- registry -------------------------------------------------------------------------

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('misplaced-type-doc'));
	}

	/** New rule, project convention: OFF unless an `apqlint.json` opts in. */
	public function testDefaultOff(): Void {
		Assert.isTrue(new MisplacedTypeDoc() is DefaultOff);
	}

	/**
	 * REGISTRY-POSITION LOCK. The doc leaves the header before any import rule touches the
	 * block it is pinned above — `Cli.computeFileLintEdits` walks the registry in order and
	 * defers a later check whose edits overlap an accepted one. The position is conventional
	 * rather than load-bearing today (see `MisplacedTypeDoc`'s class doc); this pins it so it
	 * stays true if either side's movable region ever widens.
	 */
	public function testRegisteredBeforeImportOrder(): Void {
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.indexOf('misplaced-type-doc') >= 0);
		Assert.isTrue(
			ids.indexOf('misplaced-type-doc') < ids.indexOf('import-order'), 'misplaced-type-doc must precede import-order in the registry'
		);
	}

	public function testNoCrashOnUnparseable(): Void {
		Assert.equals(0, violations('class C { function').length);
	}

	public function testNoCrashOnEmpty(): Void {
		Assert.equals(0, violations('').length);
	}

	private function violations(src: String): Array<Violation> {
		return new MisplacedTypeDoc().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: MisplacedTypeDoc = new MisplacedTypeDoc();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}

	private function fixed(src: String): String {
		return CheckFixture.applyEdits(src, edits(src));
	}

	private function countOccurrences(s: String, sub: String): Int {
		var n: Int = 0;
		var i: Int = s.indexOf(sub);
		while (i >= 0) {
			n++;
			i = s.indexOf(sub, i + sub.length);
		}
		return n;
	}

}
