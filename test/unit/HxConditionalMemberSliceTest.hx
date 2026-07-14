package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxConditionalMember;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxMemberDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.runtime.ParseError;

/**
 * Slice apq-P5-J: member-scope `#if` conditional compilation.
 *
 * `HxClassMember` gained a `Conditional(HxConditionalMember)` ctor —
 * the member-scope completion of the cond-comp arc (decl / stmt /
 * modifier scopes already shipped). `#if <cond> <members> [#elseif …]
 * [#else …] #end` now parses where whole class / interface / abstract
 * member declarations are expected, unblocking apq self-parse of
 * anyparse source that guards members with `#if sys` / `#if macro`.
 *
 * Covers the single-branch / else / elseif / nested / empty-body
 * shapes, the no-conditional regression (the new ctor must not perturb
 * existing member dispatch), the real dogfood shape (`Glob.hx`'s
 * `#if sys` method between two methods), and that the single
 * `HxClassMember` edit reaches class + interface + abstract bodies.
 */
class HxConditionalMemberSliceTest extends HxTestHelpers {

	// -- `#if` wrapping a single member inside a class --

	public function testSingleMemberConditional(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if sys\n\tfunction a():Void {}\n\t#end\n}');
		Assert.equals(1, cls.members.length);
		final cond: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals(1, cond.body.length);
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
		Assert.equals(0, cond.elseifs.length);
		Assert.isNull(cond.elseBody);
	}

	// -- A real member follows the conditional region --

	public function testConditionalThenPlainMember(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if sys\n\tfunction a():Void {}\n\t#end\n\tfunction b():Void {}\n}');
		Assert.equals(2, cls.members.length);
		final cond: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
		Assert.equals('b', (expectFnMember(cls.members[1].member).name: String));
	}

	// -- `#if … #else …` two-branch --

	public function testConditionalElse(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if js\n\tfunction a():Void {}\n\t#else\n\tfunction b():Void {}\n\t#end\n}');
		Assert.equals(1, cls.members.length);
		final cond: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('js', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
		final elseBody: Null<Array<HxMemberDecl>> = cond.elseBody;
		Assert.notNull(elseBody);
		if (elseBody != null) {
			Assert.equals(1, elseBody.length);
			Assert.equals('b', (expectFnMember(elseBody[0].member).name: String));
		}
	}

	// -- `#elseif` chained clause --

	public function testConditionalElseif(): Void {
		final cls: HxClassDecl = classMembersOf(
			'class C {\n\t#if js\n\tfunction a():Void {}\n\t#elseif sys\n\tfunction b():Void {}\n\t#else\n\tfunction c():Void {}\n\t#end\n}'
		);
		Assert.equals(1, cls.members.length);
		final cond: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('js', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
		Assert.equals(1, cond.elseifs.length);
		Assert.equals('sys', (cond.elseifs[0].cond: String));
		Assert.equals('b', (expectFnMember(cond.elseifs[0].body[0].member).name: String));
		final elseBody: Null<Array<HxMemberDecl>> = cond.elseBody;
		Assert.notNull(elseBody);
		if (elseBody != null) Assert.equals('c', (expectFnMember(elseBody[0].member).name: String));
	}

	// -- Nested `#if` inside the body --

	public function testNestedConditional(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if sys\n\t#if js\n\tfunction a():Void {}\n\t#end\n\t#end\n}');
		Assert.equals(1, cls.members.length);
		final outer: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('sys', (outer.cond: String));
		Assert.equals(1, outer.body.length);
		final inner: HxConditionalMember = expectConditionalMember(outer.body[0].member);
		Assert.equals('js', (inner.cond: String));
		Assert.equals('a', (expectFnMember(inner.body[0].member).name: String));
	}

	// -- Empty body `#if X #end` is rejected — consistent with decl scope --
	//
	// An empty conditional body (no members between `#if cond` and the
	// terminator) is a known limitation SHARED with the decl-scope
	// precedent: `HaxeModuleParser.parse('#if sys\n#end\n')` throws
	// `expected HxDecl` for the exact same reason. The `@:tryparse`
	// member Star, asked to parse zero elements, runs `HxMemberDecl`'s
	// empty meta + modifier prefix Stars (consume nothing) then hits the
	// mandatory `member:HxClassMember` field, which throws on the
	// terminator. Member scope mirrors `HxConditionalDecl` faithfully —
	// this is not a member-scope regression. No real anyparse / dogfood
	// source has an empty `#if X #end` member body (they always wrap real
	// members). Lifting this would require a core Lowering change to the
	// tryparse-Star-of-struct-element rollback, affecting decl + stmt +
	// member scopes uniformly — out of this slice's additive scope. The
	// test pins the actual contract so a future decl-scope fix updates
	// both consistently.

	public function testEmptyConditionalBodyRejectedLikeDeclScope(): Void {
		Assert.raises(classMembersOf.bind('class C {\n\t#if sys\n\t#end\n}'), ParseError);
	}

	// -- Regression: a class with NO member-`#if` is unaffected --

	public function testNoConditionalRegression(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\tvar x:Int;\n\tfunction f():Void {}\n}');
		Assert.equals(2, cls.members.length);
		Assert.equals('x', (expectVarMember(cls.members[0].member).name: String));
		Assert.equals('f', (expectFnMember(cls.members[1].member).name: String));
	}

	// -- Dogfood shape: the `Glob.hx` pattern --

	public function testDogfoodGlobShape(): Void {
		final cls: HxClassDecl = classMembersOf(
			'class Glob {\n\tpublic static function expand():Void {}\n\t#if sys\n\tprivate static function collect():Void {}\n\t#end\n}'
		);
		Assert.equals(2, cls.members.length);
		Assert.equals('expand', (expectFnMember(cls.members[0].member).name: String));
		final cond: HxConditionalMember = expectConditionalMember(cls.members[1].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals('collect', (expectFnMember(cond.body[0].member).name: String));
	}

	// -- The single ctor reaches interface bodies --

	public function testInterfaceMemberConditional(): Void {
		final module: HxModule = HaxeModuleParser.parse('interface I {\n\t#if sys\n\tfunction a():Void;\n\t#end\n}');
		final iface: HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, iface.members.length);
		final cond: HxConditionalMember = expectConditionalMember(iface.members[0].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
	}

	// -- The single ctor reaches abstract bodies --

	public function testAbstractMemberConditional(): Void {
		final module: HxModule = HaxeModuleParser.parse('abstract A(Int) {\n\t#if sys\n\tpublic function a():Void {}\n\t#end\n}');
		final abs: HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(1, abs.members.length);
		final cond: HxConditionalMember = expectConditionalMember(abs.members[0].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
	}

	private function classMembersOf(source: String): HxClassDecl {
		return HaxeParser.parse(source);
	}

}
