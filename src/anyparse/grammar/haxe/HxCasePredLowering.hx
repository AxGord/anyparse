package anyparse.grammar.haxe;

#if macro
import anyparse.macro.AstPredLowering;
import anyparse.macro.MacroNames.*;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * The SWITCH-CASE half of the Haxe grammar's AST-predicate tables.
 *
 * Split out of `HxAstPredLowering` on size alone — the two share a base,
 * a mode and one `generate()` output, and nothing here is reachable from
 * the other side. What holds the family together is a single question
 * asked in several shapes: where does a case BODY render relative to its
 * label.
 *
 * Members, in the order `generate()` emits them:
 *
 *  - `caseBodyRefusesFlat` / `caseBodyControlFlowRoot` /
 *    `caseBodyControlFlowExpr` — per-BODY shape gates. The first refuses
 *    inline emission, the other two refuse the GLUE.

 *  - `condSpliceRawWrapsCases` — the raw-fragment scan that tells a
 *    case-label splice from a statement splice.
 *
 * Type-path constants shared with `HxAstPredLowering` are aliased rather
 * than restated, so the two files cannot drift on what `HxStatement` is.
 */
final class HxCasePredLowering extends AstPredLowering {

	private static inline final HX_EXPR: String = HxAstPredLowering.HX_EXPR;
	private static inline final HX_STATEMENT: String = HxAstPredLowering.HX_STATEMENT;

	/**
	 * `HxStatement` ctors that are keyword-led CONTROL-FLOW statements —
	 * the bodies `caseBodyControlFlowRoot` refuses to glue onto a case
	 * label. What unites them is that a construct's CONTINUATION lines
	 * (`else if`, `} while`, `catch`, an inner `case`) are siblings of its
	 * head, so glued they render at the LABEL's indent and the statement
	 * reads as if it had left the branch.
	 *
	 * `Conditional` joins them for the same reason with different markers:
	 * a `#if` region as the sole case body puts `#else` / `#end` on their own
	 * lines at the head's indent, and glued the head's indent is the label's.
	 *
	 * `BlockStmt` and every `ExprStmt` shape are deliberately absent: a
	 * `{`-opening VALUE (block, object literal, lambda) ends the label line
	 * with its brace and its interior is unambiguously the body's, which is
	 * the glue those shapes were given on purpose. `MetaStmt` is absent from
	 * the TABLE on purpose too — it is transparent, so the predicate recurses
	 * into the statement it wraps and `@:meta { … }` keeps its glue while
	 * `@:meta if (c) { … }` does not.
	 */
	private static final CONTROL_FLOW_STMT_CTORS: Array<String> = [
		'IfStmt',
		'WhileStmt',
		'ForStmt',
		'DoWhileStmt',
		'SwitchStmt',
		'SwitchStmtBare',
		'TryCatchStmt',
		'TryCatchStmtBare',
		'Conditional'
	];

	/**
	 * `HxExpr` ctors that are the EXPRESSION form of the same keyword-led
	 * constructs. A case body reaches them only through a metadata prefix:
	 * `case A: if (c) { … }` parses as the `IfStmt` statement even in
	 * expression position, but `case A: @:meta if (c) { … }` is taken by the
	 * expression route first and projects as `ExprStmt(MetaExpr(…, IfExpr))`.
	 *
	 * `BlockExpr` and `MacroExpr` are absent for the same reason `BlockStmt`
	 * is absent from the statement table — a brace-opening value keeps its
	 * glue. `DoWhileExpr` is here for the same reason as `WhileExpr`: since
	 * `do … while` has an expression form, `case A: @:meta do x() while (c);`
	 * projects as `ExprStmt(MetaExpr(…, DoWhileExpr))` rather than the
	 * `MetaStmt(DoWhileStmt)` it was before, and keeps the layout it had then.
	 */
	private static final CONTROL_FLOW_EXPR_CTORS: Array<String> = [
		'IfExpr',
		'ForExpr',
		'WhileExpr',
		'DoWhileExpr',
		'SwitchExpr',
		'SwitchExprBare',
		'TryExpr'
	];

	/** The case-family predicate fields, appended to `HxAstPredLowering.generate()`'s own. */
	public function generate(): Array<Field> {
		return [
			caseBodyRefusesFlatField(),
			caseBodyControlFlowRootField(),
			caseBodyControlFlowExprField(),

			condSpliceRawWrapsCasesField()
		];
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
			'caseBodyRefusesFlat',
			[valueArg('s', HX_STATEMENT)],
			macro : Bool, body, 'True iff an `ExprStmt` case body has an outermost `&&` / `||` and must refuse inline emission.'
		);
	}

	/**
	 * `caseBodyControlFlowRoot(s) → Bool` — true when a case body's single
	 * statement is a keyword-led control-flow statement
	 * (`CONTROL_FLOW_STMT_CTORS`) or a `MetaStmt` wrapping one. Drives the
	 * `@:fmt(refuseGlueOnControlFlowRoot)` glue refusal on `HxCaseBranch.body` /
	 * `HxDefaultBranch.stmts`: such a body, when it cannot render flat, goes
	 * BELOW its label instead of gluing onto it.
	 *
	 * `MetaStmt` is handled by RECURSION rather than by a table entry, and the
	 * distinction is load-bearing: `@:meta` is transparent, so what decides the
	 * placement is the statement underneath it. `@:meta if (c) { … }` is
	 * refused; `@:meta { … }` still glues, exactly as the bare block does.
	 *
	 * The predicate answers on KIND alone and is asked only on the glue
	 * outcome, so it never touches a body that fits on one line — `case X: if
	 * (c) x();` fits and stays inline.
	 */
	private function caseBodyControlFlowRootField(): Field {
		final recurse: Expr = {
			expr: ECall(ident('caseBodyControlFlowRoot'), [field(ident('_m'), 'stmt')]),
			pos: Context.currentPos()
		};
		final exprCall: Expr = { expr: ECall(ident('caseBodyControlFlowExpr'), [ident('_e')]), pos: Context.currentPos() };
		final body: Expr = nullSwitch(ident('s'), macro false, [
			caseOf(HX_STATEMENT, CONTROL_FLOW_STMT_CTORS, macro true),
			caseBind(HX_STATEMENT, 'MetaStmt', [0 => '_m'], recurse),
			caseBind(HX_STATEMENT, 'ExprStmt', [0 => '_e'], exprCall)
		], macro false);
		return predField(
			'caseBodyControlFlowRoot',
			[valueArg('s', HX_STATEMENT)],
			macro : Bool, body, 'True iff a case body statement is a keyword-led control-flow statement (refuses to glue onto the label).'
		);
	}

	/**
	 * `caseBodyControlFlowExpr(e) → Bool` — the EXPRESSION half of
	 * `caseBodyControlFlowRoot`, reached through its `ExprStmt` arm.
	 *
	 * It exists because a metadata prefix changes which parse route a case
	 * body takes, not what it renders as. `case A: if (c) { … }` is an
	 * `IfStmt`; `case A: @:meta if (c) { … }` is taken by the expression
	 * route first and lands as `ExprStmt(MetaExpr(…, IfExpr))`. The rendered
	 * shape — and the defect glue causes in it — is identical, so the two
	 * routes must answer alike.
	 *
	 * `MetaExpr` recurses (nested annotations compose, and the annotation is
	 * transparent to the placement question); every other expression ctor,
	 * including `BlockExpr` and `MacroExpr`, is false, so `@:meta { … }`
	 * keeps the glue a bare block gets.
	 */
	private function caseBodyControlFlowExprField(): Field {
		final recurse: Expr = {
			expr: ECall(ident('caseBodyControlFlowExpr'), [field(ident('_mv'), 'expr')]),
			pos: Context.currentPos()
		};
		final body: Expr = nullSwitch(ident('e'), macro false, [
			caseOf(HX_EXPR, CONTROL_FLOW_EXPR_CTORS, macro true),
			caseBind(HX_EXPR, 'MetaExpr', [0 => '_mv'], recurse)
		], macro false);
		return predField(
			'caseBodyControlFlowExpr',
			[valueArg('e', HX_EXPR)],
			macro : Bool, body, 'True iff a case body expression is the expression form of a keyword-led control-flow construct.'
		);
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
				return !(
					(next >= 'a'.code && next <= 'z'.code)
					|| (next >= 'A'.code && next <= 'Z'.code)
					|| (next >= '0'.code && next <= '9'.code)
					|| next == '_'.code
				);
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
			'condSpliceRawWrapsCases', [{ name: 'raw', type: macro : String }],
			macro : Bool, body, 'True iff a token-splice raw fragment has a line starting with the `case` / `default` keyword.'
		);
	}

}
#end
