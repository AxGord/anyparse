package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxEnumCtor;
import anyparse.grammar.haxe.HxEnumCtorDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxIdentLit;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxParam;
import anyparse.grammar.haxe.HxParamBody;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxTopLevelDecl;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;
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

	/**
	 * Idempotency round-trip check: `write(parse(write(parse(s))))`
	 * must equal `write(parse(s))`. The first write normalises formatting;
	 * the second must produce identical output.
	 */
	private function roundTrip(source:String, ?label:String):Void {
		final written1:String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		final written2:String = try {
			HxModuleWriter.write(HaxeModuleParser.parse(written1));
		} catch (exception:Exception) {
			Assert.fail('reparse failed for ${label ?? source}: written1=<$written1>, err=${exception.message}');
			return;
		}
		Assert.equals(written1, written2, 'idempotency failed for ${label ?? source}');
	}

	private function parseSingleVarDecl(source:String):HxVarDecl {
		final ast:HxClassDecl = HaxeParser.parse(source);
		Assert.equals(1, ast.members.length);
		return expectVarMember(ast.members[0].member);
	}

	private function parseSingleFnDecl(source:String):HxFnDecl {
		final ast:HxClassDecl = HaxeParser.parse(source);
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

	private function expectClassDecl(wrapper:HxTopLevelDecl):HxClassDecl {
		return switch wrapper.decl {
			case ClassDecl(c): c;
			case _: throw 'expected ClassDecl, got ${wrapper.decl}';
		};
	}

	private function expectTypedefDecl(wrapper:HxTopLevelDecl):HxTypedefDecl {
		return switch wrapper.decl {
			case TypedefDecl(td): td;
			case _: throw 'expected TypedefDecl, got ${wrapper.decl}';
		};
	}

	private function expectEnumDecl(wrapper:HxTopLevelDecl):HxEnumDecl {
		return switch wrapper.decl {
			case EnumDecl(ed): ed;
			case _: throw 'expected EnumDecl, got ${wrapper.decl}';
		};
	}

	private function expectInterfaceDecl(wrapper:HxTopLevelDecl):HxInterfaceDecl {
		return switch wrapper.decl {
			case InterfaceDecl(id): id;
			case _: throw 'expected InterfaceDecl, got ${wrapper.decl}';
		};
	}

	private function expectAbstractDecl(wrapper:HxTopLevelDecl):HxAbstractDecl {
		return switch wrapper.decl {
			case AbstractDecl(ad): ad;
			case _: throw 'expected AbstractDecl, got ${wrapper.decl}';
		};
	}

	private function fnBodyStmts(fn:HxFnDecl):Array<HxStatement> {
		return switch fn.body {
			case BlockBody(block): block.stmts;
			case NoBody: throw 'expected BlockBody, got NoBody';
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

	/**
	 * Unwrap an `HxParam` enum to the shared body when the variant
	 * is `Required`. Throws on `Optional`.
	 *
	 * `HxParam` is an Alt-enum split — `Required(body)` vs
	 * `Optional(body)` — to carry the `?name:Type` marker. Most call
	 * sites only care about the `name`/`type`/`defaultValue` body and
	 * already know which variant they expect; this helper keeps those
	 * sites readable without an inline switch.
	 */
	private function expectRequiredParam(param:HxParam):HxParamBody {
		return switch param {
			case Required(body): body;
			case Optional(_): throw 'expected HxParam.Required, got Optional';
		};
	}

	/**
	 * Unwrap an `HxParam` enum to the shared body when the variant
	 * is `Optional`. Throws on `Required`. See `expectRequiredParam`.
	 */
	private function expectOptionalParam(param:HxParam):HxParamBody {
		return switch param {
			case Optional(body): body;
			case Required(_): throw 'expected HxParam.Optional, got Required';
		};
	}

	/**
	 * Unwrap an `HxParam` to the shared body regardless of variant.
	 *
	 * Use when the assertion only cares about `name`/`type`/`defaultValue`
	 * and the `Required` vs `Optional` distinction is irrelevant for the
	 * test (e.g. type-position tests that exercise `HxType` shapes
	 * through parameter types).
	 */
	private function paramBody(param:HxParam):HxParamBody {
		return switch param {
			case Required(body) | Optional(body): body;
		};
	}

	/**
	 * Unwrap a `HxType.Named` to its underlying `HxTypeRef`.
	 *
	 * Accepts `Null<HxType>` so optional type-position fields
	 * (`HxFnDecl.returnType`, `HxVarDecl.type`, `HxLambdaParam.type`)
	 * can be unwrapped at the assertion site without a separate
	 * non-null guard. Throws on null, on `Arrow` (function-arrow
	 * type), and on any future non-`Named` variant — callers asserting
	 * arrow shape should switch on `HxType` directly.
	 */
	private function expectNamedType(t:Null<HxType>):HxTypeRef {
		return switch t {
			case null: throw 'expected HxType.Named, got null';
			case Named(ref): ref;
			case _: throw 'expected HxType.Named, got non-Named variant';
		};
	}
}
