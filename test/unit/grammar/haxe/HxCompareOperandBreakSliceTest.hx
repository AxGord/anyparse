package unit.grammar.haxe;

import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

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

	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.opBoolChainWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.NoWrap,
			rules: [
				{
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					],
					mode: WrapMode.NoWrap
				},
				{
					conditions: [
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 120 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					],
					mode: WrapMode.NoWrap
				},
				{
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }],
					location: WrappingLocation.BeforeLast,
					mode: WrapMode.FillLine
				}
			]
		};
		edited.conditionWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap }
			]
		};
	});

	public function new(): Void {
		super();
	}

	public function testCompareOperandPastLimitBreaksBeforeOp(): Void {
		// Opened-cond compare line = 147 columns at tab=4 — the glued
		// `left == right` must break before `==` at operand indent +1.
		final glued: String = 'class C {\n\tfunction f() {\n'
			+ '\t\tif (_dataSystem.fetchStorage.getLastRemoteActionKind2(incrementalRemoteAction.filePath, true) '
			+ '== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		final broken: String = 'class C {\n\tfunction f() {\n\t\tif (\n'
			+ '\t\t\t_dataSystem.fetchStorage.getLastRemoteActionKind2(incrementalRemoteAction.filePath, true)\n'
			+ '\t\t\t\t== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED\n\t\t) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	public function testCompareExactlyOnLimitStaysGlued(): Void {
		// Full header line = exactly 140 columns — fork parity is a strict
		// `>`, so everything stays flat on the limit.
		final src: String = 'class C {\n\tfunction f() {\n'
			+ '\t\tif (_dataSystem.fetchStorage.getRemoteKind2(incrementalRemoteAction.filePath, true) '
			+ '== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
		// One column past the limit (141) — the compare breaks before `==`
		// while the header stays glued (its natural first line fits at the
		// open paren), matching the fork's `call(args)\n\t== X` shape.
		final glued141: String = 'class C {\n\tfunction f() {\n'
			+ '\t\tif (_dataSystem.fetchStorage.getRemoteKindX2(incrementalRemoteAction.filePath, true) '
			+ '== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		final broken141: String = 'class C {\n\tfunction f() {\n'
			+ '\t\tif (_dataSystem.fetchStorage.getRemoteKindX2(incrementalRemoteAction.filePath, true)\n'
			+ '\t\t\t== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(broken141, triviaWrite(glued141));
		Assert.equals(broken141, triviaWrite(broken141));
	}

	public function testCompareOperandInBoolChainBreaksBeforeOp(): Void {
		// The client StoreBase shape: a `||` operand `call(...) == CONST`
		// inside a nested-paren bool chain overflows at 151 columns — it
		// must break before `==` instead of staying glued. The paren group
		// whose content breaks opens as a container on the outer chain's line.
		final glued: String = 'class C {\n\tfunction f() {\n\t\tif (\n'
			+ '\t\t\t!incrementalRemoteAction.folder && fileTimestamp > incrementalRemoteAction.cloudTimestamp\n\t\t\t&& (fileTimestamp != '
			+ 'cloudTimestamp\n\t\t\t|| _dataSystem.fetchStorage.getLastRemoteActionKind2(incrementalRemoteAction.filePath, true) '
			+ '== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED)\n\t\t) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		final broken: String = 'class C {\n\tfunction f() {\n\t\tif (\n'
			+ '\t\t\t!incrementalRemoteAction.folder && fileTimestamp > incrementalRemoteAction.cloudTimestamp && (\n\t\t\t\tfileTimestamp '
			+ '!= cloudTimestamp\n\t\t\t\t|| _dataSystem.fetchStorage.getLastRemoteActionKind2(incrementalRemoteAction.filePath, true)\n'
			+ '\t\t\t\t\t== RemoteActionKind.ACTION_KIND_LOCAL_UPDATED\n\t\t\t)\n\t\t) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	public function testAssignmentCompareOverflowBreaksBeforeOp(): Void {
		// A `==` compare in a plain assignment (not a condition, not a ternary)
		// breaks before the op on overflow -- the left call args are short so
		// the operator break is the only way to fit (fork parity: the fork
		// breaks such compares regardless of statement context).
		final glued: String = 'class C {\n\tfunction f() {\n'
			+ '\t\tfinal locallyModified:Bool = _dataSystem.fetchStorage.getLastRemoteActionKind2(remoteAction.filePath, true) '
			+ '== RemoteActionKind.ACTION_KIND_LOCAL_UPD;\n\t}\n}';
		final broken: String = 'class C {\n\tfunction f() {\n'
			+ '\t\tfinal locallyModified:Bool = _dataSystem.fetchStorage.getLastRemoteActionKind2(remoteAction.filePath, true)\n'
			+ '\t\t\t== RemoteActionKind.ACTION_KIND_LOCAL_UPD;\n\t}\n}';
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	public function testTernaryConditionCompareStaysGlued(): Void {
		// A `==` compare that IS a ternary condition does NOT break before the
		// op -- the fork breaks the ternary (`?`/`:`), not the compare. The
		// `_inTernaryCond` flag suppresses the operand-overflow break so
		// `cond == true ? ...` stays glued.
		// (anyparse wraps the RHS after `=`; ω-natural-trailwidth deliberately
		// leaves a non-collection value on that legacy measure.)
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal trailOptText:Null<String> =\n'
			+ "\t\t\tchild.annotations.get('lit.trailOptional') == true ? child.annotations.get('lit.trailText') : null;\n\t}\n}";
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
