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
 * the node whose first token the cursor falls within (the outermost such node,
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

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final hit: Null<{ node: QueryNode, parent: Null<QueryNode> }> = findElementAt(tree, source, cursor);
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
		final span: Span = RefactorSupport.declGroupSpan(element, parent, elemSpan);
		var isComma: Bool = RefactorSupport.adjacentToComma(source, span);
		if (!isComma && parent != null) isComma = RefactorSupport.COMMA_CONTAINER_KINDS.contains(parent.kind);

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

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final container: Null<QueryNode> = findContainerAt(tree, source, cursor);
		if (container == null)
			return
				Err(
					'position $line:$col is not on the first token of a container — point at the first token of a block / array / object / call / class / switch'
				);
		final containerSpan: Null<Span> = container.span;
		return containerSpan == null
			? Err('the container at $line:$col has no source span')
			: computeAppendEdit(source, line, col, containerSpan, container.kind, trimmed, reformat, plugin, optsJson);
	}

	/**
	 * The DEEPEST container whose FIRST TOKEN the cursor falls within (its `span.from`
	 * through the token's end, inclusive) — a recognised expression / block / switch kind,
	 * or a type-decl body (final-aware via `RefactorSupport.typeDeclOf`). Deepest (largest
	 * `span.from`) so a cursor on an inner `[[`'s inner bracket resolves the inner array,
	 * and a `foo(x);` statement resolves its `Call` rather than the `ExprStmt`. The
	 * first-token tolerance (not an exact `span.from == cursor`) forgives a column landing
	 * one past the opening `{` / inside a callee name. Null when no container qualifies.
	 */
	private static function findContainerAt(tree: QueryNode, source: String, cursor: Int): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		var bestFrom: Int = -1;
		function walk(node: QueryNode): Void {
			final sp: Null<Span> = node.span;
			if (sp != null && sp.from > bestFrom && cursorInFirstToken(source, sp.from, cursor) && isContainer(node)) {
				best = node;
				bestFrom = sp.from;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	private static inline function isContainer(node: QueryNode): Bool {
		return EXPR_CONTAINER_KINDS.contains(node.kind) || RefactorSupport.typeDeclOf(node) != null;
	}

	/**
	 * The outermost node whose FIRST TOKEN the cursor falls within (the FIRST in pre-order,
	 * since a container starts before its element — a block at `{`, a call at its callee,
	 * a switch at `switch`), together with its parent. This is the list element the cursor's
	 * first token identifies. The bound is EXCLUSIVE of the token's trailing boundary so a
	 * container's single-char delimiter (`[` / `{` / `(`) does NOT swallow the first
	 * element that begins right after it — the cursor at that boundary resolves the element,
	 * not the container. A column landing inside a multi-character element name still
	 * resolves it. Null when no node's first token contains `cursor`.
	 */
	private static function findElementAt(tree: QueryNode, source: String, cursor: Int): Null<{ node: QueryNode, parent: Null<QueryNode> }> {
		var result: Null<{ node: QueryNode, parent: Null<QueryNode> }> = null;
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			if (result != null) return;
			final sp: Null<Span> = node.span;
			if (sp != null && cursor >= sp.from && cursor < firstTokenEnd(source, sp.from)) {
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

	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/**
	 * Resolve the splice point and separator for `appendElement` once the
	 * target container has been located, then canonicalise. Scans whitespace
	 * back from the container's `span.to` to its closing delimiter (robust
	 * against a decl span that swallows trailing trivia past the brace), then
	 * back over whitespace to the last content byte: an opening delimiter
	 * there means the container is empty and the element is spliced bare;
	 * otherwise it is joined with the slot separator (`,` for a comma
	 * container kind, a newline otherwise). `line` / `col` are only used for
	 * the diagnostic messages.
	 */
	private static function computeAppendEdit(
		source: String, line: Int, col: Int, containerSpan: Span, containerKind: String, trimmed: String, reformat: Bool,
		plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
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

		final isComma: Bool = RefactorSupport.COMMA_CONTAINER_KINDS.contains(containerKind);
		final at: Int = lastContent + 1;
		final text: String = empty ? trimmed : (isComma ? ', ' + trimmed : '\n' + trimmed);

		final edit: { span: Span, text: String } = { span: new Span(at, at), text: text };
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	private static inline function isIdentChar(c: Int): Bool {
		return c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code || c >= '0'.code && c <= '9'.code || c == '_'.code;
	}

	/**
	 * The offset just past the first token at `from` — the run of identifier characters
	 * when `from` is on one (a name / keyword), else the single delimiter / operator
	 * character (`{` / `[` / `(`). Lets a cursor that lands anywhere within a node's
	 * opening token (e.g. one column past `{`, or inside a callee name) still resolve it,
	 * matching the forgiving `ast --at` instead of demanding the exact `span.from` column.
	 */
	private static function firstTokenEnd(source: String, from: Int): Int {
		if (from < 0 || from >= source.length) return from;
		if (!isIdentChar(StringTools.fastCodeAt(source, from))) return from + 1;
		var i: Int = from + 1;
		while (i < source.length && isIdentChar(StringTools.fastCodeAt(source, i))) i++;
		return i;
	}

	/** Whether `cursor` falls within the first token of a node starting at `from` (its start through the token's trailing boundary). */
	private static inline function cursorInFirstToken(source: String, from: Int, cursor: Int): Bool {
		return cursor >= from && cursor <= firstTokenEnd(source, from);
	}

}
