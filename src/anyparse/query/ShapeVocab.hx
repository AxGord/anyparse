package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;

using StringTools;
using Lambda;

/**
 * The grammar's DERIVED vocabulary: every kind set a check reads as a union of `RefShape` seams — all the loops, every
 * function-like kind, every `return`, every `try` — spelled once here, so a seam a grammar adds reaches every reader at once.
 *
 * A rule's own `Seams` keeps the subset IT reads; what it must not do is respell one of these unions inline, because two
 * spellings of one union drift (`NullFlow` once carried the Haxe loop kinds as a literal list beside the one read off the
 * grammar). Each answer is a fresh array holding each kind once, in seam order; a seam the grammar leaves unset adds nothing.
 */
@:nullSafety(Strict)
final class ShapeVocab {

	/**
	 * The loop STATEMENTS — `loopStatementKinds` (body last) and `doWhileLoopKinds` (body first), each once: every loop but
	 * a comprehension's (`[for …]`, `[while …]`). A do-while in expression position is one of them: it is the statement's
	 * loop over the statement's children, and no comprehension generator.
	 */
	public static function statementLoopKinds(shape: RefShape): Array<String> {
		return union([shape.loopStatementKinds, shape.doWhileLoopKinds]);
	}

	/** Every function-like kind — the declared functions (`functionKinds`) and the nested ones (`nestedFunctionKinds`), each once. */
	public static function functionLikeKinds(shape: RefShape): Array<String> {
		return union([shape.functionKinds, nestedFunctionKinds(shape)]);
	}

	/**
	 * The local function STATEMENTS — `localFunctionKinds` and `inlineFunctionKinds`, each once: the scope reading of a
	 * local function, which the grammar splits because an `inline` one is no complexity unit of its own.
	 */
	public static function localFunctionScopeKinds(shape: RefShape): Array<String> {
		return union([shape.localFunctionKinds, shape.inlineFunctionKinds]);
	}

	/**
	 * The `return` STATEMENTS — `returnStatementKind` and `voidReturnKind`, each once: the ones that end a statement list,
	 * a `return` in expression position (`valueReturnKinds`) aside.
	 */
	public static function returnStatementKinds(shape: RefShape): Array<String> {
		return union([one(shape.returnStatementKind), one(shape.voidReturnKind)]);
	}

	/** Every `return` — the statements (`returnStatementKinds`) and `valueReturnKinds`, each once. */
	public static function returnKinds(shape: RefShape): Array<String> {
		return union([returnStatementKinds(shape), shape.valueReturnKinds]);
	}

	/** Every `try` — `tryStatementKinds` and `tryExpressionKinds`, each once. */
	public static function tryKinds(shape: RefShape): Array<String> {
		return union([shape.tryStatementKinds, shape.tryExpressionKinds]);
	}

	/** Every `if` — `ifStatementKinds` and `ifExpressionKinds`, each once; the ternary aside (`conditionalKinds`). */
	public static function ifKinds(shape: RefShape): Array<String> {
		return union([shape.ifStatementKinds, shape.ifExpressionKinds]);
	}

	/** The arms of a `switch` — `caseBranchKind` and `defaultBranchKind`, each when set. */
	public static function switchArmKinds(shape: RefShape): Array<String> {
		return union([one(shape.caseBranchKind), one(shape.defaultBranchKind)]);
	}

	/**
	 * EVERY kind that projects a function VALUE nested inside code — the lambdas in every
	 * spelling (`lambdaKinds`, which already carries the anonymous `fnExprKind`), the NAMED
	 * function literal (`namedFnExprKind`), and the local function declarations in both the
	 * plain (`localFunctionKinds`) and the `inline` (`inlineFunctionKinds`) form.
	 *
	 * THE authority for that question. Five checks used to answer it by hand and only two of
	 * the five hand sets were complete: the named literal is declared in no other kind-set, so
	 * `return-reassign-ternary` and `shadowing-local` had each silently omitted it, and a
	 * grammar adding a sixth spelling would have re-opened the same hole in all five at once.
	 * Derived rather than declared, so it can never fall behind the pieces it unions —
	 * a plugin that adds a lambda spelling to `lambdaKinds` widens this set with it.
	 *
	 * It is NOT the same question as "does this node open a new scope": a method declaration
	 * (`functionKinds`) opens one and is not a function value, so a consumer asking the scope
	 * question unions this set with its own, and documents the extra (`shadowing-local`,
	 * `trivial-getter`).
	 */
	public static function nestedFunctionKinds(shape: RefShape): Array<String> {
		return union([
			shape.lambdaKinds,
			one(shape.fnExprKind),
			one(shape.namedFnExprKind),
			shape.localFunctionKinds,
			shape.inlineFunctionKinds
		]);
	}

	/**
	 * Every loop — `loopStatementKinds`, `doWhileLoopKinds`, `iterationBindingKinds` and `whileExprKind`, each once: the
	 * one definition of a loop every check of repetition and control flow reads (`Loops`, `ErrorPaths`, `LockWindow`,
	 * the `NullFlow` back-edge clear).
	 */
	public static function loopKinds(shape: RefShape): Array<String> {
		return union([
			shape.loopStatementKinds,
			shape.doWhileLoopKinds,
			shape.iterationBindingKinds,
			one(shape.whileExprKind)
		]);
	}

	/** Every two-armed conditional — `ifKinds` and the `ternaryKind`: the constructs whose first child is a condition. */
	public static function conditionalKinds(shape: RefShape): Array<String> {
		return union([shape.ifStatementKinds, shape.ifExpressionKinds, one(shape.ternaryKind)]);
	}

	/** The single seam `kind` as a group of `union`, or null when it is unset. */
	private static inline function one(kind: Null<String>): Null<Array<String>> {
		return kind == null ? null : [kind];
	}

	/** The kinds of `groups` in order, each once; an unset group adds nothing. */
	private static function union(groups: Array<Null<Array<String>>>): Array<String> {
		final out: Array<String> = [];
		for (g in groups) if (g != null) for (k in g) if (!out.contains(k)) out.push(k);
		return out;
	}

	/**
	 * The kinds a MEMBER ACCESS projects as — the node whose receiver child is the head of a
	 * `Helper.go()`. Read off the shape rather than spelled here, so a second grammar's own spellings
	 * arrive with it; a shape that declares none contributes no receiver names at all.
	 */
	public static function memberAccessKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (kind in [shape.fieldAccessKind, shape.nullSafeAccessKind, shape.forceFieldAccessKind]) if (kind != null && !out.contains(kind))
			out.push(kind);
		return out;
	}

}
