package anyparse.grammar.haxe.query;

import anyparse.grammar.haxe.decl.HxClassMember;
import anyparse.grammar.haxe.decl.HxImportAlias;
import anyparse.grammar.haxe.decl.HxImportAliasIn;
import anyparse.grammar.haxe.decl.HxParam;
import anyparse.grammar.haxe.decl.HxWildPath;
import anyparse.grammar.haxe.expr.HxExpr;
import anyparse.grammar.haxe.meta.HxMemberModifier;
import anyparse.grammar.haxe.stmt.HxStatement;
import anyparse.grammar.haxe.trivia.Pairs.Converters;
import anyparse.grammar.haxe.trivia.Pairs.HxArrowFnTypeT;
import anyparse.grammar.haxe.trivia.Pairs.HxArrowParamT;
import anyparse.grammar.haxe.trivia.Pairs.HxClassMemberT;
import anyparse.grammar.haxe.trivia.Pairs.HxDeclT;
import anyparse.grammar.haxe.trivia.Pairs.HxExprT;
import anyparse.grammar.haxe.trivia.Pairs.HxFnBodyT;
import anyparse.grammar.haxe.trivia.Pairs.HxFnDeclT;
import anyparse.grammar.haxe.trivia.Pairs.HxForStmtT;
import anyparse.grammar.haxe.trivia.Pairs.HxIfStmtT;
import anyparse.grammar.haxe.trivia.Pairs.HxLambdaParamT;
import anyparse.grammar.haxe.trivia.Pairs.HxMemberDeclT;
import anyparse.grammar.haxe.trivia.Pairs.HxStatementT;
import anyparse.grammar.haxe.trivia.Pairs.HxThinParenLambdaT;
import anyparse.grammar.haxe.trivia.Pairs.HxTypeT;
import anyparse.grammar.haxe.trivia.Pairs.HxVarDeclT;
import anyparse.grammar.haxe.types.HxType;
import anyparse.grammar.haxe.types.HxTypeName;
import anyparse.query.Constructs.Arithmetic;
import anyparse.query.Constructs.Modifier;
import anyparse.runtime.ParseError;
import anyparse.runtime.Trivial;
import haxe.Exception;

/**
 * Typed trivia-mode Haxe nodes made from their parts: the one answer to "how is a Haxe member or statement built as a
 * typed node rather than spelled as text". A node is built of the plain grammar types and lifted by the generated
 * `Converters.rawToPaired_*`, so every trivia slot holds its no-source default and the writer lays the node out by its
 * own policy alone. A part that arrives as text (a copied source fragment, a construct built as text) is read by the
 * generated parser's entry for the node it fills, as exactly that one node, and keeps its own trivia.
 */
@:nullSafety(Strict)
final class HaxeNodes {

	/** The body of a method that has none: a declaration only. */
	public static inline function noBody(): HxFnBodyT {
		return NoBody;
	}

	/** The statement that leaves the enclosing function with no value. */
	public static inline function voidReturnStmt(): HxStatementT {
		return VoidReturnStmt;
	}

	/** The statement that goes on to the next iteration of the enclosing loop. */
	public static inline function continueStmt(): HxStatementT {
		return ContinueStmt;
	}

	/** The statement evaluating `expr` for its effect. */
	public static inline function exprStmt(expr: HxExprT): HxStatementT {
		return ExprStmt(expr, true);
	}

	/** The values from `from` up to, not including, `to`. */
	public static inline function intervalExpr(from: HxExprT, to: HxExprT): HxExprT {
		return Interval(from, to);
	}

	/** The boolean literal `value`. */
	public static inline function boolExpr(value: Bool): HxExprT {
		return BoolLit(value);
	}

	/** The block whose interior is `text`, statements and the comments among them; null when `text` is no such interior. */
	public static inline function runOf(text: String): Null<HxStatementT> {
		return read(HaxeModuleTriviaParser.parseHxStatementBlockStmtInterior, text);
	}

	/** `owner` with its member `name`. */
	public static inline function fieldExpr(owner: HxExprT, name: String): HxExprT {
		return FieldAccess(owner, name, null);
	}

	/** `inner` held together as one operand. */
	public static inline function parenExpr(inner: HxExprT): HxExprT {
		return ParenExpr(inner, false, null);
	}

	/** The one type `text` spells; null when it is not exactly one. */
	public static inline function typeOf(text: String): Null<HxTypeT> {
		return read(HaxeModuleTriviaParser.parseHxTypeNode, text);
	}

	/** The one expression `text` spells; null when it is not exactly one. */
	public static inline function valueOf(text: String): Null<HxExprT> {
		return read(HaxeModuleTriviaParser.parseHxExprNode, text);
	}

	/** The one method body `text` spells; null when it is not exactly one. */
	public static inline function bodyOf(text: String): Null<HxFnBodyT> {
		return read(HaxeModuleTriviaParser.parseHxFnBodyNode, text);
	}

	/**
	 * The import declaration of `path`, a name, a wildcard or an aliased name, tried in the order the grammar tries the
	 * import declarations; null when `path` is none.
	 */
	public static function importOf(path: String): Null<HxDeclT> {
		final wild: Null<HxWildPath> = read(HaxeModuleTriviaParser.parseHxWildPathNode, path);
		if (wild != null) return ImportWildDecl(wild);
		final alias: Null<HxImportAlias> = read(HaxeModuleTriviaParser.parseHxImportAliasNode, path);
		if (alias != null) return ImportAliasDecl(alias);
		final aliasIn: Null<HxImportAliasIn> = read(HaxeModuleTriviaParser.parseHxImportAliasInNode, path);
		if (aliasIn != null) return ImportAliasInDecl(aliasIn);
		final name: Null<HxTypeName> = read(HaxeModuleTriviaParser.parseHxTypeNameNode, path);
		return name == null ? null : ImportDecl(name);
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
			params: params.map(param -> HxParam.Required({ name: param.name, type: null, defaultValue: null })),
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

	/** The statement running `body` when `cond` holds, with no other branch. */
	public static function ifStmt(cond: HxExprT, body: HxStatementT): HxStatementT {
		final stmt: HxIfStmtT = Converters.rawToPaired_HxIfStmt(
			{ cond: HxExpr.BoolLit(true), thenBody: HxStatement.EmptyStmt, elseBody: null }
		);
		stmt.cond = cond;
		stmt.thenBody = body;
		return IfStmt(stmt);
	}

	/**
	 * The loop running `body` once per element of `iterable` bound to `binder` or, when `valueBinder` is given, once per key
	 * bound to `binder` with its value bound to `valueBinder`.
	 */
	public static function forStmt(binder: String, valueBinder: Null<String>, iterable: HxExprT, body: HxStatementT): HxStatementT {
		final stmt: HxForStmtT = Converters.rawToPaired_HxForStmt({
			varName: binder,
			valueName: valueBinder == null ? null : { name: valueBinder },
			iterable: HxExpr.BoolLit(true),
			body: HxStatement.EmptyStmt
		});
		stmt.iterable = iterable;
		stmt.body = body;
		return ForStmt(stmt);
	}

	/** A local `name`, bound once when `constant`, of `type` when given, initialised to `init` when given. */
	public static function localDecl(constant: Bool, name: String, type: Null<HxTypeT>, init: Null<HxExprT>): HxStatementT {
		return constant ? FinalStmt(varDecl(name, type, init), true) : VarStmt(varDecl(name, type, init), true);
	}

	/**
	 * One block holding the statements of `runs`, each a block read by `runOf`, in order: the comments closing the last run
	 * close the block. Null when a run before the last closes on a comment, which has no statement left to stand before.
	 */
	public static function blockOf(runs: Array<HxStatementT>): Null<HxStatementT> {
		final elements: Array<Trivial<HxStatementT>> = [];
		var last: Null<HxStatementT> = null;
		var closed: Bool = false;
		for (run in runs) switch run {
			case BlockStmt(stmts, closeTrailing, _, _, trailingLeading, _):
				if (closed) return null;
				closed = closeTrailing != null || trailingLeading.length > 0;
				for (element in stmts) elements.push(element);
				last = run;
			case _:
				return null;
		}
		return switch last {
			case BlockStmt(_, closeTrailing, openTrailing, trailingBlankBefore, trailingLeading, trailPresent):
				BlockStmt(elements, closeTrailing, openTrailing, trailingBlankBefore, trailingLeading, trailPresent);
			case _: runOf('');
		};
	}

	/** The one statement `text` spells, with no comment around it; null when it is not exactly one. */
	public static function statementOf(text: String): Null<HxStatementT> {
		return switch runOf(text) {
			case BlockStmt(stmts, null, _, _, [], _) if (
				stmts.length == 1 && stmts[0].leadingComments.length == 0 && stmts[0].trailingComment == null
			):
				stmts[0].node;
			case _: null;
		};
	}

	/** The number of statements the block interior `text` holds; null when it is no block interior. */
	public static function countOf(text: String): Null<Int> {
		return switch runOf(text) {
			case BlockStmt(stmts, _, _, _, _, _): stmts.length;
			case _: null;
		};
	}

	/** The assignment of `value` to `target`, or of `target` combined with `value` by `op` when given. */
	public static function assignExpr(target: HxExprT, op: Null<Arithmetic>, value: HxExprT): HxExprT {
		return switch op {
			case null: Assign(target, value);
			case Add: AddAssign(target, value);
			case Subtract: SubAssign(target, value);
			case Multiply: MulAssign(target, value);
			case Divide: DivAssign(target, value);
			case Remainder: ModAssign(target, value);
		};
	}

	/** The array literal holding `items` in order. */
	public static function arrayExpr(items: Array<HxExprT>): HxExprT {
		final literal: HxExprT = Converters.rawToPaired_HxExpr(HxExpr.ArrayExpr([ for (_ in items) HxExpr.BoolLit(true) ]));
		switch literal {
			case ArrayExpr(elems, _, _, _, _, _):
				for (i => item in items) elems[i].node = item;
			case _:
		}
		return literal;
	}

	/** The function type taking `params` and answering `result`. */
	public static function functionTypeOf(params: Array<HxTypeT>, result: HxTypeT): HxTypeT {
		final fn: HxArrowFnTypeT = Converters.rawToPaired_HxArrowFnType({ args: [], ret: HxType.Anon([]) });
		fn.args = params.map(param -> HxArrowParamT.Positional(param));
		fn.ret = result;
		return ArrowFn(fn);
	}

	/** The call of `callee` with `args` in order. */
	public static function callExpr(callee: HxExprT, args: Array<HxExprT>): HxExprT {
		final call: HxExprT = Converters.rawToPaired_HxExpr(HxExpr.Call(HxExpr.BoolLit(true), [ for (_ in args) HxExpr.BoolLit(true) ]));
		return switch call {
			case Call(_, elems, slotA, slotB, slotC):
				for (i => arg in args) elems[i].node = arg;
				Call(callee, elems, slotA, slotB, slotC);
			case _: call;
		};
	}

	/** The lambda taking the one name `param` and answering `body`. */
	public static function nameLambdaExpr(param: HxExprT, body: HxExprT): HxExprT {
		return ThinArrow(param, body, null, []);
	}

	/**
	 * The lambda in parentheses taking `params`, each read as a lambda parameter, and answering `body`; null when a
	 * parameter is none.
	 */
	public static function lambdaExpr(params: Array<String>, body: HxExprT): Null<HxExprT> {
		final lambda: HxThinParenLambdaT = Converters.rawToPaired_HxThinParenLambda({ params: [], body: HxExpr.BoolLit(true) });
		for (text in params) {
			final read: Null<HxLambdaParamT> = lambdaParamOf(text);
			if (read == null) return null;
			lambda.params.push(read);
		}
		lambda.body = body;
		return ThinParenLambdaExpr(lambda);
	}

	/** The using declaration of the plain name `path`; null when `path` is not one. */
	public static function usingOf(path: String): Null<HxDeclT> {
		return switch importOf(path) {
			case ImportDecl(name): UsingDecl(name);
			case _: null;
		};
	}

	/** `modifier` as a Haxe member modifier. */
	public static function memberModifier(modifier: Modifier): HxMemberModifier {
		return switch modifier {
			case Public: HxMemberModifier.Public;
			case Private: HxMemberModifier.Private;
			case Static: HxMemberModifier.Static;
			case Inline: HxMemberModifier.Inline;
			case Override: HxMemberModifier.Override;
		};
	}

	/** Write options that set a parameter's type off its name by a space after the colon, as a lambda's parameter is written in source. */
	public static function spacedHints(): HxModuleWriteOptions {
		final options: HxModuleWriteOptions = new HxModuleWriteOptions();
		options.typeHintColon = After;
		return options;
	}

	/** The one lambda parameter `text` spells; null when it is not exactly one. */
	private static inline function lambdaParamOf(text: String): Null<HxLambdaParamT> {
		return read(HaxeModuleTriviaParser.parseHxLambdaParamNode, text);
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

	/** The node `entry` reads from `text`; null when the generated parser refuses `text` as exactly one such node. */
	private static function read<T>(entry: String -> T, text: String): Null<T> {
		return try entry(text) catch (exception: ParseError) null catch (exception: Exception) null;
	}

}
