package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxMetadataUtil;
import anyparse.grammar.haxe.HxMetaExpr;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxStatement;

/**
 * Expression-level metadata wrapper tests — covers the `MetaExpr`
 * branch added to `HxExpr` and the supporting `HxMetaExpr` typedef.
 *
 * Coverage:
 *  - Parse `@:m expr` and `@:m(args) expr` at expression position.
 *  - Chained `@:m1 @:m2 expr` builds nested `MetaExpr` ctors.
 *  - Plain-mode (`HaxeModuleParser` + `HxModuleWriter`) round-trip.
 *  - Trivia-mode (`HaxeModuleTriviaParser` + `HaxeModuleTriviaWriter`)
 *    byte-exact round-trip — drives the corpus path used by
 *    `issue_241_metadata_with_parameter`.
 *
 * Verifies the writer emits `<meta-text> <space> <expr>` between the
 * two bare-Ref fields of `HxMetaExpr` (the default sibling separator
 * in `WriterLowering.lowerStruct`).
 */
class HxMetaExprSliceTest extends HxTestHelpers {

	public function testParsesPrivateAccessOnParenField():Void {
		final src:String = 'class Main { static function main() { trace(@:privateAccess (X).object); } }';
		final fn:HxFnDecl = parseSingleFnDecl(src);
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		final callExpr:HxExpr = expectExprStmt(stmts[0]);
		final args:Array<HxExpr> = expectCallArgs(callExpr);
		Assert.equals(1, args.length);
		final wrapper:HxMetaExpr = expectMetaExpr(args[0]);
		Assert.equals('@:privateAccess', HxMetadataUtil.source(wrapper.meta));
	}

	public function testParsesMetaWithArgs():Void {
		final src:String = 'class Main { static function main() { trace(@:foo(1, 2) X); } }';
		final fn:HxFnDecl = parseSingleFnDecl(src);
		final args:Array<HxExpr> = expectCallArgs(expectExprStmt(fnBodyStmts(fn)[0]));
		final wrapper:HxMetaExpr = expectMetaExpr(args[0]);
		Assert.equals('@:foo(1, 2)', HxMetadataUtil.source(wrapper.meta));
		assertIdentExpr(wrapper.expr, 'X');
	}

	public function testChainedMetadataNestsRightward():Void {
		final src:String = 'class Main { static function main() { trace(@:a @:b X); } }';
		final fn:HxFnDecl = parseSingleFnDecl(src);
		final args:Array<HxExpr> = expectCallArgs(expectExprStmt(fnBodyStmts(fn)[0]));
		final outer:HxMetaExpr = expectMetaExpr(args[0]);
		Assert.equals('@:a', HxMetadataUtil.source(outer.meta));
		final inner:HxMetaExpr = expectMetaExpr(outer.expr);
		Assert.equals('@:b', HxMetadataUtil.source(inner.meta));
		assertIdentExpr(inner.expr, 'X');
	}

	public function testPlainRoundTrip():Void {
		final src:String = 'class Main {\n\tstatic function main() {\n\t\ttrace(@:privateAccess (X).object);\n\t}\n}';
		final mod:HxModule = HaxeModuleParser.parse(src);
		final out:String = HxModuleWriter.write(mod);
		Assert.equals(src + '\n', out);
	}

	public function testTriviaRoundTripByteExact():Void {
		final src:String = 'class Main {\n\t@:overload(function())\n\tstatic function main() {\n\t\ttrace(@:privateAccess (X).object);\n\t}\n}';
		final mod:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(src);
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(mod, opts);
		Assert.equals(src, out);
	}

	private function expectExprStmt(stmt:HxStatement):HxExpr {
		return switch stmt {
			case ExprStmt(expr): expr;
			case _: throw 'expected ExprStmt, got $stmt';
		};
	}

	private function expectCallArgs(expr:HxExpr):Array<HxExpr> {
		return switch expr {
			case Call(_, args): args;
			case _: throw 'expected Call, got $expr';
		};
	}

	private function expectMetaExpr(expr:HxExpr):HxMetaExpr {
		return switch expr {
			case MetaExpr(v): v;
			case _: throw 'expected MetaExpr, got $expr';
		};
	}

	private function assertIdentExpr(expr:HxExpr, expected:String):Void {
		switch expr {
			case IdentExpr(v): Assert.equals(expected, (v : String));
			case _: Assert.fail('expected IdentExpr($expected), got $expr');
		}
	}
}
