package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-arrowif-blockbody-width: the width-visibility gap `HxArrowPlainIfOpenSliceTest`
 * left open. That slice re-tags an arrow body's hardline-free `BodyGroup` as a `Group` so
 * the arg's true width reaches the call cascade; a plain `if` whose body is a `{}`-BLOCK
 * carries hardlines, so it cannot be re-tagged and its width stays invisible — every
 * static measure sees `if (` and nothing else (measured: `flatTokenWidth` = 4 for the
 * whole construct, against 93 for the same shape written as a `for`).
 *
 * The consequence is an arrow-body probe that can never fire for that population: the
 * body glues to the header line however wide its own head is, and the `if`'s condition
 * then breaks INSIDE the arrow head at a deeper column — a shape whose first line ends
 * on a bare `if (`.
 *
 * The answer is not the re-tag (it would change the render, not just the measure) and
 * not the call cascade (making the arg's width visible there OPENS the call, which
 * relocates the problem rather than fixing it). It is a width gate on the arrow-body
 * glue itself, asked as the natural FIRST LINE of the body at the live pen column —
 * `BodyFit.arrowGlueWidthGate`, the arrow sibling of `BodyFit.glueLayout`.
 *
 * Identifiers are fully synthetic and bear no relation to any downstream code.
 */
@:nullSafety(Strict)
final class HxArrowBlockIfOverflowSliceTest extends Test {

	private static final CFG: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	/**
	 * An overflowing block-bodied plain `if` breaks after the `->` and renders at the
	 * continuation indent, where its condition fits on one line again (glued head 148
	 * columns, broken head 119).
	 */
	public function testOverflowingBlockIfBreaksAfterArrow(): Void {
		final src: String = 'class M {\n\tfunction f() {\n'
			+ '\t\towner?.forEachEntry(entryUser -> if (checkEntryForPending(entryUser, lostBatch) && !bucket.exists((u:EntryUserType) -> u.id == entryUser.id)) {\n'
			+ '\t\t\tfillMissingTag(entryUser);\n\t\t\tbucket.push(entryUser);\n\t\t});\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction f() {\n\t\towner?.forEachEntry(entryUser ->\n\t\t\tif (checkEntryForPending(entryUser, lostBatch) && !bucket.exists((u:EntryUserType) -> u.id == entryUser.id)) {\n\t\t\t\tfillMissingTag(entryUser);\n\t\t\t\tbucket.push(entryUser);\n\t\t\t}\n\t\t);\n\t}\n}',
			triviaWrite(src)
		);
	}

	/** GUARD: a block-bodied `if` whose head FITS on the arrow line stays glued. */
	public function testFittingBlockIfStaysGlued(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\towner?.forEachEntry(entryUser -> if (entryUser.id != 0) {\n'
			+ '\t\t\tfillMissingTag(entryUser);\n\t\t\tbucket.push(entryUser);\n\t\t});\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction f() {\n\t\towner?.forEachEntry(entryUser -> if (entryUser.id != 0) {\n\t\t\tfillMissingTag(entryUser);\n\t\t\tbucket.push(entryUser);\n\t\t});\n\t}\n}',
			triviaWrite(src)
		);
	}

	/**
	 * GUARD: a `{}`-BLOCK body is refused by the gate however wide the header got — it
	 * ends the header line by itself, so moving it down strands the brace and buys
	 * nothing (the population `Renderer.selfBreakingBraceBody` already owns).
	 */
	public function testOverflowingBraceBodyStaysGlued(): Void {
		final src: String = 'class M {\n\tfunction f() {\n'
			+ '\t\towner?.forEachEntryWithPendingBatchAndLostShareBucket(entryUserRecordValue -> {\n'
			+ '\t\t\tfillMissingTag(entryUserRecordValue);\n\t\t\tbucket.push(entryUserRecordValue);\n\t\t});\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction f() {\n\t\towner?.forEachEntryWithPendingBatchAndLostShareBucket(entryUserRecordValue -> {\n\t\t\tfillMissingTag(entryUserRecordValue);\n\t\t\tbucket.push(entryUserRecordValue);\n\t\t});\n\t}\n}',
			triviaWrite(src)
		);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
