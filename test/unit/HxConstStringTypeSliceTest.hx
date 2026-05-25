package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxDoubleStringLit;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;

/**
 * Phase 3 Slice 21 — string-literal const type parameter (`HxType.ConstStringType`).
 *
 * Covers the new `ConstStringType(v:HxDoubleStringLit)` atom branch on
 * `HxType` — the corpus blocker driver is `whitespace/issue_39_space_in_const_type_parameter`
 * (`abstract Tls<T>(hl.Abstract<"hl_tls">) {}`), where the underlying-type
 * slot contains a const-string type-param at one of its inner positions.
 * Dispatch is by `HxDoubleStringLit`'s `@:re '"…"'` regex (no `@:lead`
 * needed — `"` is not the legal start of any other `HxType` atom).
 */
class HxConstStringTypeSliceTest extends HxTestHelpers {

	private function expectConstString(t:Null<HxType>):HxDoubleStringLit {
		return switch t {
			case null: throw 'expected HxType.ConstStringType, got null';
			case ConstStringType(v): v;
			case _: throw 'expected HxType.ConstStringType, got non-ConstStringType variant';
		};
	}

	public function testConstStringInTypeParam():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Tls<T>(hl.Abstract<"hl_tls">) {}');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		final inner:HxTypeRef = expectNamedType(ad.underlyingType);
		Assert.equals('hl.Abstract', (inner.name : String));
		Assert.notNull(inner.params);
		Assert.equals(1, inner.params.length);
		final lit:HxDoubleStringLit = expectConstString(inner.params[0].type);
		Assert.equals('"hl_tls"', (lit : String));
	}

	public function testConstStringInVarType():Void {
		// Const-string type-param at a regular use-site (var-decl type slot).
		final module:HxModule = HaxeModuleParser.parse('class Foo { var x:hl.Abstract<"hl_tls">; }');
		Assert.equals(1, module.decls.length);
	}

	public function testNonConstStringTypeParamRegression():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo<T>(Array<Int>) {}');
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		final inner:HxTypeRef = expectNamedType(ad.underlyingType);
		Assert.equals('Array', (inner.name : String));
		Assert.equals(1, inner.params.length);
		Assert.equals('Int', (expectNamedType(inner.params[0].type).name : String));
	}

	public function testRoundTripIssue39():Void {
		// Exact issue_39 fixture body — full corpus driver.
		roundTrip('abstract Tls<T>(hl.Abstract<"hl_tls">) {}', 'issue_39-string-typeparam');
	}

	public function testRoundTripEscapeSequence():Void {
		// `@:rawString` keeps escape sequences verbatim, no decode/re-encode.
		roundTrip('abstract Tls<T>(hl.Abstract<"a\\nb">) {}', 'const-string-with-escape');
	}

	public function testRoundTripMultipleParams():Void {
		// Const-string alongside a regular named type-param.
		roundTrip('class Foo { var x:Map<"key", Int>; }', 'const-string-with-named-sibling');
	}
}
