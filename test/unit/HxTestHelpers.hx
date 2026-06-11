package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxAnonField;
import anyparse.grammar.haxe.HxAnonFieldBody;
import anyparse.grammar.haxe.HxAnonVarBody;
import anyparse.grammar.haxe.HxAnonMember;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxConditionalDecl;
import anyparse.grammar.haxe.HxConditionalMember;
import anyparse.grammar.haxe.HxConditionalObjectField;
import anyparse.grammar.haxe.HxConditionalParam;
import anyparse.grammar.haxe.HxConditionalStmt;
import anyparse.grammar.haxe.HxConditionalType;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxEnumCtor;
import anyparse.grammar.haxe.HxEnumCtorDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxEnumMember;
import anyparse.grammar.haxe.HxErrorMsg;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxIdentLit;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxLambdaParam;
import anyparse.grammar.haxe.HxLambdaParamBody;
import anyparse.grammar.haxe.HxMacroClass;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxObjectField;
import anyparse.grammar.haxe.HxObjectFieldBody;
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
	private function roundTrip(source: String, ?label: String): Void {
		final written1: String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		final written2: String = try {
			HxModuleWriter.write(HaxeModuleParser.parse(written1));
		} catch (exception: Exception) {
			Assert.fail('reparse failed for ${label ?? source}: written1=<$written1>, err=${exception.message}');
			return;
		}
		Assert.equals(written1, written2, 'idempotency failed for ${label ?? source}');
	}

	/**
	 * Byte-equality writer check: `write(parse(source))` must equal
	 * `expected`. Strictest writer assertion — catches every spurious
	 * space/newline. Idempotency alone (`roundTrip`) is not enough
	 * because a buggy output can round-trip to itself.
	 */
	private function writerEquals(source: String, expected: String, ?label: String): Void {
		final written: String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		Assert.equals(expected, written, 'writer-equals failed for ${label ?? source}');
	}

	private function parseSingleVarDecl(source: String): HxVarDecl {
		final ast: HxClassDecl = HaxeParser.parse(source);
		Assert.equals(1, ast.members.length);
		return expectVarMember(ast.members[0].member);
	}

	private function parseSingleFnDecl(source: String): HxFnDecl {
		final ast: HxClassDecl = HaxeParser.parse(source);
		Assert.equals(1, ast.members.length);
		return expectFnMember(ast.members[0].member);
	}

	private function expectVarMember(member: HxClassMember): HxVarDecl {
		return switch member {
			case VarMember(decl): decl;
			case _: throw 'expected VarMember, got $member';
		};
	}

	private function expectFnMember(member: HxClassMember): HxFnDecl {
		return switch member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember, got $member';
		};
	}

	private function expectConditionalMember(member: HxClassMember): HxConditionalMember {
		return switch member {
			case Conditional(inner): inner;
			case _: throw 'expected Conditional, got $member';
		};
	}

	private function expectConditionalDecl(decl: HxDecl): HxConditionalDecl {
		return switch decl {
			case Conditional(inner): inner;
			case _: throw 'expected Conditional, got $decl';
		};
	}

	private function expectConditionalStmt(stmt: HxStatement): HxConditionalStmt {
		return switch stmt {
			case Conditional(inner): inner;
			case _: throw 'expected Conditional, got $stmt';
		};
	}

	private function expectObjectFieldBody(field: HxObjectField): HxObjectFieldBody {
		return switch field {
			case Field(body): body;
			case _: throw 'expected Field, got $field';
		};
	}

	private function expectConditionalObjectField(field: HxObjectField): HxConditionalObjectField {
		return switch field {
			case Conditional(inner): inner;
			case _: throw 'expected Conditional, got $field';
		};
	}

	private function expectErrorDecl(decl: HxDecl): HxErrorMsg {
		return switch decl {
			case ErrorDecl(message): message;
			case _: throw 'expected ErrorDecl, got $decl';
		};
	}

	private function expectErrorMember(member: HxClassMember): HxErrorMsg {
		return switch member {
			case ErrorMember(message): message;
			case _: throw 'expected ErrorMember, got $member';
		};
	}

	private function expectErrorStmt(stmt: HxStatement): HxErrorMsg {
		return switch stmt {
			case ErrorStmt(message): message;
			case _: throw 'expected ErrorStmt, got $stmt';
		};
	}

	private function expectClassDecl(wrapper: HxTopLevelDecl): HxClassDecl {
		return switch wrapper.decl {
			case ClassDecl(c): c;
			case _: throw 'expected ClassDecl, got ${wrapper.decl}';
		};
	}

	private function expectTypedefDecl(wrapper: HxTopLevelDecl): HxTypedefDecl {
		return switch wrapper.decl {
			case TypedefDecl(td): td;
			case _: throw 'expected TypedefDecl, got ${wrapper.decl}';
		};
	}

	private function expectEnumDecl(wrapper: HxTopLevelDecl): HxEnumDecl {
		return switch wrapper.decl {
			case EnumDecl(ed): ed;
			case _: throw 'expected EnumDecl, got ${wrapper.decl}';
		};
	}

	private function expectInterfaceDecl(wrapper: HxTopLevelDecl): HxInterfaceDecl {
		return switch wrapper.decl {
			case InterfaceDecl(id): id;
			case _: throw 'expected InterfaceDecl, got ${wrapper.decl}';
		};
	}

	private function expectAbstractDecl(wrapper: HxTopLevelDecl): HxAbstractDecl {
		return switch wrapper.decl {
			case AbstractDecl(ad): ad;
			case _: throw 'expected AbstractDecl, got ${wrapper.decl}';
		};
	}

	private function expectEnumAbstractDecl(wrapper: HxTopLevelDecl): HxAbstractDecl {
		return switch wrapper.decl {
			case EnumAbstractDecl(ad): ad;
			case _: throw 'expected EnumAbstractDecl, got ${wrapper.decl}';
		};
	}

	private function fnBodyStmts(fn: HxFnDecl): Array<HxStatement> {
		return switch fn.body {
			case BlockBody(block): block.stmts;
			case UntypedBlockBody(body): body.block.stmts;
			case NoBody: throw 'expected BlockBody, got NoBody';
			case ExprBody(_): throw 'expected BlockBody, got ExprBody';
		};
	}

	private function expectSimpleCtor(ctor: HxEnumCtor): HxIdentLit {
		return switch ctor {
			case SimpleCtor(name): name;
			case _: throw 'expected SimpleCtor, got $ctor';
		};
	}

	private function expectParamCtor(ctor: HxEnumCtor): HxEnumCtorDecl {
		return switch ctor {
			case ParamCtor(decl): decl;
			case _: throw 'expected ParamCtor, got $ctor';
		};
	}

	/**
	 * Projects `HxEnumMember.ctor` out of each member so callers that
	 * don't care about leading metadata stay unchanged — the enum-body
	 * analog of `expectAnon`.
	 */
	private function enumCtors(ed: HxEnumDecl): Array<HxEnumCtor> {
		return [for (m in ed.ctors) m.ctor];
	}

	/**
	 * Returns the raw enum member list, each member exposing the
	 * leading metadata Star alongside the constructor. Use this when a
	 * test inspects `@:meta` prefixes — analog of `expectAnonMembers`.
	 */
	private function enumMembers(ed: HxEnumDecl): Array<HxEnumMember> {
		return ed.ctors;
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
	private function expectRequiredParam(param: HxParam): HxParamBody {
		return switch param {
			case Required(body): body;
			case Optional(_): throw 'expected HxParam.Required, got Optional';
			case Rest(_): throw 'expected HxParam.Required, got Rest';
			case Conditional(_): throw 'expected HxParam.Required, got Conditional';
		};
	}

	/**
	 * Unwrap an `HxParam` enum to the shared body when the variant
	 * is `Optional`. Throws on `Required`. See `expectRequiredParam`.
	 */
	private function expectOptionalParam(param: HxParam): HxParamBody {
		return switch param {
			case Optional(body): body;
			case Required(_): throw 'expected HxParam.Optional, got Required';
			case Rest(_): throw 'expected HxParam.Optional, got Rest';
			case Conditional(_): throw 'expected HxParam.Optional, got Conditional';
		};
	}

	/**
	 * Unwrap an `HxParam` enum to the shared body when the variant is
	 * `Rest` (`...name:Type` spread / varargs). Throws on `Required` /
	 * `Optional`. See `expectRequiredParam`.
	 */
	private function expectRestParam(param: HxParam): HxParamBody {
		return switch param {
			case Rest(body): body;
			case Required(_): throw 'expected HxParam.Rest, got Required';
			case Optional(_): throw 'expected HxParam.Rest, got Optional';
			case Conditional(_): throw 'expected HxParam.Rest, got Conditional';
		};
	}

	/**
	 * Unwrap an `HxParam.Conditional` to its inner `HxConditionalParam`.
	 * Throws on `Required` / `Optional` / `Rest`. Mirror of
	 * `expectConditionalObjectField` (Slice 18); the fn-param-scope twin
	 * of the cond-comp arc.
	 */
	private function expectConditionalParam(param: HxParam): HxConditionalParam {
		return switch param {
			case Conditional(inner): inner;
			case Required(_): throw 'expected HxParam.Conditional, got Required';
			case Optional(_): throw 'expected HxParam.Conditional, got Optional';
			case Rest(_): throw 'expected HxParam.Conditional, got Rest';
		};
	}

	/**
	 * Unwrap an `HxParam` to the shared body regardless of variant.
	 *
	 * Use when the assertion only cares about `name`/`type`/`defaultValue`
	 * and the `Required` vs `Optional` distinction is irrelevant for the
	 * test (e.g. type-position tests that exercise `HxType` shapes
	 * through parameter types). Throws on `Conditional` — cond-comp
	 * blocks carry no inline body and callers asserting param shape
	 * must switch on `HxParam` directly.
	 */
	private function paramBody(param: HxParam): HxParamBody {
		return switch param {
			case Required(body) | Optional(body) | Rest(body): body;
			case Conditional(_): throw 'expected HxParam.Required/Optional/Rest, got Conditional';
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
	private function expectNamedType(t: Null<HxType>): HxTypeRef {
		return switch t {
			case null: throw 'expected HxType.Named, got null';
			case Named(ref): ref;
			case _: throw 'expected HxType.Named, got non-Named variant';
		};
	}

	/**
	 * Asserts `t` is `HxType.ConditionalType` and returns the inner
	 * `HxConditionalType` body. Throws on null and on any other variant.
	 */
	private function expectConditionalType(t: Null<HxType>): HxConditionalType {
		return switch t {
			case null: throw 'expected HxType.ConditionalType, got null';
			case ConditionalType(c): c;
			case _: throw 'expected HxType.ConditionalType, got non-ConditionalType variant';
		};
	}

	/**
	 * Asserts `t` is `HxType.Anon` and returns the field-KIND list,
	 * projecting `HxAnonMember.field` out of each member so callers
	 * that don't care about leading metadata stay unchanged. Accepts
	 * `Null<HxType>` so callers can pass optional type slots (e.g.
	 * `HxVarDecl.type`) directly; throws on any non-Anon input.
	 */
	private function expectAnon(t: Null<HxType>): Array<HxAnonField> {
		return [for (m in expectAnonMembers(t)) m.field];
	}

	/**
	 * Asserts `t` is `HxType.Anon` and returns its raw member list,
	 * each member exposing the leading metadata Star alongside the
	 * field kind. Use this when a test inspects `@:meta` prefixes.
	 */
	private function expectAnonMembers(t: Null<HxType>): Array<HxAnonMember> {
		return switch t {
			case null: throw 'expected HxType.Anon, got null';
			case Anon(fields): fields;
			case _: throw 'expected HxType.Anon, got non-Anon variant';
		};
	}

	/**
	 * Asserts `field` is the `var` class-notation anon field kind and
	 * returns its `HxVarDecl`; throws on any other kind. The Slice 27
	 * `HxAnonVarBody` wrapper is unwrapped transparently — both
	 * `Optional(decl)` (`var ?name:Type`) and `Plain(decl)` collapse
	 * to the bare decl. Use `expectVarFieldOptional` when the test
	 * needs to discriminate the `?` flag.
	 */
	private function expectVarField(field: HxAnonField): HxVarDecl {
		return switch field {
			case VarField(Optional(decl)): decl;
			case VarField(Plain(decl)): decl;
			case _: throw 'expected HxAnonField.VarField, got $field';
		};
	}

	/**
	 * Asserts `field` is the `final` class-notation anon field kind
	 * and returns its `HxVarDecl`; throws on any other kind. Slice 27
	 * `HxAnonVarBody` wrapper is unwrapped transparently — see
	 * `expectVarField`.
	 */
	private function expectFinalField(field: HxAnonField): HxVarDecl {
		return switch field {
			case FinalField(Optional(decl)): decl;
			case FinalField(Plain(decl)): decl;
			case _: throw 'expected HxAnonField.FinalField, got $field';
		};
	}

	/**
	 * Asserts `field` is the `function` class-notation anon field kind
	 * and returns its `HxFnDecl`; throws on any other kind.
	 */
	private function expectFnField(field: HxAnonField): HxFnDecl {
		return switch field {
			case FnField(decl): decl;
			case _: throw 'expected HxAnonField.FnField, got $field';
		};
	}

	/**
	 * Asserts `field` is the `> Type` structure-extension anon clause
	 * and returns its `HxTypeRef`; throws on any other kind.
	 */
	private function expectExtendsField(field: HxAnonField): HxTypeRef {
		return switch field {
			case ExtendsField(type): type;
			case _: throw 'expected HxAnonField.ExtendsField, got $field';
		};
	}

	/**
	 * Asserts `field` is a short-form anon field (`name:Type` or
	 * `?name:Type`) and returns its `HxAnonFieldBody`; throws on any
	 * class-notation kind.
	 */
	private function expectShortFieldBody(field: HxAnonField): HxAnonFieldBody {
		return switch field {
			case Required(body): body;
			case Optional(body): body;
			case _: throw 'expected short HxAnonField, got $field';
		};
	}

	/**
	 * Unwraps a `HxLambdaParam` (`Optional` or `Required`) to its
	 * `HxLambdaParamBody`. The Slice 31 Alt-enum split made the bare
	 * `name` / `type` slots live one level deeper; this helper restores
	 * the pre-split call shape for tests that don't discriminate the
	 * `?` flag.
	 */
	private function lambdaParamBody(param: HxLambdaParam): HxLambdaParamBody {
		return switch param {
			case Optional(body): body;
			case Required(body): body;
		};
	}

	private function expectExprStmt(stmt: HxStatement): HxExpr {
		return switch stmt {
			case ExprStmt(expr): expr;
			case _: throw 'expected ExprStmt, got $stmt';
		};
	}

	private function expectMacroClassExpr(e: HxExpr): HxMacroClass {
		return switch e {
			case MacroClassExpr(v): v;
			case _: throw 'expected MacroClassExpr, got $e';
		};
	}

}
