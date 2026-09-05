package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;
import utest.Assert;

/**
 * Slice E -- conditional-compilation regions whose braces do NOT balance
 * inside the region.
 *
 * The Haxe compiler never sees these: it evaluates the condition at LEX
 * time and parses one branch. A formatter cannot, because `hxq fmt
 * --write` rewrites the file and a branch that was never parsed would be
 * DELETED from it. Every test here therefore pins BOTH branches.
 *
 * Four mechanisms:
 *
 *  - `HxDecl.CondSharedBodyDecl` / `HxCondSharedBodyDecl` -- parallel
 *    TYPE-DECL headers, each opening the body, members shared after
 *    `#end`. First branch structural, alternates raw.
 *  - `HxStatement.CondSpliceBlockOpen` -- parallel statement heads, each
 *    opening a block, body and `}` shared after `#end`.
 *  - `HxStatement.CondSpliceBlockClose` -- a region that CLOSES its
 *    enclosing block and re-opens a continuation, `}` shared after
 *    `#end`.
 *  - `HxStatement.CondSpliceBlockTail` -- a region that CLOSES its
 *    enclosing block and then opens AND closes a block of its own, all
 *    before `#end`. Raw head, structural body.
 *
 * Plus a regression guard for the opener/closer region PAIR: the opener
 * looks like a block-opening region but must stay a `CondSpliceStmt`.
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
			+ '@:forward() abstract G(js.html.webgl.Program) from js.html.webgl.Program {\n#end\n\tpublic static function f():Void {}\n}';
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
	 * `CondSpliceBlockOpen` off it, so the OPENER stays a `CondSpliceStmt`
	 * that binds the shared `g();` as its tail. The CLOSER region is a
	 * `CondSpliceBlockTail` since S115 - it closes the `try` and carries a
	 * block of its own - and the `return` after `#end` is a sibling
	 * statement, no longer swallowed as a tail.
	 */
	public function testOpenerCloserPairKeepsOpenerACondSpliceStmt(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f():Void { #if display try { #end g(); #if display } catch (_:Dynamic) { } #end return; } }'
		);
		Assert.equals(3, body.length);
		switch body[0] {
			case CondSpliceStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected CondSpliceStmt for the opener, got ${body[0]}');
		}
		switch body[1] {
			case CondSpliceBlockTail(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected CondSpliceBlockTail for the closer, got ${body[1]}');
		}
		switch body[2] {
			case VoidReturnStmt:
				Assert.pass();
			case null, _:
				Assert.fail('expected VoidReturnStmt after the region, got ${body[2]}');
		}
	}

	/**
	 * THE USER-REPORTED DEFECT (`pony/magic/builder/ChainBuilder.hx:72`,
	 * asked for twice). The closing region's catch body is EMPTY and written
	 * over two lines; an unguarded `} catch (_: Dynamic) {\n}` has always
	 * collapsed to `{}`, but inside a region the writer had no tree to
	 * collapse. `CondSpliceBlockTail` gives it one - and leaves the HEAD raw,
	 * so the source's own `_:Dynamic` spelling survives the rewrite while the
	 * body is formatted like any other block.
	 */
	public function testBlockTailRegionCollapsesEmptyCatchBody(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if display\n\t\ttry {\n\t\t#end\n\t\tg();\n'
			+ '\t\t#if display\n\t\t} catch (_:Dynamic) {\n\t\t}\n\t\t#end\n\t\treturn;\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.isTrue(out.indexOf('\t\t#if display\n\t\t} catch (_:Dynamic) {}\n\t\t#end\n') >= 0, 'collapsed catch tail, got:\n$out');
		Assert.equals(-1, out.indexOf('} catch (_:Dynamic) {\n\t\t}'));
	}

	/**
	 * A NON-empty block-tail body is a real statement list, so it round-trips
	 * byte for byte the way any other block does - the collapse above is the
	 * block writer's ordinary empty-body answer, not a special case.
	 */
	public function testBlockTailRegionRoundTripsNonEmptyBody(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if display\n\t\ttry {\n\t\t#end\n\t\tg();\n'
			+ '\t\t#if display\n\t\t} catch (e:Dynamic) {\n\t\t\ttrace(e);\n\t\t\th();\n\t\t}\n\t\t#end\n\t\treturn;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The split the ctor makes: the unbalanced HEAD (the `}` that closes a
	 * block opened in ANOTHER region, plus the catch clause glued to it)
	 * stays raw bytes, and everything from its `{` on is a real node the
	 * writer formats.
	 */
	public function testBlockTailRegionKeepsHeadRawAndBodyStructural(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f():Void { #if display try { #end g(); #if display } catch (_:Dynamic) { trace(1); h(); } #end return; } }'
		);
		switch body[1] {
			case CondSpliceBlockTail(inner):
				Assert.isTrue((inner.raw: String).indexOf('} catch (_:Dynamic)') >= 0, 'raw head verbatim, got ${inner.raw}');
				Assert.equals(-1, (inner.raw: String).indexOf('{'));
				Assert.equals('#end', (inner.endKw: String));
				switch inner.body {
					case BlockStmt(stmts):
						Assert.equals(2, stmts.length);
					case null, _:
						Assert.fail('expected BlockStmt body, got ${inner.body}');
				}
			case null, _:
				Assert.fail('expected CondSpliceBlockTail, got ${body[1]}');
		}
	}

	/**
	 * DISJOINTNESS -- `pony/tests/AsyncTests.hx:63`. A closing region that
	 * opens no block of its own reaches `CondSpliceBlockClose` exactly as
	 * before: `HxCondBlockTailRaw` needs a `{` after the leading `}` and
	 * finds none, so the new ctor fail-rewinds rather than mis-binding the
	 * `#end`.
	 */
	public function testCloseRegionWithoutOwnBlockStaysCondSpliceBlockClose(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f():Void { #if cs pony.cs.Synchro.lock(isRead, function() { #end a(); #if cs }); #end } }'
		);
		Assert.equals(2, body.length);
		switch body[1] {
			case CondSpliceBlockClose(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected CondSpliceBlockClose, got ${body[1]}');
		}
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, '{}');
	}

	private function parseBody(source: String): Array<HxStatement> {
		return fnBodyStmts(parseSingleFnDecl(source));
	}

}
