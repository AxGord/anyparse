package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Which side of the cursor's element the new element is inserted on.
 * Modelled as a sum type so the CLI passes one value and the operation
 * branches uniformly.
 */
enum InsertSide {

	After;
	Before;

}

/**
 * Insert a sibling element next to an existing one — the GENERALIZED
 * list-insert mutation op, and the writer-emit primitive the per-kind
 * insert ops (`AddMember`, `AddImport`, the future `add-param` engine)
 * are special cases of. It fills the gap those ops left: there was no way
 * to insert a STATEMENT into a `{ }` block, a `case` into a `switch`, or
 * an element into a comma list — only whole-node `replace-node` (a full
 * rewrite, not an insert) covered them.
 *
 * The model is the same writer-emit substrate as the insert layer
 * (`RefactorSupport.canonicalize`): there is NO fragment-parse. The
 * operation only computes WHERE to splice the raw element text and WHICH
 * separator the slot needs; the whole-file re-emit BOTH formats the
 * inserted element and re-parse-validates it (a malformed element makes
 * the re-parse fail → `Err`). The source is canonical-gated unless
 * `reformat` is set, exactly like `AddMember`.
 *
 * ## Targeting
 *
 * `line:col` points at the FIRST TOKEN of an EXISTING sibling element —
 * the node whose `span.from` equals the cursor (the outermost such node,
 * i.e. the first in pre-order: the list element itself, not a sub-node of
 * it). `--after` / `--before` then inserts the new element on that side.
 * To append, point at the last sibling with `--after`; to prepend, point
 * at the first with `--before`. (`apq refs` print-column convention,
 * identical to `extract-var` / `extract-method`'s START.)
 *
 * ## Separator — the only per-slot knowledge
 *
 * Statement / `case` lists are SELF-TERMINATED (each statement ends with
 * `;` / `}`; each `case` is delimited by the next `case`), so the element
 * is spliced with a leading / trailing newline and no separator token.
 * COMMA lists (array / object / call-args / `new`-args) need an explicit
 * `,`. The slot is a comma list when the cursor element's parent is a
 * known comma container OR the element is already adjacent to a `,` in the
 * source (the latter catches comma containers not in the enumerated set,
 * for any multi-element list). A single-element list of an unenumerated
 * comma kind can't be told from a block and falls back to the newline
 * form — the re-parse gate then refuses it rather than corrupt the file.
 *
 * The op is deliberately CONTAINER-AGNOSTIC beyond the separator: it does
 * not validate that the supplied text is a valid element for the slot —
 * the whole-file re-parse is that gate — so it works for any list-shaped
 * slot, including ones not foreseen here.
 */
@:nullSafety(Strict)
final class AddElement {

	/**
	 * Expression-list container kinds whose direct children are
	 * comma-separated. When the cursor element's parent is one of these,
	 * the new element is joined with a `,` even for a single-element list
	 * (where the source-adjacency check alone could not tell a one-element
	 * list from a block). `Call` / `NewExpr` carry a leading non-element
	 * child (the callee / the constructed type) — harmless here because the
	 * cursor element is an actual argument, never the callee.
	 */
	private static final COMMA_CONTAINER_KINDS: Array<String> = ['ArrayExpr', 'ObjectLit', 'Call', 'NewExpr'];

	/**
	 * Expression / block / switch container kinds whose source ENDS at their
	 * own closing delimiter, so back-scanning whitespace from `span.to`
	 * reliably lands on that delimiter. Type-decl bodies (class / interface /
	 * abstract / enum / typedef-anon, incl. `final class`) are NOT listed
	 * here — they are recognised through `RefactorSupport.typeDeclOf`, which
	 * is final-aware. Param lists are deliberately absent: they are embedded
	 * in a larger decl whose `span.to` is the body brace, not the param `)`,
	 * so container-append cannot target them.
	 */
	private static final EXPR_CONTAINER_KINDS: Array<String> = [
		'ArrayExpr',
		'ObjectLit',
		'Call',
		'NewExpr',
		'BlockBody',
		'BlockStmt',
		'SwitchStmtBare',
		'SwitchExprBare'
	];

	/**
	 * Sibling node kinds a declaration's modifiers and metadata project to —
	 * emitted BEFORE the decl they modify (`public static function` is
	 * `(Public)(Static)(FnMember)`; `@:meta` is `(Meta)`). `declGroupSpan`
	 * folds a run of these plus the decl into one logical element so a
	 * sibling insert lands OUTSIDE the whole `[@:meta modifiers… decl]`
	 * group, not between a modifier and its decl. `final` is NOT here — it
	 * WRAPS its decl (`FinalDecl` / `FinalModifiedMember` / `FinalMember`)
	 * instead of projecting to a separate sibling.
	 */
	private static final MODIFIER_META_KINDS: Array<String> = [
		'Meta',
		'Public',
		'Private',
		'Static',
		'Inline',
		'Override',
		'Macro',
		'Extern',
		'Dynamic'
	];

	/**
	 * Insert `code` as a new sibling element on `side` of the element whose
	 * first token is at `line:col` in `source`. `reformat` opts into a
	 * whole-file canonicalisation when the source is not already
	 * writer-canonical. `plugin` is the caller-owned grammar plugin;
	 * `optsJson` the project writer config. Returns `Ok(rewritten)` or an
	 * `Err`. The source is never mutated.
	 */
	public static function addElement(
		source: String, line: Int, col: Int, side: InsertSide, code: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final trimmed: String = StringTools.trim(code);
		if (trimmed.length == 0) return Err('add-element requires a non-empty element text');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here.
		final cursor: Int = Span.offsetOf(source, line, col + 1);

		final hit: Null<{ node: QueryNode, parent: Null<QueryNode> }> = findElementAt(tree, cursor);
		if (hit == null)
			return
				Err(
					'position $line:$col is not on the first token of an element — point at the first token of an existing statement / case / list element'
				);
		final element: QueryNode = hit.node;
		final elemSpan: Null<Span> = element.span;
		if (elemSpan == null) return Err('the element at $line:$col has no source span');

		final parent: Null<QueryNode> = hit.parent;
		// Fold a decl together with its leading modifier / meta siblings so an
		// insert lands outside the whole `[@:meta modifiers… decl]` group, not
		// between a modifier and its decl (and a cursor on a modifier targets
		// the decl it precedes). A non-decl element keeps its own span.
		final span: Span = declGroupSpan(element, parent, elemSpan);
		var isComma: Bool = adjacentToComma(source, span);
		if (!isComma && parent != null) isComma = COMMA_CONTAINER_KINDS.contains(parent.kind);

		final edit: { span: Span, text: String } = switch side {
			case After:
				{ span: new Span(span.to, span.to), text: isComma ? ', ' + trimmed : '\n' + trimmed };
			case Before:
				{ span: new Span(span.from, span.from), text: isComma ? trimmed + ', ' : trimmed + '\n' };
		};

		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * Append `code` as the LAST element of the container whose first token
	 * is at `line:col` — the container-targeting counterpart of
	 * `addElement`. Where the sibling form needs an existing element to
	 * point at, this points at the container itself, so it also works on an
	 * EMPTY container (`class C {}`, `[]`, `foo()`) where there is no sibling
	 * to address. It is the complete new primitive: front-insertion into a
	 * NON-empty list is already `addElement` with `Before` on the first
	 * element, and front-insertion into an empty container is identical to
	 * appending.
	 *
	 * A container is any node whose source ends at its own closing delimiter:
	 * an `ArrayExpr` / `ObjectLit` / `Call` / `NewExpr` / block / switch
	 * (see `EXPR_CONTAINER_KINDS`), or a type-decl body resolved via
	 * `RefactorSupport.typeDeclOf` (final-aware). The first pre-order node at
	 * the cursor that qualifies is taken — so a `foo(x);` statement resolves
	 * to its `Call`, not the wrapping `ExprStmt`.
	 *
	 * The insertion point is found by scanning whitespace back from the
	 * container's `span.to` to its closing delimiter (the same trick
	 * `AddMember` uses — robust against a decl span that swallows trailing
	 * trivia past the brace), then back again over whitespace to the last
	 * content byte. If that byte is an opening delimiter the container is
	 * empty and the element is spliced bare; otherwise it is joined with the
	 * slot separator (`,` for `COMMA_CONTAINER_KINDS`, a newline otherwise).
	 * The whole-file re-emit formats + re-parse-validates exactly as the
	 * sibling form does; the source is canonical-gated unless `reformat`.
	 */
	public static function appendElement(
		source: String, line: Int, col: Int, code: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final trimmed: String = StringTools.trim(code);
		if (trimmed.length == 0) return Err('add-element requires a non-empty element text');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here.
		final cursor: Int = Span.offsetOf(source, line, col + 1);

		final container: Null<QueryNode> = findContainerAt(tree, cursor);
		if (container == null)
			return
				Err(
					'position $line:$col is not on the first token of a container — point at the first token of a block / array / object / call / class / switch'
				);
		final containerSpan: Null<Span> = container.span;
		if (containerSpan == null) return Err('the container at $line:$col has no source span');

		// Closing delimiter: scan back over whitespace from the last byte of
		// the container's span (which may include trailing trivia past the
		// brace for some decl shapes — `AddMember`'s back-scan handles it).
		var close: Int = containerSpan.to - 1;
		if (close >= source.length) close = source.length - 1;
		while (close >= containerSpan.from && isSpace(StringTools.fastCodeAt(source, close))) close--;
		if (close < containerSpan.from) return Err('the container at $line:$col has no closing delimiter');
		final closeCode: Int = StringTools.fastCodeAt(source, close);
		if (closeCode != '}'.code && closeCode != ']'.code && closeCode != ')'.code)
			return Err('the node at $line:$col is not a brace / bracket / parenthesis container');

		// Last content byte: scan back over whitespace from just inside the
		// closing delimiter. If it is an opening delimiter, the container is
		// empty and the element is spliced without a separator.
		var lastContent: Int = close - 1;
		while (lastContent >= containerSpan.from && isSpace(StringTools.fastCodeAt(source, lastContent))) lastContent--;
		final lastCode: Int = lastContent >= containerSpan.from ? StringTools.fastCodeAt(source, lastContent) : -1;
		final empty: Bool = lastCode == '{'.code || lastCode == '['.code || lastCode == '('.code || lastContent < containerSpan.from;

		final isComma: Bool = COMMA_CONTAINER_KINDS.contains(container.kind);
		final at: Int = lastContent + 1;
		final text: String = empty ? trimmed : (isComma ? ', ' + trimmed : '\n' + trimmed);

		final edit: { span: Span, text: String } = { span: new Span(at, at), text: text };
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * The first pre-order node at `cursor` (its `span.from == cursor`) that
	 * qualifies as a container — a recognised expression / block / switch
	 * kind, or a type-decl body (final-aware via `RefactorSupport.typeDeclOf`).
	 * Pre-order means a `foo(x);` statement returns its inner `Call` rather
	 * than the `ExprStmt` that shares the cursor but is not a container.
	 * Null when nothing at the cursor is a container.
	 */
	private static function findContainerAt(tree: QueryNode, cursor: Int): Null<QueryNode> {
		var result: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			if (result != null) return;
			final sp: Null<Span> = node.span;
			if (sp != null && sp.from == cursor && isContainer(node)) {
				result = node;
				return;
			}
			for (c in node.children) {
				if (result != null) return;
				walk(c);
			}
		}
		walk(tree);
		return result;
	}

	private static inline function isContainer(node: QueryNode): Bool {
		return EXPR_CONTAINER_KINDS.contains(node.kind) || RefactorSupport.typeDeclOf(node) != null;
	}

	/**
	 * The outermost node whose `span.from == cursor` (the FIRST in
	 * pre-order, since a container always starts before its element — a
	 * block at `{`, a call at its callee, a switch at `switch`), together
	 * with its parent node. This is the list element the cursor's first
	 * token identifies. Null when no node starts exactly at `cursor`.
	 */
	private static function findElementAt(tree: QueryNode, cursor: Int): Null<{ node: QueryNode, parent: Null<QueryNode> }> {
		var result: Null<{ node: QueryNode, parent: Null<QueryNode> }> = null;
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			if (result != null) return;
			final sp: Null<Span> = node.span;
			if (sp != null && sp.from == cursor) {
				result = { node: node, parent: parent };
				return;
			}
			for (c in node.children) {
				if (result != null) return;
				walk(c, node);
			}
		}
		walk(tree, null);
		return result;
	}

	/**
	 * The source span of the LOGICAL declaration at the cursor element — a
	 * decl together with the modifier / metadata sibling nodes that precede
	 * it. Modifiers (`public` / `private` / `static` / `inline` / `override`
	 * / `macro` / `extern` / `dynamic`) and `@:meta` project to separate
	 * siblings BEFORE the decl they modify, so inserting BEFORE such a decl
	 * must land before the FIRST of them (not between the modifiers and the
	 * decl keyword), and a cursor that resolves to a modifier sibling targets
	 * the decl that follows it. Inserting AFTER lands at the decl's end — the
	 * modifiers precede it, so they do not move the end. Any element that is
	 * not part of a modifier-decl group (a statement, an array / call element)
	 * keeps its own span.
	 */
	private static function declGroupSpan(node: QueryNode, parent: Null<QueryNode>, nodeSpan: Span): Span {
		if (parent == null) return nodeSpan;
		final siblings: Array<QueryNode> = parent.children;
		final i: Int = siblings.indexOf(node);
		if (i < 0) return nodeSpan;

		// The decl is the cursor node, or — when the cursor is on a modifier /
		// meta sibling — the first following sibling that is not one.
		var declIndex: Int = i;
		while (declIndex < siblings.length && MODIFIER_META_KINDS.contains(siblings[declIndex].kind)) declIndex++;
		if (declIndex >= siblings.length) return nodeSpan;

		// Walk back over the modifier / meta run that precedes the decl.
		var startIndex: Int = declIndex;
		while (startIndex > 0 && MODIFIER_META_KINDS.contains(siblings[startIndex - 1].kind)) startIndex--;

		// No modifier / meta run AND the cursor is the decl itself → not a
		// group; leave the span untouched (statements, list elements).
		if (startIndex == declIndex && declIndex == i) return nodeSpan;

		final startSpan: Null<Span> = siblings[startIndex].span;
		final declSpan: Null<Span> = siblings[declIndex].span;
		if (startSpan == null || declSpan == null) return nodeSpan;
		return new Span(startSpan.from, declSpan.to);
	}

	/**
	 * Is the element at `span` immediately adjacent to a `,` — the next
	 * non-whitespace byte after `span.to`, or the previous non-whitespace
	 * byte before `span.from`, is a comma? True ⇒ the element sits in a
	 * comma-separated list (covers a comma container not in
	 * `COMMA_CONTAINER_KINDS`, for any list with at least two elements).
	 */
	private static function adjacentToComma(source: String, span: Span): Bool {
		var i: Int = span.to;
		while (i < source.length && isSpace(StringTools.fastCodeAt(source, i))) i++;
		if (i < source.length && StringTools.fastCodeAt(source, i) == ','.code) return true;

		var j: Int = span.from - 1;
		while (j >= 0 && isSpace(StringTools.fastCodeAt(source, j))) j--;
		if (j >= 0 && StringTools.fastCodeAt(source, j) == ','.code) return true;

		return false;
	}

	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

}
