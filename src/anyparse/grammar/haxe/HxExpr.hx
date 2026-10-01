package anyparse.grammar.haxe;

/**
 * Haxe expression grammar: atoms, unary prefix, postfix, one ternary and the binary-operator suite across
 * fourteen precedence levels. Atoms, prefix and postfix are all reached through `parseHxExprAtom` (the postfix
 * wrapper around `parseHxExprAtomCore`); operator branches carry `@:infix(op, prec[, 'Right'])` so the Pratt
 * strategy generates a precedence-climbing loop around the atom parser.
 *
 * Atom order is load-bearing wherever two branches share a prefix, resolved by `tryBranch` rollback in source
 * order: `HexLit` and `FloatLit` before `IntLit` (`[0-9]+` would stop at `0x` / `3.`); `RegexLit` before the
 * `@:prefix('~')` ctor; `ObjectLit` before `BlockExpr` (the strict `key: value` shape is tried first; an empty
 * `{}` is the zero-field literal); `ECheckTypeExpr` `(e : T)` before `ParenExpr` before `ParenLambdaExpr`
 * (`(x) => e` and `(x : T) => e` route through the first two plus the prec-0 infix `=>`); `NewExpr` and
 * `MetaExpr` before `IdentExpr`; `${` before `$name{` before `$ident`; `IdentExpr` last among the atoms — its
 * terminal is the guarded `HxExprIdentLit`, which rejects control-flow keywords up front so a failed
 * keyword-atom branch fail-rewinds honestly instead of re-matching its keyword as a call head.
 * `SingleStringExpr` is a declarative `HxInterpString` (`Literal` / `Dollar` / `Block` / `Ident` segments
 * under `@:raw`); `DoubleStringExpr` is the `@:rawString` terminal `HxDoubleStringLit` — the slice is kept
 * verbatim, escapes undecoded (its doc says why `@:unescape` is not used). `VarExpr` / `FinalExpr` /
 * `ThrowExpr` are keyword-atom mirrors of the statement forms without the statement terminator, reached when
 * an `HxExpr` is parsed directly.
 *
 * Prefix (`-` `!` `~`) recurses into the atom parser, so it binds tighter than any infix (`-x * 2` is
 * `Mul(Neg(x), 2)`). Postfix (`.name`, `?.name`, `!.name`, `[expr]`, `(args)`, `++`, `--`) is left-recursive
 * in the atom wrapper and binds tighter than both prefix and infix (`-a.b` is `Neg(FieldAccess(a, b))`); `?.`
 * / `!.` are one two-char literal each so `a != b`, `a ?? b` and `a ? b : c` fall through to the Pratt loop
 * untouched. The field suffix is `HxFieldNameLit` (an optional `$` for `obj.$name`).
 *
 * Infix tiers, tightest first: the arrow lambda `x -> body` and `in`, both ASYMMETRIC (`@:infix(op, 13, 'Right', 0)`: they
 * bind tighter than anything on their LEFT and their right operand is a whole expression, so `a ?? x -> b` is `a ?? (x ->
 * b)` and `a + b in c` is `a + (b in c)`); `is` (ASYMMETRIC — its right operand is `HxType`, routed through `parseHxType`;
 * word-boundary dispatch so `island` is not `is`); `%` alone (Haxe binds it TIGHTER than `*` `/`); `*` `/`; `+` `-`;
 * shifts; `|` `&` `^`; `??` (left-assoc — Haxe 4.3 places it between the bitwise tier and the comparisons);
 * comparisons; `...` (`@:fmt(intervalPolicy)` — `whitespace.intervalPolicy`, default `none`; one tier LOOSER
 * than the comparisons, as Haxe has it); `&&`; `||`; the ternary `? :` (`@:ternary('?', ':', 1)`, both
 * trailing operands at `minPrec = 0`, so right-assoc is inherent; `captureTernaryTrail` keeps the same-line
 * comments before `?` and `:`); and prec 0 — every assignment and `=>` (right-assoc). Every tier is
 * the compiler's own (`Context.parse` on Haxe 4.3.7, every binary operator printed parenthesised;
 * `HxPrecedenceTableTest` holds the table). Declaration order within a tier is readability only:
 * `lowerPrattLoop` sorts operators by literal length descending. `SwitchExpr` / `SwitchExprBare` carry
 * `@:fmt(propagateExprPosition)` so cases route through `expressionCase`.
 *
 * `@:memo`: the four `(`-led atoms re-enter the same operand at the same position — a failed `(e : T)` leaves
 * `(e)` to parse `e` again — so without the per-position memo on the atom a paren nest costs `2^depth`.
 */
@:peg
@:memo
enum HxExpr {

	HexLit(v: HxHexLit);

	FloatLit(v: HxFloatLit);

	IntLit(v: HxIntLit);

	@:lit('true', 'false')
	BoolLit(v: Bool);

	@:lit('null')
	NullLit;

	DoubleStringExpr(v: HxDoubleStringLit);

	SingleStringExpr(v: HxInterpString);

	RegexLit(v: HxRegexLit);

	@:lead("${") @:trail('}')
	DollarBlockExpr(expr: HxExpr);

	@:lead("$") @:trail('}')
	DollarReifExpr(v: HxDollarReif);

	@:lead("$")
	DollarIdentExpr(name: HxIdentLit);

	@:trivia @:lead('[') @:trail(']') @:sep(',') @:fmt(trailingComma('trailingCommaArrays'), trailingCommaRemovable,
		wrapRules('arrayLiteralWrap'), mapWrapRules('mapLiteralWrap'), reflowSourceMultiline, bracketKindPad, arrayMatrixWrap,
		propagateExprPosition, uniformStmtBlanks, groupRestProbe, complexItems)
	ArrayExpr(elems: Array<HxExpr>);

	ObjectLit(lit: HxObjectLit);

	@:fmt(leftCurly('blockLeftCurly'), leftCurlyAnonFnOverride('anonFunctionLeftCurly'), emptyCurlyBreak('blockEmptyCurly'),
		rightCurly('blockRightCurly'), keepCurlyBlanks, clearExprPositionNonTail, uniformStmtBlanks,
		trailSepKeepIf('elementIsConditional_HxStatement'))
	@:lead('{') @:trail('}') @:trivia
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	BlockExpr(stmts: Array<HxStatement>);

	ThinParenLambdaExpr(lambda: HxThinParenLambda);

	ECheckTypeExpr(info: HxECheckType);

	@:wrap('(', ')') @:fmt(captureWrapOpenNewline, propagateExprPosition, expressionParenHardFlatten, switchWrapSpace)
	ParenExpr(inner: HxExpr);

	ParenLambdaExpr(lambda: HxParenLambda);

	@:kw('new')
	NewExpr(expr: HxNewExpr);

	@:kw('if') @:fmt(ifPolicy)
	IfExpr(stmt: HxIfExpr);

	@:kw('for') @:fmt(forPolicy)
	ForExpr(stmt: HxForExpr);

	@:kw('for') @:fmt(forPolicy)
	ForReifExpr(inner: HxForReif);

	@:kw('while') @:fmt(whilePolicy)
	WhileExpr(stmt: HxWhileExpr);

	@:kw('switch') @:fmt(switchPolicy, propagateExprPosition)
	SwitchExpr(stmt: HxSwitchStmt);

	@:kw('switch') @:fmt(switchPolicy, propagateExprPosition)
	SwitchExprBare(stmt: HxSwitchStmtBare);

	@:kw('try')
	TryExpr(stmt: HxTryCatchExpr);

	@:kw('untyped')
	UntypedExpr(operand: HxExpr);

	@:kw('untyped')
	UntypedAtom;

	@:kw('macro') @:lead(':') @:fmt(spaceBeforeLead)
	MacroTypeExpr(t: HxType);

	@:kw('macro') @:fmt(clearBracePolicy)
	MacroClassExpr(v: HxMacroClass);

	@:kw('macro') @:fmt(clearExprPosition, clearBracePolicy)
	MacroExpr(operand: HxExpr);

	@:kw('var')
	VarExpr(decl: HxVarDecl);

	@:kw('final')
	FinalExpr(decl: HxVarDecl);

	@:kw('cast') @:fmt(tightKw)
	TypedCastExpr(info: HxTypedCast);

	/**
	 * The bare unsafe cast `cast e`. Its operand is a WHOLE expression, as the compiler parses it
	 * (`Context.parse` on Haxe 4.3.7): `cast a + b` is `cast (a + b)`, `x + b * cast c - d` is
	 * `x + b * cast (c - d)`, `cast (x) is Bool` is `cast ((x) is Bool)` and `cast a ?? b` is
	 * `cast (a ?? b)`. `cast(e, T)` is `TypedCastExpr`, tried first.
	 *
	 * `@:fmt(tightOnParenOperand)` writes `cast(x)` when the operand's LEFTMOST atom is a paren, so
	 * `cast (x) is Bool` keeps the formatter's `cast(x) is Bool`.
	 *
	 * A leading `(e : T)` ends the cast, as it does for the compiler (`@:fmt(atomOperandWhen)`): `cast (a : T) + b` is `(cast
	 * (a : T)) + b`. KNOWN DIVERGENCE, one shape: the compiler ends it at a leading block too (`cast {a;} + b`). A metadata
	 * annotation diverges in what it BINDS TO (see `MetaExpr`); `RefShape.rightGreedyExprKinds`
	 * covers both for `redundant-parens`.
	 */
	@:kw('cast') @:fmt(atomOperandWhen('ECheckTypeExpr'), tightOnParenOperand('ParenExpr', 'ECheckTypeExpr'))
	CastExpr(operand: HxExpr);

	/**
	 * `return` whose whole value is a SELF-TERMINATING token-splice `#if` region — a raw
	 * fragment whose last token before `#end` is a `;`, so nothing after the `#end` belongs to
	 * it: `function get_touchScreen():Bool return #if ios true; #else false; #end`. See
	 * `HxCondSpliceClosedRaw` for the `;` discriminator.
	 *
	 * WHY THIS EXISTS AS ITS OWN CTOR rather than as a general expression-scope one.
	 * `ReturnExpr(value: HxExpr)` sends such a region down the ordinary atom dispatch, where the
	 * last `#if` ctor is `HxExpr.CondSpliceExpr` — a `{raw, tail}` swallow whose `tail` is a
	 * MANDATORY expression parse starting after `#end`. At a member boundary that tail is the
	 * NEXT MEMBER's leading `public` / `static` word read as an `IdentExpr`, so the member
	 * carried a modifier it does not own and `member-order --fix` moved the two together —
	 * silently turning a public field private while the file still compiled. This is the
	 * `HxFnBody.CondBody`-before-`ExprBody` fix one level down: there the region IS the body,
	 * here it is the VALUE of a `return`.
	 *
	 * A general `HxExpr` ctor for the same raw shape is why the `return` keyword rides the ctor:
	 * a raw terminal matches ANY bytes, so at expression-STATEMENT position it claims two
	 * constructs that only parse today because nothing in the statement Star matches them — a
	 * switch's guarded `case` region (`HxConditionalCase` relies on the case-body statement Star
	 * failing) and a `@:meta`-prefixed statement region, which then gains a written `;` after
	 * its `#end`. Keying the ctor on `return` keeps it out of statement position entirely.
	 *
	 * Cost, stated plainly: the swallow SURVIVES everywhere this ctor does not reach — a
	 * statement-position `@:meta`-prefixed region still absorbs the next statement, and so does
	 * a block-scope `return` region, which goes through `HxStatement.ReturnStmt`. Closing those
	 * needs the raw region to stop being reachable from `ExprStmt`, or the structured
	 * `HxConditionalSemiExpr` reading, whose writer reflows the region onto one line and
	 * drifts files the formatter leaves alone. A MULTI-LINE region is reached too: it has to be
	 * re-indented when the `return` glues onto its `#if`, which the terminal does through
	 * `@:writeNormalize('reindentBlock')`.
	 */
	@:kw('return')
	CondSpliceReturnExpr(inner: HxCondSpliceClosedRegion);

	@:kw('return') @:fmt(propagateExprPosition)
	ReturnExpr(value: HxExpr);

	@:kw('return')
	VoidReturnExpr;

	@:kw('throw')
	ThrowExpr(value: HxExpr);

	@:kw('break')
	BreakExpr;

	@:kw('continue')
	ContinueExpr;

	@:kw('inline')
	InlineExpr(operand: HxExpr);

	@:kw('function')
	NamedFnExpr(decl: HxFnDecl);

	@:kw('function') @:fmt(anonFuncParens)
	FnExpr(fn: HxFnExpr);

	@:kw('#if') @:trail('#end') @:fmt(condExprFitGroup)
	ConditionalExpr(inner: HxConditionalExpr);

	@:kw('#if') @:trail('#end')
	ConditionalArgs(inner: HxConditionalArgs);

	/**
	 * Token-splice `#if` region whose fragment is a run of complete
	 * operands each followed by an operator whose right operand lives
	 * after the `#end` — see `HxCondSpliceOpExpr`. Dispatched BEFORE
	 * the raw `CondSpliceExpr` so a dangling-operator fragment keeps its operands as nodes.
	 */
	@:kw('#if')
	CondSpliceOpExpr(inner: HxCondSpliceOpExpr);

	/**
	 * Token-splice region whose every branch opens one `(` that the
	 * shared tail closes — see `HxCondSpliceCallOpen`. Dispatched BEFORE
	 * `CondSpliceExpr`, whose tail has no slot for that `)`.
	 */
	@:kw('#if') @:trail(')')
	CondSpliceCallOpenExpr(inner: HxCondSpliceCallOpen);

	/**
	 * Token-splice fallback for `#if` regions no structural
	 * conditional can represent — see `HxCondSpliceExpr`.
	 */
	@:kw('#if')
	CondSpliceExpr(inner: HxCondSpliceExpr);

	/**
	 * POST-operand token-splice conditional — a fragment spliced onto
	 * a complete operand: `A + B #if mobile - 120 #end` /
	 * `a.wrong || b.wrong #if !mobile || c.wrong #end` /
	 * `g(x, y #if FEATURE, z #end)` (live dogfood shapes). The
	 * fragment binds tightest as a postfix on the operand;
	 * `HxCondSpliceTailBody` reads it as a leading infix operator, a
	 * leading comma-separated run, or — when neither structured
	 * branch fits — the verbatim raw capture the whole shape used to
	 * take.
	 */
	@:postfix('#if') @:fmt(capturePostfixOpSpace)
	CondSpliceTail(operand: HxExpr, body: HxCondSpliceTailBody);

	/**
	 * KNOWN DIVERGENCE from the compiler, in what the annotation BINDS TO. This grammar wraps
	 * the whole expression that follows, so `@:privateAccess A.s * B.s + 1` projects with the
	 * annotation over the entire sum; the compiler binds it to the immediate primary, and
	 * that source fails to compile with `Cannot access private field` on `B.s`. The compiler moves the annotation
	 * onto the LEFTMOST operand of a binary chain or a ternary condition (`make_meta` in its parser) but keeps it
	 * over a whole assignment (`@:m a = b`), so no precedence for a prefix operator reproduces it: a rotation is
	 * what would. A before/after AST comparison cannot detect the divergence — both sides come from this parser —
	 * which is why `redundant-parens` asks `RefShape.prefixAnnotationKinds` / `parenRequiredHostKinds` instead.
	 */
	MetaExpr(v: HxMetaExpr);

	IdentExpr(v: HxExprIdentLit);

	@:prefix('++')
	PreIncr(operand: HxExpr);

	@:prefix('--')
	PreDecr(operand: HxExpr);

	@:prefix('-')
	Neg(operand: HxExpr);

	@:prefix('!')
	Not(operand: HxExpr);

	@:prefix('~')
	BitNot(operand: HxExpr);

	@:prefix('...') @:fmt(tight)
	Spread(operand: HxExpr);

	@:postfix('.') @:fmt(methodChain('methodChainWrap'), captureChainNewline)
	FieldAccess(operand: HxExpr, field: HxFieldNameLit);

	@:postfix('?.')
	SafeFieldAccess(operand: HxExpr, field: HxFieldNameLit);

	@:postfix('!.')
	ForceFieldAccess(operand: HxExpr, field: HxFieldNameLit);

	@:postfix('[', ']') @:fmt(accessBrackets)
	IndexAccess(operand: HxExpr, index: HxExpr);

	@:postfix('(', ')') @:sep(',') @:fmt(trailingComma('trailingCommaArgs'), trailingCommaRemovable, callParens, callParensInside,
		wrapRules('callParameterWrap'), methodChain('methodChainWrap'), propagateExprPosition, callArgChainNest, groupRestProbe,
		arrowValueIfElemTrail, complexItems)
	Call(operand: HxExpr, args: Array<HxExpr>);

	@:postfix('++')
	PostIncr(operand: HxExpr);

	@:postfix('--')
	PostDecr(operand: HxExpr);

	@:infix('*', 10) @:fmt(captureRhsTrail)
	Mul(left: HxExpr, right: HxExpr);

	@:infix('/', 10) @:fmt(captureRhsTrail)
	Div(left: HxExpr, right: HxExpr);

	// Prec 11, above `*` / `/` — Haxe binds `%` tighter than both
	// (`2 * 7 % 4` is 6). Declared here to keep the arithmetic ctors
	// adjacent; declaration order carries no meaning for the generated
	// dispatch, which sorts by operator-literal length.
	@:infix('%', 11) @:fmt(captureRhsTrail)
	Mod(left: HxExpr, right: HxExpr);

	@:infix('+', 9) @:fmt(captureChainNewline)
	Add(left: HxExpr, right: HxExpr);

	@:infix('-', 9) @:fmt(captureChainNewline)
	Sub(left: HxExpr, right: HxExpr);

	@:infix('<<', 8) @:fmt(captureRhsTrail)
	Shl(left: HxExpr, right: HxExpr);

	@:infix('>>>', 8) @:fmt(captureRhsTrail)
	UShr(left: HxExpr, right: HxExpr);

	@:infix('>>', 8) @:fmt(captureRhsTrail)
	Shr(left: HxExpr, right: HxExpr);

	@:infix('|', 7) @:fmt(captureRhsTrail)
	BitOr(left: HxExpr, right: HxExpr);

	@:infix('&', 7) @:fmt(captureRhsTrail)
	BitAnd(left: HxExpr, right: HxExpr);

	@:infix('^', 7) @:fmt(captureRhsTrail)
	BitXor(left: HxExpr, right: HxExpr);

	// Prec 6, between the bitwise tier and the comparisons, left-associative — where Haxe 4.3
	// puts `??` (probed on 4.3.7): `a ?? b == c` is `(a ?? b) == c`, `a ?? b | c` is
	// `a ?? (b | c)`, and `a ?? b ?? c` is `(a ?? b) ?? c`.
	@:infix('??', 6) @:fmt(captureChainNewline)
	NullCoal(left: HxExpr, right: HxExpr);

	@:infix('==', 5) @:fmt(captureRhsTrail)
	Eq(left: HxExpr, right: HxExpr);

	@:infix('!=', 5) @:fmt(captureRhsTrail)
	NotEq(left: HxExpr, right: HxExpr);

	@:infix('<=', 5) @:fmt(captureRhsTrail)
	LtEq(left: HxExpr, right: HxExpr);

	@:infix('>=', 5) @:fmt(captureRhsTrail)
	GtEq(left: HxExpr, right: HxExpr);

	@:infix('<', 5) @:fmt(captureRhsTrail)
	Lt(left: HxExpr, right: HxExpr);

	@:infix('>', 5) @:fmt(captureRhsTrail)
	Gt(left: HxExpr, right: HxExpr);

	// Prec 4, one tier LOOSER than the comparisons and tighter than `&&` — Haxe 4.3's own slot
	// (probed on 4.3.7): `a ... b == c` is `a ... (b == c)`, `a && b ... c` is `a && (b ... c)`.
	@:infix('...', 4) @:fmt(intervalPolicy)
	Interval(left: HxExpr, right: HxExpr);

	// Prec 12, above every other binary operator but the asymmetric `in` / `->` — Haxe 4.3 binds
	// `is` tighter than all of them (`a + b is T` is `a + (b is T)`, `a ?? b is T` is
	// `a ?? (b is T)`), while a prefix operator still binds first (`-a is T` is `(-a) is T`).
	@:infix('is', 12) @:fmt(captureRhsTrail)
	Is(left: HxExpr, right: HxType);

	@:infix('&&', 3) @:fmt(captureChainNewline)
	And(left: HxExpr, right: HxExpr);

	@:infix('||', 2) @:fmt(captureChainNewline)
	Or(left: HxExpr, right: HxExpr);

	@:ternary('?', ':', 1) @:fmt(captureTernaryTrail)
	Ternary(cond: HxExpr, thenExpr: HxExpr, elseExpr: HxExpr);

	// ASYMMETRIC (probed on 4.3.7): Haxe's tightest binary operator on its LEFT — `a + b in c` is
	// `a + (b in c)`, `a ?? b in c` is `a ?? (b in c)` — and right-associative with nothing binding
	// across it on its RIGHT: `a in b + c` is `a in (b + c)`, `a in b = c` is `a in (b = c)`. So prec
	// 13 for the left operand, prec 0 for the right one. The one shape no precedence pair reaches:
	// the compiler rotates a ternary OUT of `in`'s right operand (`a in b ? c : d` is
	// `(a in b) ? c : d`) while still letting an assignment in; this grammar reads
	// `a in (b ? c : d)` there.
	@:infix('in', 13, 'Right', 0)
	In(left: HxExpr, right: HxExpr);

	@:infix('=', 0, 'Right') @:fmt(propagateExprPosition)
	Assign(left: HxExpr, right: HxExpr);

	@:infix('+=', 0, 'Right') @:fmt(propagateExprPosition)
	AddAssign(left: HxExpr, right: HxExpr);

	@:infix('-=', 0, 'Right') @:fmt(propagateExprPosition)
	SubAssign(left: HxExpr, right: HxExpr);

	@:infix('*=', 0, 'Right') @:fmt(propagateExprPosition)
	MulAssign(left: HxExpr, right: HxExpr);

	@:infix('/=', 0, 'Right') @:fmt(propagateExprPosition)
	DivAssign(left: HxExpr, right: HxExpr);

	@:infix('%=', 0, 'Right') @:fmt(propagateExprPosition)
	ModAssign(left: HxExpr, right: HxExpr);

	@:infix('<<=', 0, 'Right') @:fmt(propagateExprPosition)
	ShlAssign(left: HxExpr, right: HxExpr);

	@:infix('>>>=', 0, 'Right') @:fmt(propagateExprPosition)
	UShrAssign(left: HxExpr, right: HxExpr);

	@:infix('>>=', 0, 'Right') @:fmt(propagateExprPosition)
	ShrAssign(left: HxExpr, right: HxExpr);

	@:infix('|=', 0, 'Right') @:fmt(propagateExprPosition)
	BitOrAssign(left: HxExpr, right: HxExpr);

	@:infix('&=', 0, 'Right') @:fmt(propagateExprPosition)
	BitAndAssign(left: HxExpr, right: HxExpr);

	@:infix('^=', 0, 'Right') @:fmt(propagateExprPosition)
	BitXorAssign(left: HxExpr, right: HxExpr);

	@:infix('??=', 0, 'Right') @:fmt(propagateExprPosition)
	NullCoalAssign(left: HxExpr, right: HxExpr);

	@:infix('&&=', 0, 'Right') @:fmt(propagateExprPosition)
	BoolAndAssign(left: HxExpr, right: HxExpr);

	@:infix('||=', 0, 'Right') @:fmt(propagateExprPosition)
	BoolOrAssign(left: HxExpr, right: HxExpr);

	// The arrow lambda `x -> body`. ASYMMETRIC like `in`: the parameter binds tighter than any
	// binary operator to its left — `a ?? x -> b` is `a ?? (x -> b)`, `a + x -> b` is
	// `a + (x -> b)` — and the body is a whole expression (`x -> a ? b : c`, `x -> a = b`).
	@:infix('->', 13, 'Right', 0) @:fmt(propagateExprPosition, propagateArrowLambdaBody, arrowBodyLineWrap)
	ThinArrow(left: HxExpr, right: HxExpr);

	@:infix('=>', 0, 'Right') @:fmt(propagateExprPosition)
	Arrow(left: HxExpr, right: HxExpr);

}
