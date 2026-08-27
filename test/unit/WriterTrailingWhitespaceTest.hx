package unit;

import anyparse.core.Doc;
import anyparse.core.Renderer;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The writer must never emit a trailing space, whatever config reaches it.
 *
 * Four Doc leaves used to break that: `', '`, `': '`, `'return '` and
 * `'macro '` — each a hard `Text` carrying its OWN separator space, emitted
 * immediately before a break. Under Pony's `hxformat.json` with
 * `wrapping.ternaryExpression`'s rule set to `onePerLine`, the whole tree
 * produced nine trailing-whitespace lines from exactly those four shapes.
 *
 * The fix is a distinction the Doc layer did not have: a `Text` is either
 * VERBATIM CONTENT (a comment body the writer reproduces) or SYNTAX the
 * writer emitted. The renderer holds back a syntax leaf's trailing blank run
 * and drops it when a newline is what follows; verbatim leaves are written
 * whole. Both halves are pinned here, because a fix for the first that
 * breaks the second is the one the previous slice measured and refused: a
 * blanket hold-back stripped the tab inside the `/* … *\/` at Pony's
 * `tests/test/ui/ButtonCoreTest.hx` line 44.
 *
 * The `Renderer` cases below are the CENTRAL pin: every path that writes a
 * newline gets one, so a new Doc shape cannot route around the invariant by
 * reaching a line end some other way. The `writeRoundTrip` cases above them
 * are the end-to-end repro — each is one of the four leaves, and each
 * reproduces on the pre-fix engine.
 */
@:nullSafety(Strict)
class WriterTrailingWhitespaceTest extends Test {

	/**
	 * Pony's `ternaryExpression` cascade with its rule flipped from
	 * `onePerLineAfterFirst` to `onePerLine` — the config that made all four
	 * leaves land on a line end. Nothing else about the tree changes.
	 */
	private static final TERNARY_ONE_PER_LINE: String = '{"wrapping": {"maxLineLength": 140, "ternaryExpression": '
		+ '{"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], '
		+ '"type": "onePerLine", "location": "beforeLast"}]}}}';

	/** `pony/text/tpl/TplSystem.hx` line 54, reduced: the `'return '` leaf. */
	private static final RETURN_LEAD: String = 'class A {\n\n\tpublic static function parseManifest(f: File): Manifest {\n'
		+ '\t\tfinal g: (n:String) -> Null<Null<String>> = function(n: String) return x.hasNode.resolve(n)'
		+ ' ? StringTools.trim(x.node.resolve(n).innerData) : null;\n\t\treturn null;\n\t}\n\n}\n';

	/** `pony/magic/builder/HasAssetBuilder.hx` line 105, reduced: the `'macro '` leaf. */
	private static final MACRO_LEAD: String = 'class B {\n\n\tstatic function f() {\n\t\tfinal a = { ret: macro :Void, expr: macro childs'
		+ ' ? pony.ui.AssetManager.loadPackWithChilds(cl.toString(), ASSETS_PATHES, ASSETS_LIST, cb)'
		+ ' : pony.ui.AssetManager.loadPack(ASSETS_PATHES, ASSETS_LIST, cb) };\n\t}\n\n}\n';

	/** `HasAssetBuilder.hx` line 119: `'macro '` and `'return '` back to back. */
	private static final MACRO_RETURN_LEAD: String = 'class C {\n\n\tstatic function f() {\n\t\tfinal a = { ret: macro :Int,'
		+ ' expr: macro return childs ? pony.ui.AssetManager.allCountWithChilds(cl.toString(), ASSETS_PATHES, ASSETS_LIST)'
		+ ' : pony.ui.AssetManager.allCount(ASSETS_PATHES, ASSETS_LIST) };\n\t}\n\n}\n';

	/** `pony/net/http/modules/mmodels/actions/Insert.hx` line 135: the `': '` leaf. */
	private static final TERNARY_ELSE_SEP: String = 'class D {\n\n\tprivate function inputE(name: String, value: String, fix: Bool): String {\n'
		+ "\t\tfinal s: String = st(name);\n\t\treturn s == null\n\t\t\t? '<label>${name.bigFirst()}${input(name, null, value)}</label>'\n"
		+ "\t\t\t: s == ''\n\t\t\t\t? '<label>${name.bigFirst()}${input(name, 'ok', fix ? value : '')}</label>'\n"
		+ "\t\t\t\t: '<label>${name.bigFirst()}${input(name, 'error', value)}<div>$s</div></label>';\n\t}\n\n}\n";

	/** `pony/ui/xml/PixiXmlUi.hx` line 391: the `', '` leaf, after a closing `}`. */
	private static final ARG_SEP: String = 'class E {\n\n\tstatic function f() {\n\t\tfinal video: HtmlVideoUIFS = new HtmlVideoUIFS('
		+ '{x: parseAndScale(attrs.x), y: parseAndScale(attrs.y), width: parseAndScale(attrs.w), height: parseAndScale(attrs.h)},'
		+ ' attrs.fsborder != null ? (attrs.fsborder: Border<Float>) : null, fspos, attrs.css, attrs.fscss, attrs.transition, app,'
		+ ' attrs.clicktimeout, attrs.ceil.isTrue(), attrs.fixed.isTrue());\n\t}\n\n}\n';

	/** `tests/test/ui/ButtonCoreTest.hx` line 44's shape: a tab inside a block comment. */
	private static final COMMENT_TAB: String = 'class V {\n\n\tpublic function f(): Void {\n\t\t/*\n'
		+ '\t\tareEqual(instance.visualState, Default);\t\n\t\t*/\n\t\trun();\n\t}\n\n}\n';

	/** Eleven string literals that each end in a space, wrapped one per line. */
	private static final LITERAL_TRAILING_SPACE: String = "class W {\n\n\tstatic function f(): Void {\n\t\tg(['alpha ', 'beta ',"
		+ " 'gamma ', 'delta ', 'epsilon ', 'zeta ', 'eta ', 'theta ', 'iota ', 'kappa ', 'lambda ']);\n\t}\n\n}\n";

	/** A `//` comment whose own body ends in two spaces, beside a tight one. */
	private static final LINE_COMMENT_TRAILING_SPACES: String =
		'class X {\n\n\tstatic function f(): Void {\n\t\tvar x = 1; // t  \n\t\tvar y = 2; //u\n\t}\n\n}\n';

	public inline function testBareReturnLeadSpaceIsNotStrandedByABreak(): Void {
		assertNoStrandedBlank(RETURN_LEAD, "'return '");
	}

	public inline function testMacroLeadSpaceIsNotStrandedByABreak(): Void {
		assertNoStrandedBlank(MACRO_LEAD, "'macro '");
	}

	public inline function testMacroReturnLeadSpaceIsNotStrandedByABreak(): Void {
		assertNoStrandedBlank(MACRO_RETURN_LEAD, "'macro return '");
	}

	public inline function testTernaryElseSeparatorSpaceIsNotStrandedByABreak(): Void {
		assertNoStrandedBlank(TERNARY_ELSE_SEP, "': '");
	}

	public inline function testArgumentSeparatorSpaceIsNotStrandedByABreak(): Void {
		assertNoStrandedBlank(ARG_SEP, "', '");
	}

	/**
	 * The half the blanket hold-back broke. The assertion names the tab AND
	 * the newline after it, so it cannot be satisfied by a writer that keeps
	 * the comment but moves the tab off the line end.
	 */
	public function testCommentBodyKeepsItsTrailingTabAtALineEnd(): Void {
		final written: String = write(COMMENT_TAB);
		Assert.isTrue(
			written.indexOf('areEqual(instance.visualState, Default);\t\n') >= 0,
			'the tab inside the block comment must survive verbatim, got:\n<$written>'
		);
	}

	/**
	 * A string literal's interior is its own `Text` leaf and CAN end in a
	 * space, but its closing quote always follows on the same line — so the
	 * hold-back never reaches a break. Pinned because that is an argument,
	 * not an axiom: a writer that ever broke between the two would corrupt
	 * the value, and this is what would say so.
	 */
	public function testStringLiteralInteriorKeepsItsTrailingSpaceWhenTheListBreaks(): Void {
		final written: String = write(LITERAL_TRAILING_SPACE);
		Assert.isTrue(written.indexOf("\n\t\t\t'alpha ',\n") >= 0, 'the list must break one per line, got:\n<$written>');
		Assert.isTrue(written.indexOf("'lambda '\n") >= 0, 'the last item must keep its interior space, got:\n<$written>');
	}

	/**
	 * Why the line-comment Doc leaf needs no verbatim mark, stated as a
	 * behaviour rather than left as an assumption: `LineCommentNormalizer`
	 * rtrims every `//` body on its way to a `Text`, so no such leaf can end
	 * in a blank for the renderer to trim. Teaching that normalizer to
	 * PRESERVE a comment's trailing spaces flips this test — which is the
	 * moment `WriterCodegen`'s line-comment helpers would have to emit a
	 * verbatim leaf, and the only warning that would exist.
	 */
	public function testLineCommentBodyIsRtrimmedBeforeItEverReachesADocLeaf(): Void {
		final written: String = write(LINE_COMMENT_TRAILING_SPACES);
		Assert.isTrue(written.indexOf('var x = 1; // t\n') >= 0, 'the line comment body must arrive rtrimmed, got:\n<$written>');
		assertNoStrandedBlank(LINE_COMMENT_TRAILING_SPACES, 'line comment bodies');
	}

	public function testBreakModeLineDropsTheSpaceItStrands(): Void {
		Assert.equals('a,\nb', Renderer.render(Doc.Concat([Doc.Text('a, '), Doc.Line('\n'), Doc.Text('b')]), 80));
	}

	public function testOptHardlineDropsTheSpaceItStrands(): Void {
		Assert.equals('a,\nb', Renderer.render(Doc.Concat([Doc.Text('a, '), Doc.OptHardline, Doc.Text('b')]), 80));
	}

	public function testOpenDelimAwareHardlineDropsTheSpaceItStrands(): Void {
		Assert.equals('a,\nb', Renderer.render(Doc.Concat([Doc.Text('a, '), Doc.OptHardlineSkipAtOpenDelim, Doc.Text('b')]), 80));
	}

	/**
	 * The forward-looking hardline defers its own `\n` to the next content
	 * emit, so the drop has to happen in `flushPendingHardline` rather than
	 * where the break node was seen.
	 */
	public function testDeferredHardlineDropsTheSpaceItStrands(): Void {
		Assert.equals('a,\nb', Renderer.render(Doc.Concat([Doc.Text('a, '), Doc.OptHardlineSkipBeforeHardline, Doc.Text('b')]), 80));
	}

	/** The last line of a document is a line end like any other. */
	public function testDocumentEndDropsATrailingSpace(): Void {
		Assert.equals('a,', Renderer.render(Doc.Text('a, '), 80));
	}

	/** An all-blank leaf is the same case with nothing in front of it. */
	public function testAllBlankLeafIsNotStrandedAtALineEnd(): Void {
		Assert.equals('a\nb', Renderer.render(Doc.Concat([Doc.Text('a'), Doc.Text('  '), Doc.Line('\n'), Doc.Text('b')]), 80));
	}

	/** Verbatim content is written whole even when a break lands on it. */
	public function testVerbatimLeafKeepsItsTrailingTabAtALineEnd(): Void {
		Assert.equals('a\t\nb', Renderer.render(Doc.Concat([Doc.Text('a\t', true), Doc.Line('\n'), Doc.Text('b')]), 80));
	}

	/**
	 * The half that must NOT change: a held run is only dropped by a
	 * newline. Content after it puts the bytes back where they were.
	 */
	public function testHeldRunSurvivesWhenContentFollows(): Void {
		Assert.equals('a, b', Renderer.render(Doc.Concat([Doc.Text('a, '), Doc.Text('b')]), 80));
	}

	/**
	 * An optional hardline that DROPS emits nothing, so it is not a line end
	 * and the run it sits behind stays. `Flatten` is what makes it drop.
	 */
	public function testHeldRunSurvivesAnOptHardlineThatDrops(): Void {
		Assert.equals('a, b', Renderer.render(Doc.Flatten(Doc.Concat([Doc.Text('a, '), Doc.OptHardline, Doc.Text('b')])), 80));
	}

	/** A held run precedes a later optional space, and must stay in front of it. */
	public function testHeldRunStaysInFrontOfAPendingOptSpace(): Void {
		Assert.equals('a, Xb', Renderer.render(Doc.Concat([Doc.Text('a, '), Doc.OptSpace('X'), Doc.Text('b')]), 80));
	}

	/** …including when an all-blank leaf arrives between the two. */
	public function testAllBlankLeafKeepsAPendingOptSpaceOrdered(): Void {
		Assert.equals('aX  b', Renderer.render(Doc.Concat([Doc.Text('a'), Doc.OptSpace('X'), Doc.Text('  '), Doc.Text('b')]), 80));
	}

	private function write(source: String): String {
		final written: Null<String> = new HaxeQueryPlugin().writeRoundTrip(source, TERNARY_ONE_PER_LINE);
		if (written == null) throw new Exception('the Haxe writer produced nothing for:\n<$source>');
		return written;
	}

	private function assertNoStrandedBlank(source: String, leaf: String): Void {
		final written: String = write(source);
		final stranded: Array<String> = strandedLines(written);
		Assert.equals(0, stranded.length, '$leaf reached a line end: ${haxe.Json.stringify(stranded)}\nin:\n<$written>');
	}

	/** Every line of `written`, in order, that ends in a space or a tab. */
	private static function strandedLines(written: String): Array<String> {
		return [for (line in written.split('\n')) if (endsInBlank(line)) line];
	}

	private static function endsInBlank(line: String): Bool {
		if (line.length == 0) return false;
		final last: Int = line.fastCodeAt(line.length - 1);
		return last == ' '.code || last == '\t'.code;
	}

}
