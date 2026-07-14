package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-arrowif-open: a call/array arg whose body is a PLAIN `if` (no `else`,
 * not a `{}`-block) hides its inline then-branch behind a `BodyGroup` that
 * every static width measure defers to width 0. That under-measures the arg,
 * so the `callParameter` cascade / fill-pack / outer-Group fit keep it hugged
 * even when the body overflows. `WrapList.emit` re-tags the arg's hardline-free
 * `BodyGroup`s as `Group` (render-identical; only the measure differs) so the
 * true width is visible and the call opens on the overflowing line — matching
 * the haxe-formatter fork. Excluded: fitting bodies (stay hugged), plain-CALL
 * bodies (no `if`), `{}`-block if-bodies, and if-ELSE bodies. Identifiers are
 * fully synthetic and bear no relation to any downstream code.
 */
@:nullSafety(Strict)
final class HxArrowPlainIfOpenSliceTest extends Test {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	/** A single-arg arrow whose PLAIN-`if` body FITS stays hugged on one line (no open). */
	public function testFittingPlainIfArrowHugsOnOneLine(): Void {
		final src: String = 'class M {\n\tfunction fitHug() {\n\t\tcallThing((v) -> if (v != null) shortCall(v));\n\t}\n}';
		Assert.equals('class M {\n\tfunction fitHug() {\n\t\tcallThing((v) -> if (v != null) shortCall(v));\n\t}\n}', triviaWrite(src));
	}

	/** An overflowing single-arg arrow-plain-`if` OPENS the call (arg on its own line); the `if` stays on one line at the deeper indent. */
	public function testSingleArgOverflowingPlainIfOpensCall(): Void {
		final src: String = 'class M {\n\tfunction singleArg() {\n\t\tcallThing((v:Null<PayloadRecordType>) -> if (v != null) registry.applyPendingBatch((rec:SessionEntryType) -> rec.metaTag.fieldEntry = v));\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction singleArg() {\n\t\tcallThing(\n\t\t\t(v:Null<PayloadRecordType>) -> if (v != null) registry.applyPendingBatch((rec:SessionEntryType) -> rec.metaTag.fieldEntry = v)\n\t\t);\n\t}\n}',
			triviaWrite(src)
		);
	}

	/** An overflowing two-arg call whose last arg is an arrow-plain-`if` OPENS one-per-line; the `if` stays on one line. */
	public function testTwoArgOverflowingPlainIfOpensCall(): Void {
		final src: String = 'class M {\n\tfunction twoArg() {\n\t\tpost({}, (v:Null<PayloadRecordType>) -> if (v != null) registry.applyPendingBatch((rec:SessionEntryType) -> rec.metaTag.fieldEntry = v));\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction twoArg() {\n\t\tpost(\n\t\t\t{},\n\t\t\t(v:Null<PayloadRecordType>) -> if (v != null) registry.applyPendingBatch((rec:SessionEntryType) -> rec.metaTag.fieldEntry = v)\n\t\t);\n\t}\n}',
			triviaWrite(src)
		);
	}

	/** When the opened arrow + `if` still overflow at the deeper indent, the arrow leading-breaks after `->` and the `if` sits on one line one level deeper. */
	public function testArrowLeadingBreaksWhenBodyOverflowsAtDeeperIndent(): Void {
		final src: String = 'class M {\n\tfunction deepBreak() {\n\t\tpost({}, (v:Null<DeferredPayloadType>) -> if (v != null) dispatcher.enqueueDeferredWork((rec:LedgerRecordType) -> rec.ledgerBlock.pendingSlot = v));\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction deepBreak() {\n\t\tpost(\n\t\t\t{},\n\t\t\t(v:Null<DeferredPayloadType>) ->\n\t\t\t\tif (v != null) dispatcher.enqueueDeferredWork((rec:LedgerRecordType) -> rec.ledgerBlock.pendingSlot = v)\n\t\t);\n\t}\n}',
			triviaWrite(src)
		);
	}

	/** GUARD: a plain-CALL arrow body (no `if`) is NOT matched by the arrow-plain-`if` path, so its layout is untouched (arrow leading-breaks, call opens — the pre-existing anyparse shape). */
	public function testPlainCallArrowBodyUnchangedByArrowIfPath(): Void {
		final src: String = 'class M {\n\tfunction plainCallBody() {\n\t\tcallThing((payloadValue:Null<PayloadRecordType>) -> registryService.applyPendingBatchUpdate(payloadValue, extraArgOne, extraArgTwo, extraArgThreeLong));\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction plainCallBody() {\n\t\tcallThing((payloadValue:Null<PayloadRecordType>) ->\n\t\t\tregistryService.applyPendingBatchUpdate(payloadValue, extraArgOne, extraArgTwo, extraArgThreeLong)\n\t\t);\n\t}\n}',
			triviaWrite(src)
		);
	}

	/** GUARD: a plain-`if` whose body is a `{}`-block keeps the (hardline-bearing) block deferred and stays hugged — the transform only re-tags hardline-free bodies. */
	public function testBlockIfArrowBodyStaysHugged(): Void {
		final src: String = 'class M {\n\tfunction blockIf() {\n\t\tcallThing((v:Null<PayloadRecordType>) -> if (condition) {\n\t\t\tdoOne();\n\t\t\tdoTwo();\n\t\t});\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction blockIf() {\n\t\tcallThing((v:Null<PayloadRecordType>) -> if (condition) {\n\t\t\tdoOne();\n\t\t\tdoTwo();\n\t\t});\n\t}\n}',
			triviaWrite(src)
		);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
