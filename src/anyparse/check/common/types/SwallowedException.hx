package anyparse.check.common.types;

import anyparse.check.Check.NoAutofix;
import anyparse.query.MemberKinds;
import anyparse.query.NodeShape;
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
 * The check fires ONLY under a statement try (`tryStatementKinds`): a catch body that is a statement block
 * (`blockStmtKind`, `try { … } catch (e) { … }`) or a bare statement or expression (`try g(); catch (e) h();`, `try g()
 * catch (e) h();`). An expression-position try (`var x = try … catch (e) fallback`) RECOVERS by producing the catch body's
 * value as the try-expression's result — ignoring the exception there is the point, which keeps the check out of the
 * idiomatic `catch (exception) null` skip-tolerance pattern. For the same reason a bare body that is side-effect free
 * (`null`, a constant, a name) is the value a statement try yields as the LAST element of a `case` arm or statement list,
 * and is not flagged there; mid-list it yields nothing and is flagged like any other body.
 *
 * ## What is flagged
 *
 * A `catchClauseKind` whose body is a NON-empty `blockStmtKind` or a bare statement and which:
 *
 *  - names its exception variable with a real name (a `_`-prefixed name is the explicit "I am discarding this"
 *    convention);
 *  - never references that variable in the body (`OccurrenceScan.referencedInRange`: looking at it is handling it);
 *  - contains no `controlExitKinds` node (`MemberKinds.subtreeContainsKind`: a rethrow, or a `return` fallback);
 *  - does not record the failure as an OUTCOME (`recordsOutcome`): a body that only assigns constants to locals, each
 *    read after the try in the function around it (`threw = true;` then `assert(!threw)`), turned the failure into a
 *    value the code acts on; an increment, a decrement or a compound assignment of a constant (`failed++`, `n += 1`)
 *    counts the failure the same way, and a body made only of `outcomeRecordingCalls` (`Assert.pass()` in a catch that
 *    expects the exception) has made it the test's result.
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
			tryStatementKinds: shape.tryStatementKinds ?? [],
			emptyKind: shape.emptyStmtKind,
			armKinds: ShapeVocab.switchArmKinds(shape),
			outcomeCalls: shape.outcomeRecordingCalls ?? [],
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
		final bare: Bool = body.kind != scan.blockKind;
		if (bare && !(ancestors.length > 0 && scan.tryStatementKinds.contains(ancestors[ancestors.length - 1].kind))) return;
		final bodySpan: Null<Span> = body.span;
		if (bodySpan == null) return;
		if (bare && (body.kind == scan.emptyKind || MemberKinds.isSideEffectFree(body, scan.shape) && endsItsList(ancestors, scan))) return;
		if (!bare && source.substring(bodySpan.from + 1, bodySpan.to - 1).trim() == '') return;
		final varName: Null<String> = catchNode.name;
		if (varName == null || varName.startsWith('_')) return;
		if (OccurrenceScan.referencedInRange(source, varName, bodySpan.from, bodySpan.to, [])) return;
		for (k in scan.exitKinds) if (MemberKinds.subtreeContainsKind(body, k)) return;
		if (recordsOutcome(bare ? [body] : body.children, tree, ancestors, scan)) return;
		out.push({
			file: file,
			span: bodySpan,
			rule: 'swallowed-exception',
			severity: Severity.Warning,
			message: 'exception \'$varName\' is caught but ignored'
		});
	}

	/**
	 * Whether the statement try `ancestors` ends in is the LAST element of the statement list or `case` arm around it — the one
	 * place a statement try's value is the value of the construct: a side-effect-free `catch` body (`null`) then recovers, while
	 * mid-list it computes a value nobody reads and the exception is dropped.
	 */
	private static function endsItsList(ancestors: Array<QueryNode>, scan: CatchScan): Bool {
		if (ancestors.length < 2) return false;
		final parent: QueryNode = ancestors[ancestors.length - 2];
		return (scan.statementListKinds.contains(parent.kind) || scan.armKinds.contains(parent.kind))
			&& parent.children[parent.children.length - 1] == ancestors[ancestors.length - 1];
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
	private static function recordsOutcome(
		statements: Array<QueryNode>, tree: QueryNode, ancestors: Array<QueryNode>, scan: CatchScan
	): Bool {
		var fnAt: Int = ancestors.length - 1;
		while (fnAt >= 0 && !scan.functionKinds.contains(ancestors[fnAt].kind)) fnAt--;
		if (fnAt < 0 || statements.length == 0) return false;
		for (stmt in statements) {
			if (!recordsTestOutcome(stmt, scan)) {
				final hit: Null<RefHit> = outcomeLocal(stmt, tree, scan.shape);
				if (hit == null || !readAfter(hit, tree, ancestors, fnAt, scan)) return false;
			}
		}
		return true;
	}

	/**
	 * Whether `stmt` is exactly an expression statement calling one of `RefShape.outcomeRecordingCalls` (`Assert.pass()`,
	 * `Assert.fail(msg)`): the exception became the test's result, which the run reports.
	 */
	private static function recordsTestOutcome(stmt: QueryNode, scan: CatchScan): Bool {
		final shape: RefShape = scan.shape;
		final call: QueryNode = stmt.kind == shape.exprStatementKind && stmt.children.length == 1 ? stmt.children[0] : stmt;
		if (call.kind != shape.callKind) return false;
		final access: Null<MethodCall> = NodeShape.methodCall(call, shape.fieldAccessKind);
		final recv: Null<String> = access?.receiver.kind == shape.identKind ? access?.receiver.name : null;
		return recv != null && access != null && scan.outcomeCalls.contains('$recv.${access.method}');
	}

	/**
	 * The write hit of the local `stmt` assigns, when `stmt` is exactly an expression statement assigning (plain `=`) a
	 * constant (`MemberKinds.isMovableLiteral`: it reads nothing) to an identifier bound to a `localDeclKinds` declaration —
	 * one the catch can see, so it lies before the try. A parameter, a field, a loop or catch variable is no such
	 * declaration. Null for anything else.
	 */
	private static function outcomeLocal(stmt: QueryNode, tree: QueryNode, shape: RefShape): Null<RefHit> {
		final write: QueryNode = stmt.kind == shape.exprStatementKind && stmt.children.length == 1 ? stmt.children[0] : stmt;
		final plain: Bool = write.kind == shape.assignKind && write.children.length == 2;
		final counter: Bool = (shape.operatorWriteKinds ?? []).contains(write.kind);
		if (!plain && !counter) return null;
		final target: QueryNode = write.children[0];
		final name: Null<String> = target.name;
		final span: Null<Span> = target.span;
		if (target.kind != shape.identKind || name == null || span == null) return null;
		if (write.children.length == 2 && !MemberKinds.isMovableLiteral(write.children[1], shape)) return null;
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
			if (
				listSpan != null
				&& childSpan != null
				&& scan.statementListKinds.contains(ancestors[k].kind)
				&& reads.exists(r -> r.from >= childSpan.to && r.to <= listSpan.to)
			)
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

	/** `RefShape.tryStatementKinds`: a catch under one is a statement-context handler, bare body or braced. */
	final tryStatementKinds: Array<String>;

	/** `RefShape.outcomeRecordingCalls`: dotted calls that record a test outcome. */
	final outcomeCalls: Array<String>;

	/** `ShapeVocab.switchArmKinds`: a `case` or `default` arm holds a statement list the tail of which is its value. */
	final armKinds: Array<String>;

	/** `RefShape.emptyStmtKind`: a bare body that is one is left to `empty-statement`. */
	final emptyKind: Null<String>;

	/** `ShapeVocab.functionLikeKinds`: the boundary an outcome local must not cross. */
	final functionKinds: Array<String>;

	/** `ControlFlowSupport.blockKinds`: the statement lists whose later statements follow the try. */
	final statementListKinds: Array<String>;
};
