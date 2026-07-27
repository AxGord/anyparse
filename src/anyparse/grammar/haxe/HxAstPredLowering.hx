package anyparse.grammar.haxe;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.AstPredLowering;

/**
 * Haxe-grammar AST-predicate tables — the domain knowledge behind the
 * writer/parser shape gates, generated as TYPED per-mode functions on
 * the `AstPreds` / `AstPredsT` / `AstPredsS` marker classes (see
 * `HxPredBuild`). Replaces the runtime-introspection predicates of
 * `HxExprUtil` (`Type.enumConstructor` / `Reflect.field` over
 * `Dynamic`): each predicate keeps its knowledge here as ctor tables
 * and operand indices, and the `AstPredLowering` base turns them into
 * pattern matches of the correct per-mode constructor path and arity.
 */
final class HxAstPredLowering extends AstPredLowering {

	private static inline final HX_EXPR: String = 'anyparse.grammar.haxe.HxExpr';

	private static inline final HX_STATEMENT: String = 'anyparse.grammar.haxe.HxStatement';

	private static inline final HX_TOP_LEVEL_DECL: String = 'anyparse.grammar.haxe.HxTopLevelDecl';

	private static inline final HX_DECL: String = 'anyparse.grammar.haxe.HxDecl';

	private static inline final HX_SWITCH_CASE: String = 'anyparse.grammar.haxe.HxSwitchCase';

	private static inline final HX_OBJECT_FIELD: String = 'anyparse.grammar.haxe.HxObjectField';

	private static inline final HX_MEMBER_DECL: String = 'anyparse.grammar.haxe.HxMemberDecl';

	private static inline final HX_FN_EXPR_BODY: String = 'anyparse.grammar.haxe.HxFnExprBody';

	private static inline final HX_TRY_CATCH_EXPR: String = 'anyparse.grammar.haxe.HxTryCatchExpr';

	private static inline final HX_COND_DECL: String = 'anyparse.grammar.haxe.HxConditionalDecl';

	private static inline final HX_ELSEIF_DECL: String = 'anyparse.grammar.haxe.HxElseifDecl';

	/**
	 * `HxExpr` `*Assign` ctor names — every right-associative `=` infix
	 * (`Assign` plus the 14 compound forms). `stmtExprNoSemi` walks
	 * through an assignment-statement's right operand: the last token
	 * of `x = if (…) {…} else {…}` is the else block's `}`, so the
	 * trailing `;` is optional just like for the bare statement.
	 */
	private static final ASSIGN_CTORS: Array<String> = [
		'Assign',
		'AddAssign',
		'SubAssign',
		'MulAssign',
		'DivAssign',
		'ModAssign',
		'ShlAssign',
		'UShrAssign',
		'ShrAssign',
		'BitOrAssign',
		'BitAndAssign',
		'BitXorAssign',
		'NullCoalAssign',
		'BoolAndAssign',
		'BoolOrAssign',
	];

	/**
	 * `HxExpr` ctor names for every NON-assign binary infix operator
	 * whose right operand is an `HxExpr`. Same right-operand walk as
	 * `ASSIGN_CTORS`: Haxe's own rule is purely lexical —
	 * `Parser.semicolon` makes the `;` optional whenever the previously
	 * consumed token was `}`, regardless of which operator produced it.
	 * `Is` is deliberately absent (its right operand is an `HxType` and
	 * `a is T` carries its own statement-position entry in the
	 * brace/bracket-terminal set); `Ternary` is not binary — it has its
	 * own arm walking `elseExpr` (declared index 2, not 1).
	 */
	private static final BINOP_RHS_CTORS: Array<String> = [
		'Mul',
		'Div',
		'Mod',
		'Add',
		'Sub',
		'Shl',
		'UShr',
		'Shr',
		'BitOr',
		'BitAnd',
		'BitXor',
		'Eq',
		'NotEq',
		'LtEq',
		'GtEq',
		'Lt',
		'Gt',
		'Interval',
		'And',
		'Or',
		'NullCoal',
		'In',
		'ThinArrow',
		'Arrow',
	];

	/**
	 * `HxExpr` constructors that, at statement-expression position,
	 * leave the statement `}`/`]`/literal-terminated so no trailing `;`
	 * is needed: `{ … }` block, `{ k: v }` object literal, `[ … ]`
	 * array, `${expr}` interpolation block, `$b{exprs}` reification
	 * splice, and `a is T` (permissive last-stmt-in-block semantics
	 * pinned by `whitespace/issue_605_operator_is`). Recursion targets
	 * reached through the Assign / If / Meta / Return arms.
	 *
	 * `DollarReifExpr` is DELIBERATELY absent from `_binopRhsNoSemi`'s
	 * carve-out while present here: the carve-out encodes a corpus
	 * contract for `x = ${expr}` / `x = {a: 1}` / `x = [1, 2]`, and no
	 * fixture covers a reification splice as an assignment RHS
	 * (motivating source for the bare-statement entry: Pony
	 * `DIBuilder.hx` `$b{loadBody}` inside a `macro class` body). The
	 * asymmetry is intentional, not an oversight.
	 */
	private static final STMT_BRACE_TERMINAL_CTORS: Array<String> = [
		'BlockExpr',
		'ObjectLit',
		'ArrayExpr',
		'DollarBlockExpr',
		'DollarReifExpr',
		'Is',
	];

	/**
	 * `HxStatement` constructors whose prior occurrence in a BlockBody
	 * Star needs no `;` before the next statement: the brace-terminated
	 * family (closing `}` is the last token — including the two
	 * cond-splice open forms whose own `@:trail('}')` is the last
	 * token), the sep-terminated family (their `@:trail(';')` /
	 * `@:lit(';')` already consumed the separator), and the shapes the
	 * byte-check misses (`Conditional` ends `#end`, `EllipsisStmt` ends
	 * `.`, `CondSpliceBlockClose`).
	 */
	private static final NO_SEMI_STMT_CTORS: Array<String> = [
		'BlockStmt',
		'IfStmt',
		'WhileStmt',
		'ForStmt',
		'SwitchStmt',
		'SwitchStmtBare',
		'TryCatchStmt',
		'LocalFnStmt',
		'LocalInlineFnStmt',
		'UntypedBlockStmt',
		'CondSpliceBlockOpen',
		'CondSpliceSwitchOpen',
		'VoidReturnStmt',
		'ThrowStmt',
		'DoWhileStmt',
		'ErrorStmt',
		'EmptyStmt',
		'TryCatchStmtBare',
		'Conditional',
		'EllipsisStmt',
		'CondSpliceBlockClose',
	];

	/**
	 * `var` / `final` (and static variants) statement constructors whose
	 * brace-termination depends on the init expression — all four wrap
	 * the same `HxVarDecl`, so one or-pattern case walks `.init`.
	 */
	private static final VAR_INIT_STMT_CTORS: Array<String> = ['VarStmt', 'FinalStmt', 'StaticVarStmt', 'StaticFinalStmt'];

	/**
	 * The keyword a `HxExpr.CondSpliceTail` fragment starts with when it
	 * is an if-chain continuation rather than a standalone guarded
	 * statement. See `condSpliceTailElseLedField`.
	 */
	private static inline final ELSE_KEYWORD: String = 'else';

	/**
	 * Import / using family ctors of `HxDecl` whose leaf carries a
	 * plain path String as its single positional arg — recognised by
	 * the between-imports leaf classifiers.
	 */
	private static final IMPORT_PATH_CTORS: Array<String> = ['ImportDecl', 'ImportWildDecl', 'UsingDecl', 'UsingWildDecl'];

	/**
	 * Import alias ctors of `HxDecl` — the path lives in the wrapped
	 * struct's `path` field instead of being a positional sibling (the
	 * lowering rejects multi-arg enum branches).
	 */
	private static final IMPORT_ALIAS_CTORS: Array<String> = ['ImportAliasDecl', 'ImportAliasInDecl'];

	/**
	 * `HxDecl` ctors after whose `#end` the fork keeps / re-adds a
	 * blank line before the following decl — the union of fork's
	 * `markImports` (import / using family) and `betweenTypes`
	 * (type-level decls) passes. Consumed by
	 * `tailLeafKeepsBlankAfterConditional`.
	 */
	private static final KEEPS_BLANK_CTORS: Array<String> = [
		'ImportDecl',
		'ImportWildDecl',
		'UsingDecl',
		'UsingWildDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl',
		'ClassDecl',
		'InterfaceDecl',
		'AbstractClassDecl',
		'AbstractDecl',
		'EnumDecl',
		'EnumAbstractDecl',
		'TypedefDecl',
		'FnDecl',
		'VarDecl',
		'FinalDecl',
	];

	/** All generated predicate fields for this lowering's mode. */
	public function generate(): Array<Field> {
		return [
			arrayBracketKindField(),
			endsWithCloseBraceField(),
			operandIsBlockExprField(),
			caseBodyRefusesFlatField(),
			tailStmtReadsExprPositionField(),
			elementIsConditionalEnumField(HX_STATEMENT, 's'),
			elementIsConditionalEnumField(HX_SWITCH_CASE, 'c'),
			elementIsConditionalEnumField(HX_OBJECT_FIELD, 'f'),
			elementIsConditionalDeclField(),
			elementIsConditionalFalseField(
				HX_EXPR, 'e',
				'Byte-parity: `HxExpr`\'s conditional shapes use the ctor names `ConditionalExpr` / `ConditionalArgs` / '
				+ '`CondSpliceExpr` / `CondSpliceTail`, never `Conditional` — so the retired ctor-NAME check was '
				+ 'constantly false for expression elements, and a nested `#if` inside a `#if` args region never '
				+ 'received the `alignedNestedIncrease` lift. Keep the false verdict; widening to the real ctor set '
				+ 'is a behavior change to make deliberately, against fork fixtures.'
			),
			elementIsConditionalFalseField(
				HX_MEMBER_DECL, 'm',
				'Byte-parity: the retired Dynamic adapter probed the struct\'s `.decl` field, which `HxMemberDecl` '
				+ 'does not have (its wrapper field is `.member`), so a nested conditional MEMBER never lifted. '
				+ 'Keep the false verdict; widening to `.member` → `HxClassMember.Conditional` is a behavior '
				+ 'change to make deliberately, against fork fixtures.'
			),
			condSpliceRawWrapsCasesField(),
			stmtExprNoSemiField(),
			stmtExprNoSemiAtField(),
			binopRhsNoSemiField(),
			condSpliceTailElseLedField(),
			stmtNoSemiField(),
			condLeafWalkerField('betweenImportsTailLeafClassify', true, '_classifyImportLeafTail'),
			condLeafWalkerField('betweenImportsHeadLeafClassify', false, '_classifyImportLeafHead'),
			condLeafWalkerField('tailLeafKeepsBlankAfterConditional', true, '_classifyKeepsBlankLeaf'),
			importLeafClassifierField('_classifyImportLeafTail', 'betweenImportsTailLeafClassify'),
			importLeafClassifierField('_classifyImportLeafHead', 'betweenImportsHeadLeafClassify'),
			keepsBlankLeafClassifierField(),
		];
	}

	/**
	 * `endsWithCloseBrace(e) → Bool` — true iff `e` is a control-flow
	 * expression whose `}` may serve as a statement terminator on the
	 * rhs of `var x = …` / `final x = …`. Drives the writer-side
	 * `@:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))` gate on
	 * `HxClassMember.VarMember` / `FinalMember` (drop the `;` iff true).
	 *
	 * True (brace-terminated): `SwitchExpr` / `SwitchExprBare` /
	 * `BlockExpr` / `ObjectLit` / `MacroClassExpr` outright; `FnExpr`
	 * with a `BlockBody`; and recursion through the value-position
	 * wrappers — `MacroExpr` / `MetaExpr` operands, `Ternary`'s else
	 * branch, `for` / `while` bodies, `IfExpr`'s last evaluated branch
	 * (`elseBranch` when present, else `thenBranch`), `TryExpr`'s last
	 * catch body (or the try body with no catches). Everything else —
	 * bare literals, calls, non-wrapped binops — is false. The corpus
	 * behaviour is pinned by the fork fixtures
	 * (`issue_119_expression_case`, `inline_calls`,
	 * `issue_254_case_colon*`); `stmtExprNoSemi` reuses the predicate
	 * read-only for its non-recursive tail cases.
	 */
	private function endsWithCloseBraceField(): Field {
		inline function rec(e: Expr): Expr return { expr: ECall(ident('endsWithCloseBrace'), [e]), pos: Context.currentPos() };
		final recEl: Expr = rec(macro _el);
		final recThen: Expr = rec(field(ident('_s'), 'thenBranch'));
		final recTryBody: Expr = rec(field(ident('_t'), 'body'));
		final recLastCatch: Expr = rec(field(starElem(HX_TRY_CATCH_EXPR, 'catches', macro _cs[_cs.length - 1]), 'body'));
		final fnBodySwitch: Expr = nullSwitch(
			field(ident('_f'), 'body'), macro false, [caseOf(HX_FN_EXPR_BODY, ['BlockBody'], macro true)], macro false
		);
		final body: Expr = nullSwitch(ident('e'), macro false, [
			caseOf(HX_EXPR, ['SwitchExpr', 'SwitchExprBare', 'BlockExpr', 'ObjectLit', 'MacroClassExpr'], macro true),
			caseBind(HX_EXPR, 'MacroExpr', [0 => '_o'], rec(ident('_o'))),
			caseBind(HX_EXPR, 'MetaExpr', [0 => '_m'], rec(field(ident('_m'), 'expr'))),
			caseBind(HX_EXPR, 'Ternary', [2 => '_e2'], rec(ident('_e2'))),
			caseBind(HX_EXPR, 'ForExpr', [0 => '_s'], rec(field(ident('_s'), 'body'))),
			caseBind(HX_EXPR, 'WhileExpr', [0 => '_s'], rec(field(ident('_s'), 'body'))),
			caseBind(
				HX_EXPR, 'IfExpr', [0 => '_s'], macro {
					final _el = _s.elseBranch;
					_el != null ? $recEl : $recThen;
				}
			),
			caseBind(HX_EXPR, 'FnExpr', [0 => '_f'], fnBodySwitch),
			caseBind(
				HX_EXPR, 'TryExpr', [0 => '_t'], macro {
					final _cs = _t.catches;
					_cs.length == 0 ? $recTryBody : $recLastCatch;
				}
			),
		], macro false);
		return predField(
			'endsWithCloseBrace', [valueArg('e', HX_EXPR)], macro :Bool, body,
			'True iff the expression\'s surface form ends with `}` for the var/final-rhs `;` gate (recursive).'
		);
	}

	/**
	 * `operandIsBlockExpr(e) → Bool` — true iff a `macro <operand>`
	 * reification's operand is a block (`macro { … }`). Drives
	 * `@:fmt(clearExprPosition)` on `HxExpr.MacroExpr`: a macro-BLOCK's
	 * statements are reified code and yield nothing to the enclosing
	 * expression position, so the operand reverts to statement-position
	 * body policy (the block-tail SI-2 expression frame is dropped). A
	 * non-block operand (`macro if (1) 2 else 3`) is TRANSPARENT —
	 * `macro` does not change expression-vs-statement position — so the
	 * clear must NOT fire there.
	 */
	private function operandIsBlockExprField(): Field {
		final body: Expr = nullSwitch(ident('e'), macro false, [caseOf(HX_EXPR, ['BlockExpr'], macro true)], macro false);
		return predField(
			'operandIsBlockExpr', [valueArg('e', HX_EXPR)], macro :Bool, body,
			'True iff a `macro <operand>` reification operand is a `{ … }` block.'
		);
	}

	/**
	 * `caseBodyRefusesFlat(s) → Bool` — true when a single-statement
	 * case body should refuse inline emission because its outermost
	 * expression is `&&` or `||`. Mirrors haxe-formatter's
	 * `MarkSameLine.markExpressionCase` body-shape heuristic; empirical
	 * scope (probed against fork CLI): only `And` / `Or` — all other
	 * binops, ternary, and assignment variants nest hierarchically
	 * under one `dblDot` child in fork's tokentree and are allowed
	 * inline. Drives the `@:fmt(refuseFlatOnComplexExpr)` flat-gate
	 * AND-clause on `HxCaseBranch.body` / `HxDefaultBranch.stmts`.
	 */
	private function caseBodyRefusesFlatField(): Field {
		final inner: Expr = sw(ident('_e'), [caseOf(HX_EXPR, ['And', 'Or'], macro true)], macro false);
		final body: Expr = nullSwitch(ident('s'), macro false, [caseBind(HX_STATEMENT, 'ExprStmt', [0 => '_e'], inner)], macro false);
		return predField(
			'caseBodyRefusesFlat', [valueArg('s', HX_STATEMENT)], macro :Bool, body,
			'True iff an `ExprStmt` case body has an outermost `&&` / `||` and must refuse inline emission.'
		);
	}

	/**
	 * `tailStmtReadsExprPosition(s) → Bool` — true iff a block-body /
	 * case-body TAIL statement is a NO-ELSE `if` whose body placement
	 * dispatches on `_inExprPosition` (`HxStatement.IfStmt`). Fork
	 * parity: an `if` whose direct parent is a block brace or a
	 * non-value-yielded switch-case colon is a STATEMENT — its body
	 * uses `sameLine.ifBody`, never `sameLine.expressionIf` — so a
	 * block/case tail `if` drops (or reduces) the inherited
	 * expression-position frame instead of force-propagating it. An
	 * `if` WITH an `else` keeps the frame so the chain breaks together
	 * under `fitLineIfWithElse` (mirrors the `noSiblingFallback`
	 * no-else gate); `for` / `while` tails are excluded — the fork
	 * breaks their expression-position bodies, so force-propagation
	 * already matches. Consumed by the `@:fmt(clearExprPositionNonTail)`
	 * tail-barrier emissions.
	 */
	private function tailStmtReadsExprPositionField(): Field {
		final elseAccess: Expr = field(ident('_i'), 'elseBody');
		final body: Expr = nullSwitch(
			ident('s'), macro false, [caseBind(HX_STATEMENT, 'IfStmt', [0 => '_i'], macro $elseAccess == null)], macro false
		);
		return predField(
			'tailStmtReadsExprPosition', [valueArg('s', HX_STATEMENT)], macro :Bool, body,
			'True iff a body-tail statement is a no-else `if` (drops the inherited expression-position frame).'
		);
	}

	/**
	 * `elementIsConditional_<ElemRule>(v) → Bool` family — true iff a
	 * cond-comp body / elseBody Star element (or a blockEnded statement
	 * Star element, for the sep-suppression probe) is itself a nested
	 * preprocessor `Conditional`. Drives the writer-side
	 * `alignedNestedIncrease` indent rule: the engine wraps a nested
	 * conditional element (markers AND guarded body) one indent level
	 * deeper than the surrounding region, accumulating per conditional
	 * depth — mirrors haxe-formatter's
	 * `Indenter.calcConsecutiveConditionalLevel`. The emission site
	 * derives the `elementIsConditional_<ElemRule>` name from the
	 * Star's element rule; one variant per element rule shape:
	 *
	 *  - enum elements with a `Conditional` ctor (`HxStatement` /
	 *    `HxSwitchCase` / `HxObjectField`) → this ctor probe;
	 *  - the `HxTopLevelDecl` struct → `.decl`-wrapped probe
	 *    (`elementIsConditionalDeclField`);
	 *  - shapes the probe can never match (`HxExpr` /
	 *    `HxMemberDecl`) → constant false
	 *    (`elementIsConditionalFalseField`).
	 */
	private function elementIsConditionalEnumField(rule: String, argName: String): Field {
		final body: Expr = nullSwitch(ident(argName), macro false, [caseOf(rule, ['Conditional'], macro true)], macro false);
		return predField(
			'elementIsConditional_${AstPredLowering.simpleName(rule)}', [valueArg(argName, rule)], macro :Bool, body,
			'True iff a cond-comp body Star element is itself a nested `Conditional`.'
		);
	}

	/**
	 * Decl-Star member of the `elementIsConditional_*` family
	 * (`HxConditionalDecl.body` elements): the element is an
	 * `HxTopLevelDecl` STRUCT whose `.decl` field carries the
	 * `Conditional` ctor.
	 */
	private function elementIsConditionalDeclField(): Field {
		final declAccess: Expr = field(ident('d'), 'decl');
		final inner: Expr = sw(declAccess, [caseOf(HX_DECL, ['Conditional'], macro true)], macro false);
		final body: Expr = macro d == null ? false : $inner;
		return predField(
			'elementIsConditional_HxTopLevelDecl', [valueArg('d', HX_TOP_LEVEL_DECL)], macro :Bool, body,
			'True iff a cond-comp body Star decl element wraps a nested `Conditional` in its `.decl`.'
		);
	}

	/** Constant-false member of the `elementIsConditional_*` family — see `doc` for why the shape can never match. */
	private function elementIsConditionalFalseField(rule: String, argName: String, doc: String): Field {
		return predField(
			'elementIsConditional_${AstPredLowering.simpleName(rule)}', [valueArg(argName, rule)], macro :Bool, macro false, doc
		);
	}

	/**
	 * `stmtExprNoSemi(e) → Bool` — true iff `e`, standing as a
	 * statement (`HxStatement.ExprStmt`), is `}`-terminated so Haxe
	 * needs no trailing `;`. Drives the parser-side
	 * `@:fmt(trailOptParseGate('stmtExprNoSemi'))` gate on `ExprStmt`:
	 * gate true → `;` optional (consumed if present); false → `;`
	 * required (the parser throws to terminate the statement,
	 * preserving multi-statement boundary detection — the property a
	 * blanket `@:trailOpt` would destroy on the catch-all).
	 *
	 * Note (ω-slice-X3): this predicate is no longer the sole authority
	 * on `ExprStmt`'s trail-`;` elision — the parse-time gate is a
	 * 3-disjunct OR with `peekKw(ctx, "else")` and `peekLit(ctx, "}")`.
	 * The intrinsic arms here remain load-bearing for the recursive
	 * paths (Assign / Meta / Return / If recursing into an RHS or
	 * branch) where the lookahead is checked at the OUTER `ExprStmt`,
	 * not at the inner recursion.
	 */
	private function stmtExprNoSemiField(): Field {
		final body: Expr = { expr: ECall(ident('_stmtExprNoSemiAt'), [ident('e'), macro false]), pos: Context.currentPos() };
		return predField(
			'stmtExprNoSemi', [valueArg('e', HX_EXPR)], macro :Bool, body,
			'True iff the expression at the top of an `ExprStmt` needs no trailing `;` (see `_stmtExprNoSemiAt`).'
		);
	}

	/**
	 * `stmtExprNoSemi`'s worker, carrying the one bit the public entry
	 * cannot: whether `e` sits at the TOP of an `ExprStmt` (`nested`
	 * false) or was reached by walking into an operand of it (`nested`
	 * true).
	 *
	 * The bit exists for the ctors whose grammar node owns an inner
	 * `@:trailOpt(';')` — `IfExpr` (`HxIfExpr.thenBranch`) and `ForExpr`
	 * (`HxForExpr.body`). Those slots consume the statement's `;`
	 * before the `ExprStmt` gate ever runs, so a NESTED occurrence must
	 * not `expectLit` a second one (`a << if (e) f(m); x();` failed at
	 * `x` while `a << if (e) f(m);; x();` parsed — that pair exposed
	 * the swallow). `FnExpr`'s `ExprBody` arm carries the same
	 * `nested ||` relaxation for BYTE-PARITY with the retired worker,
	 * although `HxFnExprBody.ExprBody` owns NO trail slot (that slot
	 * lives on the member-level `HxFnBody.ExprBody`; the retired doc
	 * cited the wrong enum) — its motivating source
	 * (`t.onClick << function () if (enabled) …`) reaches `true`
	 * through the `IfExpr` arm regardless. At the TOP of an `ExprStmt`
	 * the same relaxation is
	 * WRONG: a statement that starts with `if` / `for` / `function`
	 * dispatches to its statement production first and only
	 * fail-rewinds into the `ExprStmt` catch-all when that production
	 * could NOT parse it — precisely because the body's `;` is missing
	 * — so the top-level walk keeps the strict answer
	 * (`HxControlFlowSliceTest.testElsePeekScopedToElseOnly` pins the
	 * regression). Transparent wrappers (`MacroExpr` / `MetaExpr`)
	 * propagate `nested` unchanged; every genuine operand descent
	 * (binop RHS, ternary else, return value, lambda body) passes
	 * `true`. `WhileExpr` deliberately has NO arm — `HxWhileExpr.body`
	 * owns no trail slot, so its `;` survives to the enclosing gate and
	 * the body walk in `endsWithCloseBrace` (default arm) stays the
	 * right answer.
	 */
	private function stmtExprNoSemiAtField(): Field {
		inline function at(e: Expr, nested: Expr): Expr
			return { expr: ECall(ident('_stmtExprNoSemiAt'), [e, nested]), pos: Context.currentPos() };
		final fnBodySwitch: Expr = nullSwitch(field(ident('_f'), 'body'), macro false, [
			caseOf(HX_FN_EXPR_BODY, ['BlockBody'], macro true),
			caseBind(HX_FN_EXPR_BODY, 'ExprBody', [0 => '_e'], macro nested || ${at(ident('_e'), macro true)}),
		], macro false);
		final ifArm: Expr = {
			final recElse: Expr = at(ident('_el'), macro true);
			final recThen: Expr = at(field(ident('_s'), 'thenBranch'), macro true);
			macro {
				final _el = _s.elseBranch;
				_el != null ? $recElse : (nested ? true : $recThen);
			};
		}
		final body: Expr = nullSwitch(ident('e'), macro false, [
			// Any binary infix at statement position — the right operand
			// owns the statement's last token in both families.
			caseBindMulti(HX_EXPR, ASSIGN_CTORS.concat(BINOP_RHS_CTORS), [1 => '_r'], macro _binopRhsNoSemi(_r)),
			// `macro class … { members }` always ends with the members `}`.
			caseOf(HX_EXPR, ['MacroClassExpr'], macro true),
			// `macro <operand>` — `}`-terminated iff the operand is a
			// BlockExpr or itself statement-brace-terminated (transparent
			// wrapper: `nested` propagates).
			caseBind(HX_EXPR, 'MacroExpr', [0 => '_o'], macro operandIsBlockExpr(_o) || ${at(ident('_o'), ident('nested'))}),
			// `@:meta expr` — the statement's last token is the inner
			// expr's last token (transparent wrapper).
			caseBind(HX_EXPR, 'MetaExpr', [0 => '_m'], at(field(ident('_m'), 'expr'), ident('nested'))),
			// `return expr` — reaches ExprStmt only via MetaExpr.
			caseBind(HX_EXPR, 'ReturnExpr', [0 => '_v'], at(ident('_v'), macro true)),
			// `if (c) then else else'` — see the worker doc for the
			// nested-vs-top asymmetry.
			caseBind(HX_EXPR, 'IfExpr', [0 => '_s'], ifArm),
			// `c ? a : b` — the else branch owns the statement's last
			// token; re-entering HERE (not endsWithCloseBrace) keeps the
			// binop / lambda tails visible below the ternary.
			caseBind(HX_EXPR, 'Ternary', [2 => '_e2'], at(ident('_e2'), macro true)),
			// `function (…) body` — HxFnExprBody dispatch incl. the
			// ExprBody `@:trailOpt(';')` swallow.
			caseBind(HX_EXPR, 'FnExpr', [0 => '_f'], fnBodySwitch),
			// `for (…) body` — HxForExpr.body carries `@:trailOpt(';')`,
			// same swallow as HxIfExpr.thenBranch.
			caseBind(HX_EXPR, 'ForExpr', [0 => '_s'], macro nested || ${at(field(ident('_s'), 'body'), macro true)}),
			// `(…) -> body` / `(…) => body` — the lambda structs own no
			// terminator slot, so the answer is the body's. Two cases:
			// or-pattern captures must agree in type and the two lambda
			// structs differ.
			caseBind(HX_EXPR, 'ThinParenLambdaExpr', [0 => '_l'], at(field(ident('_l'), 'body'), macro true)),
			caseBind(HX_EXPR, 'ParenLambdaExpr', [0 => '_l'], at(field(ident('_l'), 'body'), macro true)),
			// `untyped <expr>` — transparent keyword wrapper with no
			// terminator slot; whatever swallowed the `;` sits inside the
			// operand, so ask as NESTED.
			caseBind(HX_EXPR, 'UntypedExpr', [0 => '_o'], at(ident('_o'), macro true)),
			// `<operand> #if … #end` — only an `else`-led fragment elides
			// the terminator (see `_condSpliceTailElseLed`).
			caseBind(HX_EXPR, 'CondSpliceTail', [1 => '_raw'], macro _condSpliceTailElseLed(_raw)),
			// Recursion targets (reached through Assign / IfExpr / … —
			// standalone `{…}` at statement position is BlockStmt).
			caseOf(HX_EXPR, STMT_BRACE_TERMINAL_CTORS, macro true),
		], macro endsWithCloseBrace(e));
		return predField(
			'_stmtExprNoSemiAt', [valueArg('e', HX_EXPR), { name: 'nested', type: macro :Bool }], macro :Bool, body,
			'Worker for `stmtExprNoSemi` — `nested` marks an operand descent (inner `@:trailOpt` already claimed the `;`).'
		);
	}

	/**
	 * Any binary infix's right operand at statement position. Carve-out:
	 * `x = {a: 1}` / `x = [1, 2]` / `x = ${expr}` / `x = a is Int` keep
	 * `;` strict (the corpus contract — distinct from the bare forms at
	 * stmt position). The carve-out lives here, not in the
	 * brace-terminal set, so the Meta / Return / If arms still see them
	 * as brace-terminated; it applies to the non-assign family too, so
	 * the two stay indistinguishable to the corpus.
	 */
	private function binopRhsNoSemiField(): Field {
		final recurse: Expr = { expr: ECall(ident('_stmtExprNoSemiAt'), [ident('r'), macro true]), pos: Context.currentPos() };
		final body: Expr = nullSwitch(ident('r'), macro false, [
			caseOf(HX_EXPR, ['ObjectLit', 'ArrayExpr', 'DollarBlockExpr', 'Is'], macro false),
		], recurse);
		return predField(
			'_binopRhsNoSemi', [valueArg('r', HX_EXPR)], macro :Bool, body,
			'Right-operand walk for the binop arms of `_stmtExprNoSemiAt`, with the assign-RHS literal carve-out.'
		);
	}

	/**
	 * True iff a `HxExpr.CondSpliceTail` fragment is an if-chain
	 * CONTINUATION — its raw text, past the condition atom, starts with
	 * the `else` keyword. Such a region cannot begin a statement on its
	 * own: the governing `if` head's `@:trailOpt(';')` already
	 * swallowed the statement's `;` BEFORE the region opened, so
	 * demanding a second `;` after the `#end` terminates the enclosing
	 * block Star one statement early (openfl
	 * `TextEngine.hx:1183`). Every OTHER fragment shape is an
	 * independent guarded statement and the mandatory `;` is what makes
	 * the Trivia-mode parser reject the postfix reading and re-read the
	 * region as a statement-scope `Conditional` (TM
	 * `GpuDirectPipeline.hx:48` — a blanket true glued the two into one
	 * postfix expression and rewrote the file). The condition atom is
	 * skipped with a paren-depth scan, not a regex: `!(js && html5)`
	 * carries spaces INSIDE its parens, so only a depth-0 space ends
	 * the atom; an unbalanced fragment drives the depth negative, the
	 * scan runs to the end, no keyword is read and the answer is the
	 * safe `false`.
	 */
	private function condSpliceTailElseLedField(): Field {
		final verdict: Expr = condSpliceElseVerdictExpr();
		final body: Expr = macro {
			inline function isWs(c: Int): Bool return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
			final n: Int = raw.length;
			var i: Int = 0;
			while (i < n && isWs(StringTools.fastCodeAt(raw, i))) i++;
			var depth: Int = 0;
			while (i < n) {
				final c: Int = StringTools.fastCodeAt(raw, i);
				if (c == '('.code)
					depth++;
				else if (c == ')'.code)
					depth--;
				else if (depth == 0 && isWs(c))
					break;
				i++;
			}
			while (i < n && isWs(StringTools.fastCodeAt(raw, i))) i++;
			$verdict;
		};
		return predField(
			'_condSpliceTailElseLed', [{ name: 'raw', type: macro :String }], macro :Bool, body,
			'True iff a token-splice fragment is an `else`-led if-chain continuation (paren-depth-aware atom skip).'
		);
	}

	/**
	 * The keyword-and-word-boundary verdict spliced at the tail of
	 * `_condSpliceTailElseLed`'s scan (`i` / `n` bound by the enclosing
	 * emitted block): `else` at `i` with a non-ident-char (or EOF)
	 * after it.
	 */
	private function condSpliceElseVerdictExpr(): Expr {
		final kwLen: Int = ELSE_KEYWORD.length;
		return macro {
			final after: Int = i + $v{kwLen};
			if (raw.substr(i, $v{kwLen}) != $v{ELSE_KEYWORD})
				false;
			else if (after >= n)
				true;
			else {
				final nc: Int = StringTools.fastCodeAt(raw, after);
				!((nc >= 'a'.code && nc <= 'z'.code) || (nc >= 'A'.code && nc <= 'Z'.code) || (nc >= '0'.code && nc <= '9'.code)
					|| nc == '_'.code);
			}
		};
	}

	/**
	 * `stmtNoSemi(s) → Bool` — HxStatement-level twin of
	 * `stmtExprNoSemi`: true iff a prior statement of shape `s` needs
	 * no trailing `;` before the next statement in a BlockBody Star.
	 * Consumed by the `@:sep(';', tailRelax, blockEnded('stmtNoSemi'))`
	 * parse gate AND the writer's between-element sep re-emission
	 * (both sides read the meta-named predicate).
	 *
	 *  - `ExprStmt(expr)` → `stmtExprNoSemi(expr)` (carve-out
	 *    semantics included). The Var-family ctors are NOT in the
	 *    unconditional set: their per-stmt `@:trailOpt(';')` is gone,
	 *    the BlockBody Star owns the trailing `;`, and answering FALSE
	 *    for a non-brace init is the signal that the Star must claim
	 *    the byte — the init walk delegates to `endsWithCloseBrace` OR
	 *    the wider parser-side worker (see `HxVarDecl` motivating
	 *    sources: `final isNegative = hasIndex(index) && { … }`,
	 *    `var wrappedCallB = () -> { … }`).
	 *  - `CondSpliceStmt` → recurse into the splice's shared `tail`
	 *    statement (the raw region contributes no terminator);
	 *    `OrphanElseStmt` → recurse into the payload (`else` adds no
	 *    terminator).
	 *  - The brace- / sep- / non-byte-terminated families
	 *    (`NO_SEMI_STMT_CTORS`) → true unconditionally.
	 */
	private function stmtNoSemiField(): Field {
		final varArm: Expr = {
			final ewcb: Expr = { expr: ECall(ident('endsWithCloseBrace'), [ident('_init')]), pos: Context.currentPos() };
			final wide: Expr = { expr: ECall(ident('_stmtExprNoSemiAt'), [ident('_init'), macro true]), pos: Context.currentPos() };
			macro {
				final _init = _d.init;
				_init != null && ($ewcb || $wide);
			};
		}
		final spliceTail: Expr = { expr: ECall(ident('stmtNoSemi'), [field(ident('_i'), 'tail')]), pos: Context.currentPos() };
		final body: Expr = nullSwitch(ident('s'), macro false, [
			caseBind(HX_STATEMENT, 'ExprStmt', [0 => '_e'], macro stmtExprNoSemi(_e)),
			caseBind(HX_STATEMENT, 'CondSpliceStmt', [0 => '_i'], spliceTail),
			caseBind(HX_STATEMENT, 'OrphanElseStmt', [0 => '_s'], macro stmtNoSemi(_s)),
			caseOf(HX_STATEMENT, NO_SEMI_STMT_CTORS, macro true),
			caseBindMulti(HX_STATEMENT, VAR_INIT_STMT_CTORS, [0 => '_d'], varArm),
		], macro false);
		return predField(
			'stmtNoSemi', [valueArg('s', HX_STATEMENT)], macro :Bool, body,
			'True iff a prior BlockBody statement needs no `;` before the next one.'
		);
	}

	/**
	 * The `#if … #end` leaf-walker family over `HxConditionalDecl` —
	 * `betweenImportsTailLeafClassify` / `betweenImportsHeadLeafClassify`
	 * / `tailLeafKeepsBlankAfterConditional`, consumed by the
	 * between-cascade and after-conditional-block emissions in
	 * `WriterLowering.triviaEofStarExpr` (the meta arg names the
	 * generated function). Each walks the conditional's branches to its
	 * TAIL leaf decl (`elseBody` → `elseifs[last..0].body` → `body`,
	 * last element of the FIRST non-empty branch in that priority) or
	 * its HEAD leaf (`body` → `elseifs[0..].body` → `elseBody`, first
	 * element), classifies the leaf via the direction's element
	 * classifier, and propagates `null` up for unrecognised leaves so
	 * the cascade treats the conditional as opaque. The strict
	 * "last/first branch wins" semantic matches what a positional
	 * trailing/leading-element walker owes the cascade: a conditional
	 * whose tail branch ends in a non-import must NOT classify as an
	 * import even when an earlier branch does.
	 */
	private function condLeafWalkerField(name: String, tail: Bool, classifier: String): Field {
		inline function cls(elem: Expr): Expr return { expr: ECall(ident(classifier), [elem]), pos: elem.pos };
		final clauseBody: Expr = field(starElem(HX_COND_DECL, 'elseifs', ident('_cl')), 'body');
		final body: Expr = if (tail) {
			final clsElse: Expr = cls(starElem(HX_COND_DECL, 'elseBody', macro _eb[_eb.length - 1]));
			final clsClause: Expr = cls(starElem(HX_ELSEIF_DECL, 'body', macro _cb[_cb.length - 1]));
			final clsBody: Expr = cls(starElem(HX_COND_DECL, 'body', macro _b[_b.length - 1]));
			macro {
				if (p == null) return null;
				final _eb = p.elseBody;
				if (_eb != null && _eb.length > 0) return $clsElse;
				final _els = p.elseifs;
				var _i: Int = _els.length - 1;
				while (_i >= 0) {
					final _cl = _els[_i];
					final _cb = $clauseBody;
					if (_cb.length > 0) return $clsClause;
					_i--;
				}
				final _b = p.body;
				_b.length > 0 ? $clsBody : null;
			};
		} else {
			final clsBody: Expr = cls(starElem(HX_COND_DECL, 'body', macro _b[0]));
			final clsClause: Expr = cls(starElem(HX_ELSEIF_DECL, 'body', macro _cb[0]));
			final clsElse: Expr = cls(starElem(HX_COND_DECL, 'elseBody', macro _eb[0]));
			macro {
				if (p == null) return null;
				final _b = p.body;
				if (_b.length > 0) return $clsBody;
				final _els = p.elseifs;
				var _i: Int = 0;
				while (_i < _els.length) {
					final _cl = _els[_i];
					final _cb = $clauseBody;
					if (_cb.length > 0) return $clsClause;
					_i++;
				}
				final _eb = p.elseBody;
				_eb != null && _eb.length > 0 ? $clsElse : null;
			};
		}
		return predField(
			name, [valueArg('p', HX_COND_DECL)], macro :Null<{ ctorName: String, path: String }>, body,
			(tail ? 'Tail' : 'Head') + '-leaf classification of a module-level conditional for the between/after cascades.'
		);
	}

	/**
	 * Element classifier for the between-imports walkers: unwraps one
	 * body-Star element's `.decl` and answers `{ctorName, path}` for
	 * the import / using family (positional-path ctors read arg 0, the
	 * alias ctors read the wrapped struct's `path` field), recurses
	 * into a nested `Conditional` via the SAME-direction walker, and
	 * answers `null` for everything else (cascade treats the
	 * conditional as opaque).
	 */
	private function importLeafClassifierField(name: String, walker: String): Field {
		final cases: Array<Case> = [
			caseBind(HX_DECL, 'Conditional', [0 => '_c'], {
				expr: ECall(ident(walker), [ident('_c')]),
				pos: Context.currentPos(),
			})
		];
		for (c in IMPORT_PATH_CTORS) cases.push(caseBind(HX_DECL, c, [0 => '_p'], macro { ctorName: $v{c}, path: _p }));
		for (c in IMPORT_ALIAS_CTORS) cases.push(caseBind(HX_DECL, c, [0 => '_a'], macro { ctorName: $v{c}, path: _a.path }));
		final body: Expr = sw(field(ident('e'), 'decl'), cases, macro null);
		return predField(
			name, [bareArg('e', HX_TOP_LEVEL_DECL)], macro :Null<{ ctorName: String, path: String }>, body,
			'Import/using leaf classification of one conditional body element (null = opaque).'
		);
	}

	/**
	 * Leaf classifier for `tailLeafKeepsBlankAfterConditional` — same
	 * element-unwrap path as the import classifiers but the broader
	 * `KEEPS_BLANK_CTORS` set (import / using family AND type-level
	 * decls; the consumer gate only reads nullness, the ctor name is
	 * informational). Recurses tail-first into a nested `Conditional`.
	 */
	private function keepsBlankLeafClassifierField(): Field {
		final cases: Array<Case> = [
			caseBind(HX_DECL, 'Conditional', [0 => '_c'], {
				expr: ECall(ident('tailLeafKeepsBlankAfterConditional'), [ident('_c')]),
				pos: Context.currentPos(),
			})
		];
		for (c in KEEPS_BLANK_CTORS) cases.push(caseOf(HX_DECL, [c], macro { ctorName: $v{c}, path: '' }));
		final body: Expr = sw(field(ident('e'), 'decl'), cases, macro null);
		return predField(
			'_classifyKeepsBlankLeaf', [bareArg('e', HX_TOP_LEVEL_DECL)], macro :Null<{ ctorName: String, path: String }>, body,
			'Keep-blank leaf classification of one conditional body element (non-null = fork keeps a blank).'
		);
	}

	/** Non-null single-value predicate argument (Star elements are never null). */
	private function bareArg(name: String, rule: String): FunctionArg {
		return { name: name, type: ruleCT(rule) };
	}

	/**
	 * `condSpliceRawWrapsCases(raw) → Bool` — true iff a `#if <cond> …
	 * #end` token-splice raw fragment wraps whole `case` / `default`
	 * clauses (a switch-case-label splice) rather than statements or
	 * expressions (a dangling-else splice). Drives the writer-side
	 * `@:fmt(condSpliceCaseMarkerDedent)` marker dedent on
	 * `HxStatement.CondSpliceStmt`: a case-label splice's leading `#if`
	 * aligns one indent level shallower (the case-list level, matching
	 * its verbatim `case` / `#else` / `#end` markers) than the case
	 * body it parses inside, while a dangling-else splice keeps its
	 * `#if` at the enclosing statement indent. Scans for a line whose
	 * first non-whitespace token is the `case` / `default` keyword —
	 * a pure `String` predicate, identical across AST families
	 * (`HxCondSpliceRaw` is an abstract over `String`).
	 */
	private function condSpliceRawWrapsCasesField(): Field {
		final body: Expr = macro {
			// NOT `inline`: the early returns make it un-inlinable
			// ("Cannot inline a not final return").
			function kwAt(s: String, at: Int, kw: String): Bool {
				final kl: Int = kw.length;
				if (at + kl > s.length) return false;
				for (k in 0...kl) if (StringTools.fastCodeAt(s, at + k) != StringTools.fastCodeAt(kw, k)) return false;
				if (at + kl >= s.length) return true;
				final next: Int = StringTools.fastCodeAt(s, at + kl);
				return !((next >= 'a'.code && next <= 'z'.code) || (next >= 'A'.code && next <= 'Z'.code)
					|| (next >= '0'.code && next <= '9'.code) || next == '_'.code);
			}
			final n: Int = raw.length;
			var atLineStart: Bool = true;
			var hit: Bool = false;
			var i: Int = 0;
			while (i < n && !hit) {
				final c: Int = StringTools.fastCodeAt(raw, i);
				if (c == '\n'.code)
					atLineStart = true;
				else if (atLineStart && c != ' '.code && c != '\t'.code) {
					hit = kwAt(raw, i, 'case') || kwAt(raw, i, 'default');
					atLineStart = false;
				}
				i++;
			}
			hit;
		};
		return predField(
			'condSpliceRawWrapsCases', [{ name: 'raw', type: macro :String }], macro :Bool, body,
			'True iff a token-splice raw fragment has a line starting with the `case` / `default` keyword.'
		);
	}

	/**
	 * Classify a `HxExpr.ArrayExpr` by its first element so the writer
	 * picks the matching `whitespace.bracketConfig.*` inner-padding
	 * policy. One grammar ctor covers three fork bracket kinds; the
	 * distinction lives in the first element's shape (mirrors the
	 * fork's token-based `TokenTreeCheckUtils.getBkOpenType`):
	 *
	 *  - `Arrow` (`k => v`) → map literal (1);
	 *  - `ForExpr` / `WhileExpr` (`[for …]` / `[while …]`) →
	 *    comprehension (2);
	 *  - anything else, or a null first element (empty list) → array
	 *    literal (0) — the default tight bracket has no padding either
	 *    way.
	 *
	 * Consumed by `@:fmt(bracketKindPad)` emission
	 * (`WriterLowering.arrayBracketInsidePolicySpace`), whose runtime
	 * switch maps 1 → `mapLiteralBrackets*`, 2 → `comprehensionBrackets*`,
	 * default → `arrayLiteralBrackets*`.
	 */
	private function arrayBracketKindField(): Field {
		final body: Expr = nullSwitch(ident('e'), macro 0, [
			caseOf(HX_EXPR, ['Arrow'], macro 1),
			caseOf(HX_EXPR, ['ForExpr', 'WhileExpr'], macro 2),
		], macro 0);
		return predField(
			'arrayBracketKind', [valueArg('e', HX_EXPR)], macro :Int, body,
			'Bracket kind of an array-`[…]` ctor by its first element: 1 map literal, 2 comprehension, 0 array literal.'
		);
	}

}
#end
