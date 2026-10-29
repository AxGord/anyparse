package anyparse.check.common.types;

import anyparse.check.Check.NoAutofix;
import anyparse.query.MemberKinds;
import anyparse.query.OccurrenceScan;
import anyparse.query.Refs;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;

/**
 * Flags a statement-context `catch` clause that silently swallows the exception it caught — a named handler whose
 * statement block neither references the exception variable, rethrows, nor returns. Catching an error you then drop on the
 * floor (a generic log, an unrelated side effect, a bare continue) hides bugs — the user's own rule: never silently
 * swallow invalid state. Purely structural (no type information). Report-only — handling or rethrowing the error is a
 * human decision.
 *
 * ## Only statement-context catches
 *
 * The check fires ONLY when the catch body is a statement block (`blockStmtKind`, the `try { … } catch (e) { … }`
 * form). An expression-position try (`var x = try … catch (e) fallback`) RECOVERS by producing the catch body's value as
 * the try-expression's result — ignoring the exception there is the point, which keeps the check out of the idiomatic
 * `catch (exception) null` skip-tolerance pattern.
 *
 * ## What is flagged
 *
 * A `catchClauseKind` whose body is a NON-empty `blockStmtKind` and which:
 *
 *  - names its exception variable with a real name (a `_`-prefixed name is the explicit "I am discarding this"
 *    convention);
 *  - never references that variable in the body (`OccurrenceScan.referencedInRange`: looking at it is handling it);
 *  - contains no `controlExitKinds` node (`MemberKinds.subtreeContainsKind`: a rethrow, or a `return` fallback);
 *  - does not record the failure as an OUTCOME (`recordsOutcome`): a body that only assigns constants to locals, each
 *    read after the try in the function around it (`threw = true;` then `assert(!threw)`), turned the failure into a
 *    value the code acts on.
 *
 * An EMPTY catch block (`catch (e) {}`) is left to the `empty-block` check; the two never both fire on the same clause.
 * Every kind comes from `RefShape` / `ControlFlowSupport`; a grammar without a catch concept leaves `catchClauseKind`
 * unset and the check no-ops.
 */
@:nullSafety(Strict)
final class SwallowedException extends RuleBase implements NoAutofix {

	public function new() {
		super(
			'swallowed-exception', 'a catch whose statement block ignores the caught exception — neither used, rethrown, nor returned',
			RuleCategory.Types
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(
			files, plugin, seams(plugin),
			(entry, tree, scan, violations) -> walk(violations, entry.file, entry.source, tree, tree, [], scan)
		);
	}

	/** Report-only — resolving a swallowed exception (handle it, or rethrow) is a human decision. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'resolving a swallowed exception — handle it, or rethrow — is a human decision';
	}

	/** The seams one run reads, or null when the grammar has no catch clause or statement block — the check no-ops. */
	private static function seams(plugin: GrammarPlugin): Null<CatchScan> {
		final shape: RefShape = plugin.refShape();
		final catchKind: Null<String> = shape.catchClauseKind;
		final blockKind: Null<String> = shape.blockStmtKind;
		return catchKind == null || blockKind == null ? null : {
			shape: shape,
			catchKind: catchKind,
			blockKind: blockKind,
			exitKinds: shape.controlExitKinds ?? [],
			functionKinds: ShapeVocab.functionLikeKinds(shape),
			statementListKinds: plugin.controlFlowSupport()?.blockKinds() ?? []
		};
	}

	/** Walk `node` below its `ancestors` (the root first), flagging every swallowing statement-context catch clause reached. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, tree: QueryNode, node: QueryNode, ancestors: Array<QueryNode>, scan: CatchScan
	): Void {
		if (node.kind == scan.catchKind) flagCatch(out, file, source, tree, node, ancestors, scan);
		ancestors.push(node);
		for (c in node.children) walk(out, file, source, tree, c, ancestors, scan);
		ancestors.pop();
	}

	/**
	 * Append a `Warning` if `catchNode` swallows its exception. Bails when the body
	 * is missing / unspanned, not a statement block (an expression-position
	 * recovery), empty (left to `empty-block`), the variable is absent or
	 * `_`-prefixed (intentional discard), referenced in the body (handled), the
	 * body deliberately exits (`controlExitKinds`: rethrow / return), or it records
	 * the failure as an outcome the code after the try acts on (`recordsOutcome`).
	 */
	private static function flagCatch(
		out: Array<Violation>, file: String, source: String, tree: QueryNode, catchNode: QueryNode, ancestors: Array<QueryNode>,
		scan: CatchScan
	): Void {
		final kids: Array<QueryNode> = catchNode.children;
		if (kids.length == 0) return;
		final body: QueryNode = kids[kids.length - 1];
		if (body.kind != scan.blockKind) return;
		final bodySpan: Null<Span> = body.span;
		if (bodySpan == null) return;
		if (source.substring(bodySpan.from + 1, bodySpan.to - 1).trim() == '') return;
		final varName: Null<String> = catchNode.name;
		if (varName == null || varName.startsWith('_')) return;
		if (OccurrenceScan.referencedInRange(source, varName, bodySpan.from, bodySpan.to, [])) return;
		for (k in scan.exitKinds) if (MemberKinds.subtreeContainsKind(body, k)) return;
		if (recordsOutcome(body, tree, ancestors, scan)) return;
		out.push({
			file: file,
			span: bodySpan,
			rule: 'swallowed-exception',
			severity: Severity.Warning,
			message: 'exception \'$varName\' is caught but ignored'
		});
	}

	/**
	 * Whether the catch `body` records the failure as an OUTCOME the function goes on to act on: every statement of it
	 * assigns a constant to a local the catch sees (`outcomeLocal`), and each of those locals is read after the try
	 * (`readAfter`). `catch (exception:Exception) { threw = true; }` followed by `assert(!threw, …)` has handled the
	 * exception — the failure became a value the code acts on.
	 *
	 * POSITIVE: an empty statement list, a statement of any other shape, a target that is no such local, a value that is
	 * not a constant, a local no read after the try binds, a try outside every function, all answer false — today's verdict.
	 * `ancestors` runs from the root to the try the catch belongs to.
	 */
	private static function recordsOutcome(body: QueryNode, tree: QueryNode, ancestors: Array<QueryNode>, scan: CatchScan): Bool {
		var fnAt: Int = ancestors.length - 1;
		while (fnAt >= 0 && !scan.functionKinds.contains(ancestors[fnAt].kind)) fnAt--;
		if (fnAt < 0 || body.children.length == 0) return false;
		for (stmt in body.children) {
			final hit: Null<RefHit> = outcomeLocal(stmt, tree, scan.shape);
			if (hit == null || !readAfter(hit, tree, ancestors, fnAt, scan)) return false;
		}
		return true;
	}

	/**
	 * The write hit of the local `stmt` assigns, when `stmt` is exactly an expression statement assigning (plain `=`) a
	 * constant (`MemberKinds.isMovableLiteral`: it reads nothing) to an identifier bound to a `localDeclKinds` declaration —
	 * one the catch can see, so it lies before the try. A parameter, a field, a loop or catch variable is no such
	 * declaration. Null for anything else.
	 */
	private static function outcomeLocal(stmt: QueryNode, tree: QueryNode, shape: RefShape): Null<RefHit> {
		final assign: Null<QueryNode> = stmt.kind == shape.exprStatementKind && stmt.children.length == 1 ? stmt.children[0] : null;
		if (assign == null || assign.kind != shape.assignKind || assign.children.length != 2) return null;
		final target: QueryNode = assign.children[0];
		final name: Null<String> = target.name;
		final span: Null<Span> = target.span;
		if (target.kind != shape.identKind || name == null || span == null || !MemberKinds.isMovableLiteral(assign.children[1], shape))
			return null;
		final hit: Null<RefHit> = Refs.find(name, tree, shape).find(h -> h.kind == RefKind.Write && h.span.from == span.from);
		final decl: Null<QueryNode> = hit?.bindingNode;
		return decl != null && (shape.localDeclKinds ?? []).contains(decl.kind) ? hit : null;
	}

	/**
	 * Whether a read of the local `write` assigns, bound to the same declaration, follows the try on some path: it lies in a
	 * LATER statement of a statement list enclosing the try, inside the innermost function around it (`ancestors[fnAt]`) —
	 * the code after a closure the try sits in runs whenever the closure is not, so it does not count. Neither does a read
	 * in another arm of a branch the try sits in, nor one before the try in a loop around it (that one is a path, but not
	 * one this proves).
	 */
	private static function readAfter(write: RefHit, tree: QueryNode, ancestors: Array<QueryNode>, fnAt: Int, scan: CatchScan): Bool {
		final binding: Null<Span> = write.bindingSpan;
		if (binding == null) return false;
		final reads: Array<Span> = [
			for (h in Refs.find(write.name, tree, scan.shape)) if (h.kind == RefKind.Read && h.bindingSpan?.from == binding.from) h.span
		];
		for (k in fnAt + 1...ancestors.length - 1) {
			final listSpan: Null<Span> = ancestors[k].span;
			final childSpan: Null<Span> = ancestors[k + 1].span;
			if (listSpan != null && childSpan != null && scan.statementListKinds.contains(ancestors[k].kind) && reads.exists(r ->
				r.from >= childSpan.to && r.to <= listSpan.to
			))
				return true;
		}
		return false;
	}

}

/** The grammar seams one `swallowed-exception` run reads, resolved once. */
private typedef CatchScan = {

	final shape: RefShape;

	final catchKind: String;

	final blockKind: String;

	/** `RefShape.controlExitKinds`: a rethrow or a return escalates or recovers. */
	final exitKinds: Array<String>;

	/** `ShapeVocab.functionLikeKinds`: the boundary an outcome local must not cross. */
	final functionKinds: Array<String>;

	/** `ControlFlowSupport.blockKinds`: the statement lists whose later statements follow the try. */
	final statementListKinds: Array<String>;
};
