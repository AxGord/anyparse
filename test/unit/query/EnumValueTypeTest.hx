package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * Whether a read off a type name is a value of the type written with no type, an enum-abstract value of that type
 * (`AbstractCasts.holdsUntypedValue`; Haxe 4.3.7 `--interp`, FU24 probes) — in every `#if` branch of the declaration, or
 * not at all.
 */
@:nullSafety(Strict)
class EnumValueTypeTest extends Test {

	private static final FIXTURE: String = 'package p;\n\nenum abstract E(Int) {\n\tvar A = 1;\n\tfinal B = 2;\n\tvar C:E = 3;\n'
		+ '\tstatic var D = 4;\n}\n\n@:enum abstract L(Int) {\n\tvar A = 1;\n}\n\n#if js\nenum abstract F(Int) {\n\tvar A = 1;\n}\n'
		+ '#else\nenum abstract F(String) {\n\tvar A = \'a\';\n}\n#end\n\n#if js\nenum abstract J(Int) {\n\tvar A = 1;\n}\n#else\n'
		+ 'enum abstract J(Int) {\n\tvar B = 1;\n}\n#end\n\n#if js\nenum abstract G(Int) {\n\tvar A = 1;\n}\n#else\n'
		+ 'typedef G = flash.text.Other;\n#end\n\nenum abstract H(Int) {\n#if js\n\tvar A = 1;\n#end\n}\n';

	/**
	 * `var` and `final` values written with no type are values of `E`, and of the deprecated `@:enum abstract L`; an
	 * annotated value carries its annotation instead (`MemberLookup.memberRead`), and a static is no value.
	 */
	@:pin('control') @:killer('M-ENUM-VALUE-UNTYPED') @:killer('M-ENUM-VALUE-STATIC')
	public function testAValueWrittenWithNoTypeIsOfItsEnumAbstract(): Void {
		final index: SymbolIndex = indexOf();
		Assert.isTrue(untypedValue(index, 'E', 'A'));
		Assert.isTrue(untypedValue(index, 'E', 'B'), 'a `final` value');
		Assert.isFalse(untypedValue(index, 'E', 'C'), 'an annotated value');
		Assert.isFalse(untypedValue(index, 'E', 'D'), 'a static field');
		Assert.isTrue(untypedValue(index, 'L', 'A'), 'the deprecated `@:enum abstract`');
	}

	/**
	 * Every branch must declare the value: `F.A` is one in both builds; `J.A` exists in one, a `typedef` branch of `G` is
	 * another type's, and `H.A` is under `#if` — none is.
	 */
	@:pin('control') @:killer('M-ENUM-VALUE-EVERY-BRANCH') @:killer('M-ENUM-VALUE-UNREAD-BRANCHES') @:killer('M-ENUM-VALUE-GUARDED')
	public function testEveryBranchMustDeclareTheValue(): Void {
		final index: SymbolIndex = indexOf();
		Assert.isTrue(untypedValue(index, 'F', 'A'));
		Assert.isFalse(untypedValue(index, 'J', 'A'), 'one branch only');
		Assert.isFalse(untypedValue(index, 'G', 'A'), 'a typedef branch');
		Assert.isFalse(untypedValue(index, 'H', 'A'), 'a value under `#if`');
	}

	private static function untypedValue(index: SymbolIndex, type: String, member: String): Bool {
		final found: Null<ResolvedType> = index.refs.findDeclaredType('p/M.hx', type);
		if (found == null) throw 'no declaration $type';
		return index.typing.casts.holdsUntypedValue(found, member);
	}

	private static function indexOf(): SymbolIndex {
		return CheckFixture.index([{ file: 'p/M.hx', source: FIXTURE }], new HaxeQueryPlugin());
	}

}
