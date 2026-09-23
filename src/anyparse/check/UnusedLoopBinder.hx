package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.query.CanonicalEdit;
import anyparse.query.CondRegionScan;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NominalTypes;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a `for` loop binder that nothing in the loop body reads, and renames it to the wildcard:
 * `for (i in 0...n)` becomes `for (_ in 0...n)`, `for (k => v in m)` with `v` unread becomes
 * `for (k => _ in m)`. `Info`, DEFAULT OFF — a style choice the project opts into, as
 * `redundant-property-access` and the other loop rewrites are.
 *
 * ## The key of a key-value loop
 *
 * An unread KEY is dropped (`for (k => v in xs)` → `for (v in xs)`) only when
 * `NominalTypes.valueIterationProvable` holds; everything else spells it `_`. `Map` never
 * qualifies: its `keyValueIterator` re-reads each value by key, so an entry the body removes reads
 * `null` there and the stale value through `iterator()`. Both binders unread follow the same proof:
 * `for (_ in xs)` or `for (_ => _ in m)`.
 *
 * ## What counts as a read
 *
 * Decided per BINDING: every occurrence of the name in the body (outside comments and inert
 * literals, not a dotted member tail) must be an inner declaration token (`Refs` `Decl`) or a
 * reference resolved to a binding INSIDE the body, so a shadowing re-declaration frees the binder
 * and a read of the binder itself, or of anything unresolvable, keeps it. Refused on sight of the
 * name: an interpolating literal, an unparsed `#if` region, a `macro` reification (no hit covers
 * it), an `untyped` subtree, a native-code carrier (`NativeCodeScan`), and a closure or local
 * function — a closure mentioning the name is a READ, whatever it binds.
 *
 * `_` is itself a readable binder (`for (_ in xs) trace(_)` compiles), so the rename is refused
 * when the body reads a `_` declared outside the loop or one the resolver cannot bind (an inherited
 * field); an unbound `_` inside a case pattern is the wildcard pattern and reads nothing. A structure
 * field NAME (`{ i: 1 }`) is a label, not a read.
 *
 * ## One owner per binder
 *
 * A key already spelled `_` is `redundant-map-iter-key`'s to drop (a statement loop; nobody drops
 * one from a comprehension); this rule still renames such a loop's unread VALUE, and the two edits
 * compose: `for (_ => v in xs)` with `v` unread becomes `for (_ in xs)` over a proved iterable and
 * `for (_ => _ in m)` otherwise. A loop that `dead-binder-counter-loop` claims
 * (`DeadBinderCounterLoop.claimer`) is left to it: its rewrite removes the counter and the dead
 * binder together. `prefer-value-loop` / `prefer-keyvalue-loop` match only a READ index;
 * `unused-local` skips loop binders.
 */
@:nullSafety(Strict)
final class UnusedLoopBinder implements Check implements DefaultOff {

	/** This check's stable id. */
	private static inline final RULE_ID: String = 'unused-loop-binder';

	/** The wildcard binder name. */
	private static inline final WILDCARD: String = '_';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a for-loop binder the body never reads — replaceable with _ (or a dropped key)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, seamsOf(plugin), (entry, tree, s, violations) -> {
			for (c in collect(fileCtxOf(tree, entry.source, entry.file, s, plugin, index))) violations.push({
				file: entry.file,
				span: c.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: c.message
			});
		});
	}

	/**
	 * Apply each flagged binder's edit, re-derived from the tree so a stale span produces none. A key
	 * the report pass could NOT prove droppable is renamed even where this pass could: the two may
	 * see different resolution scopes, and the drop is only ever the proved side.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		if (violations.length == 0) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		return RunScan.editsWith(plugin, source, seamsOf(plugin), (tree, s) -> {
			final symbols: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(
				[{ file: file, source: source }], plugin, RefactorSupport.resolutionIndexOf(plugin) ?? index
			);
			final byKey: Map<String, Candidate> = [];
			for (c in collect(fileCtxOf(tree, source, file, s, plugin, symbols))) byKey['${c.span.from}:${c.span.to}'] = c;
			final edits: Array<FixEdit> = [];
			for (v in violations) {
				final span: Null<Span> = v.span;
				final c: Null<Candidate> = span == null ? null : byKey['${span.from}:${span.to}'];
				if (c != null) edits.push(v.message == c.message ? c.edit : c.fallback ?? c.edit);
			}
			return CanonicalEdit.dropContainedEdits(edits);
		});
	}

	/** Whether `inner` lies within `outer`. */
	private static inline function within(inner: Span, outer: Span): Bool {
		return inner.from >= outer.from && inner.to <= outer.to;
	}

	/** The loop kinds and the kinds the read gates consult, or null when the grammar names no iteration binding (a no-op). */
	private static function seamsOf(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final loopKinds: Array<String> = shape.iterationBindingKinds ?? [];
		if (loopKinds.length == 0) return null;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final hazardKinds: Array<String> = [
			for (kinds in [shape.untypedKinds, shape.lambdaKinds, shape.localFunctionKinds]) if (kinds != null) for (k in kinds) k
		];
		return {
			shape: shape,
			loopKinds: loopKinds,
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			opaqueKinds: opaqueKinds,
			hazardKinds: hazardKinds,
			caseBranchKind: shape.caseBranchKind,
			plainPatternKind: shape.plainCasePatternKind
		};
	}

	/** Bundle the per-file facts; the type maps are built on first demand, since most loops never ask. */
	private static function fileCtxOf(
		tree: QueryNode, source: String, file: String, s: Seams, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>
	): FileCtx {
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final typeSources: () -> Map<Int, String> = memo(typeMapOf.bind(typed, source, true));
		final patterns: Array<Span> = [];
		collectPatternSpans(tree, s, patterns);
		return {
			root: tree,
			source: source,
			file: file,
			s: s,
			plugin: plugin,
			inert: OccurrenceScan.inertRegions(source, regions),
			comments: SourceComments.collectCommentRegions(regions),
			strings: [for (r in regions) if (r.kind == StringLit) new Span(r.from, r.to)],
			fieldNames: OccurrenceScan.structureFieldNameSpans(tree, source, s.shape),
			patterns: patterns,
			fold: plugin.stringFoldSupport(),
			index: index,
			types: memo(typeMapOf.bind(typed, source, false)),
			importMap: memo(importMapOf.bind(typed, source, file)),
			claimer: memo(() -> DeadBinderCounterLoop.claimer(tree, source, plugin, typeSources(), index))
		};
	}

	/** The simple names the file's plain imports bind, to their paths — none without type information. */
	private static function importMapOf(typed: Null<TypeInfoProvider>, source: String, file: String): Map<String, String> {
		return typed == null ? [] : typed.importMap(source, file);
	}

	/** `make`'s answer, computed on the first call and remembered for the rest. */
	private static function memo<T>(make: () -> T): () -> T {
		final cell: Array<T> = [];
		return () -> {
			if (cell.length == 0) cell.push(make());
			return cell[0];
		};
	}

	/**
	 * The span of every case PATTERN in `node`'s subtree. A `_` there is the wildcard pattern, which
	 * the resolver leaves unbound like a read of an unresolvable name; it reads nothing.
	 */
	private static function collectPatternSpans(node: QueryNode, s: Seams, out: Array<Span>): Void {
		if (node.kind == s.caseBranchKind) for (c in node.children) {
			final span: Null<Span> = c.span;
			if (c.kind == s.plainPatternKind && span != null) out.push(span);
		}
		for (c in node.children) collectPatternSpans(c, s, out);
	}

	/** The file's declared-type map — the nominal one, or the written sources with `sources` — or an empty one without type information. */
	private static function typeMapOf(typed: Null<TypeInfoProvider>, source: String, sources: Bool): Map<Int, String> {
		return if (typed == null)
			[]
		else if (sources)
			typed.declaredTypeSources(source)
		else
			typed.declaredTypes(source);
	}

	/** Every unread binder in the file, in document order. */
	private static function collect(ctx: FileCtx): Array<Candidate> {
		final out: Array<Candidate> = [];
		walk(ctx, ctx.root, out);
		return out;
	}

	/**
	 * Visit every loop under `node`. A loop is judged from its parent, which is where the previous
	 * statement `dead-binder-counter-loop` pairs it with lives. Reification subtrees are skipped.
	 */
	private static function walk(ctx: FileCtx, node: QueryNode, out: Array<Candidate>): Void {
		if (ctx.s.opaqueKinds.contains(node.kind)) return;
		for (i => kid in node.children) {
			if (ctx.s.loopKinds.contains(kid.kind) && !counterClaimed(ctx, node, i)) loopCandidates(ctx, kid, out);
			walk(ctx, kid, out);
		}
	}

	/** Whether `dead-binder-counter-loop` claims the loop at `scope.children[at]`, paired with the statement before it. */
	private static function counterClaimed(ctx: FileCtx, scope: QueryNode, at: Int): Bool {
		if (at == 0) return false;
		final claims: Null<(decl:QueryNode, forNode:QueryNode, scope:QueryNode) -> Bool> = ctx.claimer();
		return claims != null && claims(scope.children[at - 1], scope.children[at], scope);
	}

	/** The unread binders of one loop: its key-or-element binder, and a key-value loop's value binder. */
	private static function loopCandidates(ctx: FileCtx, loop: QueryNode, out: Array<Candidate>): Void {
		final loopSpan: Null<Span> = loop.span;
		final keyName: Null<String> = loop.name;
		if (loopSpan == null || keyName == null || loop.children.length == 0) return;
		final valueBinder: Null<QueryNode> = NominalTypes.iterationValueBinder(loop, ctx.s.valueBinderKinds);
		final iterable: Null<QueryNode> = NominalTypes.iterationIterable(loop, ctx.s.valueBinderKinds);
		final body: QueryNode = loop.children[loop.children.length - 1];
		if (iterable == null || body == iterable) return;
		final iterSpan: Null<Span> = iterable.span;
		final bodySpan: Null<Span> = body.span;
		if (iterSpan == null || bodySpan == null) return;
		if (wildcardBoundOutside(ctx, bodySpan)) return;
		final valueSpan: Null<Span> = valueBinder?.span;
		if (keyName == WILDCARD) {
			// A discarded KEY is `redundant-map-iter-key`'s to drop; only an unread value is this rule's.
			if (valueBinder != null && valueSpan != null) valueCandidate(ctx, body, bodySpan, valueBinder.name, valueSpan, out);
			return;
		}
		final keyToken: Null<Span> = OccurrenceScan.binderTokenSpan(ctx.source, loopSpan.from, valueSpan?.from ?? iterSpan.from, keyName);
		// The token is located in the header text, so a comment before it could hold a decoy.
		if (keyToken == null || CheckScan.hasCommentMarker(ctx.source, loopSpan.from, keyToken.from)) return;
		final keyUnread: Bool = unread(ctx, keyName, body, bodySpan);
		if (valueBinder == null || valueSpan == null) {
			if (keyUnread) out.push(renamed(keyToken, 'loop binder \'$keyName\' is never read; rename it to _'));
		} else
			keyValueCandidates(ctx, iterable, body, bodySpan, keyUnread ? keyName : null, keyToken, valueBinder.name, valueSpan, out);
	}

	/** The unread binders of a key-value loop; `unreadKey` is the key's name when the body never reads it, else null. */
	private static function keyValueCandidates(
		ctx: FileCtx, iterable: QueryNode, body: QueryNode, bodySpan: Span, unreadKey: Null<String>, keyToken: Span,
		valueName: Null<String>, valueSpan: Span, out: Array<Candidate>
	): Void {
		if (unreadKey != null) out.push(keyCandidate(ctx, iterable, unreadKey, keyToken, valueSpan, valueName ?? WILDCARD));
		valueCandidate(ctx, body, bodySpan, valueName, valueSpan, out);
	}

	/** A key-value loop's value binder, when it is named and the body never reads it. */
	private static function valueCandidate(
		ctx: FileCtx, body: QueryNode, bodySpan: Span, valueName: Null<String>, valueSpan: Span, out: Array<Candidate>
	): Void {
		if (valueName != null && valueName != WILDCARD && unread(ctx, valueName, body, bodySpan))
			out.push(renamed(valueSpan, 'value binder \'$valueName\' is never read; rename it to _'));
	}

	/**
	 * An unread KEY: dropped with its arrow when the iterable provably iterates the same values
	 * (`valueIterationProvable`) and no comment sits in the dropped text, otherwise renamed to `_`.
	 */
	private static function keyCandidate(
		ctx: FileCtx, iterable: QueryNode, keyName: String, keyToken: Span, valueSpan: Span, valueName: String
	): Candidate {
		final drop: Span = new Span(keyToken.from, valueSpan.from);
		return if (
			!CheckScan.hasCommentMarker(ctx.source, drop.from, drop.to)
			&& NominalTypes.valueIterationProvable(iterable, ctx.root, ctx.s.shape, ctx.types(), ctx.index(), ctx.file, ctx.importMap())
		)
			{
				span: keyToken,
				message: 'key binder \'$keyName\' is never read; iterate the values alone: for ($valueName in …)',
				edit: { span: drop, text: '' },
				fallback: { span: keyToken, text: WILDCARD }
			}
		else
			renamed(keyToken, 'key binder \'$keyName\' is never read; rename it to _');
	}

	/** A finding at `span` whose edit spells the binder there as `_`. */
	private static function renamed(span: Span, message: String): Candidate {
		return {
			span: span,
			message: message,
			edit: { span: span, text: WILDCARD },
			fallback: null
		};
	}

	/**
	 * Whether no occurrence of `name` in `body` reads the loop's binding of it — see the type doc's
	 * "What counts as a read". Every uncertainty answers false.
	 */
	private static function unread(ctx: FileCtx, name: String, body: QueryNode, bodySpan: Span): Bool {
		if (CondRegionScan.opaqueCondRegionMentioning(body, ctx.source, name, ctx.s.shape) != null) return false;
		if (hazardMentions(ctx, body, name)) return false;
		final occurrences: Array<Int> = occurrencesIn(ctx, name, bodySpan);
		if (occurrences.length == 0) return true;
		final covered: Array<Int> = [];
		// A reification or an interpolation hides its reads from the tree, so an occurrence
		// the hits do not account for, or one inside an interpolating literal, is a read.
		for (hit in Refs.find(name, ctx.root, ctx.s.shape)) if (within(hit.span, bodySpan)) {
			if (hit.kind == RefKind.Decl) {
				final token: Null<Span> = OccurrenceScan.binderTokenSpan(ctx.source, hit.span.from, hit.span.to, name);
				if (token != null) covered.push(token.from);
				continue;
			}
			if (boundOutside(ctx, hit, bodySpan)) return false;
			covered.push(hit.span.from);
		}
		return occurrences.foreach(at -> covered.contains(at) && !OccurrenceScan.offsetWithinAny(at, ctx.strings));
	}

	/**
	 * Whether the body reads a `_` bound OUTSIDE it. Renaming a binder to `_` would make that read
	 * resolve to the loop instead.
	 */
	private static function wildcardBoundOutside(ctx: FileCtx, bodySpan: Span): Bool {
		return occurrencesIn(ctx, WILDCARD, bodySpan).length > 0
			&& Refs.find(WILDCARD, ctx.root, ctx.s.shape)
				.exists(hit -> within(hit.span, bodySpan) && hit.kind != RefKind.Decl && boundOutside(ctx, hit, bodySpan));
	}

	/**
	 * Whether the reference `hit` reads something declared OUTSIDE the body — the loop binder, an
	 * outer binding, or a name the resolver cannot bind (an inherited field, a static import). An
	 * unbound name inside a case PATTERN is the exception: that is a pattern binder or the wildcard,
	 * and reads nothing. `unread` and `wildcardBoundOutside` both ask this, so they cannot disagree.
	 */
	private static function boundOutside(ctx: FileCtx, hit: RefHit, bodySpan: Span): Bool {
		final bound: Null<Span> = hit.bindingSpan;
		return bound == null ? !OccurrenceScan.offsetWithinAny(hit.span.from, ctx.patterns) : !within(bound, bodySpan);
	}

	/**
	 * Whether a subtree whose mention of `name` counts as a read however it resolves — a closure, an
	 * `untyped` subtree, a native-code carrier — spells `name` anywhere in its RAW text, string
	 * arguments included. A reification needs no entry: `Refs` projects no hit inside one, so the
	 * coverage test in `unread` already refuses every occurrence there.
	 */
	private static function hazardMentions(ctx: FileCtx, node: QueryNode, name: String): Bool {
		final span: Null<Span> = node.span;
		if (
			span != null && (ctx.s.hazardKinds.contains(node.kind) || NativeCodeScan.isCarrier(node, ctx.s.shape, ctx.fold))
			&& SourceText.mentionsIdent(ctx.source, span, name)
		)
			return true;
		return node.children.exists(c -> hazardMentions(ctx, c, name));
	}

	/**
	 * The start of every word-boundary occurrence of `name` in `span` that the compiler can read as a
	 * simple name: outside comments and inert literals, and not the member tail of a dotted access.
	 */
	private static function occurrencesIn(ctx: FileCtx, name: String, span: Span): Array<Int> {
		final out: Array<Int> = [];
		var at: Int = ctx.source.indexOf(name, span.from);
		while (at >= 0 && at + name.length <= span.to) {
			if (
				OccurrenceScan.referencedUnqualifiedInRange(ctx.source, name, at, at + name.length, ctx.fieldNames, ctx.comments, ctx.inert)
			)
				out.push(at);
			at = ctx.source.indexOf(name, at + 1);
		}
		return out;
	}

}

/** The grammar seams the check reads. */
private typedef Seams = {
	var shape: RefShape;
	var loopKinds: Array<String>;
	var valueBinderKinds: Array<String>;
	var opaqueKinds: Array<String>;

	/** The kinds whose subtree's mention of a name counts as a read however the tree resolves it. */
	var hazardKinds: Array<String>;

	/** The case-branch kind and the kind each of its patterns projects as; either unset leaves no pattern exempt. */
	var caseBranchKind: Null<String>;
	var plainPatternKind: Null<String>;
};

/** The per-file facts every gate reads. */
private typedef FileCtx = {
	var root: QueryNode;
	var source: String;
	var file: String;
	var s: Seams;
	var plugin: GrammarPlugin;

	/** Comments, regexes and non-interpolating literals — bytes that can neither bind nor read a name. */
	var inert: Array<Span>;
	var comments: Array<Span>;

	/** Every string literal; an occurrence inside one that is not inert sits in an interpolating literal. */
	var strings: Array<Span>;

	/** Structure field names (`{ i: 1 }`, `{ i:Int }`): a label reachable only through a receiver, never a read. */
	var fieldNames: Array<Span>;

	/** Every case pattern (see `collectPatternSpans`). */
	var patterns: Array<Span>;
	var fold: Null<StringFoldSupport>;
	var index: () -> Null<SymbolIndex>;
	var types: () -> Map<Int, String>;
	var importMap: () -> Map<String, String>;
	var claimer: () -> Null<(decl:QueryNode, forNode:QueryNode, scope:QueryNode) -> Bool>;
};

/** One unread binder: the span reported and the edit that unbinds it. */
private typedef Candidate = {
	var span: Span;
	var message: String;
	var edit: FixEdit;

	/** The rename a DROP falls back to when the report pass did not prove it; null for a rename. */
	var fallback: Null<FixEdit>;
};
