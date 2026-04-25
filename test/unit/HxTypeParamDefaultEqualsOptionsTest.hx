package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice ω-typeparam-default-equals — runtime-switchable
 * `typeParamDefaultEquals` whitespace policy for the `=` joining a
 * declare-site type-parameter to its default type
 * (`HxTypeParamDecl.defaultValue`'s lead). `WhitespacePolicy.Both`
 * (default) emits `<T = Int>`, matching haxe-formatter's
 * `whitespace.binopPolicy: @:default(Around)`. `WhitespacePolicy.None`
 * collapses to `<T=Int>`, matching the
 * `issue_650_default_type_parameter_none` corpus variant
 * (`whitespace.binopPolicy: "none"`).
 *
 * The knob is wired via `@:fmt(typeParamDefaultEquals)` on
 * `HxTypeParamDecl.defaultValue` only — regression tests below assert
 * that the optional `=` leads on `HxVarDecl.init` and
 * `HxParam.defaultValue` keep their pre-slice ` = ` layout regardless
 * of the configured type-param-default policy. They flow through the
 * bare-optional fallback path in `lowerStruct` rather than through
 * `whitespacePolicyLead`.
 *
 * The JSON loader maps `whitespace.binopPolicy` to this knob — upstream's
 * `binopPolicy` controls every binary operator, but the writer only
 * exposes the type-param-default site as a per-field knob today, so
 * that one routing covers the corpus need.
 */
@:nullSafety(Strict)
final class HxTypeParamDefaultEqualsOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testTypeParamDefaultEqualsDefaultIsBoth():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.Both, defaults.typeParamDefaultEquals);
	}

	public function testTypeParamDefaultEqualsBothEmitsSpacedEquals():Void {
		final out:String = writeWith('class C<T = Int> {}', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('class C<T = Int> {}') != -1, 'expected `class C<T = Int> {}` in: <$out>');
	}

	public function testTypeParamDefaultEqualsNoneEmitsTightEquals():Void {
		final out:String = writeWith('class C<T = Int> {}', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('class C<T=Int> {}') != -1, 'expected `class C<T=Int> {}` in: <$out>');
		Assert.isTrue(out.indexOf('T = Int') == -1, 'did not expect spaced `=` in: <$out>');
	}

	public function testTypeParamDefaultEqualsBeforeEmitsSpaceBefore():Void {
		final out:String = writeWith('class C<T = Int> {}', WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('class C<T =Int> {}') != -1, 'expected `class C<T =Int> {}` in: <$out>');
	}

	public function testTypeParamDefaultEqualsAfterEmitsSpaceAfter():Void {
		final out:String = writeWith('class C<T = Int> {}', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('class C<T= Int> {}') != -1, 'expected `class C<T= Int> {}` in: <$out>');
	}

	public function testConstraintAndDefaultBoth():Void {
		final out:String = writeWith('class C<T:Foo = Bar> {}', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('class C<T:Foo = Bar> {}') != -1, 'expected `class C<T:Foo = Bar> {}` in: <$out>');
	}

	public function testConstraintAndDefaultNone():Void {
		final out:String = writeWith('class C<T:Foo = Bar> {}', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('class C<T:Foo=Bar> {}') != -1, 'expected `class C<T:Foo=Bar> {}` in: <$out>');
	}

	public function testMultipleTypeParamsMixedDefaultsNone():Void {
		final out:String = writeWith('class C<S = Int, T = String> {}', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('class C<S=Int, T=String> {}') != -1,
			'expected `class C<S=Int, T=String> {}` in: <$out>');
	}

	public function testTypedefTypeParamDefaultNone():Void {
		final out:String = writeWith('typedef Pair<T = Int> = {a:T};', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('Pair<T=Int>') != -1, 'expected `Pair<T=Int>` in: <$out>');
	}

	public function testFunctionTypeParamDefaultNone():Void {
		final out:String = writeWith('class C { function f<T = Int>():Void {} }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('function f<T=Int>():Void') != -1,
			'expected `function f<T=Int>():Void` in: <$out>');
	}

	public function testVarInitAssignStaysSpacedRegardlessOfPolicy():Void {
		assertSpacedUnderAllPolicies('class C<T = Int> { var x:Int = 0; }', 'var x:Int = 0;', 'var init');
	}

	public function testFunctionParamDefaultStaysSpacedRegardlessOfPolicy():Void {
		assertSpacedUnderAllPolicies('class C<T = Int> { function f(x:Int = 0):Void {} }', 'x:Int = 0', 'param default');
	}

	public function testTypedefAssignStaysSpacedRegardlessOfTypeParamPolicy():Void {
		assertSpacedUnderAllPolicies('typedef Foo<T = Int> = Bar;', '= Bar;', 'typedef-rhs');
	}

	public function testJsonBinopPolicyNoneMapsToTypeParamDefaultEqualsNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"binopPolicy": "none"}}'
		);
		Assert.equals(WhitespacePolicy.None, opts.typeParamDefaultEquals);
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('class C<T = Int> {}'), opts);
		Assert.isTrue(out.indexOf('class C<T=Int> {}') != -1, 'expected tight `<T=Int>` in: <$out>');
	}

	public function testJsonBinopPolicyAroundMapsToTypeParamDefaultEqualsBoth():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"binopPolicy": "around"}}'
		);
		Assert.equals(WhitespacePolicy.Both, opts.typeParamDefaultEquals);
	}

	public function testJsonOmittedKeepsBaseDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(WhitespacePolicy.Both, opts.typeParamDefaultEquals);
	}

	private inline function writeWith(src:String, typeParamDefaultEquals:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(typeParamDefaultEquals));
	}

	private inline function makeOpts(typeParamDefaultEquals:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.typeParamDefaultEquals = typeParamDefaultEquals;
		return opts;
	}

	private inline function assertSpacedUnderAllPolicies(src:String, expected:String, label:String):Void {
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith(src, policy);
			Assert.isTrue(out.indexOf(expected) != -1,
				'$label `=` should stay spaced under typeParamDefaultEquals $policy in: <$out>');
		}
	}
}
