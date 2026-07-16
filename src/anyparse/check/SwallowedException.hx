package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a statement-context `catch` clause that silently swallows the exception
 * it caught — a named handler whose statement block neither references the
 * exception variable, rethrows, nor returns. Catching an error you then drop on
 * the floor (a generic log, an unrelated side effect, a bare continue) hides
 * bugs — the user's own rule: never silently swallow invalid state. Purely
 * structural (no type information), so it holds without a type-checker.
 * Report-only — the fix is to handle or rethrow the error, a human decision.
 *
 * ## Only statement-context catches
 *
 * The check fires ONLY when the catch body is a statement block (`blockStmtKind`,
 * the `try { … } catch (e) { … }` form). An expression-position try
 * (`var x = try … catch (e) fallback`, or a `catch (e) { … }` whose block yields
 * a value) RECOVERS by producing the catch body's value as the try-expression's
 * result — ignoring the exception there is the point, not a bug. Restricting to
 * the statement form is what keeps the check from drowning in the idiomatic
 * `catch (exception) null` skip-tolerance pattern; a swallow is only meaningful
 * where the handler is a sequence of statements that was supposed to deal with
 * the error.
 *
 * ## What is flagged
 *
 * A `catchClauseKind` whose body is a NON-empty `blockStmtKind` and which:
 *
 *  - names its exception variable with a real name (a `_`-prefixed name is the
 *    explicit "I am discarding this" convention and is left alone);
 *  - never references that variable in the body (if the handler looks at the
 *    exception, it is handling it);
 *  - contains no `controlExitKinds` node (a `throw` rethrow / wrapped re-throw,
 *    or a `return` fallback — deliberate escalation / recovery, not a swallow).
 *
 * An EMPTY catch block (`catch (e) {}`) is left to the `empty-block` check; the
 * two never both fire on the same clause.
 *
 * ## Grammar-agnostic
 *
 * Every kind comes from `RefShape` (`catchClauseKind`, `blockStmtKind`,
 * `controlExitKinds`); a grammar without a catch concept leaves `catchClauseKind`
 * unset and the check no-ops. The reference test is
 * `RefactorSupport.referencedInRange` (the conservative text scan the unused-*
 * family uses) and the exit test is `RefactorSupport.subtreeContainsKind`.
 */
@:nullSafety(Strict)
final class SwallowedException implements Check {

	public function new() {}

	public function id(): String {
		return 'swallowed-exception';
	}

	public function description(): String {
		return 'a catch whose statement block ignores the caught exception — neither used, rethrown, nor returned';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final catchKind: Null<String> = shape.catchClauseKind;
		final blockKind: Null<String> = shape.blockStmtKind;
		if (catchKind == null || blockKind == null) return [];
		final exitKinds: Array<String> = shape.controlExitKinds ?? [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, catchKind, blockKind, exitKinds);
		}
		return violations;
	}

	/** Report-only — resolving a swallowed exception (handle it, or rethrow) is a human decision. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`, flagging every swallowing statement-context catch clause reached. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, catchKind: String, blockKind: String,
		exitKinds: Array<String>
	): Void {
		if (node.kind == catchKind) flagCatch(out, file, source, node, blockKind, exitKinds);
		for (c in node.children) walk(out, file, source, c, catchKind, blockKind, exitKinds);
	}

	/**
	 * Append a `Warning` if `catchNode` swallows its exception. Bails when the body
	 * is missing / unspanned, not a statement block (an expression-position
	 * recovery), empty (left to `empty-block`), the variable is absent or
	 * `_`-prefixed (intentional discard), referenced in the body (handled), or the
	 * body deliberately exits (`controlExitKinds`: rethrow / return).
	 */
	private static function flagCatch(
		out: Array<Violation>, file: String, source: String, catchNode: QueryNode, blockKind: String, exitKinds: Array<String>
	): Void {
		final kids: Array<QueryNode> = catchNode.children;
		if (kids.length == 0) return;
		final body: QueryNode = kids[kids.length - 1];
		if (body.kind != blockKind) return;
		final bodySpan: Null<Span> = body.span;
		if (bodySpan == null) return;
		if (StringTools.trim(source.substring(bodySpan.from + 1, bodySpan.to - 1)) == '') return;
		final varName: Null<String> = catchNode.name;
		if (varName == null || StringTools.startsWith(varName, '_')) return;
		if (RefactorSupport.referencedInRange(source, varName, bodySpan.from, bodySpan.to, [])) return;
		for (k in exitKinds) if (RefactorSupport.subtreeContainsKind(body, k)) return;
		out.push({
			file: file,
			span: bodySpan,
			rule: 'swallowed-exception',
			severity: Severity.Warning,
			message: 'exception \'$varName\' is caught but ignored'
		});
	}

}
