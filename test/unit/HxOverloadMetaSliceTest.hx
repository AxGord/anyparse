package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for `@:overload(function...)` metadata args going through the
 * generic structural `MetaCall` branch (`HxMetadata.MetaCall`) — the
 * function expression argument routes through the standard `HxExpr`
 * pipeline (`HxExpr.FnExpr` → `HxFnExpr`). Format-driven knobs
 * (`typeHintColon`, `anonFuncParens`, etc.) apply uniformly via the
 * same code path that handles regular call arguments.
 *
 * Companion fixture: `whitespace/issue_184_type_hint_in_overload.hxtest`
 * — flips from byte-diff @ 40 to PASS once the structural branch
 * tightens the type-hint colons via `HxLambdaParam.type` / `HxFnExpr.returnType`.
 *
 * The fallback `PlainMeta` path is exercised by `HxToplevelMetaSliceTest`
 * for inputs whose args don't parse as `HxExpr` (deeply nested or
 * string-edge-case shapes).
 */
class HxOverloadMetaSliceTest extends HxTestHelpers {

	public function testParsesOverloadAsStructuralVariant():Void {
		final src:String = 'class M {\n\t@:overload(function<T>(key:String):T {})\n\tfunction get<T>(key:String):Null<T>;\n}';
		final ast:HxModule = HaxeModuleParser.parse(src);
		final m:HxMetadata = expectClassMembers(ast)[0].meta[0];
		switch m {
			case MetaCall(call):
				Assert.equals('@:overload', (call.name : String));
				Assert.equals(1, call.args.length);
				switch call.args[0] {
					case FnExpr(_): Assert.pass();
					case _: Assert.fail('expected FnExpr arg, got ${call.args[0]}');
				}
			case _: Assert.fail('expected MetaCall, got $m');
		}
	}

	public function testParsesNonOverloadAsGenericMeta():Void {
		// Post ω-generic-meta: `@:keep` (and any other non-overload @-led
		// meta) parses through the structural `Meta(name)` branch instead
		// of `PlainMeta`. PlainMeta is reached only when both `MetaCall`
		// and `Meta` tryBranches fail (deeply nested or string-edge-case
		// input).
		final ast:HxModule = HaxeModuleParser.parse('@:keep class M {}');
		final m:HxMetadata = ast.decls[0].meta[0];
		switch m {
			case Meta(_): Assert.pass();
			case _: Assert.fail('expected Meta, got $m');
		}
	}

	public function testWriterTightensTypeHintColons():Void {
		final src:String = 'class M {\n\t@:overload(function<T>(key : String, defaultValue : T):T {})\n\tfunction get<T>(key:String):Null<T>;\n}';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('key:String') >= 0);
		Assert.isTrue(out.indexOf('defaultValue:T') >= 0);
		Assert.isFalse(out.indexOf('key : String') >= 0);
		Assert.isFalse(out.indexOf('defaultValue : T') >= 0);
	}

	public function testWriterEmitsNoSpaceBetweenFunctionAndTypeParams():Void {
		final src:String = 'class M {\n\t@:overload(function<T>(key:String):T {})\n\tfunction get<T>(key:String):Null<T>;\n}';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('function<T>') >= 0);
	}

	public function testWriterEmitsNoSpaceBetweenFunctionAndOpenParen():Void {
		final src:String = 'class M {\n\t@:overload(function(key:String):T {})\n\tfunction get(key:String):Null<T>;\n}';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('function(') >= 0);
	}

	public function testRoundTripStructuralOverload():Void {
		final src:String = 'class M {\n\t@:overload(function<T>(key:String):T {})\n\tfunction get<T>(key:String):Null<T>;\n}';
		roundTrip(src);
	}

	public function testRoundTripBodylessOverload():Void {
		// Body-less form `@:overload(function())` parses through `MetaCall`
		// → `HxExpr.FnExpr` with `body=null` via `@:absentOn` peek-ahead.
		// Before the body-less unlock this rolled back to verbatim
		// `PlainMeta` because the function-decl body was mandatory.
		final src:String = 'class M {\n\t@:overload(function())\n\tfunction get():Void;\n}';
		roundTrip(src);
	}

	public function testWriterEmitsSpaceBeforeParenWhenAnonFuncParensBefore():Void {
		// Body-bearing form so the structural `MetaCall` → `FnExpr` path
		// fires — `anonFuncParens` is wired on `HxExpr.FnExpr`'s `function`
		// keyword, so the kw-trailing space emits when the policy is
		// `Before` / `Both`.
		final src:String = 'class M {\n\t@:overload(function():Void {})\n\tfunction main();\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"parenConfig": {"anonFuncParamParens": {"openingPolicy": "before"}}}}');
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('@:overload(function ()') >= 0,
			'expected `@:overload(function ()` under anonFuncParens=Before in: <$out>');
	}

	public function testWriterDefaultKeepsTightOverloadParen():Void {
		final src:String = 'class M {\n\t@:overload(function():Void {})\n\tfunction main();\n}';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('@:overload(function()') >= 0,
			'expected default tight `function()` inside `@:overload(...)` in: <$out>');
	}

	private function expectClassMembers(ast:HxModule) {
		return switch ast.decls[0].decl {
			case ClassDecl(c): c.members;
			case _: throw 'expected ClassDecl, got ${ast.decls[0].decl}';
		};
	}

}
