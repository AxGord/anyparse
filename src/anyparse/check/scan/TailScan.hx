package anyparse.check.scan;

import anyparse.check.scan.CheckScan;
import anyparse.query.BinderScan;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.MemberKinds;
import anyparse.query.ShapeVocab;

/**
 * The one answer to "do these statements run the same under the same names, and may a run of them move
 * without a name changing meaning": token identity of two statements, the names a statement list binds,
 * whether a tail reads one, conditional compilation and comments inside a region. Shared by `tail-merge`
 * and `hoist-common-branch-tail`.
 */
@:nullSafety(Strict)
final class TailScan {

	/** The conditional-compilation markers that refuse a candidate wherever they appear in its regions. */
	private static final CONDITIONAL_DIRECTIVES: Array<String> = ['#if', '#elseif', '#else', '#end'];

	/**
	 * Whether `a` and `b` are the SAME statement, token for token. Both halves are needed:
	 * `structurallyEqual` compares the projected tree, which is blind to a comment inside a
	 * statement's span, while the normalized-source comparison collapses whitespace INSIDE
	 * string literals and would equate `f("a  b")` with `f("a b")`. Requiring both leaves
	 * exactly token identity, so anything the pair cannot prove identical is refused.
	 */
	public static function sameStatement(a: QueryNode, b: QueryNode, source: String): Bool {
		if (!MemberKinds.structurallyEqual(a, b)) return false;
		final sa: Null<Span> = a.span;
		final sb: Null<Span> = b.span;
		if (sa == null || sb == null) return false;
		final na: NormalizedSpan = CheckScan.normalizeSpan(source, sa.from, sa.to);
		final nb: NormalizedSpan = CheckScan.normalizeSpan(source, sb.from, sb.to);
		return na.norm == nb.norm;
	}

	/**
	 * The names `stmts` bind directly — what a tail nested under them could be reading
	 * instead of the outer binding of the same spelling. A statement declares when
	 * `BinderScan.topLevelDeclaredNode` reaches a declaration through its metadata
	 * wrappers (`@:meta var t = …` is an expression statement around a `VarExpr`, not a
	 * `VarStmt`), which covers local variables in both statement and expression form; local
	 * FUNCTIONS, plain and `inline`, bind a shadowing name the same way and are matched by
	 * kind.
	 */
	public static function localDeclNames(stmts: Array<QueryNode>, seams: TailSeams): Array<String> {
		final names: Array<String> = [];
		for (c in stmts) {
			var decl: Null<QueryNode> = declaredNode(c, seams);
			// Walk the CONTINUATION chain: `var a = 1, b = 2;` binds `b` as well, on a node nested
			// right-recursively inside the head declaration. Reading the head's name alone left the
			// shadowing gate blind to every binding after the first.
			while (decl != null) {
				final node: QueryNode = decl;
				final nm: Null<String> = node.name;
				if (nm != null) names.push(nm);
				decl = node.children.find(k -> seams.localDeclContinuationKinds.contains(k.kind));
			}
		}
		return names;
	}

	/**
	 * Whether `stmts` holds a variable declaration whose bound names `localDeclNames` cannot fully
	 * enumerate. Such a statement makes the shadowing gate blind, so its mere presence refuses the candidate.
	 *
	 * A MULTI-DECLARATOR (`var a = 1, t = 2;`) is no longer one of them: every binding after the first surfaces as its
	 * own continuation node (`RefShape.localDeclContinuationKinds`) and `localDeclNames` walks the chain, so the precise
	 * shadowing gate decides it. The arms below stay as the fail-closed net for a declaration whose span or head
	 * initializer the projection does not resolve, and for one whose first declarator writes no initializer before a
	 * continuation (`var a, b;`).
	 */
	public static function hasOpaqueDecl(stmts: Array<QueryNode>, seams: TailSeams): Bool {
		for (c in stmts) {
			final decl: Null<QueryNode> = declaredNode(c, seams);
			if (decl == null || seams.fnDeclKinds.contains(decl.kind)) continue;
			if (decl.children.length > 1 || decl.span == null) return true;
			if (decl.children.exists(k -> k.span == null || seams.localDeclContinuationKinds.contains(k.kind))) return true;
		}
		return false;
	}

	/** Whether any of `names` is read as an identifier anywhere in the `tail` subtrees. */
	public static function referencesAny(tail: Array<QueryNode>, names: Array<String>, identKinds: Array<String>): Bool {
		return names.length != 0 && tail.exists(s -> mentionsName(s, names, identKinds));
	}

	/**
	 * Whether `[from, to)` holds a conditional-compilation directive. A plain text scan, so
	 * a directive spelled inside a string literal refuses too — the safe direction, and the
	 * same string-blind conservatism as `CheckScan.hasCommentMarker`.
	 */
	public static function hasConditionalCompilation(source: String, from: Int, to: Int): Bool {
		if (from >= to) return false;
		final s: String = source.substring(from, to);
		return CONDITIONAL_DIRECTIVES.exists(d -> s.indexOf(d) != -1);
	}

	/**
	 * The comments in the trivia gaps of a statement run: before its first statement (from
	 * `prevEnd`) and between consecutive ones. Every scanned range is pure trivia, so there
	 * is no string-literal to mistake a marker for.
	 */
	public static function runComments(source: String, stmts: Array<QueryNode>, prevEnd: Int): Array<String> {
		final out: Array<String> = [];
		var from: Int = prevEnd;
		for (s in stmts) {
			final span: Null<Span> = s.span;
			if (span == null) return out;
			collectComments(source, from, span.from, out);
			from = span.to;
		}
		return out;
	}

	/**
	 * Resolve the `if` / block / terminal / identifier / declaration / terminator seams, or null when a required one is
	 * unset. `terminalKinds` is built from the value-return, throw and void-return kinds rather than from
	 * `controlFlowSupport().isTerminal`, which also counts `break` and `continue`: a caller that wants only the exits whose
	 * target it can name without a loop reads the narrow set, one that refuses any exit reads `support`.
	 * `localDeclKinds` is REQUIRED even though no caller reports on a declaration: it is what the shadowing gates prove
	 * absence against, so an unset seam would silently turn them off, and with them the soundness of every move.
	 */
	public static function resolveSeams(plugin: GrammarPlugin): Null<TailSeams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final localDeclContinuationKinds: Array<String> = shape.localDeclContinuationKinds ?? [];
		if (ifKinds.length == 0 || localDeclKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final terminalKinds: Array<String> = (shape.valueReturnKinds ?? []).concat(shape.throwKinds ?? []);
		final voidReturnKind: Null<String> = shape.voidReturnKind;
		if (voidReturnKind != null) terminalKinds.push(voidReturnKind);
		if (terminalKinds.length == 0) return null;
		final identKinds: Array<String> = [shape.identKind];
		final interpIdentKind: Null<String> = shape.stringInterpIdentKind;
		if (interpIdentKind != null) identKinds.push(interpIdentKind);
		return {
			ifKinds: ifKinds,
			blockKinds: support.blockKinds(),
			opaqueKinds: shape.opaqueKinds ?? [],
			terminalKinds: terminalKinds,
			identKinds: identKinds,
			localDeclKinds: localDeclKinds,
			localDeclContinuationKinds: localDeclContinuationKinds,
			localDeclExprKinds: shape.localDeclExprKinds ?? [],
			fnDeclKinds: ShapeVocab.localFunctionScopeKinds(shape),
			metaKinds: plugin.metaShape().metaKinds,
			support: support,
			terminator: shape.statementTerminator
		};
	}

	/**
	 * The declaration `stmt` is, unwrapped from any metadata: a local variable (statement or
	 * expression form) via `BinderScan.topLevelDeclaredNode`, or a local function
	 * (`localFunctionKinds` / `inlineFunctionKinds`) by kind. Null when `stmt` binds nothing.
	 */
	private static function declaredNode(stmt: QueryNode, seams: TailSeams): Null<QueryNode> {
		return seams.fnDeclKinds.contains(stmt.kind)
			? stmt
			: BinderScan.topLevelDeclaredNode(stmt, seams.localDeclKinds, seams.localDeclExprKinds, seams.metaKinds);
	}

	/** Whether `node`'s subtree holds an identifier (or string-interpolation identifier) named in `names`. */
	private static function mentionsName(node: QueryNode, names: Array<String>, identKinds: Array<String>): Bool {
		final nm: Null<String> = node.name;
		if (nm != null && identKinds.contains(node.kind) && names.contains(nm)) return true;
		return node.children.exists(c -> mentionsName(c, names, identKinds));
	}

	/** Append every line comment (`//` to end of line) and block comment in `[from, to)` to `out`, trimmed. */
	private static function collectComments(source: String, from: Int, to: Int, out: Array<String>): Void {
		var i: Int = from;
		while (i < to - 1) switch source.substr(i, 2) {
			case '//':
				var end: Int = i + 2;
				while (end < to && source.fastCodeAt(end) != '\n'.code) end++;
				out.push(source.substring(i, end).trim());
				i = end;
			case '/*':
				final close: Int = source.indexOf('*/', i + 2);
				final end: Int = close == -1 || close + 2 > to ? to : close + 2;
				out.push(source.substring(i, end).trim());
				i = end;
			case _:
				i++;
		}
	}

}

/**
 * The grammar seams a statement-run scan resolves once per `run` / `fix`. The declaration trio feeds the
 * shadowing gate: `localDeclKinds` / `localDeclExprKinds` are the local VARIABLE forms
 * `BinderScan.topLevelDeclaredNode` unwraps `metaKinds` down to — and the only ones whose projection can
 * under-report a multi-declarator's names (`hasOpaqueDecl`) — while `fnDeclKinds` are the local FUNCTION
 * declarations, plain and `inline`, which bind a shadowing name too but never come in multiples.
 * `terminalKinds` is the return / throw set WITHOUT `break` / `continue`; `support` answers the wider
 * "does this statement exit" question.
 */
typedef TailSeams = {
	final ifKinds: Array<String>;
	final blockKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final terminalKinds: Array<String>;
	final identKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final localDeclContinuationKinds: Array<String>;
	final localDeclExprKinds: Array<String>;
	final fnDeclKinds: Array<String>;
	final metaKinds: Array<String>;
	final support: ControlFlowSupport;
	final terminator: Null<String>;
};
