package anyparse.check;

import anyparse.check.PreferComprehension.ComprehensionAcc;
import anyparse.check.PreferComprehension.ComprehensionCtx;
import anyparse.check.PreferComprehension.ComprehensionSeams;
import anyparse.query.CtorFieldFold;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The two loop shapes `prefer-comprehension` folds beyond a push-only loop, kept beside the rule so
 * its own type stays within budget. Both build the same array a push loop does, and both reuse the
 * rule's transcription, comment hoisting and self-reference gate.
 *
 * A SEQUENTIAL INDEX FILL `for (j in 0...n) a[j] = v;` into the still-EMPTY `a` appends at every step:
 * the write at step `k` lands at `a.length == k`. A NESTED BUILD body `final inner = []; <fill>;
 * a.push(inner);` builds one inner array per outer step and pushes it, which `[for (…) [<fill>]]` does
 * in the same order.
 */
@:nullSafety(Strict)
@:access(anyparse.check.PreferComprehension)
final class ComprehensionFills {

	/** An interval `lo...hi` and an assignment `target = value` each have exactly two children. */
	private static inline final BINARY_CHILD_COUNT: Int = 2;

	/** The type name whose index write appends — the one container an index fill is admitted for. */
	private static inline final ARRAY_HEAD: String = 'Array';

	/** A nested build body is exactly [inner declaration, fill loop, outer push]. */
	private static inline final NESTED_BODY_LENGTH: Int = 3;

	/**
	 * The comprehension text of the whole loop `loop` building `name`, declared with `annotation`: an index
	 * fill when the binding indexes like an ARRAY (`indexesLikeArray`), else the push-loop transcription.
	 */
	public static function loopText(
		loop: QueryNode, name: String, annotation: Null<String>, ctx: ComprehensionCtx, acc: ComprehensionAcc
	): Null<String> {
		final fill: Null<String> = indexesLikeArray(annotation) ? indexFill(loop, name, ctx, acc) : null;
		return fill ?? PreferComprehension.buildInner(loop, name, ctx, acc);
	}

	/**
	 * The comprehension text of a SEQUENTIAL INDEX FILL — `for (j in 0...n) arr[j] = v;`, the body bare or
	 * a one-statement block — or null when `node` is not exactly that. The header transfers verbatim,
	 * binder included: `unused-loop-binder` blanks an unread `j` on the next pass, which is the fixed
	 * point, rather than this rule second-guessing it.
	 *
	 * Only as the WHOLE loop of a match (`loopText` is asked for nothing else): under an outer loop or an
	 * `if` guard the same writes would overwrite or skip slots rather than append. The start must be the
	 * literal `0`, the target exactly `name[binder]`, and a key-value loop refuses. The value and the bound
	 * go through the self-reference gate like any element — `arr[j] = arr.length` reads the array being
	 * filled. The binder needs no write gate: Haxe rejects a write to a loop variable.
	 */
	public static function indexFill(node: QueryNode, name: String, ctx: ComprehensionCtx, acc: ComprehensionAcc): Null<String> {
		final s: ComprehensionSeams = ctx.seams;
		final binder: Null<String> = node.name;
		final intervalKind: Null<String> = s.intervalKind;
		if (node.kind != s.forStmtKind || node.children.length != PreferComprehension.FOR_CHILD_COUNT || binder == null) return null;
		if (intervalKind == null) return null;
		final range: QueryNode = node.children[0];
		final body: QueryNode = node.children[1];
		if (range.kind != intervalKind || range.children.length != BINARY_CHILD_COUNT || !isZeroLiteral(range.children[0], ctx))
			return null;
		final braced: Bool = body.kind == s.blockStmtKind;
		if (braced && body.children.length != 1) return null;
		final stmt: QueryNode = braced ? body.children[0] : body;
		final value: Null<QueryNode> = indexWriteValue(stmt, name, binder, s);
		final nodeSpan: Null<Span> = node.span;
		final bodySpan: Null<Span> = body.span;
		final stmtSpan: Null<Span> = stmt.span;
		final valueSpan: Null<Span> = value?.span;
		if (value == null || nodeSpan == null || bodySpan == null || stmtSpan == null || valueSpan == null) return null;
		final header: Null<String> = PreferComprehension.transcribeHeader(nodeSpan.from, bodySpan.from, ctx);
		if (header == null) return null;
		if (braced) PreferComprehension.hoistGapComments([stmt], bodySpan, ctx, acc);
		PreferComprehension.hoistCommentsIn(new Span(stmtSpan.from, valueSpan.from), ctx, acc);
		PreferComprehension.hoistCommentsIn(new Span(valueSpan.to, stmtSpan.to), ctx, acc);
		acc.checks.push(range);
		acc.checks.push(value);
		return '$header ${ctx.source.substring(valueSpan.from, valueSpan.to)}';
	}

	/**
	 * The produced element of a NESTED BUILD body — `final inner = []; <fill loop>; name.push(inner);` —
	 * as `[<inner comprehension>]`, or null when `kids` is not exactly that. The fill loop is judged by
	 * the rule's own recogniser (`loopText`), with `inner` as the accumulated name; its self-reference
	 * gate runs on `inner` here, and its checks then join the outer one, so neither array may be read in
	 * the other's element, bound or guard. `inner` appears nowhere else by construction: the three
	 * statements are the whole body, the fill loop admits it only as a push receiver or a write target,
	 * and the push argument is exactly its name.
	 */
	public static function nestedBuild(kids: Array<QueryNode>, name: String, ctx: ComprehensionCtx, acc: ComprehensionAcc): Null<String> {
		final s: ComprehensionSeams = ctx.seams;
		if (kids.length != NESTED_BODY_LENGTH || !PreferComprehension.isEmptyArrayLocal(kids[0], ctx)) return null;
		final decl: QueryNode = kids[0];
		final fill: QueryNode = kids[1];
		final innerName: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final initSpan: Null<Span> = decl.children[0].span;
		final pushed: Null<QueryNode> = PreferComprehension.pushCallArgument(kids[2], name, s);
		if (innerName == null || declSpan == null || initSpan == null) return null;
		if (PreferComprehension.commentIntersects(declSpan, ctx)) return null;
		if (pushed == null || pushed.kind != s.identKind || pushed.name != innerName) return null;
		if (fill.kind != s.forStmtKind && fill.kind != s.whileStmtKind) return null;
		final annotation: Null<String> = CtorFieldFold.declaredTypeAnnotation(ctx.source, declSpan, initSpan, innerName);
		final innerAcc: ComprehensionAcc = {
			checks: [],
			hoisted: [],
			elementType: annotation == null ? null : PreferComprehension.elementTypeOf(annotation, s)
		};
		final text: Null<String> = loopText(fill, innerName, annotation, ctx, innerAcc);
		if (text == null || innerAcc.checks.exists(cn -> PreferComprehension.referencesName(cn, innerName, s))) return null;
		if (PreferComprehension.pushArgument(kids[2], name, ctx, acc) == null) return null;
		for (c in innerAcc.checks) acc.checks.push(c);
		for (h in innerAcc.hoisted) acc.hoisted.push(h);
		return innerElement(text, annotation, acc.elementType);
	}

	/**
	 * Whether `name[j] = v` on a binding declared with `annotation` is a plain ARRAY write: no annotation
	 * (the `[]` initializer types the binding as an array) or one whose head is `Array`. A `Map` annotation
	 * turns the fold into a compile error, and an abstract `@:from` an array with an `@:arrayAccess` setter
	 * runs code on every write that a comprehension would never call — both are refused rather than judged.
	 */
	private static function indexesLikeArray(annotation: Null<String>): Bool {
		if (annotation == null) return true;
		final open: Int = annotation.indexOf('<');
		return open > 0 && annotation.substring(0, open).trim() == ARRAY_HEAD;
	}

	/**
	 * `[text]`, ascribed with the inner declaration's `annotation` unless the outer array's element type
	 * `outer` textually restates it — the rule the chain links follow, for the same reason: the annotation
	 * can be what types the elements.
	 */
	private static function innerElement(text: String, annotation: Null<String>, outer: Null<String>): String {
		final restated: Bool = annotation == null || outer != null
			&& PreferComprehension.stripWhitespace(outer) == PreferComprehension.stripWhitespace(annotation);
		return restated ? '[$text]' : '([$text] : $annotation)';
	}

	/** Whether `node` is the integer literal `0`, read off its source text. */
	private static function isZeroLiteral(node: QueryNode, ctx: ComprehensionCtx): Bool {
		final span: Null<Span> = node.span;
		return span != null && ctx.source.substring(span.from, span.to).trim() == '0';
	}

	/** The value `v` of an expression statement `name[binder] = v`, or null when `stmt` is not exactly that. */
	private static function indexWriteValue(stmt: QueryNode, name: String, binder: String, s: ComprehensionSeams): Null<QueryNode> {
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != s.assignKind || assign.children.length != BINARY_CHILD_COUNT) return null;
		final target: QueryNode = assign.children[0];
		if (target.kind != s.indexAccessKind || target.children.length != BINARY_CHILD_COUNT) return null;
		final receiver: QueryNode = target.children[0];
		final index: QueryNode = target.children[1];
		final plain: Bool = receiver.kind == s.identKind && receiver.name == name && index.kind == s.identKind && index.name == binder;
		return plain ? assign.children[1] : null;
	}

}
