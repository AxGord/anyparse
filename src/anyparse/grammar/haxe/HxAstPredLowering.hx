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

	private static inline final HX_COND_DECL: String = 'anyparse.grammar.haxe.HxConditionalDecl';

	private static inline final HX_ELSEIF_DECL: String = 'anyparse.grammar.haxe.HxElseifDecl';

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
			operandIsBlockExprField(),
			caseBodyRefusesFlatField(),
			tailStmtReadsExprPositionField(),
			elementIsConditionalEnumField(HX_STATEMENT, 's'),
			elementIsConditionalEnumField(HX_SWITCH_CASE, 'c'),
			elementIsConditionalEnumField(HX_OBJECT_FIELD, 'f'),
			elementIsConditionalDeclField(),
			elementIsConditionalFalseField(HX_EXPR, 'e',
				'`HxExpr` carries no `Conditional` ctor (a nested `#if` in an args list never parses as a bare '
				+ 'expression element), so the probe is constantly false — same verdict the ctor-name check gave.'),
			elementIsConditionalFalseField(HX_MEMBER_DECL, 'm',
				'Byte-parity: the retired Dynamic adapter probed the struct\'s `.decl` field, which `HxMemberDecl` '
				+ 'does not have (its wrapper field is `.member`), so a nested conditional MEMBER never lifted. '
				+ 'Keep the false verdict; widening to `.member` → `HxClassMember.Conditional` is a behavior '
				+ 'change to make deliberately, against fork fixtures.'),
			condSpliceRawWrapsCasesField(),
			condLeafWalkerField('betweenImportsTailLeafClassify', true, '_classifyImportLeafTail'),
			condLeafWalkerField('betweenImportsHeadLeafClassify', false, '_classifyImportLeafHead'),
			condLeafWalkerField('tailLeafKeepsBlankAfterConditional', true, '_classifyKeepsBlankLeaf'),
			importLeafClassifierField('_classifyImportLeafTail', 'betweenImportsTailLeafClassify'),
			importLeafClassifierField('_classifyImportLeafHead', 'betweenImportsHeadLeafClassify'),
			keepsBlankLeafClassifierField(),
		];
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
		return predField('operandIsBlockExpr', [valueArg('e', HX_EXPR)], macro : Bool, body,
			'True iff a `macro <operand>` reification operand is a `{ … }` block.');
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
		return predField('caseBodyRefusesFlat', [valueArg('s', HX_STATEMENT)], macro : Bool, body,
			'True iff an `ExprStmt` case body has an outermost `&&` / `||` and must refuse inline emission.');
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
		return predField('tailStmtReadsExprPosition', [valueArg('s', HX_STATEMENT)], macro : Bool, body,
			'True iff a body-tail statement is a no-else `if` (drops the inherited expression-position frame).');
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
		return predField('elementIsConditional_${AstPredLowering.simpleName(rule)}', [valueArg(argName, rule)], macro : Bool, body,
			'True iff a cond-comp body Star element is itself a nested `Conditional`.');
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
		return predField('elementIsConditional_HxTopLevelDecl', [valueArg('d', HX_TOP_LEVEL_DECL)], macro : Bool, body,
			'True iff a cond-comp body Star decl element wraps a nested `Conditional` in its `.decl`.');
	}

	/** Constant-false member of the `elementIsConditional_*` family — see `doc` for why the shape can never match. */
	private function elementIsConditionalFalseField(rule: String, argName: String, doc: String): Field {
		return predField('elementIsConditional_${AstPredLowering.simpleName(rule)}', [valueArg(argName, rule)], macro : Bool, macro false, doc);
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
		return predField(name, [valueArg('p', HX_COND_DECL)], macro : Null<{ ctorName: String, path: String }>, body,
			(tail ? 'Tail' : 'Head') + '-leaf classification of a module-level conditional for the between/after cascades.');
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
		final cases: Array<Case> = [caseBind(HX_DECL, 'Conditional', [0 => '_c'], {
			expr: ECall(ident(walker), [ident('_c')]),
			pos: Context.currentPos(),
		})];
		for (c in IMPORT_PATH_CTORS) cases.push(caseBind(HX_DECL, c, [0 => '_p'], macro { ctorName: $v{c}, path: _p }));
		for (c in IMPORT_ALIAS_CTORS) cases.push(caseBind(HX_DECL, c, [0 => '_a'], macro { ctorName: $v{c}, path: _a.path }));
		final body: Expr = sw(field(ident('e'), 'decl'), cases, macro null);
		return predField(name, [bareArg('e', HX_TOP_LEVEL_DECL)], macro : Null<{ ctorName: String, path: String }>, body,
			'Import/using leaf classification of one conditional body element (null = opaque).');
	}

	/**
	 * Leaf classifier for `tailLeafKeepsBlankAfterConditional` — same
	 * element-unwrap path as the import classifiers but the broader
	 * `KEEPS_BLANK_CTORS` set (import / using family AND type-level
	 * decls; the consumer gate only reads nullness, the ctor name is
	 * informational). Recurses tail-first into a nested `Conditional`.
	 */
	private function keepsBlankLeafClassifierField(): Field {
		final cases: Array<Case> = [caseBind(HX_DECL, 'Conditional', [0 => '_c'], {
			expr: ECall(ident('tailLeafKeepsBlankAfterConditional'), [ident('_c')]),
			pos: Context.currentPos(),
		})];
		for (c in KEEPS_BLANK_CTORS) cases.push(caseOf(HX_DECL, [c], macro { ctorName: $v{c}, path: '' }));
		final body: Expr = sw(field(ident('e'), 'decl'), cases, macro null);
		return predField('_classifyKeepsBlankLeaf', [bareArg('e', HX_TOP_LEVEL_DECL)],
			macro : Null<{ ctorName: String, path: String }>, body,
			'Keep-blank leaf classification of one conditional body element (non-null = fork keeps a blank).');
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
			function kwAt(s: String, at: Int, kw: String): Bool {
				final kl: Int = kw.length;
				if (at + kl > s.length) return false;
				for (k in 0...kl) if (StringTools.fastCodeAt(s, at + k) != StringTools.fastCodeAt(kw, k)) return false;
				if (at + kl >= s.length) return true;
				final next: Int = StringTools.fastCodeAt(s, at + kl);
				return !((next >= 'a'.code && next <= 'z'.code) || (next >= 'A'.code && next <= 'Z'.code)
					|| (next >= '0'.code && next <= '9'.code)
					|| next == '_'.code);
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
		return predField('condSpliceRawWrapsCases', [{ name: 'raw', type: macro : String }], macro : Bool, body,
			'True iff a token-splice raw fragment has a line starting with the `case` / `default` keyword.');
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
		return predField('arrayBracketKind', [valueArg('e', HX_EXPR)], macro : Int, body,
			'Bracket kind of an array-`[…]` ctor by its first element: 1 map literal, 2 comprehension, 0 array literal.');
	}

}
#end
