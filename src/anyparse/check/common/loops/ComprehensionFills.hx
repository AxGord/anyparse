package anyparse.check.common.loops;

import anyparse.check.common.control.BranchChain;
import anyparse.check.common.loops.PreferComprehension.ComprehensionAcc;
import anyparse.check.common.loops.PreferComprehension.ComprehensionCtx;
import anyparse.check.common.loops.PreferComprehension.ComprehensionSeams;
import anyparse.check.common.loops.PreferComprehension.MapTypes;
import anyparse.check.scan.NegationScan;
import anyparse.query.CtorFieldFold;
import anyparse.query.LexicalRegions;
import anyparse.query.NodeShape;
import anyparse.query.SourceText;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

private typedef KeptStep = { var text: String; var terminated: Bool; }

private typedef KeyedWrite = { var key: QueryNode; var value: QueryNode; }

/**
 * The loop shapes `prefer-comprehension` folds beyond a push-only loop, kept beside the rule so
 * its own type stays within budget. Each builds the same collection a push loop does and reuses the
 * rule's transcription, comment hoisting and self-reference gate.
 *
 * A SEQUENTIAL INDEX FILL `for (j in 0...n) a[j] = v;` into the still-EMPTY `a` appends at every step:
 * the write at step `k` lands at `a.length == k`. A NESTED BUILD body `final inner = []; <fill>;
 * a.push(inner);` builds one inner array per outer step and pushes it, which `[for (…) [<fill>]]` does
 * in the same order.
 *
 * A MAP FILL `for (x in xs) m[k] = v;` into a still-empty `m` declared `Map<K, V>` is `[for (x in xs) k => v]`:
 * the loop and the comprehension both evaluate the key, then the value, and the later pair for a repeated
 * key wins in both, so no repeated-key case needs declining. Only the plain `for` and else-less `if`
 * layers reach the write, and a pair operand the typing cannot show to have the declared key or value
 * type is ascribed with it.
 */
@:nullSafety(Strict)
@:access(anyparse.check.common.loops.PreferComprehension)
final class ComprehensionFills {

	/** A nested build body is exactly [inner declaration, fill loop, outer push]. */
	private static inline final NESTED_BODY_LENGTH: Int = 3;

	private static inline final MAP_ARITY: Int = 2;
	private static final ARROW: String = ' => ';

	/** The type name whose index write appends — the one container an index fill is admitted for. */
	private static final ARRAY_HEAD: String = 'Array';

	/** The type name whose keyed write `m[k] = v` a comprehension reproduces as `k => v`, and its key and value arity. */
	private static final MAP_HEAD: String = 'Map';

	/**
	 * The comprehension text of the whole loop `loop` building `name`, declared with `annotation`: an index
	 * fill when the binding indexes like an ARRAY (`indexesLikeArray`), else the push-loop transcription —
	 * whose terminal is the keyed write `m[k] = v` instead of a push when the binding is a `Map`.
	 */
	public static function loopText(
		loop: QueryNode, name: String, annotation: Null<String>, ctx: ComprehensionCtx, acc: ComprehensionAcc
	): Null<String> {
		acc.keyed = mapTypesOf(annotation, ctx.seams.typeSyntax);
		final fill: Null<String> = indexesLikeArray(annotation, ctx.seams.typeSyntax) ? indexFill(loop, name, ctx, acc) : null;
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
		if (node.kind != s.forStmtKind || !LoopScan.hasForShape(node.children) || binder == null) return null;
		if (intervalKind == null) return null;
		final range: QueryNode = LoopScan.forHead(node.children);
		final body: QueryNode = LoopScan.forBody(node.children);
		if (range.kind != intervalKind || !NodeShape.hasBinaryShape(range) || !isZeroLiteral(range.children[0], ctx)) return null;
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
		if (LexicalRegions.commentIntersects(declSpan.from, declSpan.to, ctx.regions)) return null;
		if (pushed == null || pushed.kind != s.identKind || pushed.name != innerName) return null;
		if (fill.kind != s.forStmtKind && fill.kind != s.whileStmtKind) return null;
		final annotation: Null<String> = CtorFieldFold.declaredTypeAnnotation(ctx.source, decl);
		final innerAcc: ComprehensionAcc = {
			checks: [],
			hoisted: [],
			keyed: null,
			pairHoles: [],
			pairLength: 0,
			elementType: annotation == null ? null : NominalTypes.elementTypeSourceOf(annotation, s.elementTypeParams, [], s.typeSyntax)
		};
		final text: Null<String> = loopText(fill, innerName, annotation, ctx, innerAcc);
		if (innerAcc.keyed != null) return null;
		if (text == null || innerAcc.checks.exists(cn -> PreferComprehension.referencesName(cn, innerName, s))) return null;
		if (PreferComprehension.pushArgument(kids[2], name, ctx, acc) == null) return null;
		for (c in innerAcc.checks) acc.checks.push(c);
		for (h in innerAcc.hoisted) acc.hoisted.push(h);
		return innerElement(text, annotation, acc.elementType);
	}

	/**
	 * The produced element of a KEPT-STATEMENT body — locals and `if (c) continue;` guards ahead of the final
	 * `name.push(e)` — as a block `{ final y = f(x); if (y != null) y; }`, or null when `kids` is anything else.
	 * The one answer to "which loop bodies may keep their own statements inside a comprehension": the chain
	 * form inlines single-use locals first, so this arm sees what the chain refuses (a local read twice, a
	 * guard).
	 *
	 * Statements keep their order and their evaluation, so the body is admitted only when every statement is a
	 * single-assignment local with one initializer (a `var`, a list, a missing initializer refuse) or a bare
	 * else-less `if` whose branch is exactly `continue` — nothing else can run between the locals and the
	 * element. A guard becomes the negated `if` around the rest, braced when a local follows it. The locals'
	 * initializers and the guards' conditions join the self-reference gate like any element, and a local named
	 * after the array, or a comment inside a kept statement, refuses.
	 */
	public static function keptBlock(kids: Array<QueryNode>, name: String, ctx: ComprehensionCtx, acc: ComprehensionAcc): Null<String> {
		final s: ComprehensionSeams = ctx.seams;
		final last: Int = kids.length - 1;
		final checks: Array<QueryNode> = [];
		final texts: Array<String> = [];
		for (i in 0...last) {
			final text: Null<String> = keptStatementText(kids[i], name, ctx, checks);
			if (text == null) return null;
			texts.push(text);
		}
		final pushed: Null<QueryNode> = PreferComprehension.pushArgument(kids[last], name, ctx, acc);
		final element: Null<Span> = pushed?.span;
		if (element == null) return null;
		for (c in checks) acc.checks.push(c);
		var steps: Array<KeptStep> = [{ text: ctx.source.substring(element.from, element.to), terminated: false }];
		var i: Int = last;
		while (i-- > 0) steps = isGuard(kids[i], s) ? [guardStep(texts[i], steps)] : [{ text: texts[i], terminated: true }].concat(steps);
		return steps.length == 1 ? steps[0].text : '{ ${renderSteps(steps)} }';
	}

	/**
	 * The MAP FILL element `k => v` of a terminal statement `name[k] = v`, or null when `stmt` is anything
	 * else (a compound write, another receiver). The pair gets the push terminal's treatment: comments outside the key
	 * and value are hoisted and both join the self-reference gate. Each operand is ascribed with the declared key or
	 * value type unless the typing proves it already has that type exactly: a map comprehension takes its pair type
	 * from the pair and is invariant against the declared `Map<K, V>`, so an `Int` value for a `Float` map or a
	 * null-narrowed key for a `String` key would stop compiling where `m[k] = v` did not. The operands are holes for
	 * `ParenGuard`, since `c ? a : b => v` and `cast x => v` do not parse.
	 */
	public static function keyedPair(stmt: QueryNode, name: String, ctx: ComprehensionCtx, acc: ComprehensionAcc): Null<String> {
		final write: Null<KeyedWrite> = keyedWrite(stmt, name, ctx.seams);
		final stmtSpan: Null<Span> = stmt.span;
		final keySpan: Null<Span> = write?.key.span;
		final valueSpan: Null<Span> = write?.value.span;
		final types: Null<MapTypes> = acc.keyed;
		if (write == null || stmtSpan == null || keySpan == null || valueSpan == null || types == null) return null;
		if (!isExactly(write.key, types.key, ctx) || !isExactly(write.value, types.value, ctx)) return null;
		PreferComprehension.hoistCommentsIn(new Span(stmtSpan.from, keySpan.from), ctx, acc);
		PreferComprehension.hoistCommentsIn(new Span(keySpan.to, valueSpan.from), ctx, acc);
		PreferComprehension.hoistCommentsIn(new Span(valueSpan.to, stmtSpan.to), ctx, acc);
		acc.checks.push(write.key);
		acc.checks.push(write.value);
		final key: String = ctx.source.substring(keySpan.from, keySpan.to);
		final value: String = ctx.source.substring(valueSpan.from, valueSpan.to);
		final pair: String = '$key => $value';
		acc.pairHoles = [new Span(0, key.length), new Span(key.length + ARROW.length, pair.length)];
		acc.pairLength = pair.length;
		return pair;
	}

	/**
	 * The character ranges of the pair operands inside the replacement `head + '];'` of a keyed match, which
	 * `ParenGuard` may wrap: the pair is the last thing `head` holds.
	 */
	public static function keyHoles(head: String, acc: ComprehensionAcc): Array<Span> {
		final from: Int = head.length - acc.pairLength;
		return acc.pairHoles.map(h -> new Span(from + h.from, from + h.to));
	}

	/**
	 * Whether `name[j] = v` on a binding declared with `annotation` is a plain ARRAY write: no annotation
	 * (the `[]` initializer types the binding as an array) or one whose head is `Array`. A `Map` annotation
	 * turns the fold into a compile error, and an abstract `@:from` an array with an `@:arrayAccess` setter
	 * runs code on every write that a comprehension would never call — both are refused rather than judged.
	 */
	private static function indexesLikeArray(annotation: Null<String>, typeSyntax: TypeSyntaxReader): Bool {
		if (annotation == null) return true;
		return switch typeSyntax(annotation)?.shape {
			case Nominal(ARRAY_HEAD, args): args.length > 0;
			case _: false;
		};
	}

	/**
	 * `[text]`, ascribed with the inner declaration's `annotation` unless the outer array's element type
	 * `outer` textually restates it — the rule the chain links follow, for the same reason: the annotation
	 * can be what types the elements.
	 */
	private static function innerElement(text: String, annotation: Null<String>, outer: Null<String>): String {
		final restated: Bool = annotation == null
			|| (outer != null && SourceText.withoutSpace(outer) == SourceText.withoutSpace(annotation));
		return restated ? '[$text]' : '([$text] : $annotation)';
	}

	/** Whether `node` is the integer literal `0`, read off its source text. */
	private static function isZeroLiteral(node: QueryNode, ctx: ComprehensionCtx): Bool {
		final span: Null<Span> = node.span;
		return span != null && ctx.source.substring(span.from, span.to).trim() == '0';
	}

	/** The value `v` of an expression statement `name[binder] = v`, or null when `stmt` is not exactly that. */
	private static function indexWriteValue(stmt: QueryNode, name: String, binder: String, s: ComprehensionSeams): Null<QueryNode> {
		final write: Null<KeyedWrite> = keyedWrite(stmt, name, s);
		final index: Null<QueryNode> = write?.key;
		return write != null && index != null && index.kind == s.identKind && index.name == binder ? write.value : null;
	}

	/** The source text of one kept statement — a local verbatim, a guard as its NEGATED condition — or null when it is neither. */
	private static function keptStatementText(
		stmt: QueryNode, name: String, ctx: ComprehensionCtx, checks: Array<QueryNode>
	): Null<String> {
		final s: ComprehensionSeams = ctx.seams;
		final stmtSpan: Null<Span> = stmt.span;
		if (stmtSpan == null || LexicalRegions.commentIntersects(stmtSpan.from, stmtSpan.to, ctx.regions)) return null;
		if (isGuard(stmt, s)) {
			final cond: QueryNode = BranchChain.condOf(stmt);
			checks.push(cond);
			return NegationScan.negateConditionText(cond, ctx.source, s.negation, s.support, null, null, ctx.regions);
		}
		if (!s.localDeclKinds.contains(stmt.kind) || s.mutableDeclKinds.contains(stmt.kind)) return null;
		if (s.continuationKinds.contains(stmt.kind) || stmt.children.length != 1 || stmt.name == name) return null;
		checks.push(stmt.children[0]);
		return ctx.source.substring(stmtSpan.from, stmtSpan.to);
	}

	/** Whether `stmt` is a bare else-less `if (c) continue;` — what a comprehension expresses by skipping the element. */
	private static function isGuard(stmt: QueryNode, s: ComprehensionSeams): Bool {
		final continueKind: Null<String> = s.continueKind;
		return continueKind != null && LoopScan.isIfContinue(stmt, s.ifKinds, s.blockStmtKind, continueKind);
	}

	/** The guard `if (negated) <rest>` over the statements that follow it: braced when more than one, bare when exactly one. */
	private static function guardStep(negated: String, rest: Array<KeptStep>): KeptStep {
		return rest.length == 1
			? { text: 'if ($negated) ${rest[0].text}', terminated: rest[0].terminated }
			: { text: 'if ($negated) { ${renderSteps(rest)} }', terminated: true };
	}

	private static function renderSteps(steps: Array<KeptStep>): String {
		return steps.map(st -> st.terminated ? st.text : '${st.text};').join(' ');
	}

	/** The key and value of an expression statement `name[k] = v` (plain `=` only), or null when `stmt` is not exactly that. */
	private static function keyedWrite(stmt: QueryNode, name: String, s: ComprehensionSeams): Null<KeyedWrite> {
		final assign: Null<QueryNode> = NodeShape.assignmentOf(stmt, s.exprStmtKind, s.assignKind);
		if (assign == null) return null;
		final target: QueryNode = assign.children[0];
		if (target.kind != s.indexAccessKind || !NodeShape.hasBinaryShape(target)) return null;
		final receiver: QueryNode = target.children[0];
		return receiver.kind == s.identKind && receiver.name == name ? { key: target.children[1], value: assign.children[1] } : null;
	}

	/** The key and value types of a two-argument `Map` `annotation`: the one declared type a keyed write `m[k] = v` folds into `k => v`. */
	private static function mapTypesOf(annotation: Null<String>, typeSyntax: TypeSyntaxReader): Null<MapTypes> {
		if (annotation == null) return null;
		final written: Null<Array<String>> = switch typeSyntax(annotation)?.shape {
			case Nominal(MAP_HEAD, args) if (args.length == MAP_ARITY): NominalTypes.typeArgumentSourcesOf(annotation, typeSyntax);
			case _: null;
		};
		return written == null || written.length != MAP_ARITY ? null : { key: written[0], value: written[1] };
	}

	/**
	 * A map comprehension is invariant against `Map<K, V>`: an operand folds only when the typing proves it exactly that type.
	 */
	private static function isExactly(node: QueryNode, expected: String, ctx: ComprehensionCtx): Bool {
		final known: Null<String> = ctx.typeOf(node);
		return known != null && SourceText.withoutSpace(known) == SourceText.withoutSpace(expected);
	}

}
