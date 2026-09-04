package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * WHERE a field is initialised — at its declaration or in the constructor — and the edits that
 * move it between the two. The shared machinery under `field-init-at-declaration`,
 * `field-init-in-constructor`, `prefer-final-field` and `prefer-read-only-field`, and by far
 * the largest single responsibility inside the old `RefactorSupport`.
 *
 * Three layers, outside in:
 *
 *  - **Finding the write.** `soleConstructor`, `soleConstructorFieldInit` and
 *    `soleConstructorFieldWrite` locate the ONE assignment to a field; `ctorWriteUnconditional`
 *    and `ctorPrefixUnconditional` prove that assignment is reached on every path, which is
 *    what makes a `final` promotion or a move to declaration position sound.
 *  - **Proving the value may move.** `contextFreeRhs`, `defaultIsMoveSafe`, `constantChain` and
 *    `ctorParamIsNullable` decide whether the expression means the same thing in the other
 *    position; `guardReachedIntact` and `superCallsFollow` decide whether the field is still in
 *    its declared state when the write happens.
 *  - **Producing the edits.** `ctorConditionalDefaultFinalEdits` (the null-guarded fold),
 *    `ctorConditionalDefaultTernaryEdits` (the general conditional fold), `finalizeFieldEdits`
 *    and `varKeywordToFinalEdits`.
 *
 * Most of the module is private: the layers above are the interface, and the ~35 predicates
 * under them exist only to make one of those verdicts.
 */
@:nullSafety(Strict)
final class CtorFieldFold {

	/**
	 * The `var` → `final` keyword-swap edits for each non-null span in `spans` (a field
	 * decl whose span starts at the `var` keyword). Shared by the `prefer-final-field`
	 * and `prefer-final-public-field` autofixes. Each edit fires only when the bytes at
	 * the span start are literally `var`, so an unexpected span is silently skipped.
	 */
	public static function varKeywordToFinalEdits(source: String, spans: Array<Null<Span>>): Array<{ span: Span, text: String }> {
		final keyword: String = 'var';
		final edits: Array<{ span: Span, text: String }> = [];
		for (span in spans) if (span != null) {
			final end: Int = span.from + keyword.length;
			if (source.substring(span.from, end) != keyword) continue;
			edits.push({ span: new Span(span.from, end), text: 'final' });
		}
		return edits;
	}

	/**
	 * What the head of a declaration whose initializer starts at `initSpan` says about its TYPE. The
	 * tree holds no type child for a local or a field, so it is read off the source: everything
	 * before the LAST `=`, then the first `:` at or after the last STANDALONE occurrence of the
	 * declared name — standalone so a leading `@:meta` cannot be mistaken for the annotation, and so
	 * a type whose own spelling ends in the name (`t:MyToolt`) cannot swallow it.
	 *
	 * The scan can FAIL, and `DeclaredType` keeps that case apart from a genuinely unannotated
	 * declaration, because a consumer may treat absence as a PROOF (see the enum's own doc). The two
	 * are told apart by asking the FIRST standalone occurrence as well: no `:` after either one means
	 * the head really writes no type, while a `:` after the first and none after the last means the
	 * annotation's own text repeats the declared name (`stack:pkg.stack`, `a:Stack<a>`) and the scan
	 * cannot say which occurrence is the binder. A missing `=`, a name that occurs nowhere standalone
	 * and an empty annotation text are `Unreadable` for the same reason.
	 *
	 * Shared by the checks that must know what a `[]` initializer was DECLARED as:
	 * `prefer-comprehension` transcribes the annotation onto the comprehension it emits (and reads
	 * `Unreadable` exactly as `Absent`, since neither gives it anything to copy — that is what
	 * `declaredTypeAnnotation` projects), while `join-array-pushes` asks whether it names an array
	 * type and must refuse an unreadable head.
	 */
	public static function declaredType(source: String, declSpan: Span, initSpan: Span, name: String): DeclaredType {
		final prefix: String = source.substring(declSpan.from, initSpan.from);
		final eq: Int = prefix.lastIndexOf('=');
		if (eq < 0) return Unreadable;
		final head: String = prefix.substring(0, eq);
		final at: Int = SourceText.lastStandaloneIdentIndex(head, name);
		if (at < 0) return Unreadable;
		final colon: Int = head.indexOf(':', at);
		if (colon >= 0) {
			final text: String = head.substring(colon + 1).trim();
			return text == '' ? Unreadable : Written(text);
		}
		final first: Int = SourceText.firstStandaloneIdentIndex(head, name);
		return first >= 0 && head.indexOf(':', first) < 0 ? Absent : Unreadable;
	}

	/**
	 * The annotation text `declaredType` read, or null when it read none — the `Null<String>`
	 * projection for a consumer that only TRANSCRIBES the annotation, for which an unreadable head
	 * and an absent one are the same answer: there is nothing to copy either way.
	 */
	public static function declaredTypeAnnotation(source: String, declSpan: Span, initSpan: Span, name: String): Null<String> {
		return switch declaredType(source, declSpan, initSpan, name) {
			case Written(text): text;
			case Absent, Unreadable: null;
		};
	}

	/**
	 * The two-edit fold of a NULL-GUARDED constructor default: a field declared WITH a
	 * default (`var x:T = D;`, plain or `(default, null)`) whose only write beyond that
	 * initializer is exactly one top-level constructor statement of the shape
	 * `if (p != null) x = p;` (`this.x = p` alike) becomes `final x:T;` plus
	 * `x = p ?? D;`. Returns the edits when the fold applies, `null` otherwise — the
	 * non-null result IS the fix, so a rule's `run` and `fix` can never disagree about a
	 * candidate, and the two edits are one unit that lands together or not at all.
	 *
	 * Fails closed on every doubt. All single-file gates live HERE, never in one
	 * consumer, so the rules claiming these candidates (`prefer-final-field`,
	 * `prefer-final-public-field`) and the one ceding them (`prefer-read-only-field`)
	 * cannot drift apart:
	 *
	 *  - the declaration carries an initializer, is not `static`, and its head is either
	 *    plain or exactly the `(default, null)` accessor pair — `final` reproduces that
	 *    access exactly (readable anywhere, writable nowhere outside the declaration),
	 *    while any other pair (`get, set`, `default, never`, …) it does not;
	 *  - the default expression is MOVE-SAFE (`moveSafeDefault`): a numeric / boolean /
	 *    non-interpolated string literal, a negated numeric literal, or a dotted access
	 *    rooted at a capitalised identifier (a type-qualified constant or enum value).
	 *    An allocation (`new T()`, `[]`), a call, `this`, and a bare identifier — which
	 *    could be another instance field, not yet initialized at constructor position —
	 *    are rejected: moving them would change allocation identity or evaluation order;
	 *  - the enclosing type has exactly one constructor, holding exactly one top-level
	 *    guarded statement of the shape above, whose parameter is optional, `Null<…>`
	 *    wrapped, or `= null`-defaulted (a non-nullable parameter cannot be
	 *    `??`-defaulted);
	 *  - no other write to the field name appears ANYWHERE in the file — the same
	 *    conservative raw-text scan `ctorSoleAssignmentFinalizable` uses, which sees
	 *    `#if` bodies — with the declaration and that one constructor target excluded.
	 *
	 * Cross-file soundness (an external, subtype, or unresolved write; an `@:access`
	 * grantee) stays the CONSUMER's job, exactly as for `ctorSoleAssignmentFinalizable`.
	 * Residual: a mutable static read by the default and written from ANOTHER file could
	 * still differ between declaration and constructor position; the in-file leg of that
	 * check lives in `moveSafeDefault`.
	 */
	public static function ctorConditionalDefaultFinalEdits(
		source: String, declSpan: Span, plugin: GrammarPlugin
	): Null<Array<{ span: Span, text: String }>> {
		final shape: RefShape = plugin.refShape();
		final coalesce: Null<String> = shape.nullCoalesceOperatorText;
		final base: Null<{
			container: QueryNode,
			field: QueryNode,
			decl: FoldableDecl,
			ctor: QueryNode
		}> = foldableCtorDefault(source, declSpan, plugin, shape);
		if (coalesce == null || base == null) return null;
		final edits: Array<{ span: Span, text: String }> = varKeywordToFinalEdits(source, [declSpan]);
		final decl: FoldableDecl = base.decl;
		final ctor: QueryNode = base.ctor;
		final guarded: Null<GuardedCtorInit> = soleGuardedCtorFieldInit(source, base.container, ctor, base.field, shape);
		if (guarded == null || !ctorParamIsNullable(source, ctor, guarded.param, shape)) return null;
		if (!guardReachedIntact(source, ctor, decl.name, guarded.stmt.from, shape)) return null;
		if (
			MemberWriteScan.writtenInRange(source, decl.name, guarded.target, 0, decl.span.from)
			|| MemberWriteScan.writtenInRange(source, decl.name, guarded.target, decl.span.to, source.length)
		)
			return null;
		final dropped: Null<Span> = decl.dropped;
		if (dropped != null) edits.push({ span: dropped, text: '' });
		edits.push({ span: decl.initDrop, text: '' });
		final targetText: String = source.substring(guarded.target.from, guarded.target.to);
		final defaultText: String = source.substring(decl.initSpan.from, decl.initSpan.to);
		edits.push({ span: guarded.stmt, text: '$targetText = ${guarded.param} $coalesce $defaultText${guarded.terminator}' });
		return edits;
	}

	/**
	 * The edits finalizing a set of flagged field declarations: the two-edit
	 * conditional-default fold (`ctorConditionalDefaultFinalEdits`) where it applies, a
	 * bare `var` -> `final` keyword swap everywhere else. The shared back end of
	 * `prefer-final-field` / `prefer-final-public-field`'s `fix`, so both rules emit the
	 * same shape for the same candidate, and each fold's edits travel as one unit through
	 * the caller's single per-file canonicalize (all of them apply, or the file reverts).
	 */
	public static function finalizeFieldEdits(
		source: String, spans: Array<Null<Span>>, plugin: GrammarPlugin
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		final plain: Array<Null<Span>> = [];
		for (span in spans) if (span != null) {
			final fold: Null<Array<{ span: Span, text: String }>> = ctorConditionalDefaultFinalEdits(source, span, plugin);
			if (fold == null)
				plain.push(span);
			else
				for (edit in fold) edits.push(edit);
		}
		for (edit in varKeywordToFinalEdits(source, plain)) edits.push(edit);
		return edits;
	}

	/**
	 * The two-or-three-edit fold of a CONDITIONALLY OVERWRITTEN constructor default — the
	 * general sibling of `ctorConditionalDefaultFinalEdits`, whose `??` shape it widens from
	 * "the guard tests the very parameter assigned" to "any condition, any value". A field
	 * declared `var x:T = D;` whose only write beyond that initializer is one assignment
	 * `x = E;` opening the then-branch of an `else`-less top-level constructor `if (C)`
	 * becomes `var x:T;` plus `x = C ? E : D;` in the `if`'s place. Returns the edits when the
	 * fold applies, `null` otherwise — the non-null result IS the fix, so a rule's `run` and
	 * `fix` can never disagree about a candidate.
	 *
	 * ONE UNCONDITIONAL ASSIGNMENT CARRYING A CONDITIONAL VALUE is the target form, and it is
	 * forced by a measurement rather than by taste: Haxe runs NO definite-assignment analysis
	 * for a `final` FIELD. `class V { final _d:Int; function new(c) if (c) _d = 1; }` compiles
	 * silently on `--interp`, `-js` and `--jvm`, and the field reads as `null` on the path that
	 * skipped the write; only `@:nullSafety(Strict)` diagnoses it. So a fold that emitted
	 * "assign in every branch" would have its completeness checked by nothing. The conditional
	 * VALUE proves completeness structurally — there is one assignment, and it always runs.
	 *
	 * The rewrite keeps `var`: making the now-single-write field `final` is `prefer-final-field`'s
	 * job, and it reaches this shape by itself once the fold has removed the second write.
	 *
	 * Fails closed on every doubt. All single-file gates live HERE rather than in the consumer,
	 * exactly as for the `??` sibling:
	 *
	 *  - the declaration is a plain non-static `var` (no accessor head — the `(default, null)`
	 *    pair the `??` fold accepts is out of scope here, since this fold does not finalize)
	 *    whose initializer is MOVE-SAFE (`foldableDeclaration` / `defaultIsMoveSafe`: a numeric /
	 *    boolean / non-interpolated string literal, a negated numeric literal, or a dotted
	 *    constant chain). An allocation, a call or a bare identifier would change allocation
	 *    identity or evaluation order when it moves down into the constructor;
	 *  - the enclosing type has exactly one constructor, and exactly ONE of its top-level
	 *    statements is an `else`-less `if` whose then-branch OPENS with `x = E;`
	 *    (`soleConditionalCtorFieldInit`). Opening the branch is what makes the hoist
	 *    order-preserving: the statements that stay behind in the branch all ran AFTER the
	 *    assignment and still do. An assignment deeper in the branch is refused and reaches the
	 *    same end state one `--fix` pass later, once the one ahead of it has moved out;
	 *  - the condition is SIDE-EFFECT-FREE (`isSideEffectFree`) whenever the `if` SURVIVES the
	 *    fold, since it is then evaluated twice. When the assignment is the branch's sole
	 *    statement the whole `if` is replaced and the condition still runs exactly once, so no
	 *    purity is demanded — the shape is a pure re-spelling;
	 *  - the constructor reaches the `if` with the field still in the state the declaration
	 *    default put it in (`guardReachedIntact`): no early exit before it, and the field name
	 *    unmentioned in the prefix;
	 *  - every explicit `super(...)` call starts AFTER the `if`. The prologue runs ahead of the
	 *    base constructor, so a default that moves below a `super(...)` is a default an
	 *    overridden method called from the base constructor no longer sees. With the call seams
	 *    unset the gate falls back to refusing every subclass;
	 *  - no `#if` region anywhere in the constructor or the declaration. A conditional-splice
	 *    region is a raw span with no branch nodes, so neither the statement geometry nor the
	 *    write count can be read across it;
	 *  - the value assigned does not itself read the field, and no comment sits in a byte range
	 *    the fold regenerates;
	 *  - no other write to the field name appears ANYWHERE in the file — the same conservative
	 *    raw-text scan (`MemberWriteScan.writtenInRange`, which sees `#if` bodies) the `??` fold
	 *    uses, with the declaration and that one constructor target excluded.
	 *
	 * Cross-file soundness (an external, subtype or unresolved write, an `@:access` grantee) stays
	 * the CONSUMER's job, as for `ctorSoleAssignmentFinalizable`.
	 *
	 * `extract`, when supplied, is offered the default the fold is about to move and may answer
	 * with the TEXT to write in the ternary's else arm instead of it - a reference to a constant it
	 * emits itself. It is asked LAST, after every gate has passed, so a caller may claim a name or
	 * stage a member insertion inside it without having to undo either. Answering null keeps the
	 * literal, which is what every caller that passes no seam at all gets.
	 */
	public static function ctorConditionalDefaultTernaryEdits(
		source: String, declSpan: Span, plugin: GrammarPlugin, ?extract: (CtorDefaultSite) -> Null<String>
	): Null<Array<{ span: Span, text: String }>> {
		final shape: RefShape = plugin.refShape();
		final base: Null<{
			container: QueryNode,
			field: QueryNode,
			decl: FoldableDecl,
			ctor: QueryNode
		}> = foldableCtorDefault(source, declSpan, plugin, shape);
		// An accessor head stays out of scope here: this fold does not finalize, so a `(default, null)`
		// pair the `??` sibling would rewrite has nothing to gain and would only lose its own spelling.
		if (base == null || base.decl.dropped != null) return null;
		final decl: FoldableDecl = base.decl;
		final ctor: QueryNode = base.ctor;
		if (holdsConditionalRegion(ctor) || holdsConditionalRegion(base.field)) return null;
		final init: Null<ConditionalCtorInit> = soleConditionalCtorFieldInit(source, base.container, ctor, base.field, shape);
		if (init == null) return null;
		final guardFrom: Int = init.ifStmt.from;
		if (!guardReachedIntact(source, ctor, decl.name, guardFrom, shape)) return null;
		if (!CtorFieldWrite.superCallsFollow(base.container, ctor, guardFrom, shape)) return null;
		if (
			MemberWriteScan.writtenInRange(source, decl.name, init.target, 0, decl.span.from)
			|| MemberWriteScan.writtenInRange(source, decl.name, init.target, decl.span.to, source.length)
		)
			return null;
		final targetText: String = source.substring(init.target.from, init.target.to);
		final condText: String = ternaryConditionText(source, init.condition, shape);
		final valueText: String = source.substring(init.value.from, init.value.to);
		final defaultText: String = source.substring(decl.initSpan.from, decl.initSpan.to);
		// Asked LAST, once every gate has passed: `extract` may have side effects (a name ledger, a
		// pending member insertion), and a caller must not pay them for a fold that then refuses.
		final elseText: String = (extract == null
			? null
			: extract({
				container: base.container,
				fieldName: decl.name,
				typeAnnotation: declaredTypeAnnotation(source, decl.span, decl.initSpan, decl.name),
				defaultNode: decl.initNode,
				defaultText: defaultText
			})) ?? defaultText;
		final folded: String = '$targetText = $condText ? $valueText : $elseText${init.terminator}';
		final edits: Array<{ span: Span, text: String }> = [{ span: decl.initDrop, text: '' }];
		if (init.sole)
			edits.push({ span: init.ifStmt, text: folded });
		else {
			edits.push({ span: new Span(guardFrom, guardFrom), text: '$folded\n' });
			edits.push({ span: ElementSpan.lineExtendedSpan(source, init.assignStmt), text: '' });
		}
		return edits;
	}

	/**
	 * The ONE top-level `if (<param> != null) <field> = <param>;` constructor statement
	 * writing `field`, or null when the constructor holds none, more than one, or one
	 * whose shape differs in any way. A statement that writes the field through some
	 * OTHER shape is not matched here — the caller's whole-file write scan rejects it.
	 */
	private static inline function soleGuardedCtorFieldInit(
		source: String, container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape
	): Null<GuardedCtorInit> {
		return soleMatchedCtorIf(source, container, ctor, field, shape, guardedFieldAssign);
	}

	/**
	 * The ONE top-level `else`-less `if` constructor statement whose then-branch OPENS with an
	 * assignment to `field`, or null when the constructor holds none, more than one, or one whose
	 * shape differs in any way. A write that sits DEEPER in a branch is not matched here — the
	 * caller's whole-file write scan then rejects the candidate, and the next `--fix` pass reaches
	 * it once the assignment ahead of it has moved out.
	 */
	private static inline function soleConditionalCtorFieldInit(
		source: String, container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape
	): Null<ConditionalCtorInit> {
		return soleMatchedCtorIf(source, container, ctor, field, shape, conditionalFieldAssign);
	}

	/**
	 * The declaration head just past the field NAME: `end` is where the type annotation
	 * (or the `=`) begins, and `dropped` the span of a `(default, null)` property head to
	 * delete — null for a plain `var`. Returns null when the head cannot be read, or
	 * carries any OTHER accessor pair, whose access `final` does not reproduce.
	 */
	private static function declHeadAfterName(source: String, declSpan: Span): Null<{ dropped: Null<Span>, end: Int }> {
		final limit: Int = declSpan.to;
		var i: Int = declSpan.from + 'var'.length;
		while (i < limit && SourceText.isSpace(source.fastCodeAt(i))) i++;
		final nameStart: Int = i;
		while (i < limit && SourceText.isIdentChar(source.fastCodeAt(i))) i++;
		if (i == nameStart) return null;
		final nameEnd: Int = i;
		while (i < limit && SourceText.isSpace(source.fastCodeAt(i))) i++;
		if (i >= limit || source.fastCodeAt(i) != '('.code) return { dropped: null, end: nameEnd };
		final close: Int = source.indexOf(')', i);
		if (close < 0 || close >= limit) return null;
		final accessors: Array<String> = [for (a in source.substring(i + 1, close).split(',')) StringTools.trim(a)];
		return accessors.length != 2 || accessors[0] != 'default' || accessors[1] != 'null' ? null : {
			dropped: new Span(nameEnd, close + 1),
			end: close + 1
		};
	}

	/**
	 * The declaration's initializer expression node, or null when the field has none.
	 * The LAST child is the initializer unless it is a type annotation
	 * (`typeAnnotationKinds`) — an anonymous structure type projects as a child of the
	 * declaration too.
	 */
	private static function declInitializer(field: QueryNode, shape: RefShape): Null<QueryNode> {
		final typeKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		if (field.children.length == 0) return null;
		final last: QueryNode = field.children[field.children.length - 1];
		return typeKinds.contains(last.kind) ? null : last;
	}

	/**
	 * The span to delete so the declaration keeps its type but loses ` = <default>`:
	 * from the whitespace before the `=` through the end of the default expression.
	 * Null when the bytes between head and default are not exactly whitespace + `=` (a
	 * comment there would be silently dropped), or when anything but the statement
	 * terminator follows the default.
	 */
	private static function initializerDropSpan(source: String, declSpan: Span, initSpan: Span, headEnd: Int): Null<Span> {
		final tail: String = source.substring(initSpan.to, declSpan.to).trim();
		if (tail != ';' && tail != '') return null;
		var i: Int = initSpan.from - 1;
		while (i >= headEnd && SourceText.isSpace(source.fastCodeAt(i))) i--;
		if (i < headEnd || source.fastCodeAt(i) != '='.code) return null;
		var start: Int = i - 1;
		while (start >= headEnd && SourceText.isSpace(source.fastCodeAt(start))) start--;
		return start < headEnd ? null : new Span(start + 1, initSpan.to);
	}

	/**
	 * Whether the declaration default `node` can be MOVED into constructor position
	 * unchanged. A positive whitelist, not a list of rejected shapes: a numeric or
	 * boolean literal, a plain string literal, a negated numeric literal, or a dotted
	 * constant chain (`constantChain`). Everything else — an allocation, a call, a bare
	 * identifier, `this` — fails by construction. A string qualifies only when it carries
	 * no interpolation at all: `containsInterpolation` catches the shorthand `$name` form,
	 * and the childless-fragments test catches the `${expr}` form, whose hole projects as
	 * a nested expression node rather than an interpolation kind.
	 */
	private static function defaultIsMoveSafe(source: String, node: QueryNode, shape: RefShape): Bool {
		final numeric: Array<String> = shape.numericLiteralKinds ?? [];
		if (numeric.contains(node.kind)) return true;
		if (node.kind == shape.boolLitKind) return true;
		return if ((shape.stringLiteralKinds ?? []).contains(node.kind))
			!containsInterpolation(node, shape) && node.children.foreach(c -> c.children.length == 0)
		else if (node.kind == shape.negationKind)
			node.children.length == 1 && numeric.contains(node.children[0].kind)
		else
			node.kind == shape.fieldAccessKind && constantChain(source, node, shape);
	}

	/** Whether `node`'s subtree carries a string-interpolation hole, which reads surrounding bindings. */
	private static function containsInterpolation(node: QueryNode, shape: RefShape): Bool {
		return node.kind == shape.stringInterpIdentKind || (shape.interpolationKinds ?? []).contains(node.kind)
			|| node.children.exists(child -> containsInterpolation(child, shape));
	}

	/**
	 * Whether `node` is a dotted access rooted at a CAPITALISED identifier — a
	 * type-qualified constant or enum value (`Defaults.MODE`, `Direction.LEFT`), the one
	 * non-literal default safe to evaluate later. A lower-case root could be an instance
	 * field, unset at constructor position. Every segment name must also be unwritten in
	 * the file, so the value cannot change between the declaration and the constructor.
	 */
	private static function constantChain(source: String, node: QueryNode, shape: RefShape): Bool {
		final segments: Array<String> = [];
		var current: QueryNode = node;
		while (current.kind == shape.fieldAccessKind) {
			final segment: Null<String> = current.name;
			if (segment == null || current.children.length != 1) return false;
			segments.push(segment);
			current = current.children[0];
		}
		final root: Null<String> = current.name;
		if (current.kind != shape.identKind || root == null || root.length == 0 || root == shape.selfReferenceText) return false;
		final head: String = root.charAt(0);
		if (head == head.toLowerCase()) return false;
		segments.push(root);
		return segments.foreach(segment -> !(MemberWriteScan.writtenInRange(source, segment, null, 0, source.length)));
	}

	/**
	 * `stmt` read as `if (<param> != null) <field> = <param>;` — the guard must be a bare
	 * `!= null` test of the very identifier assigned, the branch a single assignment
	 * statement (braced or not), and there must be no `else`. `terminator` carries the
	 * bytes the assignment ends with, so the rewritten statement keeps them verbatim.
	 */
	private static function guardedFieldAssign(
		source: String, stmt: QueryNode, fieldFrom: Int, fieldName: String, container: QueryNode, shape: RefShape
	): Null<GuardedCtorInit> {
		final stmtSpan: Null<Span> = stmt.span;
		final param: Null<String> = nullGuardParamName(stmt, shape);
		final branch: Null<QueryNode> = guardedSoleStatement(stmt, shape);
		if (stmtSpan == null || param == null || branch == null) return null;
		final branchSpan: Null<Span> = branch.span;
		if (branch.kind != shape.exprStatementKind || branch.children.length != 1 || branchSpan == null) return null;
		final assign: QueryNode = branch.children[0];
		final assignSpan: Null<Span> = assign.span;
		if (assign.kind != shape.assignKind || assign.children.length != 2 || assignSpan == null) return null;
		final target: QueryNode = assign.children[0];
		final targetSpan: Null<Span> = target.span;
		final value: QueryNode = assign.children[1];
		return if (targetSpan == null || value.kind != shape.identKind || value.name != param)
			null
		else if (!statementCommentFree(source, stmtSpan, targetSpan))
			null
		else if (!CtorFieldWrite.ctorTargetIsField(target, fieldFrom, fieldName, container, shape))
			null
		else
			{
				stmt: stmtSpan,
				target: targetSpan,
				param: param,
				terminator: source.substring(assignSpan.to, branchSpan.to)
			};
	}

	/**
	 * Whether the constructor parameter `paramName` is nullable — declared optional
	 * (`?p:T`), wrapped in a nullable type (`Null<T>`), or defaulted to `null`. A
	 * non-nullable parameter's `!= null` guard is vestigial and `p ?? d` would not fold
	 * the same way, so the rewrite refuses it.
	 */
	private static function ctorParamIsNullable(source: String, ctor: QueryNode, paramName: String, shape: RefShape): Bool {
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final wrappers: Array<String> = shape.nullableWrapperTypeNames ?? [];
		for (child in ctor.children) if (paramKinds.contains(child.kind) && child.name == paramName) {
			if (child.kind == shape.optionalParamKind) return true;
			if (child.children.exists(c -> c.kind == shape.nullLiteralKind)) return true;
			final span: Null<Span> = child.span;
			if (span == null) return false;
			final text: String = source.substring(span.from, span.to);
			final colon: Int = text.indexOf(':');
			if (colon < 0) return false;
			final declared: String = text.substring(colon + 1).trim();
			return wrappers.exists(wrapper -> declared == wrapper || declared.startsWith('$wrapper<'));
		}
		return false;
	}

	/**
	 * The declaration geometry `ctorConditionalDefaultFinalEdits` needs, or null when the
	 * declaration cannot host the fold: it must be a NON-STATIC field whose head is plain
	 * or exactly `(default, null)`, carrying a MOVE-SAFE initializer reachable by a bare
	 * ` = ` (a comment between head and default, or anything but a terminator after it,
	 * bails). `dropped` is the property head to delete, `initDrop` the ` = <default>`
	 * region, `initSpan` the default expression the constructor assignment inherits.
	 */
	private static function foldableDeclaration(
		source: String, loc: { container: QueryNode, field: QueryNode }, declSpan: Span, shape: RefShape
	): Null<FoldableDecl> {
		final field: QueryNode = loc.field;
		final name: Null<String> = field.name;
		final fieldSpan: Null<Span> = field.span;
		if (name == null || fieldSpan == null) return null;
		if (fieldSpan.from != declSpan.from) return null;
		if (MemberKinds.staticMemberFroms(loc.container, shape).contains(fieldSpan.from)) return null;
		final head: Null<{ dropped: Null<Span>, end: Int }> = declHeadAfterName(source, fieldSpan);
		final init: Null<QueryNode> = declInitializer(field, shape);
		final initSpan: Null<Span> = init?.span;
		if (head == null || init == null || initSpan == null) return null;
		if (initSpan.from < head.end || !defaultIsMoveSafe(source, init, shape)) return null;
		final initDrop: Null<Span> = initializerDropSpan(source, fieldSpan, initSpan, head.end);
		return initDrop == null ? null : {
			name: name,
			span: fieldSpan,
			dropped: head.dropped,
			initSpan: initSpan,
			initNode: init,
			initDrop: initDrop
		};
	}

	/**
	 * Whether the constructor reaches the guarded statement with the field still in the
	 * state the declaration default put it in. A declaration initializer runs at
	 * constructor ENTRY on EVERY path, so moving it down to the guard's position is
	 * behaviour-preserving only when nothing before the guard can leave the constructor
	 * (the field would then never be assigned at all — Haxe's definite-assignment check
	 * for a `final` field is not flow-sensitive, so that compiles) and nothing before the
	 * guard mentions the field (a read there sees the default today and an unset field
	 * after the fold). Both scans are deliberately coarse: a `return` inside a lambda, or
	 * the field name in a comment or an unrelated local, refuses the candidate.
	 *
	 * Residual: a read reached through a helper CALLED from the constructor before the
	 * guard is invisible here, the same blind spot `field-init-at-declaration` carries for
	 * the inverse move.
	 */
	private static function guardReachedIntact(source: String, ctor: QueryNode, name: String, guardFrom: Int, shape: RefShape): Bool {
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == shape.blockBodyKind);
		final bodySpan: Null<Span> = body?.span;
		final exitKinds: Array<String> = shape.controlExitKinds ?? [];
		// An unset exit-kind set would turn the scan below into a no-op and silently accept
		// every early return, so its completeness is load-bearing here — refuse without it.
		return body != null && bodySpan != null && exitKinds.length != 0
			&& !OccurrenceScan.referencedInRange(source, name, bodySpan.from, guardFrom, [])
			&& !CtorFieldWrite.kindStartsBefore(body, exitKinds, guardFrom);
	}

	/**
	 * Whether the guarded statement carries no comment the rewrite would drop. Only the
	 * assignment TARGET is copied verbatim; every other byte of the statement — the guard,
	 * the braces, the operator, the assigned value — is regenerated, so a comment outside
	 * the target's span disappears silently. Checking around the target rather than around
	 * the whole assignment is what makes this the same fail-closed rule the declaration
	 * side applies in `initializerDropSpan`. No false positive is possible: by the time
	 * this runs the condition is proven to be exactly `<ident> != null` and the tail is the
	 * statement terminator, so no string literal can occupy either region.
	 */
	private static function statementCommentFree(source: String, stmt: Span, target: Span): Bool {
		return !SourceComments.hasCommentMarker(source, stmt.from, target.from)
			&& !SourceComments.hasCommentMarker(source, target.to, stmt.to);
	}

	/**
	 * The parameter name of a bare `<name> != null` guard on `stmt`, or null when the
	 * condition has any other shape or an `else` branch follows (a second assignment path
	 * the `??` rewrite cannot express).
	 */
	private static function nullGuardParamName(stmt: QueryNode, shape: RefShape): Null<String> {
		if (stmt.children.length != 2) return null;
		final cond: QueryNode = stmt.children[0];
		if (cond.kind != shape.notEqKind || cond.children.length != 2 || cond.children[1].kind != shape.nullLiteralKind) return null;
		final guard: QueryNode = cond.children[0];
		return guard.kind == shape.identKind ? guard.name : null;
	}

	/**
	 * `stmt`'s then-branch reduced to its SOLE statement, unwrapping one brace level, or
	 * null when the branch holds anything but exactly one statement.
	 */
	private static function guardedSoleStatement(stmt: QueryNode, shape: RefShape): Null<QueryNode> {
		if (stmt.children.length != 2) return null;
		final branch: QueryNode = stmt.children[1];
		return if (branch.kind != shape.blockStmtKind)
			branch
		else if (branch.children.length == 1)
			branch.children[0]
		else
			null;
	}

	/**
	 * `stmt` read as `if (C) x = E;` / `if (C) { x = E; … }` — no `else` (a second assignment path
	 * the ternary cannot express), the then-branch OPENING with a plain `=` assignment statement
	 * whose target is the field.
	 *
	 * The condition must be side-effect-free only when the `if` SURVIVES the fold: with the
	 * assignment as the branch's sole statement the whole statement is replaced and the condition
	 * still runs exactly once, while a surviving `if` evaluates it a second time. The value may not
	 * read the field it initialises (after the fold that is a self-reference against an unset field),
	 * and no comment may sit in a byte range the fold regenerates — the gaps around the three spans
	 * copied verbatim, up to the end of the replaced region.
	 */
	private static function conditionalFieldAssign(
		source: String, stmt: QueryNode, fieldFrom: Int, fieldName: String, container: QueryNode, shape: RefShape
	): Null<ConditionalCtorInit> {
		final stmtSpan: Null<Span> = stmt.span;
		if (stmt.children.length != 2 || stmtSpan == null) return null;
		final cond: QueryNode = stmt.children[0];
		final condSpan: Null<Span> = cond.span;
		final branch: QueryNode = stmt.children[1];
		final braced: Bool = branch.kind == shape.blockStmtKind;
		final sole: Bool = !braced || branch.children.length == 1;
		final first: Null<QueryNode> = branchOpeningStatement(branch, braced);
		if (condSpan == null || first == null || (!sole && !MemberKinds.isSideEffectFree(cond))) return null;
		final firstSpan: Null<Span> = first.span;
		if (first.kind != shape.exprStatementKind || first.children.length != 1 || firstSpan == null) return null;
		final assign: QueryNode = first.children[0];
		final assignSpan: Null<Span> = assign.span;
		if (assign.kind != shape.assignKind || assign.children.length != 2 || assignSpan == null) return null;
		final target: QueryNode = assign.children[0];
		final targetSpan: Null<Span> = target.span;
		final valueSpan: Null<Span> = assign.children[1].span;
		return if (targetSpan == null || valueSpan == null)
			null
		else if (!CtorFieldWrite.ctorTargetIsField(target, fieldFrom, fieldName, container, shape))
			null
		else if (OccurrenceScan.referencedInRange(source, fieldName, valueSpan.from, valueSpan.to, []))
			null
		else if (!foldRegionCommentFree(source, stmtSpan, condSpan, targetSpan, valueSpan, sole ? stmtSpan.to : firstSpan.to))
			null
		else
			{
				ifStmt: stmtSpan,
				assignStmt: firstSpan,
				target: targetSpan,
				condition: cond,
				value: valueSpan,
				sole: sole,
				terminator: source.substring(assignSpan.to, firstSpan.to)
			};
	}

	/** Whether `node`'s subtree holds a `#if…#end` region of any projection (`isConditionalKind`). */
	private static function holdsConditionalRegion(node: QueryNode): Bool {
		return CondRegionScan.isConditionalKind(node.kind) || node.children.exists(child -> holdsConditionalRegion(child));
	}

	/** Parenthesise a folded ternary's condition iff it binds no tighter than `?:` (a ternary or an assignment). */
	private static function ternaryConditionText(source: String, cond: QueryNode, shape: RefShape): String {
		final span: Null<Span> = cond.span;
		final text: String = span == null ? '' : source.substring(span.from, span.to);
		final ternaryKind: Null<String> = shape.ternaryKind;
		final needsParens: Bool = (ternaryKind != null && cond.kind == ternaryKind) || shape.writeParentKinds.contains(cond.kind);
		return needsParens ? '($text)' : text;
	}

	/** `branch` reduced to the statement it OPENS with, unwrapping one brace level, or null when it holds none. */
	private static function branchOpeningStatement(branch: QueryNode, braced: Bool): Null<QueryNode> {
		final statements: Array<QueryNode> = braced ? branch.children : [branch];
		return statements.length >= 1 ? statements[0] : null;
	}

	/**
	 * Whether the byte ranges a conditional-default fold REGENERATES carry no comment — the gaps
	 * around the three spans it copies verbatim (the condition, the assignment target, the assigned
	 * value), up to `rebuiltEnd`: the whole `if` statement when the fold replaces it, the assignment
	 * statement alone when the `if` survives and only that statement is cut out of its branch.
	 */
	private static function foldRegionCommentFree(
		source: String, stmt: Span, cond: Span, target: Span, value: Span, rebuiltEnd: Int
	): Bool {
		return !SourceComments.hasCommentMarker(source, stmt.from, cond.from)
			&& !SourceComments.hasCommentMarker(source, cond.to, target.from)
			&& !SourceComments.hasCommentMarker(source, target.to, value.from)
			&& !SourceComments.hasCommentMarker(source, value.to, rebuiltEnd);
	}

	/**
	 * The declaration-and-constructor geometry BOTH conditional-default folds
	 * (`ctorConditionalDefaultFinalEdits`, `ctorConditionalDefaultTernaryEdits`) open with, so the
	 * shape they agree on is stated once: the field's container and node, its `FoldableDecl` (a
	 * non-static `var` whose head is plain or exactly `(default, null)` and whose initializer is
	 * MOVE-SAFE), and the enclosing type's sole constructor.
	 *
	 * Null when the declaration carries no `=`, is not a plain `var` (`varKeywordToFinalEdits`
	 * yielding one edit is the keyword test — the caller that needs that edit recomputes it), does
	 * not parse, or when any of the four cannot be resolved.
	 */
	private static function foldableCtorDefault(source: String, declSpan: Span, plugin: GrammarPlugin, shape: RefShape): Null<{
		container: QueryNode,
		field: QueryNode,
		decl: FoldableDecl,
		ctor: QueryNode
	}> {
		if (source.substring(declSpan.from, declSpan.to).indexOf('=') < 0) return null;
		if (varKeywordToFinalEdits(source, [declSpan]).length != 1) return null;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return null;
		final loc: Null<{ container: QueryNode, field: QueryNode }> = CtorFieldWrite.classLikeFieldAt(tree, declSpan.from, shape);
		if (loc == null) return null;
		final decl: Null<FoldableDecl> = foldableDeclaration(source, loc, declSpan, shape);
		final ctor: Null<QueryNode> = CtorFieldWrite.soleConstructor(loc.container, shape);
		return decl == null || ctor == null ? null : {
			container: loc.container,
			field: loc.field,
			decl: decl,
			ctor: ctor
		};
	}

	/**
	 * The ONE top-level `if` statement of `ctor` that `matcher` accepts for `field`, or null when the
	 * constructor holds none, or more than one. The scan both conditional-default folds run: they
	 * differ only in WHICH `if` shape they recognise, and that difference is the `matcher` argument.
	 */
	private static function soleMatchedCtorIf<T>(
		source: String, container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape,
		matcher: (String, QueryNode, Int, String, QueryNode, RefShape) -> Null<T>
	): Null<T> {
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final fieldSpan: Null<Span> = field.span;
		final fieldName: Null<String> = field.name;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == shape.blockBodyKind);
		if (fieldSpan == null || fieldName == null || body == null) return null;
		var match: Null<T> = null;
		for (stmt in body.children) if (ifKinds.contains(stmt.kind)) {
			final found: Null<T> = matcher(source, stmt, fieldSpan.from, fieldName, container, shape);
			if (found == null) continue;
			if (match != null) return null;
			match = found;
		}
		return match;
	}

}

/**
 * The declaration side of a null-guarded constructor-default fold: the field name and
 * its declaration span, the `(default, null)` property head to drop (null for a plain
 * `var`), the default expression, and the ` = <default>` region the fold deletes.
 */
private typedef FoldableDecl = {
	final name: String;
	final span: Span;
	final dropped: Null<Span>;
	final initSpan: Span;

	/** The default expression node itself — what a caller extracting the default must classify. */
	final initNode: QueryNode;
	final initDrop: Span;
};

/**
 * The constructor side of a null-guarded constructor-default fold: the whole
 * `if (p != null) x = p;` statement to replace, the assignment target and the guarded
 * parameter to rebuild it from, and the bytes the assignment ended with.
 */
private typedef GuardedCtorInit = {
	final stmt: Span;
	final target: Span;
	final param: String;
	final terminator: String;
};

/**
 * The constructor side of a CONDITIONAL field-default fold: the whole `if (C) { x = E; … }`
 * statement, the assignment STATEMENT opening its branch, the assignment target, the
 * condition node, the assigned value, whether that assignment is the branch's SOLE statement
 * (so the whole `if` is replaced rather than survived), and the bytes the assignment ended
 * with.
 */
private typedef ConditionalCtorInit = {
	final ifStmt: Span;
	final assignStmt: Span;
	final target: Span;
	final condition: QueryNode;
	final value: Span;
	final sole: Bool;
	final terminator: String;
};

/**
 * The DEFAULT a conditional-default fold is about to move into constructor position, handed to a
 * caller that wants to name it instead of moving it verbatim
 * (`ctorConditionalDefaultTernaryEdits`'s `extract` seam).
 *
 * Handed over rather than re-derived by the caller because the two must not disagree: the text a
 * caller names is the text this fold DELETES from the declaration, and a second read of the
 * declaration - through a different scan, against a source one edit older - is the way that
 * invariant breaks silently.
 */
typedef CtorDefaultSite = {
	/** The class-like container declaring the field — the receiving type of any emitted member. */
	final container: QueryNode;

	final fieldName: String;

	/** The field's written type annotation, or null when the head states none (`declaredTypeAnnotation`). */
	final typeAnnotation: Null<String>;

	/** The default expression node — what tells a caller whether it is a bare literal. */
	final defaultNode: QueryNode;

	/** The default's verbatim source text, exactly as the fold would splice it. */
	final defaultText: String;
};

/**
 * What a declaration's HEAD says about its type, as `RefactorSupport.declaredType` reads it off the
 * source text (the tree carries no type child for a local or a field).
 *
 * Three cases, not two, because the reader can FAIL. `Absent` is a positive statement — the head
 * holds no annotation, so the initializer's own type is the declared one — and a consumer may act
 * on it; `Unreadable` says only that the scan could not attribute an annotation, and a consumer
 * that would treat absence as a PROOF must refuse there instead. The distinction is load-bearing:
 * `final stack:pkg.stack = []` puts a standalone occurrence of the declared name in the TYPE's own
 * tail, so the naive "no `:` after the name" test reads the annotation as absent and would hand a
 * caller a proof it never had. A consumer that only TRANSCRIBES an annotation (there is nothing to
 * copy either way) may collapse the two.
 */
enum DeclaredType {

	/** The head writes no type annotation — the initializer types the binding. */
	Absent;

	/** The head writes `: <text>`; `text` is the annotation's verbatim source, trimmed. */
	Written(text: String);

	/** The head carries a type the scan could not attribute to the declared name — nothing is proven. */
	Unreadable;

}
