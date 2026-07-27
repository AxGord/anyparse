package anyparse.grammar.haxe;

/**
 * Plugin-side AST predicates over `HxExpr` consumed by macro-neutral
 * runtime adapters on `WriteOptions`.
 *
 * Lives in the grammar package so macro core stays free of any
 * `HxExpr`-specific logic. `HaxeFormat.defaultWriteOptions` wires the
 * static methods here into the adapter fields the macro emits calls
 * for (e.g. `endsWithCloseBrace` for `@:fmt(trailOptShapeGate)`).
 *
 * All predicates take `Dynamic` because the same adapter is invoked
 * from both Plain-mode writers (which pass `HxExpr` enum values) and
 * Trivia-mode writers (which pass `Trivial<HxExprT>` struct wrappers
 * around the paired enum). Constructor identification goes through
 * `Type.enumConstructor` rather than direct pattern matching so the
 * switch arms match against both the Plain `HxExpr` and the synthesised
 * `HxExprT` enum — they share constructor names but are distinct types
 * at runtime, so a literal `case BlockExpr(_)` would only fire on one.
 */
@:nullSafety(Strict)
final class HxExprUtil {

	/**
	 * True iff `raw` is a control-flow expression whose `}` may serve
	 * as a statement terminator on the rhs of `var x = …`. Drives the
	 * writer-side gate for `@:trailOpt(';')` on `var` / `final`
	 * declarations.
	 *
	 * **Drop `;`** (gate true):
	 *  - `SwitchExpr` / `SwitchExprBare` — `var x = switch (y) { … }`
	 *    (haxe-formatter `issue_119_expression_case`,
	 *    `issue_254_case_colon{,_next,_keep}`).
	 *  - `FnExpr` with `body=BlockBody` — `var f = function() { … }`
	 *    (haxe-formatter `inline_calls`). Bare-expression bodies
	 *    (`function(x) trace(x)`) keep the `;`.
	 *  - `TryExpr` whose last catch clause's body is itself in this set
	 *    (recursive). Bare-catch `try foo() catch (_) null` keeps the
	 *    `;` because `null` is not in the set.
	 *
	 * **Keep `;`** (gate false — explicit non-set):
	 *  - `BlockExpr` — `var x = { 1; 2; };` is a block-as-expression
	 *    value, not a statement.
	 *  - `ObjectLit` — `var o = {a: 1};` (haxe-formatter
	 *    `issue_101_comment_in_object_literal`, `space_in_anonymous_object`).
	 *  - `IfExpr` — `var x = if (a) { 1; } else { 2; };` (haxe-formatter
	 *    `issue_42_if_after_assign_with_blocks_on_same_line`).
	 *  - All prefix / infix / postfix wrappers and everything else.
	 *
	 * The discrimination follows haxe-formatter's empirical rule from
	 * the corpus: only "control-flow expressions that visually look
	 * like statements" (switch / try / function-block) drop the
	 * trailing `;`; literal-shaped expressions (object / block / array
	 * / paren / if-as-expression) keep it.
	 */
	/**
	 * HxExpr `*Assign` ctor names — every right-associative `=` infix
	 * (`Assign` plus the 14 compound forms `+=` / `-=` / `*=` / `/=` /
	 * `%=` / `<<=` / `>>>=` / `>>=` / `|=` / `&=` / `^=` / `??=` /
	 * `&&=` / `||=`). Used by `stmtExprNoSemi` to walk through an
	 * assignment-statement's right operand: the last token of
	 * `x = if (…) {…} else {…}` is the `}` of the else block, so the
	 * trailing `;` is optional just like for a bare `if (…) {…} else
	 * {…}` statement.
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
	 * `HxExpr` ctor names for every NON-assign binary infix operator whose
	 * right operand is an `HxExpr`: `*` `/` `%` `+` `-` `<<` `>>>` `>>`
	 * `|` `&` `^` `==` `!=` `<=` `>=` `<` `>` `...` `&&` `||` `??` `in`
	 * `->` `=>`. Consumed by `stmtExprNoSemi` through the same
	 * right-operand walk `ASSIGN_CTORS` gets: the statement's last token
	  * IS the right operand's last token, so `a << function () { ... }` and
	 * `s += "" + switch (e) { ... }` are `}`-terminated exactly like the
	 * already-supported `a = switch (e) { ... }`.
	 *
	 * Haxe's own rule is purely lexical -- `Parser.semicolon` makes the `;`
	 * optional whenever the previously consumed token was `}`, with no
	 * regard for which operator produced it. Restricting the walk to the
	 * `*Assign` family was therefore an under-approximation, not a
	 * deliberate narrowing; real sources hit it constantly (Pony
	 * `pony/pixi/nape/NapeGroupView.hx:47` `obj.core.onDestroy < function
	 * () { ... }` followed by `return obj;`, openfl
	 * `openfl/text/_internal/TextEngine.hx:540` `font += "" + switch
	  * (fontName) { ... }`, std `cs|java|jvm|python/_std/Std.hx` `final
	 * isNegative = hasIndex(index) && { ... }`).
	 *
	 * `Is` is deliberately absent: its right operand is an `HxType`, not
	 * an `HxExpr`, and `a is T` already carries its own statement-position
	 * entry in `STMT_BRACE_TERMINAL_CTORS`. `Ternary` is absent because it
	 * is not binary -- it has its own arm in `stmtExprNoSemi` walking
	 * `elseExpr` (parameter index 2, not 1).
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
	 * `HxExpr` constructors whose surface form always ends with `}`:
	 * `switch … { … }`, a `{ … }` block, a `{ k: v }` object literal,
	 * and `macro class … { members }`. No recursion needed.
	 */
	private static final BRACE_TERMINAL_CTORS: Array<String> = [
		'SwitchExpr',
		'SwitchExprBare',
		'BlockExpr',
		'ObjectLit',
		'MacroClassExpr',
	];

	/**
		  * `HxExpr` constructors that, at statement-expression position, leave
	 * the statement `}`/`]`/literal-terminated so no trailing `;` is
	 * needed: `{ … }` block, `{ k: v }` object literal, `[ … ]` array,
	 * `${expr}` interpolation block, `$b{exprs}` reification splice, and
	 * `a is T`. These are the
	 * recursion target reached through Assign / If / Meta / Return arms.
	 *
	 * `DollarReifExpr` is the `@:lead("$") @:trail('}')` sibling of
	 * `DollarBlockExpr` -- `$b{loadBody}` / `$a{args}` / `$v{value}`
	 * spliced as a bare statement inside a `macro class { ... }` body. Its
	 * last token is the splice's own `}`, exactly like `${expr}`.
	 * Motivating source: Pony `pony/magic/builder/DIBuilder.hx:353`, four
	 * sites of `tasks.add();` / `$b{loadBody}` / `tasks.end();`. It is NOT
	 * added to `binopRhsNoSemi`'s carve-out: that carve-out encodes a
	 * corpus contract for `x = ${expr}` / `x = {a: 1}` / `x = [1, 2]`, and
	 * no fixture covers a reification splice as an assignment RHS.
	 */
	/**
	 * The keyword a `HxExpr.CondSpliceTail` fragment starts with when it
	 * is an if-chain continuation rather than a standalone guarded
	 * statement. See `condSpliceTailElseLed`.
	 */
	private static final ELSE_KEYWORD: String = 'else';

	private static final STMT_BRACE_TERMINAL_CTORS: Array<String> = [
		'BlockExpr',
		'ObjectLit',
		'ArrayExpr',
		'DollarBlockExpr',
		'DollarReifExpr',
		'Is',
	];

	/**
	 * Statement constructors whose surface form ends with `}` — the `}`
	 * is the last token, so no trailing `;` is needed. Byte-check `'}'`
	 * would also match; the explicit set makes the intent clear.
	 */
	private static final BRACE_TERMINAL_STMT_CTORS: Array<String> = [
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
		// `#if <raw ending on '{'> #end <stmts> }` - the ctor's own `@:trail('}')` is its last token.
		'CondSpliceBlockOpen',
		// `#if <raw ending on 'switch (..) {'> #end <cases> } }` - `body`'s `@:trail('}')` is its last token.
		'CondSpliceSwitchOpen',
	];

	/**
	 * Statement constructors whose own `@:trail(';')` / `@:lit(';')`
	 * consumed the separator; the byte at `_prevEndPos - 1` is `;` so a
	 * byte-check also passes, but the explicit set keeps the intent clear.
	 */
	private static final SEP_TERMINAL_STMT_CTORS: Array<String> = [
		'VoidReturnStmt',
		'ThrowStmt',
		'DoWhileStmt',
		'ErrorStmt',
		'EmptyStmt',
		'TryCatchStmtBare',
	];

	/**
	 * Statement constructors the byte-check misses: `#if … #end`
	 * (`Conditional`) ends with `d`, and the `....` placeholder
	 * (`EllipsisStmt`) ends with `.`. The AST predicate is required here.
	 */
	private static final NON_BYTE_TERMINAL_STMT_CTORS: Array<String> = ['Conditional', 'EllipsisStmt', 'CondSpliceBlockClose'];

	/**
	 * `var` / `final` (and static variants) statement constructors whose
	 * brace-termination depends on the init expression — routed through
	 * `varInitEndsWithBrace`.
	 */
	private static final VAR_INIT_STMT_CTORS: Array<String> = ['VarStmt', 'FinalStmt', 'StaticVarStmt', 'StaticFinalStmt'];

	private static function endsWithCloseBrace(raw: Null<Dynamic>): Bool {
		final e: Null<Dynamic> = unwrap(raw);
		if (e == null) return false;
		final ctor: Null<String> = Type.enumConstructor(e);
		if (ctor == null) return false;
		// Always brace-terminated:
		//  - `SwitchExpr` / `SwitchExprBare` — `switch … { … }`
		//  - `BlockExpr` — `{ … }` block expression
		//  - `ObjectLit` — `{ k: v, … }` object literal
		//  - `MacroClassExpr` — `macro class … { members }`
		if (BRACE_TERMINAL_CTORS.contains(ctor)) return true;
		return switch ctor {
			// `macro <operand>` / `@:meta <operand>` — pure wrappers,
			// recurse on the wrapped expression. Required for the
			// `final x = macro for/if/…` idiom in macro-heavy code where
			// the outer stmt's trailing `;` was consumed by the operand's
			// own `@:trailOpt(';')` (so the predicate must declare
			// block-ended without seeing the `;` byte at `_prevEndPos-1`).
			case 'MacroExpr':
				final params: Null<Array<Dynamic>> = Type.enumParameters(e);
				params != null && params.length > 0 && endsWithCloseBrace(params[0]);
			case 'MetaExpr':
				metaExprEndsWithBrace(e);
			// `a ? b : c` — last evaluated branch is `c` (elseExpr).
			case 'Ternary':
				final params: Null<Array<Dynamic>> = Type.enumParameters(e);
				params != null && params.length >= 3 && endsWithCloseBrace(params[2]);
			// `for (…) body` / `while (…) body` — body's own `@:trailOpt(';')`
			// either consumed `;` (block-ended via `;`-byte) OR body itself
			// ends with `}` (recurse). Either way, no further sep is required
			// before the next stmt.
			case 'ForExpr', 'WhileExpr':
				loopBodyEndsWithBrace(e);
			// `if (c) then else else'` — recurse on the last evaluated
			// branch (else if present, otherwise then). Pre-fix Pattern B
			// `final v = if (a) {…} else {…}` left the outer stmt visible
			// to `stmtNoSemi` as `FinalStmt` whose init was `IfExpr`; the
			// outer `FinalStmt` handler delegates to `endsWithCloseBrace`,
			// so the recursive case here closes the loop.
			case 'IfExpr':
				ifExprEndsWithBrace(e);
			case 'FnExpr':
				fnExprEndsWithBrace(e);
			case 'TryExpr':
				tryExprEndsWithBrace(e);
			case _: false;
		};
	}

	/**
	 * True iff `raw`, standing as a statement (`HxStatement.ExprStmt`),
	 * is `}`-terminated so Haxe needs no trailing `;`. Drives the
	 * parser-side `@:fmt(trailOptParseGate('stmtExprNoSemi'))` gate on
	 * `ExprStmt`: gate true → `;` optional (consumed if present); gate
	 * false → `;` required (the parser throws to terminate the
	 * statement, preserving multi-statement boundary detection — the
	 * property a blanket `:trailOpt` would destroy on the catch-all).
	 *
	 * **No `;`** (gate true):
	 *  - `MacroClassExpr` (`macro class … { members }`) — always
	 *    `}`-terminated by the members block.
	 *  - `MacroExpr` whose operand is `BlockExpr` (`macro { … }`) or is
	 *    itself in this set (`macro switch (e) { … }`,
	 *    `macro try { … } catch …`) — recursive.
	 *  - `Assign` / compound-assign (`+=`, `??=`, `&&=`, …) whose right
	 *    operand recursively satisfies the predicate — e.g.
	 *    `fun.expr = if (…) {…} else {…}`, `x += switch (e) { … }`.
	 *    The last token of the statement IS the RHS's last token, so
	 *    the same `}`-terminated rule applies.
	 *  - `IfExpr` whose `else` branch is block-shaped (recursive on
	 *    `elseBranch`, or `thenBranch` when there is no `else`) —
	 *    `if (…) {…} else {…}` reaches `ExprStmt` only via Assign /
	 *    paren / arrow RHS; the statement-position `if` routes through
	 *    `HxStatement.IfStmt` instead.
	 *  - `MetaExpr` whose inner expression recursively satisfies the
	 *    predicate — `@:nullSafety(Off) return switch (…) { … }`,
	 *    `@:m if (…) { … }`. Routes through `ExprStmt` because the
	 *    leading `@:` forces the meta-wrapped expression path; the
	 *    statement's last token is the inner expr's last token.
	 *  - `ReturnExpr` whose value recursively satisfies the predicate
	 *    — `return switch (…) { … }` reaches `ExprStmt` only via
	 *    `MetaExpr` (statement-position `return` routes through
	 *    `HxStatement.ReturnStmt`).
	 *  - `BlockExpr` — recursion target only (a standalone block at
	 *    statement position is `HxStatement.BlockStmt`, never
	 *    `ExprStmt(BlockExpr)`), reached when an Assign's RHS or the
	 *    body of an `IfExpr` branch is `{ … }`.
	 *  - `ObjectLit` — bare `{ foo: 1 }` at statement position. `BlockStmt`'s greedy `{` attempt fails on the
	 *    `IDENT:` field shape, so `ExprStmt(ObjectLit)` is reached and
	 *    the `}` is the statement's last token. NOT triggered through
	 *    Assign-RHS — `x = {a: 1};` keeps `;` strict per the corpus contract (see the `*Assign` carve-out below).
	 *  - `ArrayExpr` — bare `[1, 2, 3]` / `[if (foo) bar else foo, …]`
	 *    at statement position. The closing `]` is the
	 *    statement's last token, same as `}` for ObjectLit / BlockExpr.
	 *    NOT triggered through Assign-RHS — `x = [1, 2];` keeps `;`
	 *    strict (same carve-out as ObjectLit). Drives `sameline/issue_365_array_comprehension`.
	 *  - `Is` — bare `x is Type` at statement position. NOT brace-terminated — `Is`'s last token is the type-ref leaf
	 *    (typically an ident like `String`). The corpus contract from
	 *    `whitespace/issue_605_operator_is` allows `{x is String}` as
	 *    a single-stmt block with no trailing `;` before the closing
	 *    `}`. Permissive extension of "last-stmt-in-block" semantics,
	 *    consistent with the existing permissive handling of
	 *    `{a:1} {b:2}` (two ObjectLit stmts without `;`). NOT
	 *    triggered through Assign-RHS — `x = a is Int;` keeps `;`
	 *    strict (same carve-out as ObjectLit / ArrayExpr /
	 *    DollarBlockExpr).
	 *  - Everything `endsWithCloseBrace` accepts (`SwitchExpr` /
	 *    `SwitchExprBare` / `FnExpr` block-body / `TryExpr` recursive):
	 *    as a statement these are `}`-terminated too.
	 *
	 * **`;` required** (gate false): every other shape — `Call`,
	 * non-assign binop, ternary, etc. — BUT see below.
	 *
	 * **Note (ω-slice-X3): this predicate is no longer the sole
	 * authority on `ExprStmt`'s trail-`;` elision.** The parse-time gate in
	 * `Lowering.hx` is a 3-disjunct OR — the intrinsic check here, plus
	 * `peekKw(ctx, "else")` (if-then-body before `else`), plus
	 * `peekLit(ctx, "}")` (any expr as the last stmt of an
	 * enclosing block). The peek-`}` disjunct generalises the per-ctor
	 * direct-return arms above (every brace/bracket-terminated expr only
	 * got `;` elision because its OWN tail token happened to close one —
	 * but the principled invariant is extrinsic: when the next non-trivia
	 * byte IS the enclosing block's `}`, the closing brace itself acts as
	 * the statement separator). Concretely: a bare `Call` / `IdentExpr` /
	 * non-assign-binop as the last stmt of a fn body, switch arm, or
	 * block-bodied for/while/if now elides its `;` at the parser level via
	 * the peek-`}` disjunct, NOT via any change to this predicate. The
	 * intrinsic arms below remain load-bearing for the recursive paths
	 * (Assign / Meta / Return / If recursing into RHS or branch) where the
	 * peek-`}` disjunct cannot reach (the lookahead is checked at the
	 * outer `ExprStmt`, not at the inner recursion). Search for
	 * `ω-slice-X3` in `Lowering.hx` to find the gateCond site.
	 *
	 * Distinct from `endsWithCloseBrace` (the writer-side `var x = …`
	 * rhs predicate), which deliberately returns `false` for
	 * `MacroExpr` / `BlockExpr` / `IfExpr` — the parser-statement gate
	 * needs the opposite answer for `macro { … }` and the Assign / IfExpr recursion cases. `endsWithCloseBrace` is reused read-only
	 * for the non-recursive tail cases (`SwitchExpr` etc., where the
	 * answer coincides) and is NOT modified — `HxClassMember.VarMember`/
	 * `FinalMember`'s writer-side `@:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))`
	 * gate keeps its stricter behaviour. The statement-side `Var`/`Final`/`StaticVar`/`StaticFinalStmt` ctors do not carry `trailOptShapeGate` — they own no `@:trailOpt(';')`
	 * at all; the BlockBody Star sep claims the trailing byte instead.
	 *
	 * `Dynamic` argument so the same predicate fires on Plain-mode
	 * `HxExpr` enum values and Trivia-mode `Trivial<HxExprT>` wrappers
	 * (see `unwrap`).
	 */
	public static function stmtExprNoSemi(raw: Null<Dynamic>): Bool return stmtExprNoSemiAt(raw, false);

	/**
	 * `stmtExprNoSemi`'s worker, carrying the one bit the public entry
	 * cannot: whether `raw` sits at the TOP of an `ExprStmt` (`nested`
	 * false) or was reached by walking into an operand of it (`nested`
	 * true).
	 *
	 * The bit exists for the three ctors whose grammar node owns an inner
	 * `@:trailOpt(';')` -- `IfExpr` (`HxIfExpr.thenBranch`), `ForExpr`
	 * (`HxForExpr.body`) and `FnExpr` (`HxFnBody.ExprBody`). Those slots
	 * consume the statement's `;` before the `ExprStmt` gate ever runs, so
	 * for a NESTED occurrence the gate must not `expectLit` a second one:
	 * `a << if (e) f(m); x();` failed at `x` while `a << if (e) f(m);;
	 * x();` parsed -- that pair is what exposed the swallow.
	 *
	 * At the TOP of an `ExprStmt` the same relaxation is WRONG. A
	 * statement that starts with `if` / `for` / `function` is dispatched to
	 * `HxStatement.IfStmt` / `ForStmt` / `LocalFnStmt` first and only
	 * fail-rewinds into the `ExprStmt` catch-all when that branch could NOT
	 * parse it -- which for `if (c) g() h();` is precisely because the
	 * then-body's `;` is missing. Relaxing there re-accepts that input,
	 * which `HxControlFlowSliceTest.testElsePeekScopedToElseOnly` pins as
	 * fatal. So the expression-position node reached top-level is exactly
	 * the statement-position node that already failed, and it must keep the
	 * strict answer.
	 *
	  * The alternative discriminator -- the trivia `<field>TrailPresent`
	 * synth slot, which records whether the `;` really was consumed -- was
	 * tried and rejected: `struct-trailopt-source-track` only synthesises
	 * it in trivia mode, so plain-mode parsing (what `hxq ast` and
	 * `hxq self-status` run) would have kept rejecting every real source
	 * this slice targets, and the two modes would have accepted different
	 * languages. Position is available in both.
	 *
	 * Transparent wrappers (`MacroExpr` / `MetaExpr`) propagate `nested`
	 * unchanged -- `@:meta expr` leaves `expr` in the same statement slot.
	 * Every genuine operand descent (binop RHS, ternary else, return value,
	 * lambda body) passes `true`.
	 */
	private static function stmtExprNoSemiAt(raw: Null<Dynamic>, nested: Bool): Bool {
		final e: Null<Dynamic> = unwrap(raw);
		if (e == null) return false;
		final ctor: Null<String> = Type.enumConstructor(e);
		if (ctor == null) return false;
		return ASSIGN_CTORS.contains(ctor) || BINOP_RHS_CTORS.contains(ctor)
			? binopRhsNoSemi(e)
			: switch ctor {
				// `macro class … { members }` always ends with the members
				// block's closing `}`, so a bare-statement `macro class {}`
				// needs no trailing `;` — regardless of named / anon / empty.
				case 'MacroClassExpr': true;
				case 'MacroExpr':
					macroExprNoSemi(e, nested);
				// Walk through `@:meta expr` into its inner expression —
				// `@:nullSafety(Off) return switch (…) { … }` and
				// `@:nullSafety(Off) if (…) { … }` end with the inner expr's `}`.
				case 'MetaExpr':
					metaExprNoSemi(e, nested);
				// Walk through `return expr` into its operand —
				// `return switch (…) { … }` ends with the switch's `}`. The
				// statement-position `return` routes through `HxStatement.ReturnStmt`,
				// so this branch only fires when something forces expression-mode
				// (e.g. `@:meta return switch (…) { … }` reaching `ExprStmt`
				// through `MetaExpr`).
				case 'ReturnExpr':
					final params: Null<Array<Dynamic>> = Type.enumParameters(e);
					params != null && params.length != 0 && stmtExprNoSemiAt(params[0], true);
				// An `IfExpr` carries `thenBranch`/`elseBranch`; the
				// statement's last token is the else branch's last token.
				// Without an `else`, `HxIfExpr.thenBranch`'s own
				// `@:trailOpt(';')` has already claimed the terminator for a
				// NESTED occurrence; only at the top of an `ExprStmt` does
				// the then-branch walk still apply.
				case 'IfExpr':
					ifExprNoSemi(e, nested);
				// `c ? a : b` -- the statement's last token is the else
				// branch's last token, so `x = c ? a : switch (e) { ... }`
				// is `}`-terminated. `endsWithCloseBrace` carries the same
				// arm but recurses through ITSELF, so it cannot see a
				// binop / lambda tail below the ternary; re-entering here
				// keeps the whole walk inside the statement-side predicate.
				// Motivating source: std `haxe/macro/Printer.hx:311` `var
				// str = t == null ? "#NULL" : (...) + ... + switch (t.kind) {
				// }` followed by `tabs = old;` on the same line.
				case 'Ternary':
					final params: Null<Array<Dynamic>> = Type.enumParameters(e);
					params != null && params.length >= 3 && stmtExprNoSemiAt(params[2], true);
				// `function (...) body` -- `HxFnBody` dispatch, incl. the
				// `ExprBody` `@:trailOpt(';')` swallow. Motivating source:
				// Pony `pony/ui/gui/ButtonCore.hx:33` `t.onClick <<
				// function () if (enabled) eClick.dispatch(mode);`.
				case 'FnExpr':
					fnExprNoSemi(e, nested);
				// `for (...) body` -- `HxForExpr.body` carries its own
				// `@:trailOpt(';')`, same swallow as `HxIfExpr.thenBranch`.
				// `WhileExpr` deliberately gets NO arm -- `HxWhileExpr.body`
				// has no trail slot, so its `;` survives to the enclosing
				// gate and the body walk in `endsWithCloseBrace` stays the
				// right answer. That asymmetry is exactly what the probe
				// pair `a << for (i in e) f(m); x();` (failed) vs
				// `a << while (e) f(m); x();` (parsed) measured.
				case 'ForExpr':
					forExprNoSemi(e, nested);
				// `(...) -> body` / `(...) => body` -- unlike `FnExpr` the
				// lambda structs own no terminator slot, so the answer is
				// the body's: `var cb = () -> { ... }` is `}`-terminated
				// (std `python/_std/sys/thread/Thread.hx:116`).
				case 'ThinParenLambdaExpr', 'ParenLambdaExpr':
					lambdaBodyNoSemi(e);
				// `untyped <expr>` -- a transparent keyword wrapper that owns
				// no terminator slot of its own, so the verdict is the
				// operand's, asked as a NESTED occurrence: whatever swallowed
				// the `;` sits inside the operand, not at the statement top.
				// Motivating source: std
				// `neko/_std/sys/db/Mysql.hx:131` `untyped if (...) e = e.msg;`
				// followed by `untyped __dollar__rethrow(e);` -- the
				// if-expr's `thenBranch` `@:trailOpt(';')` already claimed the
				// statement terminator, so the enclosing `ExprStmt` must not
				// demand a second one.
				case 'UntypedExpr':
					final params: Null<Array<Dynamic>> = Type.enumParameters(e);
					params != null && params.length != 0 && stmtExprNoSemiAt(params[0], true);
				// `<operand> #if ... #end` -- the postfix token-splice tail.
				// Only an `else`-led fragment elides the terminator; see
				// `condSpliceTailElseLed` for why every other shape must keep
				// demanding the `;`.
				case 'CondSpliceTail':
					condSpliceTailElseLed(e);
				// Recursion target. Standalone `{ … }` at statement
				// position is `HxStatement.BlockStmt`, so the brace-terminal
				// ctors only fire when reached through Assign / IfExpr above.
				case _:
					STMT_BRACE_TERMINAL_CTORS.contains(ctor) || endsWithCloseBrace(e);
			};
	}

	/**
	 * ω-stmt-no-semi — HxStatement-level twin of `stmtExprNoSemi`. Returns
	 * true iff a prior statement of shape `raw` does NOT need a trailing
	 * `;` before the next statement in a BlockBody Star.
	 *
	 * Wired through `HaxeFormat.stmtNoSemi` as the schema-instance
	 * predicate consumed by the `@:sep(';', tailRelax, blockEnded('stmtNoSemi'))`
	 * meta on BlockBody containers (AST-shape adapter in the Star primitive). Sister of `stmtExprNoSemi`, which
	 * operates on the inner `HxExpr` of `ExprStmt`; this predicate accepts
	 * the wrapping `HxStatement` enum value and dispatches:
	 *
	 *  - `ExprStmt(expr)` → recurse `stmtExprNoSemi(expr)` (carve-out
	 *    semantics for ObjectLit / ArrayExpr / IfExpr-with-else / Is / …).
	 *    Var-family ctors (`StaticVarStmt` / `StaticFinalStmt` / `VarStmt` / `FinalStmt`) are NOT in this
	 *    predicate: their per-stmt `@:trailOpt(';')` is gone, the BlockBody
	 *    Star owns the trailing `;`, and the predicate returning FALSE for
	 *    them is the correct signal that the Star must claim the byte.
	 *  - Brace-terminated stmts (`BlockStmt` / `IfStmt` / `WhileStmt` /
	 *    `ForStmt` / `SwitchStmt(Bare)` / `TryCatchStmt` / `LocalFnStmt` /
	 *    `LocalInlineFnStmt` / `UntypedBlockStmt`) → true unconditionally
	 *    (closing `}` is the stmt's last token). There is no parser-side `}` byte-check fast-path — the AST branch is the sole path for these ctors, alongside Conditional / EllipsisStmt below.
	 *  - Sep-terminated stmts (`VoidReturnStmt` / `ThrowStmt` /
	 *    `DoWhileStmt` / `ErrorStmt` / `EmptyStmt` / `TryCatchStmtBare`)
	 *    → true (their `@:trail(';')` / `@:lit(';')` already consumed the
	 *    sep; byte at `_prevEndPos - 1` is `;` so byte-check also passes).
	 *  - `Conditional` (`#if … #end`) → true (`#end`-terminated; byte at
	 *    `_prevEndPos - 1` is `d` so byte-check does NOT cover this case,
	 *    AST predicate is the only path).
	 *  - `CondSpliceStmt` (`#if <raw> #end <tail>`) -> recurse into the
	 *    splice's `tail` field. The raw region contributes no terminator of
	 *    its own, so the verdict belongs to the shared tail statement: a
	 *    brace-terminated tail (`#if !no_map_cache if (!(...)) #end { idx =
	 *    lookup(key); }` -- the std `haxe/ds/*Map.remove` idiom) elides the
	 *    `;`, a bare `ExprStmt` tail does not. Without this arm the byte
	 *    check saw the tail's closing `}` (not `;`) and the Star demanded a
	 *    separator that valid Haxe never writes.
	 *  - `OrphanElseStmt` (`else <stmt>`) -> recurse into the payload
	 *    statement, for the same reason: the `else` keyword adds no
	 *    terminator, so `else if (...) { ... }` elides the `;` and
	 *    `else foo();` does not.
	 *  - `EllipsisStmt` (`....` placeholder) → true (no terminator; byte
	 *    at `_prevEndPos - 1` is `.`, AST predicate is the only path).
	 *
	 * `Dynamic` argument so the same predicate fires on Plain-mode
	 * `HxStatement` enum values and Trivia-mode `Trivial<HxStatementT>`
	 * struct wrappers (see `unwrap`).
	 */
	public static function stmtNoSemi(raw: Null<Dynamic>): Bool {
		final s: Null<Dynamic> = unwrap(raw);
		if (s == null) return false;
		final ctor: Null<String> = Type.enumConstructor(s);
		if (ctor == null) return false;
		// ExprStmt: delegate to the inner-expr predicate, which already
		// covers ObjectLit / ArrayExpr / IfExpr-with-else / Is / Assign-RHS-recursion.
		if (ctor == 'ExprStmt') {
			final params: Null<Array<Dynamic>> = Type.enumParameters(s);
			return params != null && params.length > 0 && stmtExprNoSemi(params[0]);
		}
		// CondSpliceStmt / OrphanElseStmt carry a nested statement that owns
		// the terminator question; delegate instead of hard-coding a verdict.
		if (ctor == 'CondSpliceStmt') {
			final params: Null<Array<Dynamic>> = Type.enumParameters(s);
			if (params == null || params.length == 0) return false;
			final inner: Null<Dynamic> = params[0];
			return inner != null && stmtNoSemi(Reflect.field(inner, 'tail'));
		}
		if (ctor == 'OrphanElseStmt') {
			final params: Null<Array<Dynamic>> = Type.enumParameters(s);
			return params != null && params.length != 0 && stmtNoSemi(params[0]);
		}
		if (BRACE_TERMINAL_STMT_CTORS.contains(ctor)) return true;
		if (SEP_TERMINAL_STMT_CTORS.contains(ctor)) return true;
		if (NON_BYTE_TERMINAL_STMT_CTORS.contains(ctor)) return true;
		if (VAR_INIT_STMT_CTORS.contains(ctor)) return varInitEndsWithBrace(s);
		return false;
	}

	/**
	 * `@:meta <operand>` wrapper — recurse on the wrapped expression
	 * (`params[0].expr`).
	 */
	private static function metaExprEndsWithBrace(e: Dynamic): Bool {
		final inner: Null<Dynamic> = metaInnerExpr(e);
		return inner != null && endsWithCloseBrace(inner);
	}

	/**
	 * `for (…) body` / `while (…) body` — recurse on the loop body.
	 */
	private static function loopBodyEndsWithBrace(e: Dynamic): Bool {
		final stmt: Null<Dynamic> = Type.enumParameters(e)[0];
		if (stmt == null) return false;
		final body: Null<Dynamic> = Reflect.field(stmt, 'body');
		return body != null && endsWithCloseBrace(body);
	}

	/**
	 * `if (c) then else else'` — recurse on the last evaluated branch
	 * (the else branch if present, otherwise the then branch).
	 */
	private static function ifExprEndsWithBrace(e: Dynamic): Bool {
		final stmt: Null<Dynamic> = Type.enumParameters(e)[0];
		if (stmt == null) return false;
		final elseBranch: Null<Dynamic> = Reflect.field(stmt, 'elseBranch');
		if (elseBranch != null) return endsWithCloseBrace(elseBranch);
		final thenBranch: Null<Dynamic> = Reflect.field(stmt, 'thenBranch');
		return thenBranch != null && endsWithCloseBrace(thenBranch);
	}

	/**
	 * `function(…) body` — brace-terminated iff the body is a `BlockBody`.
	 */
	private static function fnExprEndsWithBrace(e: Dynamic): Bool {
		final fn: Null<Dynamic> = Type.enumParameters(e)[0];
		if (fn == null) return false;
		final body: Null<Dynamic> = unwrap(Reflect.field(fn, 'body'));
		return body != null && Type.enumConstructor(body) == 'BlockBody';
	}

	/**
	 * `try body catch (…) …` — recurse on the last catch clause's body,
	 * or the try body itself when there are no catches.
	 */
	private static function tryExprEndsWithBrace(e: Dynamic): Bool {
		final stmt: Null<Dynamic> = Type.enumParameters(e)[0];
		if (stmt == null) return false;
		final catches: Null<Array<Dynamic>> = Reflect.field(stmt, 'catches');
		if (catches == null || catches.length == 0) {
			final body: Null<Dynamic> = Reflect.field(stmt, 'body');
			return body != null && endsWithCloseBrace(body);
		}
		final last: Null<Dynamic> = catches[catches.length - 1];
		if (last == null) return false;
		final lastInner: Dynamic = Reflect.hasField(last, 'node') ? last.node : last;
		final body: Null<Dynamic> = Reflect.field(lastInner, 'body');
		return body != null && endsWithCloseBrace(body);
	}

	/**
	 * `macro <operand>` at statement position — `}`-terminated iff the
	 * operand is a `BlockExpr` or itself statement-brace-terminated.
	 */
	private static function macroExprNoSemi(e: Dynamic, nested: Bool): Bool {
		final params: Null<Array<Dynamic>> = Type.enumParameters(e);
		if (params == null || params.length == 0) return false;
		final operand: Null<Dynamic> = unwrap(params[0]);
		if (operand == null) return false;
		final operandCtor: Null<String> = Type.enumConstructor(operand);
		return operandCtor == 'BlockExpr' || stmtExprNoSemiAt(operand, nested);
	}

	/**
	 * `@:meta expr` at statement position — recurse on `params[0].expr`
	 * (same struct shape as `IfExpr`).
	 */
	private static function metaExprNoSemi(e: Dynamic, nested: Bool): Bool {
		final inner: Null<Dynamic> = metaInnerExpr(e);
		return inner != null && stmtExprNoSemiAt(inner, nested);
	}

	/**
	  * Any binary infix operator at statement position -- `*Assign`
	 * (`ASSIGN_CTORS`) or a plain binop (`BINOP_RHS_CTORS`) -- recurse on
	 * the right operand, which owns the statement's last token in both
	 * families. Carve-out: `x = {a: 1}`, `x = [1, 2, 3]`,
	 * `x = ${expr}` and `x = a is Int` keep `;` strict (the corpus
	 * contract — distinct from bare `{a: 1}` / `[1, 2, 3]` / `${expr}` /
	 * `a is Int` at stmt position). The carve-out lives here, not in the
	 * brace-terminal set below, so other recursive arms (Meta / Return /
	 * If) still see them as brace-terminated; it is applied to the
	 * non-assign family too, so the two stay indistinguishable to the
	 * corpus.
	 */
	private static function binopRhsNoSemi(e: Dynamic): Bool {
		final params: Null<Array<Dynamic>> = Type.enumParameters(e);
		if (params == null || params.length < 2) return false;
		final rhs: Null<Dynamic> = unwrap(params[1]);
		if (rhs == null) return false;
		final rhsCtor: Null<String> = Type.enumConstructor(rhs);
		return rhsCtor != 'ObjectLit' && rhsCtor != 'ArrayExpr' && rhsCtor != 'DollarBlockExpr' && rhsCtor != 'Is'
			&& stmtExprNoSemiAt(rhs, true);
	}

	/**
			 * `if (...) ... else ...` at statement position -- recurse on the else
			 * branch when present. `params[0]` is the `HxIfExpr` struct; its
			 * field values are wrapped and re-entered through `stmtExprNoSemi`
			 * (which calls `unwrap`).
			 *
			   * With no else branch a NESTED occurrence answers `true` outright:
	 * `HxIfExpr.thenBranch` carries `@:trailOpt(';')`, so the `;` that
	 * terminated the enclosing statement has already been consumed and
	 * asking the enclosing `ExprStmt` to `expectLit` a second one is a
	 * double-count (`a << if (e) f(m); x();` failed at `x` while
	 * `a << if (e) f(m);; x();` parsed -- that pair exposed the swallow).
	 * The mirror case `a << if (e) f(m) else g(m); x();` already parsed,
	 * because the `else` branch has no trail slot and the `;` survives to
	 * the statement gate.
	 *
	 * At the top of an `ExprStmt` (`nested` false) the then-branch walk
	 * stays: see `stmtExprNoSemiAt` for why that position means "the
	 * statement-position `if` already failed".
	 */
	private static function ifExprNoSemi(e: Dynamic, nested: Bool): Bool {
		final params: Null<Array<Dynamic>> = Type.enumParameters(e);
		if (params == null || params.length == 0) return false;
		final ifExpr: Null<Dynamic> = params[0];
		if (ifExpr == null) return false;
		final elseBranch: Null<Dynamic> = Reflect.field(ifExpr, 'elseBranch');
		if (elseBranch != null) return stmtExprNoSemiAt(elseBranch, true);
		if (nested) return true;
		final thenBranch: Null<Dynamic> = Reflect.field(ifExpr, 'thenBranch');
		return thenBranch != null && stmtExprNoSemiAt(thenBranch, true);
	}

	/**
	 * True iff a `HxExpr.CondSpliceTail` fragment is an if-chain
	 * CONTINUATION -- its raw text, past the condition atom, starts with
	 * the `else` keyword.
	 *
	 * Such a region cannot begin a statement on its own: the governing
	 * `if` head is the operand the postfix bound to, and that head's own
	 * terminator slot (`HxIfExpr.thenBranch`'s `@:trailOpt(';')`) already
	 * swallowed the statement's `;` BEFORE the region opened. Demanding a
	 * second `;` after the `#end` terminates the enclosing block Star one
	 * statement early. Motivating source -- openfl
	 * `text/_internal/TextEngine.hx:1183`:
	 *
	 * ```haxe
	 * layoutGroup._textDirection = if (!f.textDirection.invalid) f.textDirection; #if !(js && html5) else if (positions.length > 0)
	 *     positions[0].textDirection; #end
	 * else
	 *     mainDirection();
	 * ```
	 *
	 * Every OTHER fragment shape is an independent guarded statement that
	 * merely happens to follow the operand, and the mandatory `;` is what
	 * keeps it independent: it makes the Trivia-mode parser reject the
	 * postfix reading and re-read the region as a statement-scope
	 * `HxStatement.Conditional`. Tactics Manager
	 * `video/GpuDirectPipeline.hx:48` is the measured case -- a
	 * `@:privateAccess { ... }` block followed on its own line by
	 * `#if debug final t1:Float = Sys.time(); #end`. A blanket `true` here
	 * glued the two into one postfix expression and rewrote the file.
	 * (Plain mode never binds the postfix across that gap at all, so the
	 * divergence is Trivia-only and invisible to `ast --count`.)
	 *
	 * The condition atom is skipped with a paren-depth scan rather than a
	 * regex: `!(js && html5)` carries spaces INSIDE its parens, so the
	 * "first whitespace" rule only works at depth 0.
	 */
	private static function condSpliceTailElseLed(e: Dynamic): Bool {
		final params: Null<Array<Dynamic>> = Type.enumParameters(e);
		if (params == null || params.length < 2) return false;
		final rawNode: Null<Dynamic> = params[1];
		if (rawNode == null) return false;
		final raw: Null<String> = rawNode is String ? cast rawNode : cast Reflect.field(rawNode, 'node');
		if (raw == null) return false;
		final start: Int = skipCondAtom(raw);
		if (raw.substr(start, ELSE_KEYWORD.length) != ELSE_KEYWORD) return false;
		final after: Int = start + ELSE_KEYWORD.length;
		return after >= raw.length || !isCondWordChar(StringTools.fastCodeAt(raw, after));
	}

	/**
	 * Index of the first character past a splice fragment's leading
	 * condition atom (and the whitespace on either side of it).
	 *
	 * The scan is paren-depth aware rather than a plain "up to the first
	 * whitespace": `!(js && html5)` carries spaces INSIDE its parens, so
	 * only a depth-0 space ends the atom. An unbalanced fragment drives
	 * `depth` negative and the scan simply runs to the end - the caller
	 * then reads no keyword and answers `false`, which is the safe verdict.
	 */
	private static function skipCondAtom(raw: String): Int {
		final n: Int = raw.length;
		var i: Int = 0;
		while (i < n && isCondWs(StringTools.fastCodeAt(raw, i))) i++;
		var depth: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(raw, i);
			if (c == '('.code)
				depth++;
			else if (c == ')'.code)
				depth--;
			else if (depth == 0 && isCondWs(c))
				break;
			i++;
		}
		while (i < n && isCondWs(StringTools.fastCodeAt(raw, i))) i++;
		return i;
	}

	private static inline function isCondWs(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	private static inline function isCondWordChar(c: Int): Bool {
		if (c == '_'.code) return true;
		if (c >= 'a'.code && c <= 'z'.code) return true;
		if (c >= 'A'.code && c <= 'Z'.code) return true;
		return c >= '0'.code && c <= '9'.code;
	}

	/**
		 * `function (...) body` at statement position -- dispatch on the
		 * `HxFnBody` ctor:
		 *  - `BlockBody` / `UntypedBlockBody` end with `}`.
		 *  - `NoBody` is `HxFnBody`'s `@:lit(';')` -- terminator consumed.
		  *  - `ExprBody` carries `@:trailOpt(';')`, which has already claimed
	 *    the statement's `;` for a NESTED occurrence -- demanding a second
	 *    one there is a double-count. At the top of an `ExprStmt` the body
	 *    walk stays (see `stmtExprNoSemiAt`).
	 */
	private static function fnExprNoSemi(e: Dynamic, nested: Bool): Bool {
		final fn: Null<Dynamic> = Type.enumParameters(e)[0];
		if (fn == null) return false;
		final body: Null<Dynamic> = unwrap(Reflect.field(fn, 'body'));
		if (body == null) return false;
		return switch Type.enumConstructor(body) {
			case 'BlockBody', 'UntypedBlockBody', 'NoBody': true;
			case 'ExprBody':
				final params: Null<Array<Dynamic>> = Type.enumParameters(body);
				nested || (params != null && params.length != 0 && stmtExprNoSemiAt(params[0], true));
			case _: false;
		};
	}

	/**
	 * `for (...) body` at statement position -- `HxForExpr.body` carries
	 * `@:trailOpt(';')`, the same swallow `ifExprNoSemi` documents, so a
	 * NESTED occurrence answers `true` outright; at the top of an
	 * `ExprStmt` the body walk stays.
	 */
	private static function forExprNoSemi(e: Dynamic, nested: Bool): Bool {
		if (nested) return true;
		final stmt: Null<Dynamic> = Type.enumParameters(e)[0];
		if (stmt == null) return false;
		final body: Null<Dynamic> = Reflect.field(stmt, 'body');
		return body != null && stmtExprNoSemiAt(body, true);
	}

	/**
	 * `(...) -> body` / `(...) => body` at statement position -- recurse on
	 * the lambda body. `params[0]` is the `HxThinParenLambda` /
	 * `HxParenLambda` struct, which owns no terminator slot of its own,
	 * so the statement's last token is the body's last token.
	 */
	private static function lambdaBodyNoSemi(e: Dynamic): Bool {
		final params: Null<Array<Dynamic>> = Type.enumParameters(e);
		if (params == null || params.length == 0) return false;
		final lambda: Null<Dynamic> = params[0];
		if (lambda == null) return false;
		final body: Null<Dynamic> = Reflect.field(lambda, 'body');
		return body != null && stmtExprNoSemiAt(body, true);
	}

	/**
		 * `var x = expr` / `final x = expr` / static-variant stmts whose init
		 * expression ends with `}` (Switch / TryCatch / FnExpr with
		 * BlockBody). Byte-check on `_prevEndPos - 1` misses these because the
		  * stmt's own trailing `skipWs` (before `@:trailOpt(';')`'s `matchLit`)
	 * advances past the brace + newline + tabs when no trailing `;` is
	 * present, leaving `_prevEndPos` past the `}`. Delegate to
	 * `endsWithCloseBrace` on the `HxVarDecl.init` field.
	 *
	 * `stmtExprNoSemi` is consulted as a SECOND, more permissive opinion
	 * on the same init expression. The two predicates deliberately differ:
	 * `endsWithCloseBrace` is also the writer-side gate behind
	 * `@:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))` on
	 * `VarStmt` / `FinalStmt` / `Var|FinalMember`, so widening it would
	 * start DROPPING the `;` the formatter currently emits after
	 * `var f = () -> { ... };` and `var x = a && { ... };`. Only the parser
	 * needs the wider answer, and `stmtExprNoSemi` is exactly the
	 * parser-side statement-terminator predicate -- reusing it here keeps
	 * the binop / ternary / lambda walks in one place. Motivating sources:
	 * std `cs|java|jvm|python/_std/Std.hx` (`final isNegative =
	  * hasIndex(index) && { ... }` with no `;`), std `haxe/macro/Printer.hx`
	 * (`var str = ... ? ... : ... + switch (t.kind) { ... }`), std
	 * `python/_std/sys/thread/Thread.hx` (`var wrappedCallB = () -> { ... }`).
	 */
	private static function varInitEndsWithBrace(s: Dynamic): Bool {
		final params: Null<Array<Dynamic>> = Type.enumParameters(s);
		if (params == null || params.length == 0) return false;
		final decl: Null<Dynamic> = params[0];
		if (decl == null) return false;
		final init: Null<Dynamic> = Reflect.field(decl, 'init');
		return init != null && (endsWithCloseBrace(init) || stmtExprNoSemiAt(init, true));
	}

	/**
	 * Returns the inner enum value for `raw`. Handles three shapes:
	 *  - `null` → `null`
	 *  - direct enum value (Plain-mode AST node) → `raw` unchanged
	 *  - `Trivial<T>` struct wrapper (Trivia-mode AST node) → `raw.node`
	 */
	private static inline function unwrap(raw: Null<Dynamic>): Null<Dynamic> {
		return raw == null ? null : Type.getEnum(raw) != null ? raw : Reflect.field(raw, 'node');
	}


	/** The wrapped expression of an `@:meta <operand>` node (`params[0].expr`), or null. */
	private static function metaInnerExpr(e: Dynamic): Null<Dynamic> {
		final params: Null<Array<Dynamic>> = Type.enumParameters(e);
		if (params == null || params.length == 0) return null;
		final metaExpr: Null<Dynamic> = params[0];
		return metaExpr == null ? null : Reflect.field(metaExpr, 'expr');
	}

}
