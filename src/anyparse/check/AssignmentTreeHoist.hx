package anyparse.check;

import anyparse.check.IfExpressionChain.Carried;
import anyparse.check.IfExpressionChain.CarryGap;
import anyparse.check.IfExpressionChain.CarrySeat;
import anyparse.check.IfExpressionChain.IfChain;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * Recursive assignment-tree hoist machinery shared by `prefer-if-expression-assignment` and
 * `prefer-switch-expression-assignment`. A statement-position `switch` or `if`/`else-if` chain
 * whose every arm / branch body is a HOISTABLE UNIT collapses to one `<lvalue> = <expr-tree>;`
 * assignment; a hoistable unit is either a plain `<lvalue> = <expr>;` leaf (same l-value
 * throughout, textually) or, RECURSIVELY, a nested switch / if-chain with the same property.
 *
 * The two rules differ only in the TOP-LEVEL construct they own (an `if`-chain vs a `switch`,
 * plus the switch rule's decl-pairing) and in their rule-specific gates (ternary-disjointness,
 * receiver purity, decl priority, initializer synthesis). Everything structural -- recognising a
 * unit, threading the common l-value, and building the compact value text (a switch-expression or
 * an if-expression) -- lives here. The emitted text is re-formatted by the canonical writer.
 *
 * ## Comment carry
 *
 * A unit reports two things the caller needs to place comments: `atom`, the ONE copied span a
 * plain-assign leaf becomes (null for a nested construct, which is several pieces and therefore
 * no single slot), and `gaps`, the comment slots opened around those atoms. Only `ifChainValue`
 * opens slots — a `;`-terminated switch arm has no ` else ` a comment could swallow — but the
 * recursion carries a nested chain's slots up through a switch arm, so the rule that owns the
 * whole collapsed region classifies all of them at once. `carried`, threaded back down on the
 * second pass, is what welds each classified comment onto its atom
 * (`IfExpressionChain.spanText`); with none passed, every emitter yields the plain verbatim
 * slice and the built text is byte-identical to the first pass.
 */
@:nullSafety(Strict)
final class AssignmentTreeHoist {

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/**
	 * Bundle the kinds the recursion reads from `shape`, or null when a required kind is unset
	 * (the hoist is then inert). `ifKinds` / `switchKinds` stay nullable: a grammar missing one
	 * simply does not support that nesting (the recursion returns null for such a node), and each
	 * rule gates its own top-level construct on the kind it owns.
	 */
	public static function readTreeSeams(shape: RefShape): Null<TreeSeams> {
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		if (caseBranchKind == null) return null;
		final defaultBranchKind: Null<String> = shape.defaultBranchKind;
		if (defaultBranchKind == null) return null;
		final plainCasePatternKind: Null<String> = shape.plainCasePatternKind;
		if (plainCasePatternKind == null) return null;
		final wildcardPatternName: Null<String> = shape.wildcardPatternName;
		if (wildcardPatternName == null) return null;
		final parenKind: Null<String> = shape.parenKind;
		return parenKind == null ? null : {
			identKind: shape.identKind,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			assignKind: assignKind,
			caseBranchKind: caseBranchKind,
			defaultBranchKind: defaultBranchKind,
			plainCasePatternKind: plainCasePatternKind,
			wildcardPatternName: wildcardPatternName,
			parenKind: parenKind,
			ifKinds: shape.ifStatementKinds,
			switchKinds: shape.switchKinds,
			conditionalKinds: IfExpressionChain.conditionalKinds(shape)
		};
	}

	/**
	 * Recursively recognise `node` (a statement) as a hoistable unit and build its VALUE
	 * expression -- the r-value of a leaf `<lvalue> = <expr>;`, or a nested switch / if-chain whose
	 * arms / branches are themselves hoistable units. `ref` threads the common l-value: the first
	 * (leftmost) leaf sets it, every later leaf must textually match it. Null when `node` is not a
	 * single hoistable unit.
	 */
	public static function unitValue(node: QueryNode, ref: LvalueRef, source: String, s: TreeSeams, ?carried: Carried): Null<UnitValue> {
		final stmt: QueryNode = node.kind == s.blockStmtKind && node.children.length == 1 ? node.children[0] : node;
		final assign: Null<QueryNode> = plainAssign(stmt, s);
		if (assign != null) {
			final lhs: QueryNode = assign.children[0];
			if (!establishOrMatch(ref, lhs, source)) return null;
			final rhs: QueryNode = assign.children[1];
			// The ONE point a leaf r-value becomes emitted text, so the ONE place the terminator
			// swallow can be refused for every consumer: an else-less conditional at the r-value's
			// ROOT has the statement's own `;` folded INTO its span by the parser, so copying it
			// into a ` case h: <v>;` arm or a chain terminal writes `…;;` — which anyparse
			// re-parses but Haxe rejects. Root-ONLY: `g(if (q) 2)` cannot swallow the terminator.
			// A NON-terminal chain branch is already refused one level up by the whole-subtree
			// scan, which this neither widens nor replaces.
			if (IfExpressionChain.isElseLessConditional(rhs, s.conditionalKinds)) return null;
			// The ONE r-value slice in the recursion, so the ONE place a carried comment can ride a
			// leaf: `atom` hands that span up to `ifChainValue`, which is where the branch seats —
			// and with them the comment slots around this value — are opened.
			final rhsSpan: Null<Span> = rhs.span;
			return rhsSpan == null ? null : {
				text: IfExpressionChain.spanText(source, rhsSpan, carried),
				kept: [rhsSpan],
				gaps: [],
				atom: rhsSpan,
				leafCount: 1
			};
		}
		final switchKinds: Null<Array<String>> = s.switchKinds;
		if (switchKinds != null && switchKinds.contains(stmt.kind)) return switchValue(stmt, ref, source, s, carried);
		final ifKinds: Null<Array<String>> = s.ifKinds;
		return ifKinds != null && ifKinds.contains(stmt.kind) ? ifValue(stmt, ref, source, s, carried) : null;
	}

	/**
	 * The nested-switch unit value `switch subj { case h1: v1; … case _: vN; }`, or null when an
	 * arm is not a hoistable unit or the switch has no source default arm (a nested switch has no
	 * initializer to synthesize one, so it must already be exhaustive).
	 */
	public static function switchValue(
		switchNode: QueryNode, ref: LvalueRef, source: String, s: TreeSeams, ?carried: Carried
	): Null<UnitValue> {
		final sa: Null<SwitchArms> = switchArms(switchNode, ref, source, s, carried);
		if (sa == null || !sa.hasDefault) return null;
		final subjectSrc: Null<String> = slice(source, sa.subject);
		if (subjectSrc == null) return null;
		final kept: Array<Span> = sa.kept.copy();
		final subjectSpan: Null<Span> = sa.subject.span;
		if (subjectSpan != null) kept.push(subjectSpan);
		// No `atom`: a switch value is several copied pieces, not one, so no branch seat opens
		// around it and a comment in its own gaps keeps failing the site closed.
		return {
			text: 'switch $subjectSrc {${sa.armsText} }',
			kept: kept,
			gaps: sa.gaps,
			atom: null,
			leafCount: sa.leafCount
		};
	}

	/**
	 * Collect a switch's arms into ` case <header>: <value>;` text (each value the recursive hoist
	 * of the arm body), plus the verbatim-copied spans, whether a source default exists, the total
	 * leaf-assignment count, and the subject node. Null when a child is not a `case` / `default`
	 * arm (a `#if`-guarded `Conditional`, …) or an arm body is not a hoistable unit. Does NOT
	 * require a default -- the caller decides (a nested switch and the l-value arm require one; the
	 * decl arm may synthesize it).
	 */
	public static function switchArms(
		switchNode: QueryNode, ref: LvalueRef, source: String, s: TreeSeams, ?carried: Carried
	): Null<SwitchArms> {
		if (!switchReady(s) || switchNode.children.length < 2) return null;
		final subject: QueryNode = switchNode.children[0];
		final buf: StringBuf = new StringBuf();
		final kept: Array<Span> = [];
		final gaps: Array<CarryGap> = [];
		var hasDefault: Bool = false;
		var leafCount: Int = 0;
		for (i in 1...switchNode.children.length) {
			final branch: QueryNode = switchNode.children[i];
			if (branch.kind != s.caseBranchKind && branch.kind != s.defaultBranchKind) return null;
			final body: Null<QueryNode> = armBody(branch, s);
			if (body == null) return null;
			final unit: Null<UnitValue> = unitValue(body, ref, source, s, carried);
			if (unit == null) return null;
			final header: Null<String> = armHeader(branch, source, s);
			if (header == null) return null;
			buf.add(' ');
			buf.add(header);
			buf.add(': ');
			buf.add(unit.text);
			buf.add(';');
			final hs: Null<Span> = headerKeptSpan(branch, s);
			if (hs != null) kept.push(hs);
			for (k in unit.kept) kept.push(k);
			// An arm opens no seat of its own — a `;`-terminated arm value has no ` else ` to be
			// commented out — but a chain NESTED in one does, and its gaps ride up to the top-level
			// classification that owns the whole collapsed region.
			for (g in unit.gaps) gaps.push(g);
			leafCount += unit.leafCount;
			if (isDefaultArm(branch, s)) hasDefault = true;
		}
		return {
			armsText: buf.toString(),
			kept: kept,
			gaps: gaps,
			hasDefault: hasDefault,
			leafCount: leafCount,
			subject: subject
		};
	}

	/**
	 * The nested if-chain unit value `if (c1) v1 else if (c2) v2 … else vTerminal`, or null when
	 * the chain does not terminate in a final `else` or a branch is not a hoistable unit. A
	 * 2-branch `if`/`else` counts here (`minBranches` 1) -- as a nested VALUE it is unambiguous;
	 * only the TOP-level if-rule keeps the ternary-disjointness gate.
	 */
	public static function ifValue(ifNode: QueryNode, ref: LvalueRef, source: String, s: TreeSeams, ?carried: Carried): Null<UnitValue> {
		final ifKinds: Null<Array<String>> = s.ifKinds;
		if (ifKinds == null) return null;
		final chain: Null<IfChain> = IfExpressionChain.collect(ifNode, ifKinds, s.blockStmtKind, 1);
		return chain == null ? null : ifChainValue(chain, ref, source, s, carried);
	}

	/**
	 * Build the if-expression value from an already-collected chain (the top if-rule collects it once
	 * for its disjointness gate, then reuses it). This is the ONE place a ` else ` is emitted for an
	 * if-chain value, so it is also where the else-less gate sits: it covers the top-level assignment
	 * chain, every chain nested inside it, and the nested if-chains `prefer-switch-expression-assignment`
	 * builds through the same recursion.
	 *
	 * A NON-terminal branch whose statement subtree holds an else-less conditional is refused
	 * (`IfExpressionChain.holdsElseLessConditional`): that construct ends an expression OPEN, so the
	 * ` else ` emitted after its value re-parents onto it and the rest of the chain silently becomes
	 * that `if`'s else branch -- output that still parses, so the `--fix` re-parse gate waves it
	 * through. The BRANCH STATEMENT is scanned, not just the built value: the value is composed
	 * RECURSIVELY, so the statement subtree is the granularity that subsumes every leaf and nested
	 * value the recursion copies -- including a nested chain's own terminal, which is exempt at ITS
	 * level but sits in a non-terminal position at THIS one. `chain.terminal` is EXEMPT from THIS
	 * scan: nothing the rebuild emits follows it, so nothing can re-parent onto it. It stays subject
	 * to the narrower ROOT-only terminator check in `unitValue`, for the unrelated span reason
	 * documented there.
	 *
	 * The scan is conservative for a nested `switch` branch -- its arm values are `;`-terminated, so an
	 * else-less `if` there could absorb nothing -- consistent with the family's stance that proving
	 * which is which costs more than the rare cleanup it buys.
	 */
	public static function ifChainValue(chain: IfChain, ref: LvalueRef, source: String, s: TreeSeams, ?carried: Carried): Null<UnitValue> {
		final kept: Array<Span> = [];
		final gaps: Array<CarryGap> = [];
		final built: Array<{ cond: String, value: String }> = [];
		final seatParts: Array<{ cond: Null<Span>, atom: Null<Span> }> = [];
		var leafCount: Int = 0;
		for (b in chain.branches) {
			if (IfExpressionChain.holdsElseLessConditional(b.stmt, s.conditionalKinds)) return null;
			final unit: Null<UnitValue> = unitValue(b.stmt, ref, source, s, carried);
			if (unit == null) return null;
			final condSrc: Null<String> = slice(source, b.cond);
			if (condSrc == null) return null;
			built.push({ cond: condSrc, value: unit.text });
			final condSpan: Null<Span> = b.cond.span;
			if (condSpan != null) kept.push(condSpan);
			for (k in unit.kept) kept.push(k);
			for (g in unit.gaps) gaps.push(g);
			seatParts.push({ cond: condSpan, atom: unit.atom });
			leafCount += unit.leafCount;
		}
		final term: Null<UnitValue> = unitValue(chain.terminal, ref, source, s, carried);
		if (term == null) return null;
		for (k in term.kept) kept.push(k);
		for (g in term.gaps) gaps.push(g);
		leafCount += term.leafCount;
		for (g in seatGaps(seatParts, chain.terminal)) gaps.push(g);
		return {
			text: IfExpressionChain.buildValue(built, term.text),
			kept: kept,
			gaps: gaps,
			atom: null,
			leafCount: leafCount
		};
	}

	/** Whether any branch / terminal of `chain` is a nested switch / if construct (not a plain-assign leaf) -- the if-rule's 2-branch disjointness gate. */
	public static function chainHasConstruct(chain: IfChain, s: TreeSeams): Bool {
		for (b in chain.branches) if (isConstruct(b.stmt, s)) return true;
		return isConstruct(chain.terminal, s);
	}

	/**
	 * The single plain `=` assignment (`assignKind`, [l-value, r-value]) a statement holds -- a
	 * bare `lvalue = e;` or a braced `{ lvalue = e; }` wrapping one, with ANY l-value. Null when
	 * not exactly one such plain assignment (a compound / `??=` operator, a multi-statement body,
	 * or a non-assignment disqualify). L-value validation is left to the caller.
	 */
	public static function plainAssign(stmt: QueryNode, s: TreeSeams): Null<QueryNode> {
		final inner: QueryNode = stmt.kind == s.blockStmtKind ? (stmt.children.length == 1 ? stmt.children[0] : stmt) : stmt;
		if (inner.kind != s.exprStmtKind || inner.children.length != 1) return null;
		final assign: QueryNode = inner.children[0];
		return assign.kind == s.assignKind && assign.children.length == ASSIGN_CHILD_COUNT ? assign : null;
	}

	/**
	 * The one body statement of a case / default arm -- the arm's children minus its pattern
	 * wrapper(s) (`plainCasePatternKind`, one per comma alternative) and its optional guard
	 * (`caseGuard`). Null when the arm holds zero or several body statements.
	 */
	public static function armBody(branch: QueryNode, s: TreeSeams): Null<QueryNode> {
		final guard: Null<QueryNode> = caseGuard(branch, s);
		var body: Null<QueryNode> = null;
		for (c in branch.children) if (c.kind != s.plainCasePatternKind && c != guard) {
			if (body != null) return null;
			body = c;
		}
		return body;
	}

	/**
	 * The guard expression of a case branch (`case p if (c):` -- a bare parenthesized expression
	 * sibling after the pattern alternatives), or null when unguarded. Scans past the leading
	 * pattern children so a comma-alternative form (`case _, 4 if (c):`) is caught too.
	 */
	public static function caseGuard(branch: QueryNode, s: TreeSeams): Null<QueryNode> {
		for (i in 1...branch.children.length) if (branch.children[i].kind == s.parenKind) return branch.children[i];
		return null;
	}

	/**
	 * Whether `branch` is an exhaustive default arm -- a `default:` (`defaultBranchKind`) or an
	 * unguarded wildcard `case _:` (its pattern is the plain wrapper holding just the wildcard
	 * identifier). A guarded wildcard can still fail to match, so it never counts.
	 */
	public static function isDefaultArm(branch: QueryNode, s: TreeSeams): Bool {
		if (branch.kind == s.defaultBranchKind) return true;
		if (branch.kind != s.caseBranchKind || branch.children.length == 0 || caseGuard(branch, s) != null) return false;
		final pattern: QueryNode = branch.children[0];
		if (pattern.kind != s.plainCasePatternKind || pattern.children.length != 1) return false;
		final ident: QueryNode = pattern.children[0];
		return ident.kind == s.identKind && ident.name == s.wildcardPatternName;
	}

	/** The `case <pattern> [if <guard>]` header source of an arm (`default` for a default arm), or null. */
	public static function armHeader(branch: QueryNode, source: String, s: TreeSeams): Null<String> {
		if (branch.kind == s.defaultBranchKind) return 'default';
		final hs: Null<Span> = headerKeptSpan(branch, s);
		return hs == null ? null : source.substring(hs.from, hs.to);
	}

	/** The `[case … pattern/guard]` span copied verbatim into the header -- null for a `default` arm (its keyword carries no comment). */
	public static function headerKeptSpan(branch: QueryNode, s: TreeSeams): Null<Span> {
		final span: Null<Span> = branch.span;
		if (span == null || branch.kind == s.defaultBranchKind) return null;
		final guard: Null<QueryNode> = caseGuard(branch, s);
		final endNode: Null<QueryNode> = guard ?? lastPattern(branch, s);
		if (endNode == null) return null;
		final endSpan: Null<Span> = endNode.span;
		return endSpan == null ? null : new Span(span.from, endSpan.to);
	}

	/** The source text of `node`'s span, or null when it has none. */
	public static function slice(source: String, node: QueryNode): Null<String> {
		final span: Null<Span> = node.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

	/** All switch-machinery kinds present -- the recursion recognises a switch only when they are. */
	private static inline function switchReady(s: TreeSeams): Bool {
		return s.switchKinds != null;
	}

	/**
	 * The comment slots of a chain's branches: one seat per branch whose value is ONE copied span
	 * (a plain-assign leaf), running from that branch's condition end to where the NEXT copied
	 * piece starts — the following branch's condition, or the terminal statement. A branch whose
	 * value is a nested construct opens no seat: its text is several pieces, so there is no single
	 * slot a comment could ride, and the site keeps failing closed. The TERMINAL branch opens none
	 * either — the gap in front of it is the previous branch's trailing gap, and the region behind
	 * it belongs to whatever the enclosing rule welds on (a `;` a line comment would swallow).
	 */
	private static function seatGaps(parts: Array<{ cond: Null<Span>, atom: Null<Span> }>, terminal: QueryNode): Array<CarryGap> {
		final terminalSpan: Null<Span> = terminal.span;
		if (terminalSpan == null) return [];
		final seats: Array<CarrySeat> = [];
		for (i in 0...parts.length) {
			final cond: Null<Span> = parts[i].cond;
			final atom: Null<Span> = parts[i].atom;
			final next: Null<Span> = i + 1 < parts.length ? parts[i + 1].cond : terminalSpan;
			if (cond == null || atom == null || next == null) continue;
			// Re-bind: a narrowed Null<T> does not carry its narrowing into a struct literal.
			final value: Span = atom;
			seats.push({ condEnd: cond.to, value: value, nextStart: next.from });
		}
		return IfExpressionChain.carryGaps(seats);
	}

	/** Whether `node` (after a single-statement block unwrap) is a switch / if construct. */
	private static function isConstruct(node: QueryNode, s: TreeSeams): Bool {
		final stmt: QueryNode = node.kind == s.blockStmtKind && node.children.length == 1 ? node.children[0] : node;
		final switchKinds: Null<Array<String>> = s.switchKinds;
		if (switchKinds != null && switchKinds.contains(stmt.kind)) return true;
		final ifKinds: Null<Array<String>> = s.ifKinds;
		return ifKinds != null && ifKinds.contains(stmt.kind);
	}

	/** Establish the common l-value from the first leaf, or textually match a later leaf against it. */
	private static function establishOrMatch(ref: LvalueRef, lhs: QueryNode, source: String): Bool {
		final cur: Null<QueryNode> = ref.lvalue;
		if (cur != null) return IfExpressionChain.sameSource(cur, lhs, source);
		ref.lvalue = lhs;
		return true;
	}

	/** The last pattern wrapper child of a case branch (the tail of a comma-alternative list). */
	private static function lastPattern(branch: QueryNode, s: TreeSeams): Null<QueryNode> {
		var last: Null<QueryNode> = null;
		for (c in branch.children) if (c.kind == s.plainCasePatternKind) last = c;
		return last;
	}

}

/**
 * The AST kinds the recursive assignment-tree hoist reads (`ifKinds` / `switchKinds` nullable --
 * unset disables that nesting; `conditionalKinds` is every `if` form, statement and expression, for
 * `ifChainValue`'s else-less gate).
 */
typedef TreeSeams = {
	var identKind: String;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var assignKind: String;
	var caseBranchKind: String;
	var defaultBranchKind: String;
	var plainCasePatternKind: String;
	var wildcardPatternName: String;
	var parenKind: String;
	var ifKinds: Null<Array<String>>;
	var switchKinds: Null<Array<String>>;
	var conditionalKinds: Array<String>;
}

/** A mutable holder threading the common l-value through the recursion (set by the leftmost leaf). */
typedef LvalueRef = {
	var lvalue: Null<QueryNode>;
}

/** A recognised hoistable unit's built value expression, the verbatim-copied spans (comment-drop guard), and its leaf-assignment count. */
typedef UnitValue = {
	var text: String;
	var kept: Array<Span>;
	var gaps: Array<CarryGap>;
	var atom: Null<Span>;
	var leafCount: Int;
}

/** A switch's collected arms: the ` case h: v;…` text, the kept spans, whether a source default exists, the leaf count, and the subject node. */
typedef SwitchArms = {
	var armsText: String;
	var kept: Array<Span>;
	var gaps: Array<CarryGap>;
	var hasDefault: Bool;
	var leafCount: Int;
	var subject: QueryNode;
}
