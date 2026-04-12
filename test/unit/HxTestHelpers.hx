package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxFnDecl;
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
}
