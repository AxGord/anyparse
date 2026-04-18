package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * ψ₈ — runtime-switchable `elseIf` keyword placement for the nested
 * `if` inside an `else` clause (the `else if (...)` idiom).
 *
 * Controls only the `IfStmt` ctor of `elseBody`: `KeywordPlacement.Same`
 * (default, matching haxe-formatter's `sameLine.elseIf: @:default(Same)`)
 * keeps `else if` inline even when `elseBody=Next` would push non-if
 * branches to their own line; `KeywordPlacement.Next` moves the nested
 * `if` to the next line at one indent level deeper.
 *
 * Wired via `@:fmt(elseIf)` (no argument — ψ₆ principle) on
 * `HxIfStmt.elseBody`. The override runs at `bodyPolicyWrap` time:
 * when the runtime value matches the `IfStmt(_)` pattern on
 * `HxStatement`, the emission routes to `opt.elseIf` regardless of the
 * field's own `@:fmt(bodyPolicy(...))` flag value. Non-if else branches fall
 * through to `elseBody`-driven layout.
 */
@:nullSafety(Strict)
class HxElseIfOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testElseIfDefaultIsSame():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(KeywordPlacement.Same, defaults.elseIf);
	}

	public function testElseIfSameKeepsNestedIfInline():Void {
		final out:String = writeWithElseIf(
			'class F { function f():Void { if (a) {} else if (b) {} } }',
			KeywordPlacement.Same
		);
		Assert.isTrue(out.indexOf('} else if (b)') != -1, 'expected `} else if (b)` inline in: <$out>');
		Assert.isTrue(out.indexOf('} else\n\t\t\tif') == -1, 'did not expect next-line nested if in: <$out>');
	}

	public function testElseIfNextMovesNestedIfToNextLine():Void {
		final out:String = writeWithElseIf(
			'class F { function f():Void { if (a) {} else if (b) {} } }',
			KeywordPlacement.Next
		);
		Assert.isTrue(out.indexOf('else\n\t\t\tif (b)') != -1, 'expected `else\\n\\t\\t\\tif (b)` in: <$out>');
		Assert.isTrue(out.indexOf('} else if (b)') == -1, 'did not expect inline nested if in: <$out>');
	}

	public function testElseIfSameAppliesEvenWhenElseBodyIsNext():Void {
		// Block bodies bypass bodyPolicy (block kind-awareness always
		// single-space), so the only way to observe elseIf=Same winning
		// over elseBody=Next is through the IfStmt ctor — the override
		// must fire regardless of what the `elseBody` policy says.
		final out:String = writeWithOpts(
			'class F { function f():Void { if (a) {} else if (b) {} } }',
			KeywordPlacement.Same, BodyPolicy.Next
		);
		Assert.isTrue(out.indexOf('} else if (b)') != -1, 'expected inline `} else if (b)` in: <$out>');
	}

	public function testElseIfDoesNotAffectNonIfElseBranches():Void {
		// elseBody is a block — not an IfStmt ctor. elseIf=Next should
		// have no effect here; the block's own kind-awareness keeps it
		// inline on a single space after `else`.
		final out:String = writeWithElseIf(
			'class F { function f():Void { if (a) {} else {} } }',
			KeywordPlacement.Next
		);
		Assert.isTrue(out.indexOf('} else {') != -1, 'expected `} else {` (block inline) in: <$out>');
	}

	public function testElseIfNextOnlyLastLevelKeepsFirstLevelInline():Void {
		// else-if-else chain. Only the immediate else that is itself an
		// IfStmt is subject to elseIf; the terminal else carrying a
		// block is unaffected.
		final out:String = writeWithElseIf(
			'class F { function f():Void { if (a) {} else if (b) {} else {} } }',
			KeywordPlacement.Next
		);
		Assert.isTrue(out.indexOf('else\n\t\t\tif (b)') != -1, 'expected nested if on next line in: <$out>');
	}

	public function testElseIfSameDoesNotInterfereWithSameLineElse():Void {
		// sameLineElse controls the space/hardline BEFORE `else`. elseIf
		// controls what happens AFTER `else`. With sameLineElse=false
		// and elseIf=Same, `else` moves to its own line but the nested
		// `if` stays inline after it.
		final out:String = writeWithSameLineElseAndElseIf(
			'class F { function f():Void { if (a) {} else if (b) {} } }',
			false, KeywordPlacement.Same
		);
		Assert.isTrue(out.indexOf('}\n\t\telse if (b)') != -1, 'expected `}\\n\\t\\telse if (b)` in: <$out>');
	}

	public function testElseIfRoundTripsIdempotently():Void {
		final src:String = 'class F { function f():Void { if (a) {} else if (b) {} else {} } }';
		final opts:HxModuleWriteOptions = makeOpts(KeywordPlacement.Next, HaxeFormat.instance.defaultWriteOptions.elseBody);
		final out1:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		final out2:String = HxModuleWriter.write(HaxeModuleParser.parse(out1), opts);
		Assert.equals(out1, out2);
	}

	private inline function writeWithElseIf(src:String, elseIf:KeywordPlacement):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(elseIf, HaxeFormat.instance.defaultWriteOptions.elseBody));
	}

	private inline function writeWithOpts(src:String, elseIf:KeywordPlacement, elseBody:BodyPolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(elseIf, elseBody));
	}

	private function writeWithSameLineElseAndElseIf(src:String, sameLineElse:Bool, elseIf:KeywordPlacement):String {
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final opts:HxModuleWriteOptions = {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			sameLineElse: sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: base.objectFieldColon,
			elseIf: elseIf,
		};
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

	private function makeOpts(elseIf:KeywordPlacement, elseBody:BodyPolicy):HxModuleWriteOptions {
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		return {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: base.ifBody,
			elseBody: elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: base.objectFieldColon,
			elseIf: elseIf,
		};
	}
}
