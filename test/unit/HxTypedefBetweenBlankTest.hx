package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-typedef-between-blank — verifies the inter-typedef blank-line rule
 * fires under Allman `anonTypeLeftCurly = Next` and stays inert under
 * `Same`. Driven by the new `multilineWhenFieldCtorAndOpt('type', 'Anon',
 * 'anonTypeLeftCurly', 'anyparse.format.BracePlacement.Next')` predicate
 * on `HxTypedefDecl` + `TypedefDecl` added to `HxModule.decls`'s
 * `blankLinesAfterCtorIf` / `blankLinesBeforeCtorIf` ctor lists.
 *
 * Closes the residual gap in `lineends/issue_301_typedef_anon_type.hxtest`
 * and `…_wrap_keep.hxtest` (was the lone byte-diff after slice
 * ω-var-type-hint-anon-indent landed).
 */
@:nullSafety(Strict)
class HxTypedefBetweenBlankTest extends Test {

	public function new(): Void {
		super();
	}

	public function testBlankBetweenTwoMultilineTypedefsUnderNext(): Void {
		// Source has no blank between the two typedefs; under
		// `leftCurly: "both"` (= Next) both render multi-line (force-
		// multi rule), so afterMultilineDecl fires 1 blank between them.
		final src: String = 'typedef Point2D = {\n\tx:Int,\n\ty:Int\n};\ntypedef Point3D = {x:Int, y:Int, z:Int};\n';
		final out: String = writeWithLeftCurlyBoth(src);
		Assert.isTrue(
			out.indexOf('};\n\ntypedef Point3D') != -1,
			'expected blank line between consecutive multi-line typedefs under Next in:\n<$out>'
		);
	}

	public function testNoBlankBetweenTwoCuddledTypedefsUnderSame(): Void {
		// Default `anonTypeLeftCurly = Same` — the predicate's opt-gate
		// fails, predicate stays false, afterMultilineDecl doesn't fire.
		// betweenSingleLineTypes (default 0) handles the gap → 0 blanks.
		final src: String = 'typedef A = {x:Int};\ntypedef B = {y:Int};\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isFalse(out.indexOf('};\n\ntypedef B') != -1, 'expected NO blank between cuddled typedefs under Same in:\n<$out>');
	}

	public function testBlankBetweenMultilineTypedefAndClass(): Void {
		// typedef multi-line → class — afterMultilineDecl (prev=typedef
		// multi-line) fires 1 blank; beforeMultilineDecl (curr=class
		// multi-line) also fires 1; cascade picks first match. Result is
		// 1 blank either way.
		final src: String = 'typedef T = {\n\tx:Int,\n\ty:Int\n};\nclass A { var x:Int; }\n';
		final out: String = writeWithLeftCurlyBoth(src);
		Assert.isTrue(out.indexOf('};\n\nclass A') != -1, 'expected blank between multi-line typedef and class under Next in:\n<$out>');
	}

	public function testNonAnonTypedefDoesNotFire(): Void {
		// `typedef T = Int;` is not Anon — predicate stays false even
		// under Next. Cascade falls through to betweenSingleLineTypes (0).
		final src: String = 'typedef A = Int;\ntypedef B = String;\n';
		final out: String = writeWithLeftCurlyBoth(src);
		Assert.isFalse(out.indexOf('Int;\n\ntypedef B') != -1, 'expected NO blank between non-Anon typedefs in:\n<$out>');
	}

	public function testIssue301RoundTrip(): Void {
		// End-to-end probe matching the exact corpus fixture input.
		final src: String = 'typedef Point2D = {\n\tx:Int,\n\ty:Int\n\t};\ntypedef Point3D = {x:Int, y:Int, z:Int};\n\nclass A {\n\tvar a:{x:Int, y:Int, z:Int};\n\tvar a:{\n\t\tx:Int,\n\t\ty:Int,\n\t\tz:Int\n\t};\n}';
		final out: String = writeWithLeftCurlyBoth(src);
		Assert.isTrue(
			out.indexOf('};\n\ntypedef Point3D =\n{') != -1, 'expected blank + Allman shape between Point2D and Point3D in:\n<$out>'
		);
		Assert.isTrue(out.indexOf('};\n\nclass A') != -1, 'expected blank between Point3D and class A in:\n<$out>');
	}

	private inline function writeWithLeftCurlyBoth(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"leftCurly": "both"}}');
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
