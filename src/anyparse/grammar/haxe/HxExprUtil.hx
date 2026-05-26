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
	 * HxExpr ctor names that — when wrapped in `ExprStmt(expr)` and
	 * standing as the sole statement of a case body — refuse inline
	 * emission. Empirical scope (probed against fork CLI): only `And`
	 * (`&&`) and `Or` (`||`). All other binops, ternary, and
	 * assignment variants nest hierarchically under one `dblDot` child
	 * in fork's tokentree and are allowed inline.
	 */
	private static final REFUSED_CASE_BODY_CTORS:Array<String> = ['And', 'Or'];

	/**
	 * True when a single-statement case body should refuse inline
	 * because its outermost expression is `&&` or `||`. Mirrors
	 * haxe-formatter's `MarkSameLine.markExpressionCase` body-shape
	 * heuristic. Wired on `WriteOptions.caseBodyRefusesFlat` so the
	 * writer-side `@:fmt(refuseFlatOnComplexExpr)` flat-gate AND-clause
	 * dispatches through the plugin without engine→plugin coupling.
	 *
	 * `Dynamic` argument so the same predicate fires on both Plain-mode
	 * `HxStatement` enum values and Trivia-mode `Trivial<HxStatementT>`
	 * struct wrappers — `Type.enumConstructor` matches against both
	 * enums (Plain `HxStatement` and synthesised `HxStatementT`) since
	 * they share constructor names. Returns `false` for null,
	 * non-enum, or non-`ExprStmt` shapes.
	 */
	public static function refusesCaseFlat(raw:Null<Dynamic>):Bool {
		final s:Null<Dynamic> = unwrap(raw);
		if (s == null) return false;
		if (Type.enumConstructor(s) != 'ExprStmt') return false;
		final params:Null<Array<Dynamic>> = Type.enumParameters(s);
		if (params == null || params.length == 0) return false;
		final inner:Null<Dynamic> = unwrap(params[0]);
		if (inner == null) return false;
		final ctor:Null<String> = Type.enumConstructor(inner);
		if (ctor == null) return false;
		return REFUSED_CASE_BODY_CTORS.contains(ctor);
	}

	public static function endsWithCloseBrace(raw:Null<Dynamic>):Bool {
		final e:Null<Dynamic> = unwrap(raw);
		if (e == null) return false;
		final ctor:Null<String> = Type.enumConstructor(e);
		if (ctor == null) return false;
		return switch ctor {
			case 'SwitchExpr', 'SwitchExprBare': true;
			// `{ … }` block expression — `}` is the literal last token.
			case 'BlockExpr': true;
			// `{ k: v, … }` object literal — `}` last token.
			case 'ObjectLit': true;
			// `macro class … { members }` — `}` of the members block.
			case 'MacroClassExpr': true;
			// `macro <operand>` / `@:meta <operand>` — pure wrappers,
			// recurse on the wrapped expression. Required for the
			// `final x = macro for/if/…` idiom in macro-heavy code where
			// the outer stmt's trailing `;` was consumed by the operand's
			// own `@:trailOpt(';')` (so the predicate must declare
			// block-ended without seeing the `;` byte at `_prevEndPos-1`).
			case 'MacroExpr':
				final params:Null<Array<Dynamic>> = Type.enumParameters(e);
				params != null && params.length > 0 && endsWithCloseBrace(params[0]);
			case 'MetaExpr':
				final params:Null<Array<Dynamic>> = Type.enumParameters(e);
				if (params == null || params.length == 0) false;
				else {
					final metaExpr:Null<Dynamic> = params[0];
					if (metaExpr == null) false;
					else {
						final inner:Null<Dynamic> = Reflect.field(metaExpr, 'expr');
						inner != null && endsWithCloseBrace(inner);
					}
				}
			// `a ? b : c` — last evaluated branch is `c` (elseExpr).
			case 'Ternary':
				final params:Null<Array<Dynamic>> = Type.enumParameters(e);
				params != null && params.length >= 3 && endsWithCloseBrace(params[2]);
			// `for (…) body` / `while (…) body` — body's own `@:trailOpt(';')`
			// either consumed `;` (block-ended via `;`-byte) OR body itself
			// ends with `}` (recurse). Either way, no further sep is required
			// before the next stmt.
			case 'ForExpr':
				final stmt:Null<Dynamic> = Type.enumParameters(e)[0];
				if (stmt == null) false;
				else {
					final body:Null<Dynamic> = Reflect.field(stmt, 'body');
					body != null && endsWithCloseBrace(body);
				}
			case 'WhileExpr':
				final stmt:Null<Dynamic> = Type.enumParameters(e)[0];
				if (stmt == null) false;
				else {
					final body:Null<Dynamic> = Reflect.field(stmt, 'body');
					body != null && endsWithCloseBrace(body);
				}
			// `if (c) then else else'` — recurse on the last evaluated
			// branch (else if present, otherwise then). Pre-fix Pattern B
			// `final v = if (a) {…} else {…}` left the outer stmt visible
			// to `stmtNoSemi` as `FinalStmt` whose init was `IfExpr`; the
			// outer `FinalStmt` handler delegates to `endsWithCloseBrace`,
			// so the recursive case here closes the loop.
			case 'IfExpr':
				final stmt:Null<Dynamic> = Type.enumParameters(e)[0];
				if (stmt == null) false;
				else {
					final elseBranch:Null<Dynamic> = Reflect.field(stmt, 'elseBranch');
					if (elseBranch != null) endsWithCloseBrace(elseBranch);
					else {
						final thenBranch:Null<Dynamic> = Reflect.field(stmt, 'thenBranch');
						thenBranch != null && endsWithCloseBrace(thenBranch);
					}
				}
			case 'FnExpr':
				final fn:Null<Dynamic> = Type.enumParameters(e)[0];
				if (fn == null) false;
				else {
					final body:Null<Dynamic> = unwrap(Reflect.field(fn, 'body'));
					body != null && Type.enumConstructor(body) == 'BlockBody';
				}
			case 'TryExpr':
				final stmt:Null<Dynamic> = Type.enumParameters(e)[0];
				if (stmt == null) false;
				else {
					final catches:Null<Array<Dynamic>> = Reflect.field(stmt, 'catches');
					if (catches == null || catches.length == 0) {
						final body:Null<Dynamic> = Reflect.field(stmt, 'body');
						body != null && endsWithCloseBrace(body);
					} else {
						final last:Null<Dynamic> = catches[catches.length - 1];
						if (last == null) false;
						else {
							final lastInner:Dynamic = Reflect.hasField(last, 'node') ? last.node : last;
							final body:Null<Dynamic> = Reflect.field(lastInner, 'body');
							body != null && endsWithCloseBrace(body);
						}
					}
				}
			case _: false;
		};
	}

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
	private static final ASSIGN_CTORS:Array<String> = [
		'Assign', 'AddAssign', 'SubAssign', 'MulAssign', 'DivAssign',
		'ModAssign', 'ShlAssign', 'UShrAssign', 'ShrAssign',
		'BitOrAssign', 'BitAndAssign', 'BitXorAssign',
		'NullCoalAssign', 'BoolAndAssign', 'BoolOrAssign',
	];

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
	 *  - `ObjectLit` — bare `{ foo: 1 }` at statement position
	 *    (slice 30). `BlockStmt`'s greedy `{` attempt fails on the
	 *    `IDENT:` field shape, so `ExprStmt(ObjectLit)` is reached and
	 *    the `}` is the statement's last token. NOT triggered through
	 *    Assign-RHS — `x = {a: 1};` keeps `;` strict per the corpus
	 *    contract (Slice 19 carve-out in the `*Assign` arm below).
	 *  - `ArrayExpr` — bare `[1, 2, 3]` / `[if (foo) bar else foo, …]`
	 *    at statement position (slice 39). The closing `]` is the
	 *    statement's last token, same as `}` for ObjectLit / BlockExpr.
	 *    NOT triggered through Assign-RHS — `x = [1, 2];` keeps `;`
	 *    strict (same carve-out as ObjectLit). Drives `sameline/issue_365_array_comprehension`.
	 *  - `Is` — bare `x is Type` at statement position (slice 43).
	 *    NOT brace-terminated — `Is`'s last token is the type-ref leaf
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
	 * **Note (Slice 44, ω-slice-X3): this predicate is no longer the sole
	 * authority on `ExprStmt`'s trail-`;` elision.** The parse-time gate in
	 * `Lowering.hx` is a 3-disjunct OR — the intrinsic check here, plus
	 * `peekKw(ctx, "else")` (Slice X2: if-then-body before `else`), plus
	 * `peekLit(ctx, "}")` (Slice X3: any expr as the last stmt of an
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
	 * needs the opposite answer for `macro { … }` and the Slice 19
	 * Assign / IfExpr cases. `endsWithCloseBrace` is reused read-only
	 * for the non-recursive tail cases (`SwitchExpr` etc., where the
	 * answer coincides) and is NOT modified — `HxClassMember.VarMember`/
	 * `FinalMember`'s writer-side `@:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))`
	 * gate keeps its stricter behaviour. Post Sessions 10.1-10.5 the
	 * statement-side `Var`/`Final`/`StaticVar`/`StaticFinalStmt` ctors
	 * no longer carry `trailOptShapeGate` — they own no `@:trailOpt(';')`
	 * at all; the BlockBody Star sep claims the trailing byte instead.
	 *
	 * `Dynamic` argument so the same predicate fires on Plain-mode
	 * `HxExpr` enum values and Trivia-mode `Trivial<HxExprT>` wrappers
	 * (see `unwrap`).
	 */
	public static function stmtExprNoSemi(raw:Null<Dynamic>):Bool {
		final e:Null<Dynamic> = unwrap(raw);
		if (e == null) return false;
		final ctor:Null<String> = Type.enumConstructor(e);
		if (ctor == null) return false;
		// `macro class … { members }` always ends with the members
		// block's closing `}`, so a bare-statement `macro class {}`
		// needs no trailing `;` — regardless of named / anon / empty.
		if (ctor == 'MacroClassExpr') return true;
		if (ctor == 'MacroExpr') {
			final params:Null<Array<Dynamic>> = Type.enumParameters(e);
			if (params == null || params.length == 0) return false;
			final operand:Null<Dynamic> = unwrap(params[0]);
			if (operand == null) return false;
			final operandCtor:Null<String> = Type.enumConstructor(operand);
			return operandCtor == 'BlockExpr' || stmtExprNoSemi(operand);
		}
		// Slice 28: walk through `@:meta expr` into its inner expression —
		// `@:nullSafety(Off) return switch (…) { … }` and
		// `@:nullSafety(Off) if (…) { … }` end with the inner expr's `}`.
		// `params[0]` is the `HxMetaExpr` struct (Plain) / `HxMetaExprT`
		// struct (Trivia); read `.expr` directly (same shape as `IfExpr`).
		if (ctor == 'MetaExpr') {
			final params:Null<Array<Dynamic>> = Type.enumParameters(e);
			if (params == null || params.length == 0) return false;
			final metaExpr:Null<Dynamic> = params[0];
			if (metaExpr == null) return false;
			final inner:Null<Dynamic> = Reflect.field(metaExpr, 'expr');
			return inner != null && stmtExprNoSemi(inner);
		}
		// Slice 28: walk through `return expr` into its operand —
		// `return switch (…) { … }` ends with the switch's `}`. The
		// statement-position `return` routes through `HxStatement.ReturnStmt`,
		// so this branch only fires when something forces expression-mode
		// (e.g. `@:meta return switch (…) { … }` reaching `ExprStmt`
		// through `MetaExpr`).
		if (ctor == 'ReturnExpr') {
			final params:Null<Array<Dynamic>> = Type.enumParameters(e);
			if (params == null || params.length == 0) return false;
			return stmtExprNoSemi(params[0]);
		}
		// Slice 19: walk through `*Assign` into its right operand —
		// `x = if (…) {…} else {…}` ends with the else block's `}`.
		// Slice 30 / 39 / 42 / 43 carve-out: `x = {a: 1}`, `x = [1, 2, 3]`,
		// `x = ${expr}` and `x = a is Int` keep `;` strict (the corpus
		// contract — distinct from bare `{a: 1}` / `[1, 2, 3]` /
		// `${expr}` / `a is Int` at stmt position). The carve-out lives
		// here, not in the ObjectLit / ArrayExpr / DollarBlockExpr / Is
		// direct-returns below, so other recursive arms (Meta / Return /
		// If) still see them as brace-terminated.
		if (ASSIGN_CTORS.contains(ctor)) {
			final params:Null<Array<Dynamic>> = Type.enumParameters(e);
			if (params == null || params.length < 2) return false;
			final rhs:Null<Dynamic> = unwrap(params[1]);
			if (rhs == null) return false;
			final rhsCtor:Null<String> = Type.enumConstructor(rhs);
			if (rhsCtor == 'ObjectLit' || rhsCtor == 'ArrayExpr' || rhsCtor == 'DollarBlockExpr' || rhsCtor == 'Is') return false;
			return stmtExprNoSemi(rhs);
		}
		// Slice 19: an `IfExpr` carries `thenBranch`/`elseBranch`; the
		// statement's last token is the else branch's last token, or
		// the then branch's when there is no `else`. `params[0]` is the
		// `HxIfExpr` struct (Plain) / `HxIfExprT` struct (Trivia) — no
		// outer enum wrapper, so we read its fields directly. The field
		// values ARE wrapped (Plain `HxExpr` enum / Trivia `Trivial<HxExprT>`
		// struct) so we run them through `stmtExprNoSemi` which calls
		// `unwrap` at entry.
		if (ctor == 'IfExpr') {
			final params:Null<Array<Dynamic>> = Type.enumParameters(e);
			if (params == null || params.length == 0) return false;
			final ifExpr:Null<Dynamic> = params[0];
			if (ifExpr == null) return false;
			final elseBranch:Null<Dynamic> = Reflect.field(ifExpr, 'elseBranch');
			if (elseBranch != null) return stmtExprNoSemi(elseBranch);
			final thenBranch:Null<Dynamic> = Reflect.field(ifExpr, 'thenBranch');
			return thenBranch != null && stmtExprNoSemi(thenBranch);
		}
		// Slice 19: recursion target. Standalone `{ … }` at statement
		// position is `HxStatement.BlockStmt`, so this branch only
		// fires when reached through Assign / IfExpr above.
		if (ctor == 'BlockExpr') return true;
		// Slice 30: object literal at statement position is brace-
		// terminated. `{ foo: 1 }` reaches `ExprStmt(ObjectLit)` after
		// `BlockStmt`'s greedy `{` attempt fails on the `IDENT:` field
		// shape, so the gate must allow `;` elision matching Haxe's
		// rule that a `}`-closed statement needs no `;`. Twin of the
		// `BlockExpr` arm above — direct ctor-name match, no recursion.
		if (ctor == 'ObjectLit') return true;
		// Slice 39: array literal at statement position is `]`-terminated
		// (the closing bracket is the statement's last token, same role
		// as `}` for ObjectLit / BlockExpr). Drives `sameline/issue_365`
		// (`[if (foo) bar else foo, …]` as sole stmt of fn body) — Haxe
		// elides the `;` after a `]`-closed statement just like after a
		// `}`-closed one. Byte-twin of the `ObjectLit` direct-return; the
		// `*Assign` arm above carves `x = [1, 2, 3]` out so RHS arrays
		// keep `;` strict.
		if (ctor == 'ArrayExpr') return true;
		// Slice 42: macro block-reification `${expr}` at statement position
		// is `}`-terminated (`@:lead("${") @:trail("}")` on the ctor —
		// the closing `}` is the statement's last token). Drives
		// `lineends/issue_215_macro_with_dollar_block` (`macro { $e0;
		// ${loop(el)} };` — `${…}` as last stmt of macro block). Byte-
		// twin of `ObjectLit` / `ArrayExpr` direct-returns; the `*Assign`
		// arm above carves `x = ${expr}` out so RHS keeps `;` strict.
		if (ctor == 'DollarBlockExpr') return true;
		// Slice 43: `Is` operator at statement position. Departs from
		// the brace-terminated rule of the other direct-returns above —
		// `Is`'s last token is a type-ref leaf (`String` ident in
		// `x is String`), not `}` / `]`. Corpus driver:
		// `whitespace/issue_605_operator_is` (`{x is String}` as the
		// sole stmt of an outer brace-block — the inner ExprStmt has no
		// `;` before the closing `}`). Permissive extension of
		// "last-stmt-in-block" semantics consistent with the existing
		// `{a:1} {b:2}` (two ObjectLit stmts no `;`) acceptance. The
		// `*Assign` arm above carves `x = a is Int` out so RHS keeps
		// `;` strict.
		if (ctor == 'Is') return true;
		return endsWithCloseBrace(e);
	}

	/**
	 * ω-stmt-no-semi — HxStatement-level twin of `stmtExprNoSemi`. Returns
	 * true iff a prior statement of shape `raw` does NOT need a trailing
	 * `;` before the next statement in a BlockBody Star.
	 *
	 * Wired through `HaxeFormat.stmtNoSemi` as the schema-instance
	 * predicate consumed by the `@:sep(';', tailRelax, blockEnded('stmtNoSemi'))`
	 * meta on BlockBody containers (Session 6 option b2 — AST-shape
	 * adapter in the Star primitive). Sister of `stmtExprNoSemi`, which
	 * operates on the inner `HxExpr` of `ExprStmt`; this predicate accepts
	 * the wrapping `HxStatement` enum value and dispatches:
	 *
	 *  - `ExprStmt(expr)` → recurse `stmtExprNoSemi(expr)` (carve-out
	 *    semantics for ObjectLit / ArrayExpr / IfExpr-with-else / Is / …).
	 *    Migrated var-family ctors (`StaticVarStmt` / `StaticFinalStmt` /
	 *    `VarStmt` / `FinalStmt` — Sessions 10.1-10.5) are NOT in this
	 *    predicate: their per-stmt `@:trailOpt(';')` is gone, the BlockBody
	 *    Star owns the trailing `;`, and the predicate returning FALSE for
	 *    them is the correct signal that the Star must claim the byte.
	 *  - Brace-terminated stmts (`BlockStmt` / `IfStmt` / `WhileStmt` /
	 *    `ForStmt` / `SwitchStmt(Bare)` / `TryCatchStmt` / `LocalFnStmt` /
	 *    `LocalInlineFnStmt` / `UntypedBlockStmt`) → true unconditionally
	 *    (closing `}` is the stmt's last token). Post-Session-11 the
	 *    parser-side `}` byte-check fast-path is removed — the AST branch
	 *    is now the sole path for these ctors, alongside Conditional /
	 *    EllipsisStmt below.
	 *  - Sep-terminated stmts (`VoidReturnStmt` / `ThrowStmt` /
	 *    `DoWhileStmt` / `ErrorStmt` / `EmptyStmt` / `TryCatchStmtBare`)
	 *    → true (their `@:trail(';')` / `@:lit(';')` already consumed the
	 *    sep; byte at `_prevEndPos - 1` is `;` so byte-check also passes).
	 *  - `Conditional` (`#if … #end`) → true (`#end`-terminated; byte at
	 *    `_prevEndPos - 1` is `d` so byte-check does NOT cover this case,
	 *    AST predicate is the only path).
	 *  - `EllipsisStmt` (`....` placeholder) → true (no terminator; byte
	 *    at `_prevEndPos - 1` is `.`, AST predicate is the only path).
	 *
	 * `Dynamic` argument so the same predicate fires on Plain-mode
	 * `HxStatement` enum values and Trivia-mode `Trivial<HxStatementT>`
	 * struct wrappers (see `unwrap`).
	 */
	public static function stmtNoSemi(raw:Null<Dynamic>):Bool {
		final s:Null<Dynamic> = unwrap(raw);
		if (s == null) return false;
		final ctor:Null<String> = Type.enumConstructor(s);
		if (ctor == null) return false;
		// ExprStmt: delegate to the inner-expr predicate, which already
		// covers ObjectLit / ArrayExpr / IfExpr-with-else / Is / Assign-RHS-recursion.
		if (ctor == 'ExprStmt') {
			final params:Null<Array<Dynamic>> = Type.enumParameters(s);
			return params != null && params.length > 0 && stmtExprNoSemi(params[0]);
		}
		// Brace-terminated stmts — `}` is the last token. Byte-check
		// `'}'` would also match; AST branch makes the intent explicit.
		if (ctor == 'BlockStmt' || ctor == 'IfStmt' || ctor == 'WhileStmt' || ctor == 'ForStmt'
				|| ctor == 'SwitchStmt' || ctor == 'SwitchStmtBare' || ctor == 'TryCatchStmt'
				|| ctor == 'LocalFnStmt' || ctor == 'LocalInlineFnStmt' || ctor == 'UntypedBlockStmt')
			return true;
		// Sep-terminated stmts — their own `@:trail(';')` / `@:lit(';')`
		// consumed the sep; byte at `_prevEndPos - 1` is `;` so byte-check
		// also passes. AST branch is explicit.
		if (ctor == 'VoidReturnStmt' || ctor == 'ThrowStmt' || ctor == 'DoWhileStmt'
				|| ctor == 'ErrorStmt' || ctor == 'EmptyStmt' || ctor == 'TryCatchStmtBare')
			return true;
		// `#if … #end` ends with `d`; byte-check misses, AST predicate
		// is required. `....` placeholder ends with `.`; same reasoning.
		if (ctor == 'Conditional' || ctor == 'EllipsisStmt') return true;
		// `var x = expr` / `final x = expr` / static-variant stmts whose
		// init expression ends with `}` (Switch / TryCatch / FnExpr with
		// BlockBody). Byte-check on `_prevEndPos - 1` misses these because
		// the stmt's own trailing `skipWs` (before `@:trailOpt(';')`'s
		// `matchLit`) advances past the brace + newline + tabs when no
		// trailing `;` is present, leaving `_prevEndPos` past the `}`.
		// Delegate to `endsWithCloseBrace` on the `HxVarDecl.init` field.
		if (ctor == 'VarStmt' || ctor == 'FinalStmt' || ctor == 'StaticVarStmt' || ctor == 'StaticFinalStmt') {
			final params:Null<Array<Dynamic>> = Type.enumParameters(s);
			if (params == null || params.length == 0) return false;
			final decl:Null<Dynamic> = params[0];
			if (decl == null) return false;
			final init:Null<Dynamic> = Reflect.field(decl, 'init');
			return init != null && endsWithCloseBrace(init);
		}
		return false;
	}

	/**
	 * Returns the inner enum value for `raw`. Handles three shapes:
	 *  - `null` → `null`
	 *  - direct enum value (Plain-mode AST node) → `raw` unchanged
	 *  - `Trivial<T>` struct wrapper (Trivia-mode AST node) → `raw.node`
	 */
	private static inline function unwrap(raw:Null<Dynamic>):Null<Dynamic> {
		if (raw == null) return null;
		return Type.getEnum(raw) != null ? raw : Reflect.field(raw, 'node');
	}

	/**
	 * ω-cond-comp-tail-transparency — classifies the tail leaf decl of a
	 * `HxConditionalDecl` (or its Trivia synth pair `HxConditionalDeclT`)
	 * for the between-cascade in `WriterLowering.triviaEofStarExpr`.
	 *
	 * Walk priority (LAST non-empty branch wins — strict positional):
	 *  1. `elseBody` Star — if non-empty, classify its last element and
	 *     return that result directly (`null` is propagated up so the
	 *     caller treats the conditional as opaque). The other branches
	 *     are NOT consulted.
	 *  2. else `elseifs[last].body` … `elseifs[0].body` — scan from
	 *     tail back to find a non-empty clause body; classify its last
	 *     element and return that result directly. Branch fall-through
	 *     skips empty clauses but stops at the FIRST non-empty one.
	 *  3. else `body` Star — last element classification, returned
	 *     directly.
	 *  4. else `null` (no non-empty branch — cascade falls through to
	 *     kind=0/path='').
	 *
	 * The strict "last branch wins" semantic matches what the cascade
	 * expects from a positional trailing-element walker: a conditional
	 * whose tail branch ends in a non-import (e.g. `class Foo {}`)
	 * should NOT classify as an import even when an earlier branch
	 * does, because the source's last sibling-emitted decl is the
	 * non-import.
	 *
	 * Element classification: unwrap `Trivial<HxTopLevelDeclT>` if
	 * present, read `.decl` field (`HxDecl` or `HxDeclT` enum). On
	 * `Conditional` ctor, recurse into the wrapped payload (handles
	 * nested `#if … #if … #end #end`). On `ImportDecl` /
	 * `ImportWildDecl` / `UsingDecl` / `UsingWildDecl`, return
	 * `{ctorName, path}` with the path String the parser captured
	 * (`HxTypeName` / `HxWildPath` are abstract over String — runtime
	 * values are plain Strings). On any other ctor, return `null` —
	 * cascade treats the conditional as opaque (kind=0/path='').
	 *
	 * Wired on `WriteOptions.betweenImportsTailLeafClassify` via
	 * `HaxeFormat.defaultWriteOptions`. Same shared adapter feeds both
	 * Imports and Usings between infos on `HxModule.decls`; the engine
	 * does the per-info `_r.ctorName == '<info ctor>'` filter so each
	 * info only sees a leaf classification matching its own ctorNames.
	 *
	 * `Null<Dynamic>` argument because the same predicate fires on
	 * both Plain-mode (`HxConditionalDecl` plain struct) and Trivia-mode
	 * (`HxConditionalDeclT` paired struct); both have the same field
	 * names (`body`, `elseifs`, `elseBody`) so `Reflect.field` reads
	 * uniformly.
	 */
	public static function tailLeafClassifyImports(payload:Null<Dynamic>):Null<{ctorName:String, path:String}> {
		if (payload == null) return null;
		final elseBody:Null<Array<Dynamic>> = Reflect.field(payload, 'elseBody');
		if (elseBody != null && elseBody.length > 0)
			return classifyTopLevelDeclElement(elseBody[elseBody.length - 1], Tail);
		final elseifs:Null<Array<Dynamic>> = Reflect.field(payload, 'elseifs');
		if (elseifs != null && elseifs.length > 0) {
			var i:Int = elseifs.length - 1;
			while (i >= 0) {
				final clause:Null<Dynamic> = unwrapTrivialStruct(elseifs[i]);
				if (clause != null) {
					final clauseBody:Null<Array<Dynamic>> = Reflect.field(clause, 'body');
					if (clauseBody != null && clauseBody.length > 0)
						return classifyTopLevelDeclElement(clauseBody[clauseBody.length - 1], Tail);
				}
				i--;
			}
		}
		final body:Null<Array<Dynamic>> = Reflect.field(payload, 'body');
		if (body != null && body.length > 0)
			return classifyTopLevelDeclElement(body[body.length - 1], Tail);
		return null;
	}

	/**
	 * ω-imports-using-transition — classifies the head leaf decl of a
	 * `HxConditionalDecl` (or its Trivia synth pair `HxConditionalDeclT`)
	 * for the between-cascade in `WriterLowering.triviaEofStarExpr`.
	 *
	 * Walk priority (FIRST non-empty branch wins — strict positional,
	 * source order: `body` → `elseifs[0..]` → `elseBody`). Mirror of
	 * `tailLeafClassifyImports` but reversed: the conditional's head is
	 * what its first source-order branch contributes first.
	 *
	 *  1. `body` Star — if non-empty, classify its first element and
	 *     return that result directly (`null` propagates up so the
	 *     caller treats the conditional as opaque). Other branches
	 *     are NOT consulted.
	 *  2. else `elseifs[0].body` … `elseifs[last].body` — scan from
	 *     head to find the first non-empty clause body; classify its
	 *     first element and return directly.
	 *  3. else `elseBody` Star — first element classification.
	 *  4. else `null`.
	 *
	 * Recurses into nested `Conditional` ctors via the `Head` direction
	 * so `#if a #if b import x; #end #end` resolves to `import x` as
	 * the head leaf, not the inner conditional opaquely.
	 *
	 * Wired on `WriteOptions.betweenImportsHeadLeafClassify` via
	 * `HaxeFormat.defaultWriteOptions`. Used by both `betweenImports`
	 * cascade head-transparent path and the cross-subset transition
	 * cascade (`blankLinesOnTransitionAcross`) on `HxModule.decls`.
	 */
	public static function headLeafClassifyImports(payload:Null<Dynamic>):Null<{ctorName:String, path:String}> {
		if (payload == null) return null;
		final body:Null<Array<Dynamic>> = Reflect.field(payload, 'body');
		if (body != null && body.length > 0)
			return classifyTopLevelDeclElement(body[0], Head);
		final elseifs:Null<Array<Dynamic>> = Reflect.field(payload, 'elseifs');
		if (elseifs != null && elseifs.length > 0) {
			var i:Int = 0;
			while (i < elseifs.length) {
				final clause:Null<Dynamic> = unwrapTrivialStruct(elseifs[i]);
				if (clause != null) {
					final clauseBody:Null<Array<Dynamic>> = Reflect.field(clause, 'body');
					if (clauseBody != null && clauseBody.length > 0)
						return classifyTopLevelDeclElement(clauseBody[0], Head);
				}
				i++;
			}
		}
		final elseBody:Null<Array<Dynamic>> = Reflect.field(payload, 'elseBody');
		if (elseBody != null && elseBody.length > 0)
			return classifyTopLevelDeclElement(elseBody[0], Head);
		return null;
	}

	/**
	 * Classify one element from a `HxConditionalDecl.body` /
	 * `elseifs[i].body` / `elseBody` Star. Element shape is
	 * `HxTopLevelDecl` (Plain mode) or `Trivial<HxTopLevelDeclT>`
	 * (Trivia mode); both expose a `.decl` field of an `HxDecl` /
	 * `HxDeclT` enum value. Returns `null` on null input, missing
	 * `.decl`, or any unsupported ctor.
	 *
	 * `direction` selects which sub-walker recurses into a nested
	 * `Conditional` payload — `Head` keeps walking into first-branch /
	 * first-element, `Tail` into last-branch / last-element. Direction
	 * does NOT affect terminal `ImportDecl` / `UsingDecl` etc. cases.
	 */
	private static function classifyTopLevelDeclElement(elem:Null<Dynamic>, direction:LeafDirection):Null<{ctorName:String, path:String}> {
		final inner:Null<Dynamic> = unwrapTrivialStruct(elem);
		if (inner == null) return null;
		final decl:Null<Dynamic> = Reflect.field(inner, 'decl');
		if (decl == null) return null;
		final ctor:Null<String> = Type.enumConstructor(decl);
		if (ctor == null) return null;
		final params:Null<Array<Dynamic>> = Type.enumParameters(decl);
		if (params == null || params.length == 0) return null;
		return switch ctor {
			case 'Conditional': direction == Tail ? tailLeafClassifyImports(params[0]) : headLeafClassifyImports(params[0]);
			case 'ImportDecl' | 'ImportWildDecl' | 'UsingDecl' | 'UsingWildDecl':
				final path:Null<String> = params[0];
				path == null ? null : {ctorName: ctor, path: path};
			case 'ImportAliasDecl':
				// First ctor arg is `HxImportAlias` struct, not a String —
				// the lowering rejects multi-arg enum branches so the path
				// lives in the wrapped struct's `path` field instead of
				// being a positional sibling.
				final aliasDecl:Null<Dynamic> = unwrapTrivialStruct(params[0]);
				if (aliasDecl == null) return null;
				final path:Null<String> = Reflect.field(aliasDecl, 'path');
				path == null ? null : {ctorName: ctor, path: path};
			case _: null;
		};
	}

	/**
	 * Unwrap a `Trivial<T>` wrapper struct around another struct (e.g.
	 * `Trivial<HxTopLevelDeclT>` → `HxTopLevelDeclT`). Distinct from
	 * `unwrap` above because that one targets enum values and uses
	 * `Type.getEnum` to discriminate; here both wrapper and wrapped are
	 * structs, so the discriminator is `Reflect.hasField('node')`. Plain
	 * structs (`HxTopLevelDecl` directly, no wrapper) have no `node`
	 * field and pass through unchanged.
	 */
	private static inline function unwrapTrivialStruct(raw:Null<Dynamic>):Null<Dynamic> {
		if (raw == null) return null;
		return Reflect.hasField(raw, 'node') ? Reflect.field(raw, 'node') : raw;
	}
}

/**
 * Recursion direction selector for `classifyTopLevelDeclElement` when
 * encountering a nested `Conditional` ctor. `Head` recurses via
 * `headLeafClassifyImports` (first branch / first element); `Tail`
 * recurses via `tailLeafClassifyImports` (last branch / last element).
 */
private enum abstract LeafDirection(Int) {
	final Head = 0;
	final Tail = 1;
}
