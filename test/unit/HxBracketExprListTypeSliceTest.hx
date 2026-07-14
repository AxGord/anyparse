package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;
import anyparse.grammar.haxe.HxTypedefDecl;

/**
 * Phase 3 Slice 23 — macro-expression bracket list in a type-parameter
 * slot (`HxType.BracketExprListType`).
 *
 * Covers the new `BracketExprListType(elems:Array<HxExpr>)` atom branch
 * on `HxType` — the corpus blocker driver is
 * `whitespace/issue_622_bracket`
 * (`private typedef Init = haxe.macro.MacroType<[cdb.Module.build("data.cdb")]>;`),
 * where the type-parameter slot of `haxe.macro.MacroType<T>` carries a
 * comma-separated list of expressions in `[…]` brackets. Dispatch is by
 * the `[` lead — no other `HxType` atom begins with `[`.
 */
class HxBracketExprListTypeSliceTest extends HxTestHelpers {

	public function testBracketTypeParamSingle(): Void {
		final module: HxModule = HaxeModuleParser.parse('private typedef Init = haxe.macro.MacroType<[cdb.Module.build("data.cdb")]>;');
		Assert.equals(1, module.decls.length);
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final ref: HxTypeRef = expectNamedType(td.type);
		Assert.equals('haxe.macro.MacroType', (ref.name: String));
		Assert.notNull(ref.params);
		Assert.equals(1, ref.params.length);
		final elems: Array<HxExpr> = expectBracketExprList(ref.params[0].type);
		Assert.equals(1, elems.length);
	}

	public function testBracketTypeParamEmpty(): Void {
		// Empty `<[]>` — structural completeness, no corpus fixture exercises it.
		final module: HxModule = HaxeModuleParser.parse('typedef Init = haxe.macro.MacroType<[]>;');
		Assert.equals(1, module.decls.length);
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final ref: HxTypeRef = expectNamedType(td.type);
		final elems: Array<HxExpr> = expectBracketExprList(ref.params[0].type);
		Assert.equals(0, elems.length);
	}

	public function testBracketTypeParamMulti(): Void {
		// Multi-element body — parses; byte-emit fmt deferred (no multi corpus fixture).
		final module: HxModule = HaxeModuleParser.parse('typedef Init = haxe.macro.MacroType<[a, b]>;');
		Assert.equals(1, module.decls.length);
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final ref: HxTypeRef = expectNamedType(td.type);
		final elems: Array<HxExpr> = expectBracketExprList(ref.params[0].type);
		Assert.equals(2, elems.length);
	}

	public function testNonBracketTypeParamRegression(): Void {
		// Non-bracket type-params still parse as before.
		final module: HxModule = HaxeModuleParser.parse('typedef T = Array<Int>;');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final ref: HxTypeRef = expectNamedType(td.type);
		Assert.equals('Array', (ref.name: String));
		Assert.equals(1, ref.params.length);
		Assert.equals('Int', (expectNamedType(ref.params[0].type).name: String));
	}

	public function testRoundTripIssue622(): Void {
		// Exact issue_622_bracket fixture body — full corpus driver.
		roundTrip('private typedef Init = haxe.macro.MacroType<[cdb.Module.build("data.cdb")]>;', 'issue_622-bracket-typeparam');
	}

	private function expectBracketExprList(t: Null<HxType>): Array<HxExpr> {
		return switch t {
			case null: throw 'expected HxType.BracketExprListType, got null';
			case BracketExprListType(elems): elems;
			case _: throw 'expected HxType.BracketExprListType, got non-BracketExprListType variant';
		};
	}

}
