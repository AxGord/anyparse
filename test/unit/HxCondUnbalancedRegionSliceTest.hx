package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice E -- conditional-compilation regions whose braces do NOT balance
 * inside the region.
 *
 * The Haxe compiler never sees these: it evaluates the condition at LEX
 * time and parses one branch. A formatter cannot, because `hxq fmt
 * --write` rewrites the file and a branch that was never parsed would be
 * DELETED from it. Every test here therefore pins BOTH branches.
 *
 * Three mechanisms:
 *
 *  - `HxDecl.CondSharedBodyDecl` / `HxCondSharedBodyDecl` -- parallel
 *    TYPE-DECL headers, each opening the body, members shared after
 *    `#end`. First branch structural, alternates raw.
 *  - `HxStatement.CondSpliceBlockOpen` -- parallel statement heads, each
 *    opening a block, body and `}` shared after `#end`.
 *  - `HxStatement.CondSpliceBlockClose` -- a region that CLOSES its
 *    enclosing block and re-opens a continuation, `}` shared after
 *    `#end`.
 *
 * Plus a regression guard for the opener/closer region PAIR, which looks
 * like a block-opening region but must stay two `CondSpliceStmt`s.
 */
@:nullSafety(Strict)
class HxCondUnbalancedRegionSliceTest extends HxTestHelpers {

	/**
	 * `pony/flash/ui/TooltipSource.hx:16` -- parallel `class` headers,
	 * members and `}` shared after `#end`.
	 */
	public function testDeclHeaderSplitClassRoundTrips(): Void {
		final src: String = '#if starling\nclass T extends MovieClip implements IStarlingConvertible {\n#else\n'
			+ 'class T extends MovieClip {\n#end\n\tpublic function new() {\n\t\tsuper();\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The FIRST branch stays structural: its name and heritage are in the
	 * tree, and so is every shared member. Only the alternates are bytes.
	 */
	public function testDeclHeaderSplitKeepsFirstBranchStructural(): Void {
		final src: String = '#if starling\nclass T extends MovieClip implements IStarlingConvertible {\n#else\n'
			+ 'class T extends MovieClip {\n#end\n\tpublic function new() {\n\t\tsuper();\n\t}\n}';
		final ast: HxModule = HaxeModuleParser.parse(src);
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case CondSharedBodyDecl(inner):
				switch inner.head {
					case ClassHead(head):
						Assert.equals('T', (head.name: String));
						Assert.equals(2, head.heritage.length);
					case _:
						Assert.fail('expected ClassHead, got ${inner.head}');
				}
				Assert.equals(1, inner.members.length);
				Assert.isTrue((inner.alt: String).indexOf('class T extends MovieClip {') >= 0);
			case _:
				Assert.fail('expected CondSharedBodyDecl, got ${ast.decls[0].decl}');
		}
	}

	/**
	 * `lime/graphics/opengl/GLProgram.hx:13` -- the `abstract` form, with
	 * the metadata that belongs to the first branch written inside the
	 * region.
	 */
	public function testDeclHeaderSplitAbstractRoundTrips(): Void {
		final src: String = '#if !lime_webgl\n@:forward(id, refs) abstract G(GLObject) from GLObject to GLObject {\n#else\n'
			+ '@:forward() abstract G(js.html.webgl.Program) from js.html.webgl.Program {\n#end\n'
			+ '\tpublic static function f():Void {}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * `pony/ui/gui/BaseLayoutCore.hx:63` -- parallel `if` heads each
	 * opening a block; the shared body, its `}` and the trailing `else`
	 * all live after `#end`.
	 */
	public function testBlockOpenSpliceRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfor (child in children) {\n\t\t\t#if (haxe_ver >= 4.10)\n'
			+ '\t\t\tif (Std.isOfType(child, Bitmap)) {\n\t\t\t#else\n\t\t\tif (Std.is(child, Bitmap)) {\n\t\t\t#end\n'
			+ '\t\t\t\tcast(child, Bitmap).tile = tile;\n\t\t\t\tbreak;\n\t\t\t}\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The shared statements after `#end` are parsed structurally, and the
	 * trailing `else` reaches the pre-existing `OrphanElseStmt` rather
	 * than a field of its own.
	 */
	public function testBlockOpenSpliceParsesSharedBody(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { #if X if (a) { #else if (b) { #end g(); } else h(); } }');
		Assert.equals(2, body.length);
		switch body[0] {
			case CondSpliceBlockOpen(inner):
				Assert.equals(1, inner.body.length);
				Assert.isTrue((inner.raw: String).indexOf('if (b) {') >= 0);
			case null, _:
				Assert.fail('expected CondSpliceBlockOpen, got ${body[0]}');
		}
		switch body[1] {
			case OrphanElseStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected OrphanElseStmt, got ${body[1]}');
		}
	}

	/**
	 * `pony/ui/gui/BaseLayoutCore.hx:63` -- the same shape with a
	 * trailing `else` after the shared `}`. The writer moves that `else`
	 * onto its own line (it is a separate `OrphanElseStmt` in the
	 * enclosing Star, not a clause of the spliced head), so the assertion
	 * is the slice's real invariant rather than byte identity: BOTH
	 * branches survive the write, and the result is stable.
	 */
	public function testBlockOpenSpliceWithTrailingElseKeepsBothBranches(): Void {
		final src: String = 'class C {\n\tfunction addWait(o) {\n\t\t#if (haxe_ver >= 4.10)\n\t\tif (Std.isOfType(o, IWH)) {\n'
			+ '\t\t#else\n\t\tif (Std.is(o, IWH)) {\n\t\t#end\n\t\t\ttasks.add();\n\t\t} else load(o);\n\t}\n}';
		final written: String = triviaWrite(src);
		Assert.isTrue(written.indexOf('if (Std.isOfType(o, IWH)) {') >= 0, 'first branch lost');
		Assert.isTrue(written.indexOf('if (Std.is(o, IWH)) {') >= 0, 'alternate branch lost');
		Assert.isTrue(written.indexOf('else load(o);') >= 0, 'trailing else lost');
		Assert.equals(written, triviaWrite(written));
	}

	/**
	 * `std/cs/internal/Runtime.hx:118` -- the region closes the enclosing
	 * block and re-opens an `else`; the shared `}` follows `#end`.
	 */
	public function testBlockCloseSpliceRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tg();\n\t\t\t#if !erase_generics\n\t\t} else {\n'
			+ '\t\t\th();\n\t\t#end\n\t\t}\n\t\treturn false;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The block-closing ctor is payload-only: everything up to and
	 * including `#end` is bytes, and the `}` after it belongs to the
	 * enclosing block, not to this statement.
	 */
	public function testBlockCloseSpliceIsPayloadOnly(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (a) { g(); #if X } else { h(); #end } return; } }');
		Assert.equals(2, body.length);
		switch body[0] {
			case IfStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected IfStmt, got ${body[0]}');
		}
	}

	/**
	 * REGRESSION GUARD -- `pony/magic/builder/ChainBuilder.hx:26`. An
	 * opener region with NO alternative branch, whose matching closer
	 * lives in a SECOND region, also ends on `{`. Consuming a `}` after
	 * its shared statements would steal the enclosing function's closer.
	 * The `#else` requirement in `HxCondBlockOpenRaw` keeps
	 * `CondSpliceBlockOpen` off it, so the file stays two
	 * `CondSpliceStmt`s exactly as before this slice.
	 */
	public function testOpenerCloserPairStaysCondSpliceStmt(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f():Void { #if display try { #end g(); #if display } catch (_:Dynamic) { } #end return; } }'
		);
		Assert.equals(2, body.length);
		for (stmt in body) switch stmt {
			case CondSpliceStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected CondSpliceStmt, got $stmt');
		}
	}

	private function parseBody(source: String): Array<HxStatement> {
		return fnBodyStmts(parseSingleFnDecl(source));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
