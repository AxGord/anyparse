package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Outcome of an `Inline.inline` call. `Ok` carries the format-preserving
 * rewritten source; `Err` carries a human-readable diagnostic (cursor
 * not on an inlinable identifier, an unsafe initializer, a reassigned
 * binding, a post-rewrite re-parse failure). Modelled as a sum type so
 * the CLI maps it to stdout vs. stderr + a non-zero exit without a
 * sentinel-string convention. Mirrors `RenameResult`.
 */
enum InlineResult {

	Ok(text: String);
	Err(message: String);

}

/**
 * Scope-correct, format-preserving inline-variable — the sibling of
 * `Rename`, the second refactoring operation built on the query engine.
 *
 * Given a cursor on a LOCAL `var` / `final` declaration (or on any read
 * of it), the inline:
 *
 *  1. Resolves the binding at `line:col` via the shared cursor resolver.
 *  2. Confirms the decl is a local `var` / `final` with an initializer
 *     (not a field / param / for-iterator / catch-var).
 *  3. Refuses unless the binding is single-assignment (no writes) and
 *     the initializer is INLINE-SAFE — side-effect-free and free of
 *     reference-identity / property-getter / evaluation-order hazards.
 *  4. Substitutes every read of the binding with the initializer's exact
 *     source text (parenthesised when the initializer root is an
 *     operator, so precedence is preserved), deletes the decl line, and
 *     re-parses the result; an unparseable rewrite is rejected.
 *
 * The safety model is a strict WHITELIST: the initializer subtree is
 * inlined only when EVERY node kind is in `SAFE_KINDS` (or matches the
 * literal-suffix rule). A missed-but-safe kind costs a spurious refusal;
 * a missed hazardous kind would be a silent miscompile — so the default
 * is always to refuse the unknown. Calls, field/index access, object /
 * array / map literals, lambdas, `new`, assignments, increment /
 * decrement, and interpolated strings embedding any of these are all
 * outside the whitelist and therefore refused.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (1-based), identical to
 * `Rename`.
 */
@:nullSafety(Strict)
final class Inline {

	/**
	 * Initializer root kinds that are atomic primaries — they never need
	 * parentheses when substituted into an arbitrary expression context.
	 * An operator root (binary / unary / ternary) is wrapped in `(...)`
	 * instead so the surrounding precedence is preserved.
	 */
	private static final ATOMIC_ROOT_KINDS: Array<String> = [
		'IntLit',
		'FloatLit',
		'BoolLit',
		'NullLit',
		'DoubleStringExpr',
		'SingleStringExpr',
		'IdentExpr',
		'ParenExpr',
	];

	/**
	 * Local-variable declaration kinds the cursor's binding must carry to
	 * be inlinable. Excludes statics, fields, params, for-iterators and
	 * catch-vars — only a plain local `var` / `final` qualifies.
	 */
	private static final LOCAL_DECL_KINDS: Array<String> = ['VarStmt', 'FinalStmt'];

	/**
	 * Inline the local variable whose binding is identified by the symbol
	 * at `line:col` in `source`. `plugin` / `shape` are the caller-owned
	 * grammar plugin and its `RefShape` (the same pair the `refs` CLI
	 * builds), so the resolver stays language-agnostic. Returns
	 * `Ok(rewritten)` or an `Err` describing why the inline could not be
	 * applied. The source is never mutated — the caller decides whether to
	 * write the result.
	 *
	 * Named `inlineVar` (not `inline`) because `inline` is a Haxe keyword
	 * and `Inline.inline(...)` does not parse at the call site.
	 */
	public static function inlineVar(source: String, line: Int, col: Int, plugin: GrammarPlugin, shape: RefShape): InlineResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final prep: InlinePrep = resolveInlineTarget(source, line, col, cursor, tree, shape);
		return switch prep {
			case PErr(message): Err(message);
			case POk(target): buildInlineEdits(source, target, plugin);
		};
	}

	/**
	 * Free-identifier safety: for every `IdentExpr` in the initializer
	 * (other than `this`), confirm that
	 *
	 *  - nothing anywhere writes that name (any write ⇒ evaluation-order
	 *    hazard once the decl is removed and the read moves), and
	 *  - the ident resolves to a LOCAL binding — a non-field-member decl.
	 *    An unresolved ident (field / property / static / import) or one
	 *    that resolves to a class member could be a property getter, whose
	 *    duplicated reads would re-invoke the getter.
	 *
	 * Returns an `Err` message string on the first hazard, or null when
	 * every free ident is safe to duplicate.
	 */
	private static function checkFreeIdents(name: String, init: QueryNode, tree: QueryNode, shape: RefShape): Null<String> {
		final idents: Array<QueryNode> = collectIdentExprs(init);
		for (id in idents) {
			final nm: Null<String> = id.name;
			final idSpan: Null<Span> = id.span;
			if (nm == null || nm == 'this' || idSpan == null) continue;

			final nmHits: Array<RefHit> = Refs.find(nm, tree, shape);
			if (nmHits.exists(h -> h.kind == RefKind.Write))
				return '"$name" initializer depends on reassigned variable "$nm" — cannot inline';

			final readHit: Null<RefHit> = nmHits.find(h -> h.span.from == idSpan.from);
			final boundSpan: Null<Span> = readHit == null ? null : readHit.bindingSpan;
			if (boundSpan == null) return '"$name" initializer reads non-local "$nm" — cannot inline (may be a property)';

			final boundDecl: Null<QueryNode> = RefactorSupport.nodeAtFrom(tree, boundSpan.from);
			if (boundDecl == null || RefactorSupport.isFieldMemberKind(boundDecl.kind))
				return '"$name" initializer reads non-local "$nm" — cannot inline (may be a property)';
		}
		return null;
	}

	/** Every `IdentExpr` node in `node`'s subtree, in pre-order. */
	private static function collectIdentExprs(node: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function walk(n: QueryNode): Void {
			if (n.kind == 'IdentExpr') out.push(n);
			for (c in n.children) walk(c);
		}
		walk(node);
		return out;
	}

	/**
	 * The span of bytes to delete for the decl line. The decl span
	 * (`declSpan`) covers `var <name> = <init>;` including the trailing
	 * `;`. The deletion is widened to the whole physical line — back to
	 * the previous line break and forward over the next one — but ONLY
	 * when the decl owns its line exclusively:
	 *
	 *  - everything before `declSpan.from` back to the previous `\n` (or
	 *    start of file) is whitespace, and
	 *  - everything after `declSpan.to` up to the next `\n` (or EOF) is
	 *    whitespace.
	 *
	 * Otherwise the decl shares its line with other code / a comment and
	 * we return null so the caller refuses rather than corrupt that text.
	 */
	private static function computeDeclDeleteSpan(source: String, declSpan: Null<Span>): Null<Span> {
		if (declSpan == null) return null;
		final from: Int = declSpan.from;
		final to: Int = declSpan.to;

		var lineStart: Int = from;
		while (lineStart > 0 && source.charAt(lineStart - 1) != '\n') lineStart--;
		// Everything in [lineStart, from) must be whitespace.
		for (i in lineStart ... from) if (!isSpace(StringTools.fastCodeAt(source, i))) return null;

		var lineEnd: Int = to;
		while (lineEnd < source.length && source.charAt(lineEnd) != '\n') lineEnd++;
		// Everything in [to, lineEnd) must be whitespace.
		for (i in to ... lineEnd) if (!isSpace(StringTools.fastCodeAt(source, i))) return null;
		// Consume the trailing line break itself so no blank line is left.
		if (lineEnd < source.length && source.charAt(lineEnd) == '\n') lineEnd++;

		return new Span(lineStart, lineEnd);
	}

	/** `from` offset of a Read/Write hit's binding span (callers pre-null-check). */
	private static inline function bindingSpanFrom(hit: RefHit): Int {
		final b: Null<Span> = hit.bindingSpan;
		return b == null ? -1 : b.from;
	}

	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\r'.code;
	}

	/**
	 * Resolve and validate the inline target at `cursor`: the binding must be a
	 * local `var` / `final` (not a field / param / for-iterator / catch-var)
	 * with a single-assignment, inline-safe initializer and at least one read,
	 * every free identifier of which is a stable local. Returns the validated
	 * `InlineTarget` or a `PErr` with the precise refusal reason.
	 */
	private static function resolveInlineTarget(
		source: String, line: Int, col: Int, cursor: Int, tree: QueryNode, shape: RefShape
	): InlinePrep {
		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return PErr('position $line:$col is not on an inlinable identifier');
		final targetName: Null<String> = node.name;
		if (targetName == null) return PErr('position $line:$col is not on an inlinable identifier');
		final name: String = targetName;

		final hits: Array<RefHit> = Refs.find(name, tree, shape);

		final bindingFrom: Null<Int> = RefactorSupport.resolveBindingFrom(node, hits);
		if (bindingFrom == null) return PErr('could not resolve a binding for "$name" at $line:$col');
		final binding: Int = bindingFrom;

		// The decl node must be a local var / final, not a field / param /
		// for-iterator / catch-var.
		final declNode: Null<QueryNode> = RefactorSupport.nodeAtFrom(tree, binding);
		if (declNode == null) return PErr('could not locate the declaration of "$name" at $line:$col');
		final decl: QueryNode = declNode;
		if (!LOCAL_DECL_KINDS.contains(decl.kind)) return PErr('"$name" is not a local variable (only local var/final can be inlined)');

		// The initializer is the decl's first child.
		final init: Null<QueryNode> = decl.children.length > 0 ? decl.children[0] : null;
		final initSpan: Null<Span> = init == null ? null : init.span;
		if (init == null || initSpan == null) return PErr('"$name" has no initializer to inline');
		final initializer: QueryNode = init;
		final initRange: Span = initSpan;

		// No reassignment: the binding must have zero Write hits.
		final writes: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Write && h.bindingSpan != null && bindingSpanFrom(h) == binding);
		if (writes.length > 0) return PErr('"$name" is reassigned — cannot inline a mutable variable');

		// Collect reads of this binding.
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read && h.bindingSpan != null && bindingSpanFrom(h) == binding);
		if (reads.length == 0) return PErr('"$name" has no reads to inline');

		// The initializer subtree must be entirely inline-safe.
		if (!RefactorSupport.isSideEffectFree(initializer))
			return PErr('"$name" initializer is not inline-safe (contains calls/field-access/collection/lambda)');

		// Every free identifier the initializer reads must be a stable
		// local (not reassigned anywhere, not a field / property).
		final freeIdentErr: Null<String> = checkFreeIdents(name, initializer, tree, shape);
		return freeIdentErr != null
			? PErr(freeIdentErr)
			: POk({
				name: name,
				decl: decl,
				initializer: initializer,
				initRange: initRange,
				reads: reads
			});
	}

	/**
	 * Build and apply the inline edits for a validated `target`: substitute the
	 * initializer's exact source (parenthesised when its root is an operator) for
	 * every read, delete the decl line (refusing if the decl shares its line),
	 * then re-parse the rewrite — an unparseable result is rejected.
	 */
	private static function buildInlineEdits(source: String, target: InlineTarget, plugin: GrammarPlugin): InlineResult {
		final name: String = target.name;
		final initializer: QueryNode = target.initializer;
		final initRange: Span = target.initRange;

		// Build the substitution text: the initializer's exact source,
		// parenthesised when the root is an operator.
		final initText: String = source.substring(initRange.from, initRange.to);
		final substitution: String = ATOMIC_ROOT_KINDS.contains(initializer.kind) ? initText : '($initText)';

		final edits: Array<{ span: Span, text: String }> = [];

		// Each read's identifier token is replaced with the substitution.
		for (read in target.reads) {
			final identFrom: Int = RefactorSupport.identTokenOffset(source, read.span, name);
			if (identFrom >= 0) edits.push({ span: new Span(identFrom, identFrom + name.length), text: substitution });
		}

		// The decl line is deleted. The decl span includes its trailing
		// `;`; the line is removed only when the decl owns it exclusively
		// (whitespace before, nothing but whitespace + the line break
		// after) — otherwise we refuse rather than mangle adjacent code.
		final deleteSpan: Null<Span> = computeDeclDeleteSpan(source, target.decl.span);
		if (deleteSpan == null) return Err('"$name" declaration shares its line — cannot inline cleanly');
		edits.push({ span: deleteSpan, text: '' });

		final rewritten: String = RefactorSupport.applyEdits(source, edits);
		if (rewritten == source) return Err('inline of "$name" is a no-op');

		try
			plugin.parseFile(rewritten)
		catch (exception: ParseError)
			return Err('rewritten source does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten source does not parse: ${exception.message}');

		return Ok(rewritten);
	}

}

/**
 * A validated inline target: the binding name, its local decl node, the
 * inline-safe initializer subtree and its exact source span, and the reads
 * to substitute.
 */
private typedef InlineTarget = {
	final name: String;
	final decl: QueryNode;
	final initializer: QueryNode;
	final initRange: Span;
	final reads: Array<RefHit>;
};

/** Resolution outcome of `resolveInlineTarget`: the target or a refusal. */
private enum InlinePrep {

	POk(target: InlineTarget);
	PErr(message: String);

}
