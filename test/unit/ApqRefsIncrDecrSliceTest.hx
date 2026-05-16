package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;

using Lambda;

/**
 * apq P5 query-value Slice (#2): `++` / `--` write classification.
 *
 * Slice H added `PreIncr` / `PreDecr` / `PostIncr` / `PostDecr` to
 * `HxExpr` (parse-rate), but `RefShape.writeParentKinds` was never
 * extended — `x++` / `--x` classified as `[read]`, so `apq refs x
 * --writes` silently under-reported any only-incremented binding.
 * These ctors join the write-parent set; their single operand at
 * child-0 reclassifies to Write exactly like an assign LHS.
 *
 * Pre-fix these assertions are RED (`x++` is a Read); post-fix GREEN.
 */
class ApqRefsIncrDecrSliceTest extends Test {

	public function testPostIncrementIsWrite():Void {
		final hits:Array<RefHit> = findIn('class X { static function f():Void { var x:Int = 0; x++; } }', 'x');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Decl), 'decl expected — got ${describe(hits)}');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Write), '`x++` must be a Write — got ${describe(hits)}');
		Assert.isFalse(hits.exists(h -> h.kind == RefKind.Read), '`x++` must NOT surface as a Read — got ${describe(hits)}');
	}

	public function testPreDecrementIsWrite():Void {
		final hits:Array<RefHit> = findIn('class X { static function f():Void { var x:Int = 0; --x; } }', 'x');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Write), '`--x` must be a Write — got ${describe(hits)}');
		Assert.isFalse(hits.exists(h -> h.kind == RefKind.Read), '`--x` must NOT surface as a Read — got ${describe(hits)}');
	}

	public function testPreIncrementAndPostDecrementAreWrites():Void {
		final inc:Array<RefHit> = findIn('class X { static function f():Void { var a:Int = 0; ++a; } }', 'a');
		Assert.isTrue(inc.exists(h -> h.kind == RefKind.Write), '`++a` must be a Write — got ${describe(inc)}');
		Assert.isFalse(inc.exists(h -> h.kind == RefKind.Read), '`++a` must NOT surface as a Read — got ${describe(inc)}');
		final dec:Array<RefHit> = findIn('class X { static function f():Void { var b:Int = 0; b--; } }', 'b');
		Assert.isTrue(dec.exists(h -> h.kind == RefKind.Write), '`b--` must be a Write — got ${describe(dec)}');
		Assert.isFalse(dec.exists(h -> h.kind == RefKind.Read), '`b--` must NOT surface as a Read — got ${describe(dec)}');
	}

	public function testNestedIncrementReceiverStaysRead():Void {
		// `obj.x++` — child-0 of PostIncr is a FieldAccess, not a bare
		// IdentExpr. Only the direct child-0 IdentExpr reclassifies, so
		// the receiver `obj` keeps Read (mirrors the assign convention:
		// `obj.x = …` keeps `obj` a Read).
		final hits:Array<RefHit> = findIn('class X { static function f():Void { var obj:Int = 0; obj.x++; } }', 'obj');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Read), 'receiver `obj` stays a Read — got ${describe(hits)}');
		Assert.isFalse(hits.exists(h -> h.kind == RefKind.Write), '`obj.x++` must not write the receiver — got ${describe(hits)}');
	}

	private static function findIn(source:String, name:String):Array<RefHit> {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree:QueryNode = plugin.parseFile(source);
		final shape:RefShape = plugin.refShape();
		return Refs.find(name, tree, shape);
	}

	private static function describe(hits:Array<RefHit>):String {
		return hits.map(h -> '${h.kind}@${h.span.from}').join(', ');
	}
}
