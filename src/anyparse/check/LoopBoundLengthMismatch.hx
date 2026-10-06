package anyparse.check;

import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.LoopScan.LoopSeams;
import anyparse.query.CtorFieldWrite;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.MemberWriteScan;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags an indexed loop `for (i in 0...Y)` that READS `xs[i]` while the length of `xs` is PROVEN to
 * come from a different expression `X` — the loop bound is unrelated to the array it indexes. The
 * shape that motivated it: a field filled `numPoints` times in the constructor and read by loops
 * that run to `Grid.GRID_NUM_HORIZONTAL + 1`, which agree only while the constructor's default
 * argument does. `Warning`, report-only (`NoAutofix`): which of the two bounds is right is a bug
 * fix, and a human decides it.
 *
 * ## The length source — a positive proof, silent without one
 *
 * An array's length is KNOWN in three shapes, and in no other:
 *
 * - **Filled by one loop.** It starts empty (`[]` or `new Array()`, at the declaration or — for a
 *   field with no initializer — by one top-level constructor assignment ahead of the loop), and its
 *   only append is ONE statement directly in the body of a top-level `for (_ in 0...X)` whose body
 *   holds no jump, return or throw. A field is filled in its type's sole constructor and must be an
 *   instance field; a local in a later statement of its own block. Arrays appended in the same loop
 *   are PARALLEL: they share `X`, and one's `length` bounds the other.
 * - **A literal of `k` elements** — no comprehension, no conditional region among them.
 * - **A fixed-length construction** `new T(n)` of a type `ExecutionShape.fixedLengthArrayTypes`
 *   names, by its path or by a simple name the file imports by exactly that path.
 *
 * Then every occurrence of the name in its scope (the whole type for a field, the enclosing function
 * for a local) must sit in a position that keeps that length: an index READ, a `length` read, the
 * subject of a `for`-in, a call of a method `nonMutatingArrayMethods` lists, the one append, the one
 * initializing assignment. An index WRITE is admitted for a fixed-length type only — on an array it
 * extends. Anything else (an argument, an alias, a return, another receiver's `o.xs`, an
 * interpolation, a binder that shadows the name) refuses the array outright. A field must be
 * non-public, a non-property, and confined to its file (`RefactorSupport.isPrivateMemberConfined`:
 * no subtype, access grant or skip-parsed file); a declared type must be the type the source builds.
 *
 * ## The comparison
 *
 * A bound that mentions the array or a parallel one (`xs.length - 1`) is related by construction and
 * never reported, and neither is a loop nested in the fill loop. Otherwise both bounds are folded to
 * integers where they are integer literals and `static final` constants of a type in the run, under
 * `ExecutionShape.integerFoldOperators` (`4 + 1` equals `5`); two folded values compare by value, and
 * anything else by its text with whitespace and outer parentheses dropped. The finding names both
 * sources and the line the length comes from.
 */
@:nullSafety(Strict)
final class LoopBoundLengthMismatch implements Check implements NoAutofix implements VolatileMessage {

	/** This check's stable id, spelled once. */
	private static inline final RULE_ID: String = 'loop-bound-length-mismatch';

	/** The lead-in of the line the length comes from — the coordinate `messageIdentity` masks. */
	private static inline final LINE_LEAD: String = '(line ';

	/** A single-binder `for` / comprehension has exactly [iterable, body] children. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An interval and every binary node have exactly [left, right] children. */
	private static inline final BINARY_CHILD_COUNT: Int = 2;

	/** How deep a constant may refer to another constant before folding gives up — a cycle stops here. */
	private static inline final MAX_FOLD_DEPTH: Int = 16;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an indexed loop reading xs[i] whose bound is not the expression the length of xs provably comes from';
	}

	public function noAutofixReason(): String {
		return 'which bound is right, the array\'s or the loop\'s, is a bug fix a human decides';
	}

	public function messageIdentity(message: String): String {
		return MessageMask.maskAfter(message, LINE_LEAD);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final resolved: Null<Seams> = seamsOf(plugin.refShape());
		if (resolved == null) return [];
		// Re-bound to a non-null local: a narrowing does not reach into an anonymous struct literal.
		final seams: Seams = resolved;
		final parsed: Array<{ file: String, source: String, tree: QueryNode }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) parsed.push({ file: entry.file, source: entry.source, tree: tree });
		}
		final constants: Map<String, Constant> = collectConstants(parsed, seams);
		final lazyIndex: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final out: Array<Violation> = [];
		for (p in parsed) walk(p.tree, null, null, {
			file: p.file,
			source: p.source,
			tree: p.tree,
			seams: seams,
			constants: constants,
			types: typed?.declaredTypeSources(p.source),
			typeSyntax: plugin.typeSyntax,
			lazyIndex: lazyIndex,
			plugin: plugin,
			out: out
		});
		return out;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Descend `node`, scanning each class-like type for field sources and each statement list for
	 * local ones. `owner` is the nearest enclosing type's name and `fn` the nearest enclosing
	 * function, the scope a local's occurrences are checked over.
	 */
	private static function walk(node: QueryNode, owner: Null<String>, fn: Null<QueryNode>, ctx: FileCtx): Void {
		final s: Seams = ctx.seams;
		if (s.core.opaqueKinds.contains(node.kind)) return;
		final name: Null<String> = node.name;
		final here: Null<String> = s.containers.contains(node.kind) && name != null ? name : owner;
		if (here != null && here != owner) scanFields(node, here, ctx);
		final scope: Null<QueryNode> = s.scopeKinds.contains(node.kind) ? node : fn;
		if (scope != null && s.statementListKinds.contains(node.kind)) scanLocals(node, scope, here ?? '', ctx);
		for (c in node.children) walk(c, here, scope, ctx);
	}

	/** Every field of `container` whose length is known, each checked against the loops of the whole type. */
	private static function scanFields(container: QueryNode, owner: String, ctx: FileCtx): Void {
		final ctor: Null<QueryNode> = CtorFieldWrite.soleConstructor(container, ctx.seams.core.shape);
		final ctorBody: Array<QueryNode> = ctor == null ? [] : statementsOf(ctor, ctx.seams);
		final found: Array<LengthSource> = [];
		for (field in container.children) {
			final source: Null<LengthSource> = fieldSource(field, container, ctorBody, ctx);
			if (source != null) found.push(source);
		}
		final index: Null<SymbolIndex> = found.length == 0 ? null : ctx.lazyIndex();
		if (index == null) return;
		final confined: SymbolIndex = index;
		final kept: Array<LengthSource> = [
			for (src in found) if (
				MemberWriteScan.referencesConfined(owner, src.name, ctx.source, confined, ctx.plugin)
				&& keepsLength(container, src, owner, true, ctx)
			)
				src
		];
		for (src in kept) checkLoops(container, src, kept, owner, true, ctx);
	}

	/**
	 * The length source of `field`, a non-public non-property field of `container` whose declared type
	 * fits it: its literal or fixed-length initializer, or — for an instance field — the loop of the
	 * constructor's top-level statements `ctorBody` that fills it. Null otherwise.
	 */
	private static function fieldSource(
		field: QueryNode, container: QueryNode, ctorBody: Array<QueryNode>, ctx: FileCtx
	): Null<LengthSource> {
		final s: Seams = ctx.seams;
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (!s.fieldKinds.contains(field.kind) || name == null || span == null) return null;
		final mods: Array<QueryNode> = MemberKinds.precedingModifiers(field, container, s.modifierKinds);
		if (mods.exists(m -> s.visibility.contains(m.kind) && textOf(m, ctx.source) != s.defaultVis)) return null;
		if (AccessorClauseText.accessorClause(ctx.source, span) != null) return null;
		final init: Null<QueryNode> = field.children.length == 1 ? field.children[0] : null;
		final source: Null<LengthSource> = if (init != null && !isEmptyArray(init, s))
			fixedSource(name, field, init, ctx);
		else if (mods.exists(m -> m.kind == s.staticKind))
			null;
		else
			fillSource(name, field, init, ctorBody, ctx);
		return source != null && declaredTypeFits(span, source, ctx) ? source : null;
	}

	/** Every local declared directly in `block` whose length is known, checked against the loops of its function `scope`. */
	private static function scanLocals(block: QueryNode, scope: QueryNode, owner: String, ctx: FileCtx): Void {
		final s: Seams = ctx.seams;
		final stmts: Array<QueryNode> = block.children;
		final kept: Array<LengthSource> = [];
		for (d in 0...stmts.length) {
			final decl: QueryNode = stmts[d];
			final name: Null<String> = LoopScan.singleLocalDeclName(decl, s.core.localDeclKinds, s.core);
			final span: Null<Span> = decl.span;
			if (name == null || span == null) continue;
			final init: QueryNode = decl.children[0];
			final source: Null<LengthSource> = isEmptyArray(init, s)
				? fillSource(name, decl, init, stmts.slice(d + 1), ctx)
				: fixedSource(name, decl, init, ctx);
			if (source != null && declaredTypeFits(span, source, ctx) && keepsLength(scope, source, owner, false, ctx)) kept.push(source);
		}
		for (src in kept) checkLoops(scope, src, kept, owner, false, ctx);
	}

	/**
	 * The length source of an array filled by one loop among `stmts` — the constructor's top-level
	 * statements for a field, the statements after a local's declaration for a local — or null. A
	 * field with no initializer (`init` null) must be initialized empty by one of those statements
	 * ahead of the loop.
	 */
	private static function fillSource(
		name: String, decl: QueryNode, init: Null<QueryNode>, stmts: Array<QueryNode>, ctx: FileCtx
	): Null<LengthSource> {
		final declSpan: Null<Span> = decl.span;
		if (declSpan == null) return null;
		var initAssign: Null<QueryNode> = null;
		for (stmt in stmts) {
			if (init == null && initAssign == null) initAssign = emptyAssignOf(stmt, name, ctx);
			final loop: Null<{ bound: QueryNode, push: QueryNode }> = fillLoopOf(stmt, name, ctx);
			final loopSpan: Null<Span> = stmt.span;
			if (loop == null || loopSpan == null) continue;
			return init == null && initAssign == null ? null : {
				name: name,
				declFrom: declSpan.from,
				bound: loop.bound,
				line: loopSpan.lineCol(ctx.source).line,
				literalCount: -1,
				fillLoop: stmt,
				push: loop.push,
				initAssign: initAssign,
				fixedLength: false
			};
		}
		return null;
	}

	/** The length source of a `k`-element literal or a fixed-length construction initializing `decl`, or null. */
	private static function fixedSource(name: String, decl: QueryNode, init: QueryNode, ctx: FileCtx): Null<LengthSource> {
		final s: Seams = ctx.seams;
		final span: Null<Span> = decl.span;
		if (span == null) return null;
		final line: Int = span.lineCol(ctx.source).line;
		if (init.kind == s.arrayLiteralKind) {
			return init.children.length == 0 || init.children.exists(c -> s.unsizedElementKinds.contains(c.kind)) ? null : {
				name: name,
				declFrom: span.from,
				bound: init,
				line: line,
				literalCount: init.children.length,
				fillLoop: null,
				push: null,
				initAssign: null,
				fixedLength: false
			};
		}
		if (init.kind != s.newExprKind || !isFixedLengthType(init.name, ctx)) return null;
		final args: Array<QueryNode> = [for (c in init.children) if (!s.typeArgKinds.contains(c.kind)) c];
		return args.length != 1 ? null : {
			name: name,
			declFrom: span.from,
			bound: args[0],
			line: line,
			literalCount: -1,
			fillLoop: null,
			push: null,
			initAssign: null,
			fixedLength: true
		};
	}

	/**
	 * Whether the constructed type `typeName` is a fixed-length array type: its path, or a simple name
	 * the file imports by exactly that path.
	 */
	private static function isFixedLengthType(typeName: Null<String>, ctx: FileCtx): Bool {
		if (typeName == null) return false;
		for (path in ctx.seams.fixedTypes) {
			if (typeName == path) return true;
			if (typeName == simpleName(path) && ctx.tree.children.exists(c -> ctx.seams.modulePathKinds.contains(c.kind) && c.name == path))
				return true;
		}
		return false;
	}

	/**
	 * The bound and the append call of `stmt` when it is a fill loop of `name`: a single-binder `for`
	 * over `0...X` whose body appends to `name` in exactly one direct statement and holds no jump,
	 * return or throw. Null otherwise.
	 */
	private static function fillLoopOf(stmt: QueryNode, name: String, ctx: FileCtx): Null<{ bound: QueryNode, push: QueryNode }> {
		final s: Seams = ctx.seams;
		final bound: Null<QueryNode> = zeroBasedBound(stmt, s.core.forStmtKind, ctx);
		if (bound == null) return null;
		final body: QueryNode = stmt.children[1];
		if (containsAnyKind(body, s.exitKinds)) return null;
		final direct: Array<QueryNode> = body.kind == s.core.blockStmtKind ? body.children : [body];
		final pushes: Array<QueryNode> = [];
		for (st in direct) {
			final call: Null<QueryNode> = appendCallOf(st, name, ctx);
			if (call != null) pushes.push(call);
		}
		return pushes.length == 1 ? { bound: bound, push: pushes[0] } : null;
	}

	/** The upper bound of `loop` when it is a single-binder loop of `kind` over `0...Y`, else null. */
	private static function zeroBasedBound(loop: QueryNode, kind: String, ctx: FileCtx): Null<QueryNode> {
		if (loop.kind != kind || loop.name == null || loop.children.length != FOR_CHILD_COUNT) return null;
		final range: QueryNode = loop.children[0];
		return range.kind != ctx.seams.intervalKind || range.children.length != BINARY_CHILD_COUNT
			|| !LoopScan.isZeroLiteral(range.children[0], ctx.source, ctx.seams.core)
			? null
			: range.children[1];
	}

	/** The call of `stmt` when it is exactly one append statement `name.push(v);` (or through `this.`), else null. */
	private static function appendCallOf(stmt: QueryNode, name: String, ctx: FileCtx): Null<QueryNode> {
		final s: Seams = ctx.seams;
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final call: QueryNode = stmt.children[0];
		if (call.kind != s.core.callKind || call.children.length != BINARY_CHILD_COUNT) return null;
		final callee: QueryNode = call.children[0];
		return callee.kind == s.core.fieldAccessKind && callee.name == s.appendMethod && callee.children.length == 1
			&& isPlainRef(callee.children[0], name, s)
			? call
			: null;
	}

	/** The assignment of `stmt` when it is exactly `name = []` / `name = new Array()` (or through `this.`), else null. */
	private static function emptyAssignOf(stmt: QueryNode, name: String, ctx: FileCtx): Null<QueryNode> {
		final s: Seams = ctx.seams;
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		return assign.kind == s.assignKind && assign.children.length == BINARY_CHILD_COUNT && isEmptyArray(assign.children[1], s)
			&& isPlainRef(assign.children[0], name, s)
			? assign
			: null;
	}

	/** Whether `node` is the bare `name` or `this.name`. */
	private static function isPlainRef(node: QueryNode, name: String, s: Seams): Bool {
		return node.kind == s.core.identKind && node.name == name || node.kind == s.core.fieldAccessKind && node.name == name
			&& node.children.length == 1 && node.children[0].kind == s.core.identKind && s.selfText != null
			&& node.children[0].name == s.selfText;
	}

	/** Whether `node` builds an EMPTY array of the built-in type: `[]` or `new Array()` with no argument. */
	private static function isEmptyArray(node: QueryNode, s: Seams): Bool {
		return node.kind == s.arrayLiteralKind && node.children.length == 0 || node.kind == s.newExprKind
			&& s.arrayTypes.contains(node.name ?? '') && !node.children.exists(c -> !s.typeArgKinds.contains(c.kind));
	}

	/** Whether the type declared at `declSpan`, when there is one, is the type `source` builds. */
	private static function declaredTypeFits(declSpan: Span, source: LengthSource, ctx: FileCtx): Bool {
		final typeSource: Null<String> = ctx.types == null ? null : ctx.types[declSpan.from];
		if (typeSource == null) return true;
		final outer: Null<String> = NominalTypes.outerNominalOf(typeSource, ctx.typeSyntax);
		if (outer == null) return false;
		final nominal: String = outer;
		return source.fixedLength
			? ctx.seams.fixedTypes.exists(p -> p == nominal || simpleName(p) == nominal)
			: ctx.seams.arrayTypes.contains(nominal);
	}

	/**
	 * Whether every occurrence of `src.name` in `scope` keeps the length its source gives it, and no
	 * other binder in `scope` takes the name. For a field the occurrences include `this.name` (and,
	 * for a static, `Owner.name`), and any other receiver's member of that name refuses.
	 */
	private static function keepsLength(scope: QueryNode, src: LengthSource, owner: String, isField: Bool, ctx: FileCtx): Bool {
		final s: Seams = ctx.seams;
		var ok: Bool = true;
		function visit(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>): Void {
			if (!ok || s.core.opaqueKinds.contains(node.kind)) return;
			final from: Null<Int> = node.span?.from;
			if (node.name == src.name && s.binderKinds.contains(node.kind) && from != src.declFrom) {
				ok = false;
				return;
			}
			if (node.name == src.name && node.kind == s.interpIdentKind) {
				ok = false;
				return;
			}
			if (isRef(node, src.name, owner, isField, s)) {
				// a local's name ahead of its declaration is some other binding's (a field's)
				if (!admitted(node, parent, grand, src, s) || !isField && (from ?? -1) < src.declFrom) ok = false;
				return;
			}
			if (isField && node.kind == s.core.fieldAccessKind && node.name == src.name) {
				ok = false;
				return;
			}
			for (c in node.children) visit(c, node, parent);
		}
		visit(scope, null, null);
		return ok;
	}

	/**
	 * Whether `node` is an occurrence of the array: the bare name, or — for a field — `this.name` or
	 * `Owner.name`.
	 */
	private static function isRef(node: QueryNode, name: String, owner: String, isField: Bool, s: Seams): Bool {
		if (node.kind == s.core.identKind) return node.name == name;
		if (!isField || node.kind != s.core.fieldAccessKind || node.name != name || node.children.length != 1) return false;
		final receiver: QueryNode = node.children[0];
		return receiver.kind == s.core.identKind && (receiver.name == owner || s.selfText != null && receiver.name == s.selfText);
	}

	/**
	 * Whether the occurrence `ref` (with its parent and grandparent) sits in a position that keeps the
	 * length: an index read (an index write too for a fixed-length type), a size read, a call of a
	 * reading method, the source's own append or initializing assignment, a `for`-in subject.
	 */
	private static function admitted(ref: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, src: LengthSource, s: Seams): Bool {
		if (parent == null) return false;
		if (parent.kind == s.core.indexAccessKind && parent.children[0] == ref) return src.fixedLength || !isWriteTarget(parent, grand, s);
		if (s.core.accessKinds.contains(parent.kind) && parent.children.length == 1) {
			if (isWriteTarget(parent, grand, s)) return false;
			if (parent.name == s.sizeMember) return true;
			if (grand == null || grand.kind != s.core.callKind || grand.children[0] != parent) return false;
			return s.readMethods.contains(parent.name ?? '') || grand == src.push;
		}
		return s.loopKinds.contains(parent.kind)
			? parent.children.length > 1 && parent.children.indexOf(ref) == parent.children.length - 2
			: parent == src.initAssign && parent.children[0] == ref;
	}

	/** Whether `node` is the l-value of an assignment / increment — the first child of a `writeParentKinds` parent. */
	private static function isWriteTarget(node: QueryNode, parent: Null<QueryNode>, s: Seams): Bool {
		return parent != null && s.core.writeParentKinds.contains(parent.kind) && parent.children.length >= 1 && parent.children[0] == node;
	}

	/**
	 * Report each loop in `scope` that reads `src.name[i]` with a bound unrelated to `src`'s. `all`
	 * holds every source kept in the scope, so a bound naming a PARALLEL array (one appended by the
	 * same loop) is recognised as related.
	 */
	private static function checkLoops(
		scope: QueryNode, src: LengthSource, all: Array<LengthSource>, owner: String, isField: Bool, ctx: FileCtx
	): Void {
		final s: Seams = ctx.seams;
		final related: Array<String> = [
			for (o in all) if (o.name == src.name || src.fillLoop != null && o.fillLoop == src.fillLoop) o.name
		];
		final fillFrom: Int = src.fillLoop?.span?.from ?? -1;
		final fillTo: Int = src.fillLoop?.span?.to ?? -1;
		function visit(node: QueryNode): Void {
			if (s.core.opaqueKinds.contains(node.kind)) return;
			final span: Null<Span> = node.span;
			if (span == null || span.from >= fillFrom && span.to <= fillTo) return;
			final index: Null<String> = node.name;
			for (kind in s.loopKinds) {
				final bound: Null<QueryNode> = zeroBasedBound(node, kind, ctx);
				if (bound == null || index == null) continue;
				final body: QueryNode = node.children[1];
				final reach: Null<Int> = binds(body, index, s) ? null : readReach(body, src.name, index, owner, isField, ctx);
				if (reach != null) compare(scope, span, bound, { index: index, reach: reach }, src, related, owner, isField, ctx);
			}
			for (c in node.children) visit(c);
		}
		visit(scope);
	}

	/**
	 * How far past the index `body` READS `name` — 0 for `name[index]`, `k` for `name[index + k]` with
	 * a non-negative literal `k` — the largest over every read, or null when it reads neither. A write
	 * is not a read, and `name[index - k]` reaches no further than `name[index]`, so neither counts.
	 */
	private static function readReach(body: QueryNode, name: String, index: String, owner: String, isField: Bool, ctx: FileCtx): Null<Int> {
		final s: Seams = ctx.seams;
		var reach: Null<Int> = null;
		function offset(node: QueryNode): Null<Int> {
			if (node.kind == s.core.identKind) return node.name == index ? 0 : null;
			if (s.foldOps[node.kind] != 'add' || node.children.length != BINARY_CHILD_COUNT) return null;
			for (i in 0...BINARY_CHILD_COUNT) {
				final indexSide: QueryNode = node.children[i];
				if (indexSide.kind != s.core.identKind || indexSide.name != index) continue;
				final k: Null<Int> = fold(node.children[1 - i], ctx.source, owner, _ -> true, ctx, 0);
				return k != null && k >= 0 ? k : null;
			}
			return null;
		}
		function visit(node: QueryNode, parent: Null<QueryNode>): Void {
			if (s.core.opaqueKinds.contains(node.kind)) return;
			if (
				node.kind == s.core.indexAccessKind && node.children.length == BINARY_CHILD_COUNT
				&& isRef(node.children[0], name, owner, isField, s) && !isWriteTarget(node, parent, s)
			) {
				final k: Null<Int> = offset(node.children[1]);
				if (k != null && (reach == null || k > (reach ?? 0))) reach = k;
			}
			for (c in node.children) visit(c, node);
		}
		visit(body, null);
		return reach;
	}

	/** Whether a binder anywhere under `node` takes `name`. */
	private static function binds(node: QueryNode, name: String, s: Seams): Bool {
		return node.name == name && s.binderKinds.contains(node.kind) || node.children.exists(c -> binds(c, name, s));
	}

	/** Whether `node`'s subtree holds an occurrence of the array `name`. */
	private static function mentions(node: QueryNode, name: String, owner: String, isField: Bool, s: Seams): Bool {
		return isRef(node, name, owner, isField, s) || node.children.exists(c -> mentions(c, name, owner, isField, s));
	}

	/**
	 * Report the loop at `loopSpan` when `bound` is neither related to `src` nor equal to its length
	 * expression. A bare constant name resolves only where no binder in `scope` takes it.
	 */
	private static function compare(
		scope: QueryNode, loopSpan: Span, bound: QueryNode, read: { index: String, reach: Int }, src: LengthSource, related: Array<String>,
		owner: String, isField: Bool, ctx: FileCtx
	): Void {
		final s: Seams = ctx.seams;
		final reach: Int = read.reach;
		if (related.exists(name -> mentions(bound, name, owner, isField, s))) return;
		final literal: Bool = src.literalCount >= 0;
		final shadowed: String -> Bool = name -> binds(scope, name, s);
		final boundValue: Null<Int> = fold(bound, ctx.source, owner, shadowed, ctx, 0);
		final lengthValue: Null<Int> = literal ? src.literalCount : fold(src.bound, ctx.source, owner, shadowed, ctx, 0);
		final boundText: String = shownText(bound, ctx.source);
		final lengthText: String = literal ? '${src.literalCount}' : shownText(src.bound, ctx.source);
		final same: Bool = if (boundValue != null && lengthValue != null)
			boundValue + reach == lengthValue;
		else if (reach > 0)
			true;
		else
			normalized(boundText) == normalized(lengthText);
		if (same) return;
		final from: String = literal ? 'its ${src.literalCount}-element literal' : '`$lengthText`';
		final tail: String = reach > 0 ? ' and reads `${src.name}[${read.index} + $reach]`' : '';
		ctx.out.push({
			file: ctx.file,
			span: loopSpan,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: 'the length of `${src.name}` comes from $from $LINE_LEAD${src.line}), this loop runs to `$boundText`$tail'
		});
	}

	/**
	 * The integer `node` (in `source`) evaluates to at compile time — a numeric literal, a parenthesis,
	 * a negation, an `integerFoldOperators` operation, or a `static final` constant (`Type.NAME`, or a
	 * bare `NAME` of the enclosing type `shadowed` says no binder takes) — or null when any part is not
	 * one.
	 */
	private static function fold(
		node: QueryNode, source: String, owner: String, shadowed: String -> Bool, ctx: FileCtx, depth: Int
	): Null<Int> {
		final s: Seams = ctx.seams;
		final kids: Array<QueryNode> = node.children;
		if (depth > MAX_FOLD_DEPTH) return null;
		if (s.core.numericLiteralKinds.contains(node.kind)) return integerLiteral(node, source);
		if (node.kind == s.parenKind && kids.length == 1) return fold(kids[0], source, owner, shadowed, ctx, depth);
		if (s.negKinds.contains(node.kind) && kids.length == 1) {
			final inner: Null<Int> = fold(kids[0], source, owner, shadowed, ctx, depth);
			return inner == null ? null : -inner;
		}
		final op: Null<String> = s.foldOps[node.kind];
		if (op != null && kids.length == BINARY_CHILD_COUNT)
			return applied(op, fold(kids[0], source, owner, shadowed, ctx, depth), fold(kids[1], source, owner, shadowed, ctx, depth));
		final key: Null<String> = constantKey(node, owner, shadowed, s);
		final constant: Null<Constant> = key == null ? null : ctx.constants[key];
		return constant == null ? null : fold(constant.value, constant.source, constant.owner, _ -> false, ctx, depth + 1);
	}

	/**
	 * Every `static final` member of a class-like type in the run that has an initializer, keyed
	 * `Type.NAME` by the type's simple name. A key two declarations claim is dropped: which one a
	 * reference means is not provable from the name.
	 */
	private static function collectConstants(
		parsed: Array<{ file: String, source: String, tree: QueryNode }>, s: Seams
	): Map<String, Constant> {
		final out: Map<String, Constant> = [];
		final ambiguous: Array<String> = [];
		function visit(node: QueryNode, source: String): Void {
			final name: Null<String> = node.name;
			if (!s.containers.contains(node.kind) || name == null) {
				for (c in node.children) visit(c, source);
				return;
			}
			final owner: String = name;
			for (member in node.children) {
				final memberName: Null<String> = member.name;
				if (member.kind != s.finalFieldKind || memberName == null || member.children.length != 1) continue;
				if (!MemberKinds.precedingModifiers(member, node, s.modifierKinds).exists(m -> m.kind == s.staticKind)) continue;
				final key: String = '$owner.$memberName';
				if (out.exists(key)) ambiguous.push(key);
				out[key] = { value: member.children[0], source: source, owner: owner };
			}
			for (c in node.children) visit(c, source);
		}
		for (p in parsed) visit(p.tree, p.source);
		for (key in ambiguous) out.remove(key);
		return out;
	}

	/** The statements of `fn`'s block body, or none when it has no block body. */
	private static function statementsOf(fn: QueryNode, s: Seams): Array<QueryNode> {
		final body: Null<QueryNode> = fn.children.length == 0 ? null : fn.children[fn.children.length - 1];
		return body != null && s.statementListKinds.contains(body.kind) ? body.children : [];
	}

	/** Whether `node`'s subtree holds a node of any of `kinds`. */
	private static function containsAnyKind(node: QueryNode, kinds: Array<String>): Bool {
		return kinds.contains(node.kind) || node.children.exists(c -> containsAnyKind(c, kinds));
	}

	/** The trimmed source text of `node`. */
	private static function textOf(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to).trim();
	}

	/** `node`'s source text with every whitespace run collapsed to one space — what the message quotes. */
	private static function shownText(node: QueryNode, source: String): String {
		return ~/\s+/g.replace(textOf(node, source), ' ');
	}

	/** The comparison key of a bound's text: no whitespace at all, and no parentheses wrapping the whole. */
	private static function normalized(text: String): String {
		var t: String = ~/\s+/g.replace(text, '');
		while (t.length >= 2 && t.charAt(0) == '(' && t.charAt(t.length - 1) == ')' && balanced(t.substring(1, t.length - 1)))
			t = t.substring(1, t.length - 1);
		return t;
	}

	/** Whether every parenthesis of `text` closes one it opened — so stripping a wrapping pair keeps the text whole. */
	private static function balanced(text: String): Bool {
		var depth: Int = 0;
		for (i in 0...text.length) {
			final c: String = text.charAt(i);
			if (c == '(') depth++;
			if (c == ')' && --depth < 0) return false;
		}
		return depth == 0;
	}

	/** The last dot-separated segment of `path`. */
	private static function simpleName(path: String): String {
		return path.substr(path.lastIndexOf('.') + 1);
	}

	/** Bundle the kinds this check reads, or null when one it cannot work without is unset (the check is then a no-op). */
	private static function seamsOf(shape: RefShape): Null<Seams> {
		final core: LoopSeams = LoopScan.seamsOf(shape) ?? return null;
		final arrayLiteralKind: String = shape.arrayLiteralKind ?? return null;
		final appendCall: String = shape.execution?.comprehensionCalls?.get(arrayLiteralKind) ?? return null;
		final mutable: Array<String> = present(shape.mutableFieldDeclKinds);
		final finalFieldKinds: Array<String> = [for (k in present(shape.fieldDeclKinds)) if (!mutable.contains(k)) k];
		if (finalFieldKinds.length != 1) return null;
		final loopKinds: Array<String> = present(shape.iterationBindingKinds);
		return {
			core: core,
			intervalKind: shape.intervalKind ?? return null,
			containers: MemberKinds.classLikeContainerKinds(shape),
			fieldKinds: present(shape.fieldDeclKinds),
			finalFieldKind: finalFieldKinds[0],
			modifierKinds: present(shape.modifierKinds),
			visibility: present(shape.visibilityModifierKinds),
			defaultVis: shape.defaultVisibilityModifierText ?? return null,
			staticKind: shape.staticModifierKind ?? return null,
			arrayLiteralKind: arrayLiteralKind,
			newExprKind: shape.newExprKind ?? return null,
			assignKind: shape.assignKind ?? return null,
			exprStmtKind: shape.exprStatementKind ?? return null,
			arrayTypes: present(shape.arrayTypeNames),
			fixedTypes: present(shape.execution?.fixedLengthArrayTypes),
			appendMethod: simpleName(appendCall),
			sizeMember: present(shape.sizeFieldNames)[0] ?? return null,
			readMethods: present(shape.execution?.nonMutatingArrayMethods),
			loopKinds: loopKinds,
			unsizedElementKinds: MemberKinds.withSetKinds(loopKinds.concat(present(shape.conditionalRegionKinds)), [shape.whileExprKind]),
			binderKinds: MemberKinds.withSetKinds(
				core.localDeclKinds.concat(present(shape.paramKinds))
					.concat(loopKinds)
					.concat(present(shape.iterationValueBinderKinds))
					.concat(present(shape.casePatternBinderKinds))
					.concat(present(shape.localFunctionKinds)),
				[shape.catchClauseKind]
			),
			exitKinds: present(shape.controlExitKinds),
			scopeKinds: present(shape.functionKinds).concat(present(shape.lambdaKinds)),
			statementListKinds: MemberKinds.withSetKinds([core.blockStmtKind], [shape.blockBodyKind]),
			modulePathKinds: present(shape.modulePathKinds),
			typeArgKinds: present(shape.typeAnnotationKinds),
			interpIdentKind: shape.stringInterpIdentKind,
			selfText: shape.selfReferenceText,
			parenKind: shape.parenKind,
			negKinds: present(shape.unaryMinusKinds),
			foldOps: shape.execution?.integerFoldOperators ?? []
		};
	}

	/** `kinds`, or none when unset. */
	private static function present(kinds: Null<Array<String>>): Array<String> {
		return kinds ?? [];
	}

	/** The value of a decimal or hexadecimal integer literal, or null for any other numeric literal. */
	private static function integerLiteral(node: QueryNode, source: String): Null<Int> {
		final span: Null<Span> = node.span;
		final text: String = span == null ? '' : source.substring(span.from, span.to);
		return ~/^(0[xX][0-9a-fA-F]+|[0-9]+)$/.match(text) ? Std.parseInt(text) : null;
	}

	/** `a op b` for one of `add`, `subtract`, `multiply`, or null when either operand is unknown or the operator is another. */
	private static function applied(op: String, a: Null<Int>, b: Null<Int>): Null<Int> {
		return if (a == null || b == null)
			null;
		else if (op == 'add')
			a + b;
		else if (op == 'subtract')
			a - b;
		else if (op == 'multiply')
			a * b;
		else
			null;
	}

	/**
	 * The `Type.NAME` key a constant reference names: `Type.NAME` itself, or a bare `NAME` of the
	 * enclosing type `owner` when `shadowed` says no binder takes it. Null for anything else.
	 */
	private static function constantKey(node: QueryNode, owner: String, shadowed: String -> Bool, s: Seams): Null<String> {
		final name: Null<String> = node.name;
		return if (name == null)
			null;
		else if (node.kind == s.core.identKind)
			shadowed(name) ? null : '$owner.$name';
		else if (node.kind == s.core.fieldAccessKind && node.children.length == 1 && node.children[0].kind == s.core.identKind)
			'${node.children[0].name}.$name';
		else
			null;
	}

}

/** The `RefShape` kinds and names this check reads, bundled once by `seamsOf`. */
private typedef Seams = {
	var core: LoopSeams;
	var intervalKind: String;
	var containers: Array<String>;
	var fieldKinds: Array<String>;
	var finalFieldKind: String;
	var modifierKinds: Array<String>;
	var visibility: Array<String>;
	var defaultVis: String;
	var staticKind: String;
	var arrayLiteralKind: String;
	var newExprKind: String;
	var assignKind: String;
	var exprStmtKind: String;
	var arrayTypes: Array<String>;
	var fixedTypes: Array<String>;
	var appendMethod: String;
	var sizeMember: String;
	var readMethods: Array<String>;
	var loopKinds: Array<String>;
	var unsizedElementKinds: Array<String>;
	var binderKinds: Array<String>;
	var exitKinds: Array<String>;
	var scopeKinds: Array<String>;
	var statementListKinds: Array<String>;
	var modulePathKinds: Array<String>;
	var typeArgKinds: Array<String>;
	var interpIdentKind: Null<String>;
	var selfText: Null<String>;
	var parenKind: Null<String>;
	var negKinds: Array<String>;
	var foldOps: Map<String, String>;
}

/** The per-file facts every scan reads. */
private typedef FileCtx = {
	var file: String;
	var source: String;
	var tree: QueryNode;
	var seams: Seams;
	var constants: Map<String, Constant>;
	var types: Null<Map<Int, String>>;
	var typeSyntax: TypeSyntaxReader;
	var lazyIndex: () -> Null<SymbolIndex>;
	var plugin: GrammarPlugin;
	var out: Array<Violation>;
}

/**
 * What proves an array's length: the expression it comes from (`bound` — the fill loop's upper bound,
 * the literal itself, the construction's argument), the line that says so, and the nodes the
 * occurrence scan admits as the source's own (`push`, `initAssign`). `literalCount` is the element
 * count of a literal source and -1 otherwise; `declFrom` is where the declaration starts.
 */
private typedef LengthSource = {
	var name: String;
	var declFrom: Int;
	var bound: QueryNode;
	var line: Int;
	var literalCount: Int;
	var fillLoop: Null<QueryNode>;
	var push: Null<QueryNode>;
	var initAssign: Null<QueryNode>;
	var fixedLength: Bool;
}

/** A `static final` member's initializer, the source it lives in and its type's simple name — what a reference folds to. */
private typedef Constant = {
	var value: QueryNode;
	var source: String;
	var owner: String;
}
