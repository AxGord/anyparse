package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-meta-allman-objectlit — when an `HxMetaExpr` wraps an `ObjectLit`
 * value (`@meta { ... }`), the writer routes the meta→value separator
 * through `Nest(_cols, [Hardline, writeExpr])` instead of the default
 * inline space. Effect: `{` lands on its own line at indent +1
 * relative to the meta token, and the value's own internal nest pushes
 * the body to indent +2. Layout is unconditional — no companion
 * `WriteOptions` knob — because the haxe-formatter convention treats
 * this as a structural property of the meta-prefixed brace form.
 *
 * Companion change: `triviaSepStarExpr`'s `appendTrailingComma` for
 * `@:trivia` sep-Stars with a close literal flipped from
 * `trailPresent && knob` to `trailPresent || knob`. Source `,`
 * round-trips in any multi-line shape regardless of the knob; flat
 * `NoWrap` still ignores the flag (`shapeNoWrap` doesn't append) so
 * the existing `testSourceTrailingCommaIgnoredWhenKnobOff` invariant
 * holds — the change only matters when something else (surrounding
 * hardlines, natural cascade fit, or `forceExceeds` itself) already
 * forces multi-line.
 *
 * Together these unblock the corpus fixture
 * `whitespace/issue_607_anon_object_with_meta.hxtest` end-to-end.
 */
@:nullSafety(Strict)
final class HxMetaAllmanObjectLitSliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testMetaObjectLitGetsAllmanIndent():Void {
		// `@patch { ... }` precedes an ObjectLit → the wrap forces `{`
		// onto its own line at indent +1 (`return @patch\n\t\t\t{`).
		final src:String = 'class Main {\n\tstatic function main() {\n\t\treturn @patch {\n\t\t\tstatus: InProgress(v),\n\t\t}\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('return @patch\n\t\t\t{\n') != -1,
			'expected `return @patch\\n\\t\\t\\t{` Allman placement, got: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t\tstatus: InProgress(v)') != -1,
			'expected body indented +2 (4 tabs), got: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t}\n') != -1,
			'expected close brace at indent +1 (3 tabs), got: <$out>');
	}

	public function testMetaObjectLitPreservesSourceTrailingComma():Void {
		// Source has `InProgress(v),` (trailing `,`); default knob
		// `trailingCommaObjectLits = false`. The disjunction in
		// `appendTrailingCommaExpr` keeps the `,` because the meta-
		// Allman wrap forces multi-line via the leading hardline.
		final src:String = 'class Main {\n\tstatic function main() {\n\t\treturn @patch {\n\t\t\tstatus: InProgress(v),\n\t\t}\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('InProgress(v),\n\t\t\t}') != -1,
			'expected source `,` retained before close brace, got: <$out>');
	}

	public function testMetaIdentifierFallsThroughToInlineSpace():Void {
		// `@patch foo` — meta-prefixed non-ObjectLit value falls
		// through to the default `_dt(' ')` separator. The wrap fires
		// only for the named ctor (`ObjectLit`); other expression
		// shapes round-trip with the inline space layout.
		final src:String = 'class M { function f():Void { var x:Dynamic = @patch foo; } }';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('@patch foo') != -1,
			'expected inline `@patch foo` for non-ObjectLit value, got: <$out>');
	}

	public function testMetaParenExprFallsThrough():Void {
		// `@:privateAccess (X).object` — the parenthesised expression
		// is `ParenExpr`, not `ObjectLit`, so the wrap stays inert and
		// the meta + paren value emits inline. Mirrors the original
		// `HxMetaExpr` doc's reference fixture from the fork corpus.
		final src:String = 'class M { function f():Void { trace(@:privateAccess (X).object); } }';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('@:privateAccess (X).object') != -1,
			'expected inline `@:privateAccess (X).object`, got: <$out>');
	}

	private inline function format(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
