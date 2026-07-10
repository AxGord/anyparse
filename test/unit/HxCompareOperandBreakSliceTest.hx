package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-compare-operand-linewrap: a `==` / `!=` comparison whose glued emit
 * (`startsWithOpenDelim(right) || endsWithCloseDelim(left)` — the operand
 * carries its own brackets) overflows the physical line breaks BEFORE the
 * operator at +1 indent instead of staying glued past `maxLineLength`.
 * Mirrors the fork's `breakLongOpBoolOperandAtCompare` +
 * `preferCompareBreakOverInnerCallParamWrap` post-passes (Eq/NotEq only,
 * genuine overflow only, strict `>` — a line exactly ON the limit stays
 * glued). Probe: `IfLineExceeds(lineWidth + 1, …)` in the compare-infix
 * glue arm (`WriterLowering.lowerInfix`).
 */
@:nullSafety(Strict)
final class HxCompareOperandBreakSliceTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testCompareOperandPastLimitBreaksBeforeOp(): Void {
		// Opened-cond compare line = 147 columns at tab=4 — the glued
		// `left == right` must break before `==` at operand indent +1.
		final glued: String = 'class C {\n\tfunction f() {\n\t\tif (_dataSystem.cloudStorage.getLastRemoteActionKind2(incrementalRemoteAction.filePath, true) == RemoteActionKind.ACTION_KIND_LOCAL_UPDATED) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		final broken: String = 'class C {\n\tfunction f() {\n\t\tif (\n\t\t\t_dataSystem.cloudStorage.getLastRemoteActionKind2(incrementalRemoteAction.filePath, true)\n\t\t\t\t== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED\n\t\t) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	public function testCompareExactlyOnLimitStaysGlued(): Void {
		// Full header line = exactly 140 columns — fork parity is a strict
		// `>`, so everything stays flat on the limit.
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (_dataSystem.cloudStorage.getRemoteKind2(incrementalRemoteAction.filePath, true) == RemoteActionKind.ACTION_KIND_LOCAL_UPDATED) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
		// One column past the limit (141) — the compare breaks before `==`
		// while the header stays glued (its natural first line fits at the
		// open paren), matching the fork's `call(args)\n\t== X` shape.
		final glued141: String = 'class C {\n\tfunction f() {\n\t\tif (_dataSystem.cloudStorage.getRemoteKindX2(incrementalRemoteAction.filePath, true) == RemoteActionKind.ACTION_KIND_LOCAL_UPDATED) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		final broken141: String = 'class C {\n\tfunction f() {\n\t\tif (_dataSystem.cloudStorage.getRemoteKindX2(incrementalRemoteAction.filePath, true)\n\t\t\t== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(broken141, triviaWrite(glued141));
		Assert.equals(broken141, triviaWrite(broken141));
	}

	public function testCompareOperandInBoolChainBreaksBeforeOp(): Void {
		// The TM FileSystemBase shape: a `||` operand `call(...) == CONST`
		// inside a nested-paren bool chain overflows at 151 columns — it
		// must break before `==` instead of staying glued.
		final glued: String = 'class C {\n\tfunction f() {\n\t\tif (\n\t\t\t!incrementalRemoteAction.folder && fileTimestamp > incrementalRemoteAction.cloudTimestamp\n\t\t\t&& (fileTimestamp != cloudTimestamp\n\t\t\t|| _dataSystem.cloudStorage.getLastRemoteActionKind2(incrementalRemoteAction.filePath, true) == RemoteActionKind.ACTION_KIND_LOCAL_UPDATED)\n\t\t) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		final broken: String = 'class C {\n\tfunction f() {\n\t\tif (\n\t\t\t!incrementalRemoteAction.folder && fileTimestamp > incrementalRemoteAction.cloudTimestamp\n\t\t\t&& (fileTimestamp != cloudTimestamp\n\t\t\t|| _dataSystem.cloudStorage.getLastRemoteActionKind2(incrementalRemoteAction.filePath, true)\n\t\t\t\t== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED)\n\t\t) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	public function testAssignmentCompareOverflowBreaksBeforeOp(): Void {
		// A `==` compare in a plain assignment (not a condition, not a ternary)
		// breaks before the op on overflow -- the left call args are short so
		// the operator break is the only way to fit (fork parity: the fork
		// breaks such compares regardless of statement context).
		final glued: String = 'class C {\n\tfunction f() {\n\t\tfinal locallyModified:Bool = _dataSystem.cloudStorage.getLastRemoteActionKind2(remoteAction.filePath, true) == RemoteActionKind.ACTION_KIND_LOCAL_UPD;\n\t}\n}';
		final broken: String = 'class C {\n\tfunction f() {\n\t\tfinal locallyModified:Bool = _dataSystem.cloudStorage.getLastRemoteActionKind2(remoteAction.filePath, true)\n\t\t\t== RemoteActionKind.ACTION_KIND_LOCAL_UPD;\n\t}\n}';
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	public function testTernaryConditionCompareStaysGlued(): Void {
		// A `==` compare that IS a ternary condition does NOT break before the
		// op -- the fork breaks the ternary (`?`/`:`), not the compare. The
		// `_inTernaryCond` flag suppresses the operand-overflow break so
		// `cond == true ? ...` stays glued (anyparse wraps the RHS after `=`).
		final src: String = "class C {\n\tfunction f() {\n\t\tfinal trailOptText:Null<String> =\n\t\t\tchild.annotations.get('lit.trailOptional') == true ? child.annotations.get('lit.trailText') : null;\n\t}\n}";
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
