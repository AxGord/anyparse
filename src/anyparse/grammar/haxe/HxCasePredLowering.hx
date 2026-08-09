package anyparse.grammar.haxe;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.AstPredLowering;

/**
 * The SWITCH-CASE half of the Haxe grammar's AST-predicate tables.
 *
 * Split out of `HxAstPredLowering` on size alone — the two share a base,
 * a mode and one `generate()` output, and nothing here is reachable from
 * the other side. What holds the family together is a single question
 * asked in several shapes: where does a case BODY render relative to its
 * label, and which units of a switch force the answer for their siblings.
 *
 * Members, in the order `generate()` emits them:
 *
 *  - `caseBodyRefusesFlat` / `caseBodyControlFlowRoot` /
 *    `caseBodyControlFlowExpr` — per-BODY shape gates. The first refuses
 *    inline emission, the other two refuse the GLUE.
 *  - `caseSiblingUnits_*` / `_caseSiblingUnitsInto` /
 *    `_addCaseSiblingUnit` — the `#if`-region flattener the sibling
 *    pre-pass measures through.
 *  - `caseUnitStructuralBreak_*` / `caseUnitControlFlowBody_*` — per-UNIT
 *    verdicts feeding that pre-pass.
 *  - `condSpliceRawWrapsCases` — the raw-fragment scan that tells a
 *    case-label splice from a statement splice.
 *
 * Type-path constants shared with `HxAstPredLowering` are aliased rather
 * than restated, so the two files cannot drift on what `HxStatement` is.
 */
final class HxCasePredLowering extends AstPredLowering {

	private static inline final HX_EXPR: String = HxAstPredLowering.HX_EXPR;
	private static inline final HX_STATEMENT: String = HxAstPredLowering.HX_STATEMENT;
	private static inline final HX_SWITCH_CASE: String = HxAstPredLowering.HX_SWITCH_CASE;
	private static inline final HX_CASE_BRANCH: String = 'anyparse.grammar.haxe.HxCaseBranch';
	private static inline final HX_DEFAULT_BRANCH: String = 'anyparse.grammar.haxe.HxDefaultBranch';
	private static inline final HX_CONDITIONAL_CASE: String = 'anyparse.grammar.haxe.HxConditionalCase';
	private static inline final HX_ELSEIF_CASE: String = 'anyparse.grammar.haxe.HxElseifCase';

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
		'Conditional',
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
	 * glue. There is no `DoWhileExpr`; `do … while` has only the statement
	 * form, which a metadata prefix routes through `MetaStmt` instead.
	 */
	private static final CONTROL_FLOW_EXPR_CTORS: Array<String> = [
		'IfExpr',
		'ForExpr',
		'WhileExpr',
		'SwitchExpr',
		'SwitchExprBare',
		'TryExpr',
	];

	/** The case-family predicate fields, appended to `HxAstPredLowering.generate()`'s own. */
	public function generate(): Array<Field> {
		return [
			caseBodyRefusesFlatField(),
			caseBodyControlFlowRootField(),
			caseBodyControlFlowExprField(),
			caseSiblingUnitsField(),
			caseSiblingUnitsIntoField(),
			addCaseSiblingUnitField(),
			caseUnitStructuralBreakField(),
			caseUnitControlFlowBodyField(),
			condSpliceRawWrapsCasesField(),
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
			'caseBodyRefusesFlat', [valueArg('s', HX_STATEMENT)],
			macro :Bool, body, 'True iff an `ExprStmt` case body has an outermost `&&` / `||` and must refuse inline emission.'
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
	 * (c) x();` is the measured outcome and stays inline. It is also the
	 * AST half of the sibling-symmetry verdict: `caseUnitControlFlowBody_*`
	 * pairs it with the pre-pass's own `flatLength == -1` measurement, which is
	 * the bit no AST walk can supply.
	 */
	private function caseBodyControlFlowRootField(): Field {
		final recurse: Expr = {
			expr: ECall(ident('caseBodyControlFlowRoot'), [field(ident('_m'), 'stmt')]),
			pos: Context.currentPos(),
		};
		final exprCall: Expr = { expr: ECall(ident('caseBodyControlFlowExpr'), [ident('_e')]), pos: Context.currentPos() };
		final body: Expr = nullSwitch(ident('s'), macro false, [
			caseOf(HX_STATEMENT, CONTROL_FLOW_STMT_CTORS, macro true),
			caseBind(HX_STATEMENT, 'MetaStmt', [0 => '_m'], recurse),
			caseBind(HX_STATEMENT, 'ExprStmt', [0 => '_e'], exprCall),
		], macro false);
		return predField(
			'caseBodyControlFlowRoot', [valueArg('s', HX_STATEMENT)],
			macro :Bool, body, 'True iff a case body statement is a keyword-led control-flow statement (refuses to glue onto the label).'
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
			pos: Context.currentPos(),
		};
		final body: Expr = nullSwitch(ident('e'), macro false, [
			caseOf(HX_EXPR, CONTROL_FLOW_EXPR_CTORS, macro true),
			caseBind(HX_EXPR, 'MetaExpr', [0 => '_mv'], recurse),
		], macro false);
		return predField(
			'caseBodyControlFlowExpr', [valueArg('e', HX_EXPR)],
			macro :Bool, body, 'True iff a case body expression is the expression form of a keyword-led control-flow construct.'
		);
	}

	/**
	 * `caseSiblingUnits_<ElemRule>(c) → Null<Array<…>>` — the case UNITS
	 * one switch-case Star element stands for, or `null` when the element
	 * is its own single unit. Consumed by the widest-sibling pre-pass of
	 * `@:fmt(caseSiblingSymmetry(…))` (see
	 * `WriterLowering.caseSiblingWidthProbeExpr`), which splices the
	 * returned units in place of the element before measuring.
	 *
	 * A `#if <cond> case … #end` region projects as ONE
	 * `HxSwitchCase.Conditional` element whose Doc carries directive
	 * hardlines, so its own `WrapList.flatLength` is `-1`: the region can
	 * FOLLOW a plain sibling's break but could never LEAD one. Flattening
	 * it into its inner case elements hands the pre-pass the same per-case
	 * widths it already has for a plain sibling, so an over-wide
	 * `#if`-guarded body now triggers the spread like any other.
	 *
	 * `null` — never `[]` — is the answer for every non-region element:
	 * this runs for every case of every switch, so the hot path must not
	 * allocate. Deliberately `null` as well:
	 *
	 *  - `CondSpliceCase`, the region shape that splits a case's LABELS
	 *    from the body they share after `#end`. Its labels live in a
	 *    byte-verbatim `HxCondSpliceRaw`, so there is no inner
	 *    case-element list to measure and the element stays one
	 *    non-contributing unit.
	 *  - a PATTERN-scope conditional (`case #if js "a" #else "b" #end:`),
	 *    which parses as a plain `CaseBranch` and never reaches this arm —
	 *    it already measures FLAT (the directives render inline in the
	 *    flat walk) and already contributes.
	 *  - a `#if` inside a case BODY (statement scope): the element is a
	 *    `CaseBranch` whose own Doc measures `-1`, unchanged.
	 */
	private function caseSiblingUnitsField(): Field {
		final unitsCT: ComplexType = ruleArrayCT(HX_SWITCH_CASE);
		final collect: Expr = macro {
			final _u: $unitsCT = [];
			_caseSiblingUnitsInto(_i, _u);
			_u;
		};
		final body: Expr = nullSwitch(ident('c'), macro null, [caseBind(HX_SWITCH_CASE, 'Conditional', [0 => '_i'], collect)], macro null);
		return predField(
			'caseSiblingUnits_${AstPredLowering.simpleName(HX_SWITCH_CASE)}', [valueArg('c', HX_SWITCH_CASE)],
			ruleNullArrayCT(HX_SWITCH_CASE), body,
			'The case units a `#if`-guarded switch-case element expands to, or null when it is its own single unit.'
		);
	}

	/**
	 * Worker of `caseSiblingUnits_*`: appends every case element of every
	 * branch of ONE `#if` case region to `out`, in `body` →
	 * `elseifs[i].body` → `elseBody` order.
	 *
	 * The units are taken ACROSS the branches because `#if` / `#elseif` /
	 * `#else` are ALTERNATIVES — only one of them is ever compiled — so
	 * the maximum over all of them is the conservative trigger, and the
	 * bytes this writer emits are one file serving every compilation
	 * variant.
	 */
	private function caseSiblingUnitsIntoField(): Field {
		inline function addUnit(elem: Expr): Expr
			return { expr: ECall(ident('_addCaseSiblingUnit'), [elem, ident('out')]), pos: Context.currentPos() };
		final addBody: Expr = addUnit(starElem(HX_CONDITIONAL_CASE, 'body', macro _b[_i]));
		final clauseBody: Expr = field(starElem(HX_CONDITIONAL_CASE, 'elseifs', ident('_cl')), 'body');
		final addClause: Expr = addUnit(starElem(HX_ELSEIF_CASE, 'body', macro _cb[_k]));
		final addElse: Expr = addUnit(starElem(HX_CONDITIONAL_CASE, 'elseBody', macro _eb[_m]));
		final body: Expr = macro {
			if (p == null) return;
			final _b = p.body;
			var _i: Int = 0;
			while (_i < _b.length) {
				$addBody;
				_i++;
			}
			final _els = p.elseifs;
			var _j: Int = 0;
			while (_j < _els.length) {
				final _cl = _els[_j];
				final _cb = $clauseBody;
				var _k: Int = 0;
				while (_k < _cb.length) {
					$addClause;
					_k++;
				}
				_j++;
			}
			final _eb = p.elseBody;
			if (_eb != null) {
				var _m: Int = 0;
				while (_m < _eb.length) {
					$addElse;
					_m++;
				}
			}
		};
		return predField(
			'_caseSiblingUnitsInto', [
				valueArg('p', HX_CONDITIONAL_CASE),
				{ name: 'out', type: ruleArrayCT(HX_SWITCH_CASE) }
			],
			macro :Void, body, 'Appends every case element of every branch of one `#if` case region to `out`.'
		);
	}

	/**
	 * Appends ONE switch-case Star element to `out` as units: a nested
	 * `#if` region recurses back through `_caseSiblingUnitsInto` (so a
	 * region inside a region flattens all the way down), anything else
	 * pushes itself.
	 *
	 * Under the DEFAULT `indentation.conditionalPolicy: aligned` a region's
	 * body renders at the enclosing case-list indent, so a nested unit's
	 * flat width is directly comparable with a top-level sibling's. The
	 * `Increase` / `Decrease` policies do lift a region body one level per
	 * conditional depth (`@:fmt(conditionalBodyIndent)` on
	 * `HxConditionalCase.body` reads `opt.conditionalPolicy`), and the
	 * pre-pass measures every unit at the switch's own indent while
	 * `IfIndentWidthExceeds` evaluates each body at ITS indent — so under
	 * those policies a region can still come out asymmetric. Measured
	 * byte-identical to the pre-slice engine there, so that is a limitation
	 * carried forward rather than introduced; a depth-aware unit width is a
	 * separate slice.
	 */
	private function addCaseSiblingUnitField(): Field {
		final regionOf: Expr = sw(ident('n'), [caseBind(HX_SWITCH_CASE, 'Conditional', [0 => '_i'], ident('_i'))], macro null);
		final regionCT: ComplexType = ruleNullCT(HX_CONDITIONAL_CASE);
		final body: Expr = macro {
			final _c: $regionCT = $regionOf;
			if (_c == null) {
				out.push(n);
				return;
			}
			_caseSiblingUnitsInto(_c, out);
		};
		return predField(
			'_addCaseSiblingUnit', [bareArg('n', HX_SWITCH_CASE), { name: 'out', type: ruleArrayCT(HX_SWITCH_CASE) }],
			macro :Void, body, 'Appends one switch-case element to `out`, flattening a nested `#if` region into its own units.'
		);
	}

	/**
		 * `caseUnitStructuralBreak_<ElemRule>(c) → Bool` — true iff ONE case
		 * unit's body renders on the line(s) BELOW its own label whatever the
		 * budget, so the per-switch symmetry verdict can be reached without a
		 * width comparison at all. Consumed by the
		 * `@:fmt(caseSiblingSymmetry(…))` pre-pass
		 * (`WriterLowering.caseSiblingWidthProbeExpr`), which drops the whole
		 * widest-sibling measurement for `BodyFit.SIBLING_FORCE_BREAK` on the
		 * first unit that answers true.
		 *
		 * The verdict is the body statement COUNT plus the flat-refusal gate,
		 * on `CaseBranch.body` and `DefaultBranch.stmts` alike:
		 *
		 *  - two or more statements — the body cannot share the label line, so
		 *    it already sits below it;
		 *  - exactly one statement that `caseBodyRefusesFlat` refuses (an
		 *    outermost `&&` / `||`) — the same placement, reached through the
		 *    shape gate instead of the count;
		 *  - exactly one statement otherwise — false, and that deliberately
		 *    covers a GLUED body (a lambda / block / object literal whose Doc
		 *    carries a hardline). Its FIRST line shares the label line, which is
		 *    not a below-label placement; a triggered switch still moves it, it
		 *    just never leads;
		 *  - ZERO statements — false. There is no body to place, and a forced
		 *    break would have nothing to move.
		 *
		 * `CondSpliceCase` is true with no check at all. It splits a case's
		 * LABELS from the body they share after `#end`, and that body is
		 * MANDATORY (`HxCondSpliceCase.tail`, plus whatever `rest` absorbs) and
		 * renders on the line(s) BELOW those labels at every budget — there is no
		 * count to take and no width that could put it back on a label line. A
		 * `Conditional` region, by contrast, never reaches this predicate AS
		 * ITSELF: the pre-pass flattens it through `caseSiblingUnits_*` first, so
		 * the predicate runs per INNER unit and a multi-statement case inside a
		 * `#if` leads the outer spread like any other unit. Every other ctor is
		 * false.
		 *
		  * A single CONTROL-FLOW statement is deliberately not listed above, even
	 * though `BodyFit.fitLineLayout` refuses it the glue: the same statement
	 * kind covers `case X: if (c) x();`, which fits on one line and stays
	 * there. The verdict needs the width measure, so it lives in the pre-pass's
	 * own loop through the sibling predicate `caseUnitControlFlowBody_*`.
	 *
	 * RESIDUAL: two shapes that render below their label are not trigger inputs
	 * HERE — a body element with leading comments, and a label carrying its own
	 * trailing comment. (A body Star with ORPHAN trailing comments was a third
	 * until omega-case-trail-comment-inline made it flatten instead.) Nothing in
	 * those trees resists the question; the obstacle is generated-table
	 * UNIFORMITY. One predicate name emits ONE body, shared by the plain /
	 * trivia / spans AST families, and the slots holding those shapes are
	 * trivia-family-specific — so reading them would make one predicate answer
	 * differently per family for the same tree.
	 *
	 * The residual is NARROWER than it looks, because the pre-pass's width loop
	 * closes half of it as a side effect. A comment-refused body still renders
	 * below its label, so its element Doc measures `-1`; if its single statement
	 * is control-flow, `caseUnitControlFlowBody_*` — which reads only the KIND,
	 * never the trivia — answers true and the switch DOES spread. So the shapes
	 * still outside the trigger set are exactly the comment-refused bodies whose
	 * statement is not control-flow. Closing those needs a trivia-aware channel,
	 * which is a separate slice.
	 */
	private function caseUnitStructuralBreakField(): Field {
		inline function verdict(rule: String, fieldName: String, holder: String): Expr {
			final stmts: Expr = field(ident(holder), fieldName);
			final refuses: Expr = {
				expr: ECall(ident('caseBodyRefusesFlat'), [starElem(rule, fieldName, macro _cs[0])]),
				pos: Context.currentPos(),
			};
			return macro {
				final _cs = $stmts;
				_cs.length >= 2 || (_cs.length == 1 && $refuses);
			};
		}
		final body: Expr = nullSwitch(ident('c'), macro false, [
			caseBind(HX_SWITCH_CASE, 'CaseBranch', [0 => '_b'], verdict(HX_CASE_BRANCH, 'body', '_b')),
			caseBind(HX_SWITCH_CASE, 'DefaultBranch', [0 => '_d'], verdict(HX_DEFAULT_BRANCH, 'stmts', '_d')),
			caseOf(HX_SWITCH_CASE, ['CondSpliceCase'], macro true),
		], macro false);
		return predField(
			'caseUnitStructuralBreak_${AstPredLowering.simpleName(HX_SWITCH_CASE)}', [valueArg('c', HX_SWITCH_CASE)],
			macro :Bool, body,
			'True iff a case unit\'s body sits below its label at any budget (multi-statement, one refused statement, '
			+ 'or a label-splice region).'
		);
	}

	/**
	 * `caseUnitControlFlowBody_<ElemRule>(c) → Bool` — true iff a case unit
	 * holds EXACTLY ONE body statement and that statement is control-flow
	 * (`caseBodyControlFlowRoot`). The AST half of the glue refusal's
	 * sibling-symmetry verdict.
	 *
	 * It is deliberately NOT part of `caseUnitStructuralBreak_*`, whose
	 * contract is "below its label at ANY budget": `case X: if (c) x();` and
	 * `case X: if (c) { x(); }` are the SAME statement kind, and only the width
	 * measure separates the one that stays inline from the one that is refused.
	 * So this predicate is consumed inside the pre-pass's WIDTH loop, gated on
	 * the unit having measured `-1` — the bit no AST walk can supply.
	 *
	 * `CondSpliceCase` answers false: its shared body already triggers
	 * structurally, and its labels are byte-verbatim so it carries no body
	 * count to take here.
	 */
	private function caseUnitControlFlowBodyField(): Field {
		inline function verdict(rule: String, fieldName: String, holder: String): Expr {
			final stmts: Expr = field(ident(holder), fieldName);
			final isControlFlow: Expr = {
				expr: ECall(ident('caseBodyControlFlowRoot'), [starElem(rule, fieldName, macro _cs[0])]),
				pos: Context.currentPos(),
			};
			return macro {
				final _cs = $stmts;
				_cs.length == 1 && $isControlFlow;
			};
		}
		final body: Expr = nullSwitch(ident('c'), macro false, [
			caseBind(HX_SWITCH_CASE, 'CaseBranch', [0 => '_b'], verdict(HX_CASE_BRANCH, 'body', '_b')),
			caseBind(HX_SWITCH_CASE, 'DefaultBranch', [0 => '_d'], verdict(HX_DEFAULT_BRANCH, 'stmts', '_d')),
		], macro false);
		return predField(
			'caseUnitControlFlowBody_${AstPredLowering.simpleName(HX_SWITCH_CASE)}', [valueArg('c', HX_SWITCH_CASE)],
			macro :Bool, body, 'True iff a case unit holds exactly one body statement and that statement is control-flow.'
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
			'condSpliceRawWrapsCases', [{ name: 'raw', type: macro :String }],
			macro :Bool, body, 'True iff a token-splice raw fragment has a line starting with the `case` / `default` keyword.'
		);
	}

	private function ruleArrayCT(rule: String): ComplexType {
		return TPath({ pack: [], name: 'Array', params: [TPType(ruleCT(rule))] });
	}

	private function ruleNullArrayCT(rule: String): ComplexType {
		return TPath({ pack: [], name: 'Null', params: [TPType(ruleArrayCT(rule))] });
	}

}
#end
