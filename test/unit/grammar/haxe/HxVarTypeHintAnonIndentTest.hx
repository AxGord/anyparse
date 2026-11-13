package unit.grammar.haxe;

import anyparse.format.BracePlacement;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxListsKeepSource;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-var-type-hint-anon-indent — extra `+cols` indent step on the multi-
 * line `Anon` value of a var's type-hint RHS under Allman. Verifies
 * `@:fmt(indentValueIfCtor('Anon', 'indentVarTypeHintAnon',
 * 'anonTypeLeftCurly'))` on `HxVarDecl.type` fires the existing
 * `indentValueIfCtorWrap` macro path for the optional-Ref branch.
 *
 * Trivia-mode writer is the canonical corpus runner; plain `HxModuleWriter`
 * also exercises the optional-Ref path (the meta lives outside the enum-
 * Alt isTriviaStar branch) so either writer could be used here.
 */
@:nullSafety(Strict)
class HxVarTypeHintAnonIndentTest extends Test {

	public function new(): Void {
		super();
	}

	public function testFlagDefaultsTrue(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.isTrue(defaults.indentVarTypeHintAnon);
	}

	public function testMultiLineAnonGetsExtraIndentUnderNext(): Void {
		// An anon body over the item count, so the wrap rules break it, under leftCurly=both (= Next).
		// Expected: `\tvar a:` then `\n\t\t{` (+1 step before `{`),
		// then `\n\t\t\tx:Int,…` (+2 inside body), then `\n\t\t};` (+1
		// before closing `}`).
		final src: String = 'class A {\n\tvar a:{\n\t\tx:Int,\n\t\ty:Int,\n\t\tz:Int,\n\t\tw:Int,\n\t\tv:Int\n\t};\n}';
		final out: String = writeWithLeftCurlyBoth(src);
		Assert.isTrue(
			out.indexOf('\tvar a:\n\t\t{\n\t\t\tx:Int,\n\t\t\ty:Int,\n\t\t\tz:Int,\n\t\t\tw:Int,\n\t\t\tv:Int\n\t\t};') != -1,
			'expected `+1` indent step on multi-line var-type-hint anon in output:\n<$out>'
		);
	}

	public function testSingleLineAnonStaysFlatUnderNext(): Void {
		// Single-line source-flat anon stays cuddled — the wrap is
		// inert when no internal hardlines exist. AnonType's downgrade-
		// if-source-flat rule keeps the body flat under Next.
		final src: String = 'class A { var a:{x:Int, y:Int, z:Int}; }';
		final out: String = writeWithLeftCurlyBoth(src);
		Assert.isTrue(
			out.indexOf('\tvar a:{x:Int, y:Int, z:Int};') != -1, 'expected flat single-line var-type-hint anon under Next in:\n<$out>'
		);
	}

	public function testFlagOffDoesNotIndentMultiLineAnon(): Void {
		// With `indentVarTypeHintAnon=false`, the wrap is inert even
		// under Next — the multi-line body retains the pre-slice shape
		// (one tab `\tvar a:\n\t{`). Single space probe accepts both
		// pre- and post-slice byte-shapes for the colon→`{` boundary
		// since the gate only flips the surrounding Nest level.
		final src: String = 'class A {\n\tvar a:{\n\t\tx:Int,\n\t\ty:Int,\n\t\tz:Int,\n\t\tw:Int,\n\t\tv:Int\n\t};\n}';
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
			HxListsKeepSource.keep(edited);
			edited.leftCurly = BracePlacement.Next;
			edited.objectLiteralLeftCurly = BracePlacement.Next;
			edited.anonTypeLeftCurly = BracePlacement.Next;
			edited.anonFunctionLeftCurly = BracePlacement.Next;
			edited.blockLeftCurly = BracePlacement.Next;
		});
		opts.indentVarTypeHintAnon = false;
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(
			out.indexOf('\tvar a:\n\t{\n\t\tx:Int,\n\t\ty:Int,\n\t\tz:Int,\n\t\tw:Int,\n\t\tv:Int\n\t};') != -1,
			'expected pre-slice 1-tab indent with flag off in:\n<$out>'
		);
	}

	public function testNonAnonTypeUnaffected(): Void {
		// A plain identifier type (`Int`) shouldn't get the wrap — the
		// runtime ctor check (`Type.enumConstructor(_optVal) == 'Anon'`)
		// fails. Output stays byte-identical to the unwrapped path.
		final src: String = 'class A { var a:Int; }';
		final out: String = writeWithLeftCurlyBoth(src);
		Assert.isTrue(out.indexOf('var a:Int;') != -1, 'expected unchanged `var a:Int;` in:\n<$out>');
	}

	public function testSameLeftCurlyKeepsCuddledMultiLineAnon(): Void {
		// Under `anonTypeLeftCurly = Same` (cuddled), the gate
		// `opt.anonTypeLeftCurly == Next` fails, so the wrap is inert.
		// Multi-line source-anon emits cuddled `{` and pre-slice nest.
		final src: String = 'class A {\n\tvar a:{\n\t\tx:Int,\n\t\ty:Int\n\t};\n}';
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(HxListsKeepSource.keep);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(
			out.indexOf('\tvar a:{\n\t\tx:Int,\n\t\ty:Int\n\t};') != -1 || out.indexOf('\tvar a:{x:Int, y:Int};') != -1,
			'expected cuddled `{` under Same in:\n<$out>'
		);
	}

	private inline function writeWithLeftCurlyBoth(src: String): String {
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
			HxListsKeepSource.keep(edited);
			edited.leftCurly = BracePlacement.Next;
			edited.objectLiteralLeftCurly = BracePlacement.Next;
			edited.anonTypeLeftCurly = BracePlacement.Next;
			edited.anonFunctionLeftCurly = BracePlacement.Next;
			edited.blockLeftCurly = BracePlacement.Next;
		});
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
