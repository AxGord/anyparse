package anyparse.grammar.haxe.query;

import anyparse.grammar.haxe.decl.HxClassMember;
import anyparse.grammar.haxe.decl.HxParam;
import anyparse.grammar.haxe.meta.HxMemberModifier;
import anyparse.grammar.haxe.trivia.Pairs.Converters;
import anyparse.grammar.haxe.trivia.Pairs.HxClassMemberT;
import anyparse.grammar.haxe.trivia.Pairs.HxExprT;
import anyparse.grammar.haxe.trivia.Pairs.HxFnBodyT;
import anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT;
import anyparse.grammar.haxe.trivia.Pairs.HxMemberDeclT;
import anyparse.grammar.haxe.trivia.Pairs.HxModuleT;
import anyparse.grammar.haxe.trivia.Pairs.HxStatementT;
import anyparse.grammar.haxe.trivia.Pairs.HxTypeT;
import anyparse.grammar.haxe.trivia.Pairs.HxVarDeclT;
import anyparse.query.Constructs.Modifier;
import anyparse.runtime.ParseError;
import haxe.Exception;

/** The text around a part that makes it the one member of a class, so the part is read in the slot it fills. */
private typedef Slot = { final before: String; final after: String; }

/**
 * Typed trivia-mode Haxe nodes made from their parts: the one answer to "how is a Haxe member or statement built as a
 * typed node rather than spelled as text". A node is built of the plain grammar types and lifted by the generated
 * `Converters.rawToPaired_*`, so every trivia slot holds its no-source default and the writer lays the node out by its
 * own policy alone. A part that arrives as text (a copied source fragment, a construct built as text) is read by the
 * grammar in the slot it fills and keeps its own trivia.
 */
@:nullSafety(Strict)
final class HaxeNodes {

	private static final TYPE_SLOT: Slot = { before: 'class _C { var _v: ', after: '; }' };
	private static final VALUE_SLOT: Slot = { before: 'class _C { var _v = ', after: '; }' };
	private static final BODY_SLOT: Slot = { before: 'class _C { function _f() ', after: ' }' };

	/** The body of a method that has none: a declaration only. */
	public static inline function noBody(): HxFnBodyT {
		return NoBody;
	}

	/** A type member carrying `modifiers` in the order given. */
	public static function memberDecl(modifiers: Array<Modifier>, member: HxClassMemberT): HxMemberDeclT {
		final decl: HxMemberDeclT = Converters.rawToPaired_HxMemberDecl(
			{ meta: [], modifiers: modifiers.map(memberModifier), member: null }
		);
		decl.member = member;
		return decl;
	}

	/** A value `name` bound once, of `type` when given, initialised to `init` when given. */
	public static function constant(name: String, type: Null<HxTypeT>, init: Null<HxExprT>): HxClassMemberT {
		return FinalMember(varDecl(name, type, init), true);
	}

	/** A value `name` that may be reassigned, of `type` when given, initialised to `init` when given. */
	public static function variable(name: String, type: Null<HxTypeT>, init: Null<HxExprT>): HxClassMemberT {
		return VarMember(varDecl(name, type, init), true);
	}

	/** A method `name` taking `params`, each a name and its type, answering `result` when given, with `body`. */
	public static function method(
		name: String, params: Array<{ name: String, type: HxTypeT }>, result: Null<HxTypeT>, body: HxFnBodyT
	): HxClassMemberT {
		final decl: HxFnDeclT = Converters.rawToPaired_HxFnDecl({
			name: name,
			typeParams: null,
			params: params.map(param -> Required({ name: param.name, type: null, defaultValue: null })),
			returnType: null,
			body: NoBody
		});
		for (i in 0...params.length) switch decl.params[i].node {
			case Required(slot):
				slot.type = params[i].type;
			case _:
		}
		decl.returnType = result;
		decl.body = body;
		return FnMember(decl);
	}

	/** The statement that leaves the enclosing function with `value`. */
	public static function returnStmt(value: HxExprT): HxStatementT {
		return ReturnStmt(value, true, null, []);
	}

	/** The type `text` spells, read as a declared type; null when it is not one. */
	public static function typeOf(text: String): Null<HxTypeT> {
		return switch member(TYPE_SLOT, text) {
			case VarMember(decl, _) if (decl.more.length == 0): decl.type;
			case _: null;
		};
	}

	/** The expression `text` spells, read as an initial value; null when it is not one. */
	public static function valueOf(text: String): Null<HxExprT> {
		return switch member(VALUE_SLOT, text) {
			case VarMember(decl, _) if (decl.type == null && decl.more.length == 0): decl.init;
			case _: null;
		};
	}

	/** The method body the statement `text` spells; null when it is not one. */
	public static function bodyOf(text: String): Null<HxFnBodyT> {
		return switch member(BODY_SLOT, text) {
			case FnMember(decl): decl.body;
			case _: null;
		};
	}

	private static function varDecl(name: String, type: Null<HxTypeT>, init: Null<HxExprT>): HxVarDeclT {
		final decl: HxVarDeclT = Converters.rawToPaired_HxVarDecl({
			meta: [],
			name: name,
			access: null,
			type: null,
			condInit: null,
			init: null,
			more: []
		});
		decl.type = type;
		decl.init = init;
		return decl;
	}

	/** The one member `text` makes inside `slot`; null when the whole does not parse to exactly one member. */
	private static function member(slot: Slot, text: String): Null<HxClassMemberT> {
		final tree: Null<HxModuleT> = try
			HaxeModuleTriviaParser.parse(slot.before + text + slot.after)
		catch (exception: ParseError)
			null
		catch (exception: Exception)
			null;
		if (tree == null || tree.decls.length != 1) return null;
		return switch tree.decls[0].node.decl {
			case ClassDecl(body) if (body.members.length == 1): body.members[0].node.member;
			case _: null;
		};
	}

	/** `modifier` as a Haxe member modifier. */
	private static function memberModifier(modifier: Modifier): HxMemberModifier {
		return switch modifier {
			case Public: HxMemberModifier.Public;
			case Private: HxMemberModifier.Private;
			case Static: HxMemberModifier.Static;
			case Inline: HxMemberModifier.Inline;
			case Override: HxMemberModifier.Override;
		};
	}

}
