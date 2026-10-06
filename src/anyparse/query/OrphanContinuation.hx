package anyparse.query;

import anyparse.query.CondBranchProjection.CondBranchRun;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SourceComments.CommentTok;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * The validity predicate over a parsed tree that the parse itself cannot be: which ORPHAN
 * CONTINUATIONS (`RefShape.orphanContinuationKinds` — Haxe `OrphanElseStmt`, an `else` with no
 * `if` in front of it) the compiler would reject.
 *
 * The grammar accepts an orphan `else` anywhere a statement may stand, deliberately: conditional
 * compilation cuts if-chains in half (`if (a) f(); #if x else g(); #end`, the parallel `if` heads of
 * `#if a if (x) #else if (y) #end body; else other;`), and those files must parse with BOTH variants
 * structured. A PEG cannot also ask what stands in front of the clause, so the same production
 * admits an `else` an edit stranded — `hxq patch` duplicating an `else if (c)` header line wrote
 * `if (c) else if (c) …` and reported success. Checked against the compiler: every orphan it
 * accepts sits next to a `#if` seam, and every other one is `Expected }` /
 * `Expected expression`.
 *
 * So an orphan is JUSTIFIED by a seam, by exactly two positive shapes:
 *
 *  - it OPENS a branch of a conditional region (`#if x else g(); #end`, `#else else h();`) — the
 *    branch runs come from `CondBranchProjection.conditionalBranchRuns`, the same gap arithmetic the
 *    branch-aware projection uses;
 *  - its previous sibling in a statement sequence ENDS with a conditional region (`#if a if (c) f();
 *    #end else g();`, the `else` after a `CondSpliceStmt` or a `CondSpliceBlockOpen`, and an
 *    expression statement whose value closes on a spliced region — see `endsAtSeam`).
 *
 * Everything else is unjustified — an orphan as the body of an `if` / `while` / `else`, first in a
 * plain block, or after an ordinary statement. Whether a JUSTIFIED one compiles depends on the
 * defines (`#if a if (c) f(); #end else g();` compiles only with `-D a`), which a whole-file parse
 * cannot know, so justified means "a seam makes it possible", never "it compiles".
 *
 * Read by the writer-emit gate (`CanonicalEdit.canonicalize`) and by `apq fmt --write`, both through
 * `introduced`: a result may not hold MORE unjustified orphans than its input. The input's own count
 * is the floor rather than zero, so a file that already carries one is still editable and still
 * formats — the output has to be at least as valid as the input, not valid.
 *
 * Grammar-agnostic: the orphan kinds, the conditional-region kinds
 * (`CondRegionScan.isConditionalKind`), the statement-sequence kinds
 * (`ControlFlowSupport.blockKinds`) and the branch keywords all come from the plugin, and a grammar
 * declaring no orphan kind makes every question here answer "none".
 */
@:nullSafety(Strict)
final class OrphanContinuation {

	/** How far `leadWord` reads for the clause's own keyword — a cap so a refusal cannot turn into a paragraph. */
	private static inline final WORD_CAP: Int = 16;

	/**
	 * The refusal message when `result` holds more unjustified orphan continuations than `source`,
	 * or null when it does not.
	 *
	 * An unparseable `result` answers null: the caller's re-parse is about to report it in its own
	 * words. An unparseable `source` counts as holding none, so any orphan in a parseable result is
	 * new. An unchanged text (the empty edit set every `--reformat` canonicalisation passes) is
	 * answered without a parse. The result is parsed first and the source only when the result holds one, so the common
	 * answer costs one parse — and none at all under a `CachingGrammarPlugin` whose run already
	 * parsed that text.
	 */
	public static function introduced(source: String, result: String, plugin: GrammarPlugin): Null<String> {
		if (result == source || (plugin.refShape().orphanContinuationKinds ?? []).length == 0) return null;
		final after: Null<QueryNode> = try plugin.parseFile(result) catch (exception: Exception) null;
		if (after == null) return null;
		final stranded: Array<QueryNode> = unjustified(after, result, plugin);
		if (stranded.length == 0) return null;
		final before: Array<QueryNode> = try unjustified(plugin.parseFile(source), source, plugin) catch (exception: Exception) [];
		if (stranded.length <= before.length) return null;
		final fresh: QueryNode = firstUnmatched(stranded, result, [for (node in before) textOf(node, source)]);
		final span: Null<Span> = fresh.span;
		final at: String = span == null ? '' : {
			final pos: Position = span.lineCol(result);
			' at line ${pos.line}, column ${pos.col}';
		};
		return 'the result would hold `${leadWord(fresh, result)}`$at with nothing in front of it to continue — no construct it '
			+ 'belongs to and no conditional-compilation seam — which the compiler rejects (the source has ${before.length} such '
			+ 'clause(s), the result ${stranded.length})';
	}

	/**
	 * Every orphan-continuation node in `tree` that no conditional-compilation seam justifies, in
	 * document order. `source` is the text `tree` was parsed from; the branch runs read its gaps.
	 */
	public static function unjustified(tree: QueryNode, source: String, plugin: GrammarPlugin): Array<QueryNode> {
		final shape: RefShape = plugin.refShape();
		final kinds: Array<String> = shape.orphanContinuationKinds ?? [];
		final out: Array<QueryNode> = [];
		if (kinds.length == 0) return out;
		collect(tree, {
			source: source,
			shape: shape,
			kinds: kinds,
			sequenceKinds: sequenceKinds(plugin, shape),
			comments: null,
			regions: plugin.lexicalRegions.bind(source)
		}, out);
		return out;
	}

	private static inline function trimmedEnd(span: Span, ctx: OrphanScan): Int {
		return SourceComments.trimTrivia(ctx.source, span, commentsOf(ctx)).to;
	}

	private static inline function isWordChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/**
	 * The kinds whose children run in SEQUENCE, so a child's previous sibling is the code in front of
	 * it: the statement lists (`ControlFlowSupport.blockKinds`) and the `case` / `default` arms, whose
	 * body statements follow the pattern as siblings (`case 1: #if a if (c) f(); #end else g();`
	 * compiles under `-D a`).
	 */
	private static function sequenceKinds(plugin: GrammarPlugin, shape: RefShape): Array<String> {
		final kinds: Array<String> = (plugin.controlFlowSupport()?.blockKinds() ?? []).copy();
		for (arm in [shape.caseBranchKind, shape.defaultBranchKind]) if (arm != null) kinds.push(arm);
		return kinds;
	}

	private static function collect(node: QueryNode, ctx: OrphanScan, out: Array<QueryNode>): Void {
		final kids: Array<QueryNode> = node.children;
		for (i => kid in kids) {
			if (ctx.kinds.contains(kid.kind) && !justified(node, i, ctx)) out.push(kid);
			collect(kid, ctx, out);
		}
	}

	/**
	 * Whether the orphan at `parent.children[i]` stands next to a conditional-compilation seam —
	 * the two positive shapes the class doc names, and nothing else. A parent whose children are not
	 * a statement sequence (an `if`'s condition and body slots, a loop body) justifies nothing: a
	 * clause there continues no sibling at all.
	 */
	private static function justified(parent: QueryNode, i: Int, ctx: OrphanScan): Bool {
		final regionParent: Bool = CondRegionScan.isConditionalKind(parent.kind, ctx.shape);
		if (!regionParent && !ctx.sequenceKinds.contains(parent.kind)) return false;
		if (i > 0 && endsAtSeam(parent.children[i - 1], ctx)) return true;
		if (!regionParent) return false;
		final runs: Null<Array<CondBranchRun>> = CondBranchProjection.conditionalBranchRuns(
			parent, ctx.source, ctx.shape.conditionalElseKeywords ?? [], commentsOf(ctx)
		);
		final orphan: QueryNode = parent.children[i];
		return runs != null && runs.exists(run -> run.nodes[0] == orphan);
	}

	/**
	 * Whether `stmt` ENDS with a conditional region: it is one, or the region closes its last-child
	 * chain at its very last byte. The second shape is a region spliced into the TAIL of an
	 * expression statement — openfl's `d = if (b) c; #if !html5 else if (p) q; #end else m();`
	 * parses as an `ExprStmt` whose assigned value ends in a raw `CondSpliceTail`, so the `else`
	 * after it continues an `if` the region holds. The span equality is what keeps a region merely
	 * NESTED in the statement out: `{ #if a f(); #end } else g();` ends on the block's `}`, not on
	 * the region, and that `else` continues nothing in any build. A statement's span may run on over
	 * the trivia up to the next token, so both ends are compared with that trivia trimmed.
	 */
	private static function endsAtSeam(stmt: QueryNode, ctx: OrphanScan): Bool {
		final end: Null<Span> = stmt.span;
		var node: QueryNode = stmt;
		while (true) {
			if (CondRegionScan.isConditionalKind(node.kind, ctx.shape)) {
				final region: Null<Span> = node.span;
				return node == stmt || (end != null && region != null && trimmedEnd(region, ctx) == trimmedEnd(end, ctx));
			}
			final kids: Array<QueryNode> = node.children;
			if (kids.length == 0) return false;
			node = kids[kids.length - 1];
		}
	}

	/** The file's comment tokens, scanned once per walk and only when a seam question needs them. */
	private static function commentsOf(ctx: OrphanScan): Array<CommentTok> {
		final known: Null<Array<CommentTok>> = ctx.comments;
		if (known != null) return known;
		final scanned: Array<CommentTok> = SourceComments.collectCommentTokens(ctx.regions());
		ctx.comments = scanned;
		return scanned;
	}

	/**
	 * The first of `stranded` whose text is not one of the source's own unjustified clauses, each
	 * source clause matching at most once — so the refusal points at the clause the edit made, not
	 * at one the file already had. A caller guarantees `stranded` outnumbers `known`, so one is
	 * always left over.
	 */
	private static function firstUnmatched(stranded: Array<QueryNode>, result: String, known: Array<String>): QueryNode {
		for (node in stranded) if (!known.remove(textOf(node, result))) return node;
		throw new Exception('more unjustified orphans than the source has, yet every one matched a source clause');
	}

	private static function textOf(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to);
	}

	/** The clause's own leading word as the author wrote it (`else`), never a node kind. */
	private static function leadWord(node: QueryNode, source: String): String {
		final text: String = textOf(node, source);
		var end: Int = 0;
		while (end < text.length && end < WORD_CAP && isWordChar(text.fastCodeAt(end))) end++;
		return end > 0 ? text.substr(0, end) : text.substr(0, 1);
	}

}

/** One walk's seams, plus the comment tokens `OrphanContinuation.commentsOf` scans on first need. */
private typedef OrphanScan = {
	final source: String;
	final shape: RefShape;
	final kinds: Array<String>;
	final sequenceKinds: Array<String>;
	var comments: Null<Array<CommentTok>>;
	final regions: () -> Array<LexRegion>;
};
