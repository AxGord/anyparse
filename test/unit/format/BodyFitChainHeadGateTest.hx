package unit.format;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * The two-link `FitLine` chain gate, `BodyFit.chainHeadGate`.
 *
 * Under a `conditionWrapping` cascade an `if` carries its condition inside a
 * construct-level `BodyGroup`, which `Renderer.fitsFlat` defers. A `for` whose
 * `fitLine` body is such an `if` therefore measured the link by its keyword alone
 * and always glued it; the `if` then paid at the deeper column by wrapping its
 * condition, although the whole link fitted on a line of its own. The gate charges
 * the link's honest head — up to its own body — the way the fork's
 * `MarkSameLine.resolveFitLine` Phase 2 does: the link glues when that head fits on
 * the header line, and otherwise goes to the next line whole.
 *
 * The statement fixtures place the chain at two tabs of indent (8 columns); the
 * comprehension fixtures place it inside a comprehension item.
 */
@:nullSafety(Strict)
final class BodyFitChainHeadGateTest extends Test {

	/** `for` -> `if` -> call: the `if` link is 86 columns, its head (to the `)`) 73. */
	private static final LINK: String = 'if (OccurrenceScan.referencedInRange(src, name, matchMaskFor(file, src))) return true;';

	private static final HEADER: String = 'for (file => src in _sources)';

	/** The link on its own line one indent deeper: 12 + 86 = 98 columns. */
	private static final NEXT_LINE: String = '\t\t$HEADER\n\t\t\t$LINK';

	/** The torn shape the gate removes — the link glued and its condition paren opened. */
	private static final TORN: String = '$HEADER if (\n';

	private static final SRC: String = 'class C {\n\tfunction f():Bool {\n\t\t$HEADER $LINK\n\t\treturn false;\n\t}\n}\n';
	private static final SRC_BROKEN: String = 'class C {\n\tfunction f():Bool {\n$NEXT_LINE\n\t\treturn false;\n\t}\n}\n';

	/** A short-headed link: `for (…) if (ok) …` keeps its head on the header line. */
	private static final SHORT_HEAD_SRC: String = 'class C {\n\tfunction f():Void {\n\t\t$HEADER if (ok) '
		+ 'OccurrenceScan.referencedInRange(src, name, matchMaskFor(file, src), excluded[file] ?? []);\n\t}\n}\n';

	@:pin('control')
	@:killer('M-CHAIN-HEAD-GATE-OFF')
	public function testHiddenHeadOverTheLimitMovesTheLinkWhole(): Void {
		// Glued, the head ends at 8 + 29 + 1 + 73 = 111 > 100: the link goes below
		// its header whole instead of opening its condition paren.
		final out: String = write(SRC, condWrapJson(100));
		Assert.isTrue(out.indexOf(NEXT_LINE) != -1, 'the link must move to the next line whole: <$out>');
		Assert.isTrue(out.indexOf(TORN) == -1, 'the condition paren must not open on the header line: <$out>');
	}

	public function testHeadThatFitsStaysGlued(): Void {
		// The head-fit glue the fork keeps: `if (ok)` fits beside the header, so
		// the link glues and its own body answers `fitLine` below it.
		final out: String = write(SHORT_HEAD_SRC, condWrapJson(100));
		Assert.isTrue(out.indexOf('\t\t$HEADER if (ok)\n\t\t\tOccurrenceScan') != -1, 'a fitting head must stay glued: <$out>');
	}

	public function testWholeChainThatFitsStaysOnOneLine(): Void {
		final out: String = write(SRC, condWrapJson(140));
		Assert.isTrue(out.indexOf('\t\t$HEADER $LINK') != -1, 'a chain that fits must stay on one line: <$out>');
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-GATE-OFF')
	public function testHiddenHeadBreaksAlsoWhenTheNextLineOverflows(): Void {
		// Fork Phase 2 refuses the glue on the head alone: at 90 neither line
		// holds the link, and it still goes below its header.
		final out: String = write(SRC, condWrapJson(90));
		Assert.isTrue(out.indexOf(TORN) == -1, 'the condition paren must not open on the header line: <$out>');
		Assert.isTrue(out.indexOf('\t\t$HEADER\n\t\t\tif (') != -1, 'the link must start below its header: <$out>');
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-GATE-OFF')
	public function testGluedHeadExactlyOnTheLimitStaysGlued(): Void {
		// The boundary: a glued head ending ON `maxLineLength` fits, one column more
		// moves the link whole — the `head` measure excludes the glue space, so an
		// off-by-one there lands on exactly this pair.
		final onLimit: String = 'for (x in xs) if (OccurrenceScan.referencedInRange(src, name, matchMaskFor(file, src, mor)))';
		final overLimit: String = 'for (x in xs) if (OccurrenceScan.referencedInRange(src, name, matchMaskFor(file, src, more)))';
		final json: String = condWrapJson(100);
		final glued: String = write('class C {\n\tfunction f():Bool {\n\t\t$onLimit return true;\n\t\treturn false;\n\t}\n}\n', json);
		Assert.isTrue(glued.indexOf('\t\t$onLimit\n') != -1, 'a head ending on the limit must stay glued: <$glued>');
		final moved: String = write('class C {\n\tfunction f():Bool {\n\t\t$overLimit return true;\n\t\treturn false;\n\t}\n}\n', json);
		Assert.isTrue(moved.indexOf('\t\tfor (x in xs)\n\t\t\tif (') != -1, 'a head one column over must move the link: <$moved>');
	}

	public function testVisibleHeadIsUntouched(): Void {
		// Without the cascade the `if` head is not grouped, `fitsFlat` already
		// measures it, and the gate leaves the same-line layout alone: the same
		// over-wide head moves to the next line by the plain `FitLine` answer.
		final out: String = write(SRC, fitJson(100));
		Assert.isTrue(out.indexOf(NEXT_LINE) != -1, 'a visible head keeps the plain FitLine answer: <$out>');
	}

	public function testIsIndependentOfTheSourceLineShape(): Void {
		for (w in [100, 140]) {
			final json: String = condWrapJson(w);
			final once: String = write(SRC, json);
			Assert.equals(once, write(SRC_BROKEN, json), 'placement must not depend on the source line shape at $w');
			Assert.equals(once, write(once, json), 'one pass must reach the fixed point at $w');
		}
	}

	@:pin('control')
	@:killer('M-SLOT-PROBE-BREAK-NONE')
	public function testGatedComprehensionKeepsItsCuddledOpen(): Void {
		// A cuddled `[ for` drops the comprehension's body below its header, and a
		// three-link chain's body slot sits inside its gate's probe: the drop must
		// read through the probe, or the bracket opens on a line of its own.
		final src: String = 'class D {\n\tfunction run():Void {\n\t\tfinal x = [for (sceneNode in sceneNodes) for (p in sceneNode.payloads)'
			+ ' if (payload.kind == sceneNode.kind) new UpdateNodePropsCommandXX(this, cast sceneNode, p)];\n\t}\n}\n';
		final cuddled: String = '\t\tfinal x = [ for (sceneNode in sceneNodes)\n\t\t\tfor (p in sceneNode.payloads)\n'
			+ '\t\t\t\tif (payload.kind == sceneNode.kind) new UpdateNodePropsCommandXX(this, cast sceneNode, p)\n\t\t];';
		final json: String = '{"wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
			+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';
		final out: String = write(src, json);
		Assert.isTrue(out.indexOf(cuddled) != -1, 'the comprehension must keep its cuddled open bracket: <$out>');
		Assert.equals(out, write(out, json), 'one pass must reach the fixed point');
	}

	@:pin('control')
	@:killer('M-GROUPIFY-GATE-REFOLD-OFF')
	public function testGateInsideAComprehensionItemMeasuresTheChainOnce(): Void {
		// A comprehension item's `BodyGroup`s are re-tagged as `Group`s to expose
		// their width, which widens a gate's flat side: unless the gate's threshold is
		// re-folded, the body counts twice and a chain that fits breaks mid-way.
		final line: String =
			'for (m in run) if (meta != null && m.name == meta) for (c in m.children) if ((shape.lambd ?? []).contains(c)) c';
		final src: String = 'class G {\n\tfunction f() {\n\t\tfinal out:Array<QueryNode> = [$line];\n\t}\n}\n';
		final json: String = '{"wrapping": {"maxLineLength": 140, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak",'
			+ ' "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}},'
			+ ' "sameLine": {"ifBody": "fitLine", "forBody": "fitLine", "expressionIf": "next", "comprehensionFor": "keep"}}';
		final out: String = write(src, json);
		Assert.isTrue(out.indexOf('\t\t\t$line\n') != -1, 'a comprehension chain that fits must stay on one line: <$out>');
	}

	/** `maxLineLength: <w>` with the two body knobs the chain uses on `fitLine`. */
	private inline function fitJson(w: Int): String {
		return '{"wrapping": {"maxLineLength": $w}, "sameLine": {"ifBody": "fitLine", "forBody": "fitLine"}}';
	}

	/** `fitJson` plus the `conditionWrapping` cascade that groups an `if` head with its body. */
	private inline function condWrapJson(w: Int): String {
		return '{"wrapping": {"maxLineLength": $w, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak",'
			+ ' "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}},'
			+ ' "sameLine": {"ifBody": "fitLine", "forBody": "fitLine"}}';
	}

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
