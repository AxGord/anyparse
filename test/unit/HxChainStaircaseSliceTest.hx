package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * T135 — the chained-`FitLine` staircase gate.
 *
 * A control-flow construct whose `fitLine` body is another such construct
 * that in turn carries one — three links or more — used to glue link by
 * link, because `Renderer.fitsFlat` DEFERS a nested `BodyGroup` (Departure
 * 2). Each link therefore measured its own header plus the next link's
 * header and nothing below that, so the chain kept gluing until some link's
 * OWN content overflowed — at the deepest column in the chain, where the
 * only thing left to break was that link's CONDITION. The reported shape is
 * four lines (`… if (` / cond / `)` / body) where the source had three, and
 * `haxe-formatter`'s own `MarkSameLine.resolveFitLine` carries the same
 * cascade for the same reason ("an un-broken chain feeds conditionWrapping a
 * maxLen-exceeding line which wraps each condition paren").
 *
 * `BodyFit.chainStaircase` answers it the way the fork does: the chain glues
 * onto ONE line when the WHOLE line fits, and otherwise every link but the
 * last goes to its own line. The last link keeps its own `fitLine` answer,
 * which is why `if (…) push();` stays on one line at the bottom of every
 * staircase below.
 *
 * TWO-LINK CHAINS ARE NOT TOUCHED. `for (…) if (…) push();` keeps the
 * head-fit glue it has always had — that is the population
 * `sameline/fitline_chained_for_if_long.hxtest` pins, and it is pinned again
 * here so the gate cannot quietly widen onto it.
 *
 * EVERY FIXTURE BELOW PLACES THE CHAIN AS A STATEMENT IN A BRACED BLOCK, and
 * that is the whole population the gate reaches. Three sibling shapes were
 * reproduced against the FIXED engine and still tear their innermost
 * condition: a chain inside an arrow-lambda argument, a chain that IS a
 * brace-less function body, and a chain whose last link carries a `{}` block
 * or an `else`. They are recorded in `BodyFit.chainStaircase`'s doc and left
 * for a slice of their own; `testTornConditionParenIsGone` therefore claims
 * the statement band, not the construct.
 *
 * Per `feedback_unit_test_trivia_writer.md`: the knobs are visible only
 * through `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxChainStaircaseSliceTest extends Test {

	/** `if` -> `for` -> `if` -> call: three links, 115 columns of content at 8 of indent. */
	private static final CHAIN_LINE: String =
		'\t\tif (matchedVar != null) for (depField in ownStaticDIVars) if (info.varName == matchedVar) childDeps.push(depField);';

	private static final CHAIN_STAIRCASE: String = '\t\tif (matchedVar != null)\n\t\t\tfor (depField in ownStaticDIVars)\n'
		+ '\t\t\t\tif (info.varName == matchedVar) childDeps.push(depField);';

	/** The same AST written one line, and written already staircased. */
	private static final CHAIN_SRC: String = 'class M {\n\tfunction f():Void {\n$CHAIN_LINE\n\t}\n}\n';

	private static final CHAIN_SRC_BROKEN: String = 'class M {\n\tfunction f():Void {\n$CHAIN_STAIRCASE\n\t}\n}\n';

	/** TWO links — the control. Its head-fit glue is fork behaviour and must survive. */
	private static final TWO_LINK_SRC: String = 'class T {\n\tfunction f():Void {\n'
		+ '\t\tfor (depField in ownStaticDIVars) if (info.varName == matchedVar) childDeps.push(depField);\n\t}\n}\n';

	private static final TWO_LINK_GLUED: String =
		'\t\tfor (depField in ownStaticDIVars) if (info.varName == matchedVar)\n\t\t\tchildDeps.push(depField);';

	/** FIVE links: every link but the last carries a gate of its own, and they must resolve as ONE shape. */
	private static final FIVE_LINK_SRC: String = 'class P {\n\tfunction f():Void {\n\t\tfor (fi in files) for (t in fi.types)'
		+ ' if (t.name == typeName) for (sup in t.supertypes) if (declares(sup, field)) found = true;\n\t}\n}\n';

	private static final FIVE_LINK_STAIRCASE: String = '\t\tfor (fi in files)\n\t\t\tfor (t in fi.types)\n\t\t\t\tif (t.name == typeName)\n'
		+ '\t\t\t\t\tfor (sup in t.supertypes)\n\t\t\t\t\t\tif (declares(sup, field)) found = true;';

	/** The torn shape the gate exists to remove — the condition paren opened mid-chain. */
	private static final TORN_CONDITION: String = 'if (\n\t\t\tinfo.varName == matchedVar\n\t\t)';

	public function testWholeChainOverTheLimitStaircases(): Void {
		// The chain's one-line form is 123 columns; at 122 it does not fit, so
		// the top two links go to their own lines and the last keeps its glue.
		final out: String = write(CHAIN_SRC, fitJson(122));
		Assert.isTrue(out.indexOf(CHAIN_STAIRCASE) != -1, 'an over-wide chain must staircase: <$out>');
	}

	public function testWholeChainExactlyAtTheLimitStaysOnOneLine(): Void {
		// Upper edge. 123 columns against a 123-column limit is a line that
		// fits, and the fork's Phase 1 keeps it whole — so must this gate.
		final out: String = write(CHAIN_SRC, fitJson(123));
		Assert.isTrue(out.indexOf(CHAIN_LINE) != -1, 'a chain exactly at the limit must stay on one line: <$out>');
	}

	public function testTwoLinkChainKeepsItsHeadFitGlue(): Void {
		// The gate's entry test is "the body is a link AND its body is a link",
		// so a two-link chain never reaches it: `for (…) if (…)` keeps sharing a
		// line even though the whole statement (99 columns) does not fit.
		for (limit in [80, 90]) {
			final out: String = write(TWO_LINK_SRC, fitJson(limit));
			Assert.isTrue(out.indexOf(TWO_LINK_GLUED) != -1, 'a two-link chain must keep its head-fit glue at $limit: <$out>');
		}
	}

	public function testTornConditionParenIsGone(): Void {
		// The reported symptom, under a `conditionWrapping` cascade: the chain
		// glued until the innermost `if` had nothing left to break but its own
		// condition. Pinned across the whole band where the base engine tore it —
		// in STATEMENT position, the only one the gate reaches. The same chain in
		// an arrow-lambda argument or as a brace-less function body still tears;
		// see `BodyFit.chainStaircase`'s population note.
		for (limit in [75, 85, 96]) {
			final out: String = write(CHAIN_SRC, condWrapJson(limit));
			Assert.isTrue(out.indexOf(TORN_CONDITION) == -1, 'the condition paren must not be opened mid-chain at $limit: <$out>');
			Assert.isTrue(out.indexOf(CHAIN_STAIRCASE) != -1, 'the chain must staircase instead at $limit: <$out>');
		}
	}

	public function testFiveLinkChainStaircasesAsOneShape(): Void {
		// Every link but the last installs a gate of its own, so the OUTER
		// link's classifier has to read THROUGH a gate to see the chain below
		// it. Without that the top two links stay glued and only the tail
		// staircases — a hybrid that reads worse than either answer.
		final out: String = write(FIVE_LINK_SRC, fitJson(100));
		Assert.isTrue(out.indexOf(FIVE_LINK_STAIRCASE) != -1, 'a five-link chain must staircase whole: <$out>');
		// "as ONE shape" is the claim, so the hybrid must be absent too — a
		// partial answer that staircases only the tail would satisfy the line
		// above if the outer links had glued and the assertion matched further in.
		Assert.isTrue(out.indexOf('for (fi in files) for (t in fi.types)') == -1, 'the top links must not stay glued: <$out>');
	}

	public function testNonFitLinePoliciesAreInert(): Void {
		// The gate belongs to `fitLine` alone. `same` glues unconditionally and
		// must keep doing so at the width that makes `fitLine` staircase.
		final json: String = '{"wrapping": {"maxLineLength": 122}, "sameLine": {"ifBody": "same", "forBody": "same"}}';
		final out: String = write(CHAIN_SRC, json);
		Assert.isTrue(out.indexOf(CHAIN_LINE) != -1, '`same` must keep the unconditional glue: <$out>');
	}

	public function testIsIdempotentAcrossThreePasses(): Void {
		final json: String = fitJson(122);
		final once: String = write(CHAIN_SRC, json);
		final twice: String = write(once, json);
		Assert.equals(once, twice, 'the staircase decision must reach a fixed point in one pass');
		Assert.equals(twice, write(twice, json), 'third pass must also be a fixed point');
		// The fixed point must be the STAIRCASE — without this the test passes on
		// an engine with the gate reverted, since the pre-slice glue is a fixed
		// point of its own.
		Assert.isTrue(once.indexOf(CHAIN_STAIRCASE) != -1, 'the fixed point must be the staircase: <$once>');
	}

	public function testIsIndependentOfTheSourceLineShape(): Void {
		// The decision reads the pen column and the chain's flat width, never
		// how the chain was written — so both source shapes of ONE AST must
		// render identically, on both sides of the boundary.
		final tight: String = fitJson(122);
		Assert.equals(write(CHAIN_SRC, tight), write(CHAIN_SRC_BROKEN, tight), 'placement must not depend on the source line shape');
		final wide: String = fitJson(123);
		Assert.equals(write(CHAIN_SRC, wide), write(CHAIN_SRC_BROKEN, wide), 'the same must hold on the one-line side of the boundary');
	}

	/** `maxLineLength: <w>` with the two body knobs the chain uses on `fitLine`. */
	private inline function fitJson(w: Int): String {
		return '{"wrapping": {"maxLineLength": $w}, "sameLine": {"ifBody": "fitLine", "forBody": "fitLine"}}';
	}

	/** `fitJson` plus the `conditionWrapping` cascade that turns an over-wide head into an opened paren. */
	private inline function condWrapJson(w: Int): String {
		return '{"wrapping": {"maxLineLength": $w, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak",'
			+ ' "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}},'
			+ ' "sameLine": {"ifBody": "fitLine", "forBody": "fitLine"}}';
	}

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
