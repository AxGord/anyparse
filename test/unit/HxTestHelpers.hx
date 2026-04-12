package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxEnumCtor;
import anyparse.grammar.haxe.HxEnumCtorDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxIdentLit;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxTypedefDecl;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Shared test helpers for Phase 3 Haxe grammar tests.
 *
 * Provides common destructuring helpers used across multiple Hx*SliceTest
 * files. Extend this class instead of `utest.Test` directly to avoid
 * duplicating these methods in every test file.
 */
class HxTestHelpers extends Test {

	private function parseSingleVarDecl(source:String):HxVarDecl {
		final ast:HxClassDecl = HaxeFastParser.parse(source);
		Assert.equals(1, ast.members.length);
		return expectVarMember(ast.members[0].member);
	}

	private function parseSingleFnDecl(source:String):HxFnDecl {
		final ast:HxClassDecl = HaxeFastParser.parse(source);
		Assert.equals(1, ast.members.length);
		return expectFnMember(ast.members[0].member);
	}

	private function expectVarMember(member:HxClassMember):HxVarDecl {
		return switch member {
			case VarMember(decl): decl;
			case _: throw 'expected VarMember, got $member';
		};
	}

	private function expectFnMember(member:HxClassMember):HxFnDecl {
		return switch member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember, got $member';
		};
	}

	private function expectClassDecl(decl:HxDecl):HxClassDecl {
		return switch decl {
			case ClassDecl(c): c;
			case _: throw 'expected ClassDecl, got $decl';
		};
	}

	private function expectTypedefDecl(decl:HxDecl):HxTypedefDecl {
		return switch decl {
			case TypedefDecl(td): td;
			case _: throw 'expected TypedefDecl, got $decl';
		};
	}

	private function expectEnumDecl(decl:HxDecl):HxEnumDecl {
		return switch decl {
			case EnumDecl(ed): ed;
			case _: throw 'expected EnumDecl, got $decl';
		};
	}

	private function expectInterfaceDecl(decl:HxDecl):HxInterfaceDecl {
		return switch decl {
			case InterfaceDecl(id): id;
			case _: throw 'expected InterfaceDecl, got $decl';
		};
	}

	private function expectSimpleCtor(ctor:HxEnumCtor):HxIdentLit {
		return switch ctor {
			case SimpleCtor(name): name;
			case _: throw 'expected SimpleCtor, got $ctor';
		};
	}

	private function expectParamCtor(ctor:HxEnumCtor):HxEnumCtorDecl {
		return switch ctor {
			case ParamCtor(decl): decl;
			case _: throw 'expected ParamCtor, got $ctor';
		};
	}
}
