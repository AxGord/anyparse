package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.ElementSpan.ElementHit;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.runtime.Span;
import haxe.ds.Either;

using Lambda;
using StringTools;

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
 * ## The brace-less body slot
 *
 * One slot is not a list at all: the sole statement of an `if` / `else` / loop body or an
 * arrow lambda's expression body, written without `{ }`. It holds exactly ONE statement by
 * construction, so there is no sibling position in it, and the separator logic above would
 * splice the new element AFTER the whole construct — where it runs unconditionally, in source
 * that parses and compiles. `braceLessBodySlot` detects that case and the slot gains braces
 * instead, with both statements inside. The addressing carries the intent with no flag needed:
 * pointing at the STATEMENT means inside the body, pointing at the enclosing `if` means after
 * the `if`.
 *
 * The op is deliberately CONTAINER-AGNOSTIC beyond the separator: it does
 * not validate that the supplied text is a valid element for the slot —
 * the whole-file re-parse is that gate — so it works for any list-shaped
 * slot, including ones not foreseen here.
 */
@:nullSafety(Strict)
final class AddElement {

	/** The refusal of an empty element text, which every insert mode shares. */
	private static inline final EMPTY_ELEMENT: String = 'add-element requires a non-empty element text';

	/** The label a parse failure of the edited source is reported under. */
	private static inline final SOURCE_LABEL: String = 'source';

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
		final trimmed: String = code.trim();
		if (trimmed.length == 0) return Err(EMPTY_ELEMENT);

		final tree: QueryNode = switch ParseGate.parse(plugin, source, SOURCE_LABEL) {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		// A `final class` addressed through its inner form is lifted to the wrapper: inserting `--before`
		// the form landed between `final` and `class`.
		final hit: Null<ElementHit> = ElementSpan.liftedElementAt(tree, source, cursor);
		if (hit == null)
			return Err(
				'position $line:$col'
				+ ' is not on the first token of an element — point at the first token of an existing statement / case / list element'
			);
		final element: QueryNode = hit.node;
		final elemSpan: Null<Span> = element.span;
		if (elemSpan == null) return Err('the element at $line:$col has no source span');

		final parent: Null<QueryNode> = hit.parent;
		// Fold a decl together with its leading modifier / meta siblings so an
		// insert lands outside the whole `[@:meta modifiers… decl]` group, not
		// between a modifier and its decl (and a cursor on a modifier targets
		// the decl it precedes). A non-decl element keeps its own span.
		final span: Span = ElementSpan.declGroupSpan(element, parent, elemSpan);
		var isComma: Bool = ElementSpan.adjacentToComma(source, span);
		if (!isComma && parent != null) isComma = (plugin.refShape().commaContainerKinds ?? []).contains(parent.kind);

		// A `;`-terminated element can never belong to a comma-separated list —
		// the cursor resolved to a call-argument / array / object slot while the
		// caller almost certainly meant a sibling STATEMENT. Refuse with the
		// recipe instead of the cryptic parse error the splice would produce.
		if (isComma && trimmed.endsWith(';'))
			return Err(
				'the element ends with ";" but the target is a comma-separated list (call arguments / array / object) — '
				+ 'to add a sibling STATEMENT next to a bare-call statement, use '
				+ '`apq replace-node --match \'<the call>\' --kind ExprStmt` replacing the one statement with two'
			);

		// A BRACE-LESS body slot holds exactly one statement, so there is no sibling
		// position inside it to splice into — see `braceLessBodySlot`.
		if (!isComma && braceLessBodySlot(parent, element, plugin)) {
			final held: String = terminated(source.substring(span.from, span.to));
			final block: String = switch side {
				case After: '{\n$held\n$trimmed\n}';
				case Before: '{\n$trimmed\n$held\n}';
			};
			return CanonicalEdit.canonicalize(source, [{ span: span, text: block }], reformat, plugin, optsJson);
		}

		// BOTH offsets ask the same question, of the same helper: which doc comments
		// belong to the declaration on the far side of this position? A leading doc is
		// trivia OUTSIDE the target's span, so `span.from` sits BELOW the target's own
		// doc; and a MODULE-level span is greedy — it runs to the first token of the
		// NEXT declaration — so `span.to` sits below the NEIGHBOUR's doc. Inserting at
		// either raw offset handed that doc to the insertion.
		//
		// `docExtendedSpan(…, docOnly)` is the attribution the delete side already asks
		// (`RefactorSupport.deleteNodes`), so the two agree on whose doc it is, and it
		// walks back over `/**` blocks that START THEIR LINE only. That last clause is
		// what keeps the `After` offset off a TRAILING comment: `} // note about A` and
		// `a: 1 /* about a */,` both end their element's span, and both stay on the
		// element they trail. Trimming the whole span instead — the first shape this
		// fix took — moved exactly those two onto the insertion, which is the same
		// defect in the other direction.
		final before: Int = ElementSpan.docExtendedSpan(source, span, plugin.lexicalRegions(source), true).from;
		final after: Int = ElementSpan.docExtendedSpan(source, new Span(span.to, span.to), plugin.lexicalRegions(source), true).from;
		// The new element must end its own line whichever side of a line break the `After` offset lands
		// on. Right after the target's last token (a member's tight span) the break goes first; at the
		// START of a line — the next declaration's doc, or its first token where a module-level span is
		// greedy — the element goes first and the break after it, so what followed (that doc above all)
		// stays at the start of a line instead of trailing the element's last token: `} /** doc *\/`.
		final afterText: String = SourceText.startsItsLine(source, after) ? '$trimmed\n' : '\n$trimmed';
		final edit: Splice = switch side {
			case After:
				{ span: new Span(after, after), text: isComma ? ', $trimmed' : afterText };
			case Before:
				{ span: new Span(before, before), text: isComma ? '$trimmed, ' : '$trimmed\n' };
		};

		return CanonicalEdit.canonicalize(source, [edit], reformat, plugin, optsJson);
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
	 * (the grammar's `RefShape.delimitedContainerKinds`), or a type-decl body resolved via
	 * `RefactorSupport.typeDeclOf` (final-aware). The first pre-order node at
	 * the cursor that qualifies is taken — so a `foo(x);` statement resolves
	 * to its `Call`, not the wrapping `ExprStmt`.
	 *
	 * The insertion point is found by scanning whitespace back from the
	 * container's `span.to` to its closing delimiter (the same trick
	 * `AddMember` uses — robust against a decl span that swallows trailing
	 * trivia past the brace), then back again over whitespace AND whole
	 * comment tokens to the last content byte. If that byte is an opening
	 * delimiter the container is empty and the element is spliced bare;
	 * otherwise it is joined with the slot separator (`,` for a
	 * `RefShape.commaContainerKinds` kind, a newline otherwise). When trailing comments
	 * were skipped the separator stays glued to the last element and the new
	 * element is spliced on its own line PAST them, so nothing is ever written
	 * into comment text. The whole-file re-emit formats + re-parse-validates
	 * exactly as the sibling form does; the source is canonical-gated unless
	 * `reformat`.
	 */
	public static function appendElement(
		source: String, line: Int, col: Int, code: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final trimmed: String = code.trim();
		if (trimmed.length == 0) return Err(EMPTY_ELEMENT);

		final tree: QueryNode = switch ParseGate.parse(plugin, source, SOURCE_LABEL) {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final container: Null<QueryNode> = findContainerAt(tree, source, cursor, plugin.refShape());
		if (container == null)
			return Err(
				'position $line:$col'
				+ ' is not on the first token of a container — point at the first token of a block / array / object / call / class / switch'
			);
		final containerSpan: Null<Span> = container.span;
		return containerSpan == null
			? Err('the container at $line:$col has no source span')
			: computeAppendEdit(source, line, col, containerSpan, container.kind, trimmed, reformat, plugin, optsJson);
	}

	/**
	 * Insert the STRING entries `code` — one element or a comma list of them, as `appendElement` takes —
	 * into the array literal whose first token is at `line:col`, each at its SORTED position: code-unit
	 * order, the order a generated registry sorts in. A hand-kept sorted list then gains entries without
	 * anyone working out where each one goes; `appendElement` is the explicit unsorted form.
	 *
	 * Positive by construction: the container must be the grammar's array literal
	 * (`RefShape.arrayLiteralKind`), and every element, existing and new, a CONSTANT string —
	 * a plain literal or a concatenation of them (`sortKeyOf`) — so the order compares string VALUES.
	 * The existing elements must already be strictly ascending, and an entry the list already holds is
	 * refused: a list that is not a sorted set is never reordered or doubled behind the caller's back.
	 *
	 * The entries are split by the PARSER, never by scanning `code` (`parsedEntries`). Each lands before
	 * the first existing element whose key sorts after it — clear of that element's leading doc, as
	 * `addElement` `Before` does — or after the last one; entries sharing a gap keep their own order.
	 */
	public static function insertSorted(
		source: String, line: Int, col: Int, code: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final trimmed: String = withoutTrailingComma(code.trim());
		if (trimmed.length == 0) return Err(EMPTY_ELEMENT);
		final tree: QueryNode = switch ParseGate.parse(plugin, source, SOURCE_LABEL) {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};
		final arrayKind: Null<String> = plugin.refShape().arrayLiteralKind;
		final fold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (arrayKind == null || fold == null) return Err('--sorted needs a grammar that names its array literal and its string literals');
		final container: Null<QueryNode> = findContainerAt(tree, source, Span.offsetOf(source, line, col), plugin.refShape());
		final containerSpan: Null<Span> = container?.span;
		if (container == null || containerSpan == null || container.kind != arrayKind)
			return Err('position $line:$col is not on the first token of an array literal — --sorted inserts into an array');

		final existing: Array<SortedEntry> = switch sortedElements(container, source, fold) {
			case Left(message): return Err(message);
			case Right(elements): elements;
		};
		final entries: Array<SortedEntry> =
			switch parsedEntries(source, containerSpan, existing.length, trimmed, plugin, arrayKind, fold) {
				case Left(message): return Err(message);
				case Right(parsed): parsed;
			};
		entries.sort((a, b) -> Reflect.compare(a.key, b.key));
		for (i => entry in entries) if (existing.exists(e -> e.key == entry.key) || (i > 0 && entries[i - 1].key == entry.key))
			return Err('${entry.text} is already in the list');
		return CanonicalEdit.canonicalize(source, gapEdits(source, containerSpan, existing, entries, plugin), reformat, plugin, optsJson);
	}

	/**
	 * Does `element` sit in a BRACE-LESS body slot of `parent` — the sole statement of an
	 * `if` / `else` / loop body or an arrow lambda's expression body, written without `{ }`?
	 *
	 * Such a slot holds exactly ONE statement by construction, so it has no sibling position
	 * to splice into. Splicing anyway is the reason this path exists: `\n<new>` after the
	 * element lands the new statement OUTSIDE the construct, where it runs unconditionally —
	 * source that PARSES and compiles, so neither the re-parse gate nor a build catches it.
	 * (On an arrow body it usually fails to parse instead, which is the same defect surfacing
	 * loudly rather than quietly.) The slot has to gain braces first, which is what the
	 * caller does when this returns true.
	 *
	 * The addressing already carries the intent and needs no flag: pointing at the STATEMENT
	 * means "next to this statement", i.e. inside the body; pointing at the enclosing `if`
	 * means "next to the if". Only the first reaches here.
	 *
	 * WHICH child is the body is answered per family, because the two disagree:
	 *
	 * - a LAMBDA's body is its last child, whatever its parameters are, so the test is
	 *   last-child. `() -> doThing()` has the body at index 0 and still qualifies.
	 * - a CONTROL-FLOW construct puts its condition / subject FIRST, so the test is
	 *   index > 0. That also refuses `do body while (c)`, whose body IS at index 0 — a
	 *   fail-closed miss (the caller gets the old sibling splice) rather than a wrap that
	 *   might land around a condition.
	 *
	 * An element that is ALREADY a block is not in a brace-less slot, so it takes the
	 * ordinary sibling path — as does every element whose parent is a block, a comma
	 * container, or any kind the grammar's seams do not describe. Every seam is optional:
	 * a grammar that declares none makes this function constantly false and the op behaves
	 * exactly as it did before.
	 * The held body text as a STATEMENT, for splicing into the block that is about to wrap it.
	 *
	 * An arrow lambda's expression body carries no terminator of its own (`() -> doOne()`), and
	 * a block wants one; a statement body already has its `;`, and a body that is itself a
	 * braced construct (`if (c) { … }` as an `else` body) ends on `}` and needs none.
	 *
	 * HAZARD this does not fix, and cannot: a block's value is its LAST expression, so wrapping
	 * an expression body and appending after it moves the lambda's value to the NEW statement.
	 * `() -> compute()` returns `compute()`; `() -> { compute(); log(); }` returns `log()`.
	 * Inserting BEFORE keeps the value where it was. Nothing here can tell whether the value is
	 * used — no types at this layer — so the caller's chosen side decides, and `--before` is the
	 * value-preserving one.
	 */
	private static inline function terminated(held: String): String {
		final trimmedHeld: String = held.trim();
		return trimmedHeld.endsWith(';') || trimmedHeld.endsWith('}') ? held : '$held;';
	}

	private static inline function isContainer(node: QueryNode, shape: RefShape): Bool {
		return (shape.delimitedContainerKinds ?? []).contains(node.kind) || RefactorSupport.typeDeclOf(node) != null;
	}

	/**
	 * Whether `cursor` falls within the first token of a node starting at
	 * `from` (its start through the token's trailing boundary, inclusive).
	 */
	private static inline function cursorInFirstToken(source: String, from: Int, cursor: Int): Bool {
		return cursor >= from && cursor <= SourceText.firstTokenEnd(source, from);
	}

	/** Whether `code` opens a brace / bracket / parenthesis container — the last content byte of an EMPTY one. */
	private static inline function isOpenDelimiter(code: Int): Bool {
		return code == '{'.code || code == '['.code || code == '('.code;
	}

	private static function braceLessBodySlot(parent: Null<QueryNode>, element: QueryNode, plugin: GrammarPlugin): Bool {
		if (parent == null) return false;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null || support.blockKinds().contains(element.kind)) return false;
		final shape: RefShape = plugin.refShape();
		final children: Array<QueryNode> = parent.children;
		final at: Int = children.indexOf(element);
		if (at < 0) return false;
		if ((shape.lambdaKinds ?? []).contains(parent.kind)) return at == children.length - 1;
		final constructKinds: Array<String> = ShapeVocab.ifKinds(shape).concat(shape.loopStatementKinds ?? []);
		return constructKinds.contains(parent.kind) && at > 0;
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
	private static function findContainerAt(tree: QueryNode, source: String, cursor: Int, shape: RefShape): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		var bestFrom: Int = -1;
		function walk(node: QueryNode): Void {
			final sp: Null<Span> = node.span;
			if (sp != null && sp.from > bestFrom && cursorInFirstToken(source, sp.from, cursor) && isContainer(node, shape)) {
				best = node;
				bestFrom = sp.from;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * Index of the comment token whose `[from, to)` range covers `at`, or -1 when
	 * `at` is outside every comment. The back-scan calls it once per comment it
	 * skips, not once per byte, so the linear walk is not a hot path.
	 */
	private static function commentIndexAt(comments: Array<{ from: Int, to: Int, isLine: Bool }>, at: Int): Int {
		for (i => comment in comments) if (at >= comment.from && at < comment.to) return i;
		return -1;
	}

	/**
	 * Walk back through a container's interior `[lo, hi)` over whitespace and
	 * whole comment TOKENS, and report the last CODE byte (`lastContent`, `lo - 1`
	 * when the interior holds no code) together with the end of the LAST comment
	 * skipped on the way (`afterComments`, -1 when none was).
	 *
	 * Only a comment lying entirely inside `[lo, hi)` is trusted: one reaching past
	 * `hi` means the lexical scan and the parser disagree there — an escaped double
	 * slash inside a regex literal reads as a line comment running to end of line —
	 * so its bytes count as code and the walk stops, leaving the pre-existing splice
	 * point intact.
	 */
	private static function scanBackOverTrivia(
		source: String, lo: Int, hi: Int, regions: Array<LexRegion>
	): { lastContent: Int, afterComments: Int } {
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(regions);
		var at: Int = hi - 1;
		var afterComments: Int = -1;
		while (at >= lo) {
			if (SourceText.isSpace(source.fastCodeAt(at))) {
				at--;
				continue;
			}
			final ci: Int = commentIndexAt(comments, at);
			if (ci < 0 || comments[ci].from < lo || comments[ci].to > hi) break;
			if (afterComments < 0) afterComments = comments[ci].to;
			at = comments[ci].from - 1;
		}
		return { lastContent: at, afterComments: afterComments };
	}

	/**
	 * Resolve the splice point and separator for `appendElement` once the
	 * target container has been located, then canonicalise. Scans whitespace
	 * back from the container's `span.to` to its closing delimiter (robust
	 * against a decl span that swallows trailing trivia past the brace), then
	 * back over whitespace AND whole comment tokens to the last content byte:
	 * an opening delimiter there means the container is empty and the element
	 * is spliced bare; otherwise it is joined with the slot separator (`,` for
	 * a comma container kind, a newline otherwise). Comments are skipped by
	 * TOKEN (`RefactorSupport.collectCommentTokens`), never by scanning the
	 * text for an opener — a whitespace-only scan took a trailing comment's
	 * last character for the last content byte and spliced separator + element
	 * INSIDE the comment, so the element vanished while the file still parsed
	 * and stayed byte-canonical. When comments WERE skipped the separator is
	 * spliced right after the last element and the new element on its own line
	 * past the last comment. `line` / `col` are only used for the diagnostics.
	 */
	private static function computeAppendEdit(
		source: String, line: Int, col: Int, containerSpan: Span, containerKind: String, trimmed: String, reformat: Bool,
		plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		var close: Int = containerSpan.to - 1;
		if (close >= source.length) close = source.length - 1;
		while (close >= containerSpan.from && SourceText.isSpace(source.fastCodeAt(close))) close--;
		if (close < containerSpan.from) return Err('the container at $line:$col has no closing delimiter');
		final closeCode: Int = source.fastCodeAt(close);
		if (closeCode != '}'.code && closeCode != ']'.code && closeCode != ')'.code)
			return Err('the node at $line:$col is not a brace / bracket / parenthesis container');

		// Last content byte: scan back from just inside the closing delimiter over
		// whitespace AND whole comment tokens. Skipping comments by TOKEN is what
		// keeps the splice out of comment TEXT: a trailing `// x` otherwise passes
		// for content, and the separator spliced behind it lands inside the comment.
		final scan: { lastContent: Int, afterComments: Int } = scanBackOverTrivia(
			source, containerSpan.from, close, plugin.lexicalRegions(source)
		);
		final lastContent: Int = scan.lastContent;
		final afterComments: Int = scan.afterComments;
		final lastCode: Int = lastContent >= containerSpan.from ? source.fastCodeAt(lastContent) : -1;
		final empty: Bool = isOpenDelimiter(lastCode) || lastContent < containerSpan.from;

		final isComma: Bool = (plugin.refShape().commaContainerKinds ?? []).contains(containerKind);
		// Same statement-into-comma-list refusal as the sibling insert path: a
		// `;`-terminated element never belongs in call arguments / array / object.
		if (isComma && trimmed.endsWith(';'))
			return Err(
				'the element ends with ";" but the container is a comma-separated list (call arguments / array / object) — '
				+ 'to append a STATEMENT to the enclosing block, point --append at the block, not the call'
			);
		final at: Int = lastContent + 1;
		// A comma list written WITH a trailing separator (`['a', 'b',]`) already ends on its `,`: the new
		// element follows it and takes the trailing separator over, instead of doubling it (`,, x`).
		final trailingSeparator: Bool = isComma && !empty && lastCode == ','.code;
		if (afterComments < 0) {
			final edit: Splice = { span: new Span(at, at), text: appendedText(trimmed, empty, trailingSeparator, isComma) };
			return CanonicalEdit.canonicalize(source, [edit], reformat, plugin, optsJson);
		}

		// Trailing comments sit between the last element and the closing delimiter.
		// The separator has to stay attached to that element — a `,` written after a
		// LINE comment would be swallowed by it — and the new element goes on its own
		// line past the last comment, so neither splice lands in comment text.
		final edits: Array<Splice> = [];
		if (!empty && isComma && !trailingSeparator) edits.push({ span: new Span(at, at), text: ',' });
		edits.push({ span: new Span(afterComments, afterComments), text: trailingSeparator ? '\n$trimmed,' : '\n$trimmed' });
		return CanonicalEdit.canonicalize(source, edits, reformat, plugin, optsJson);
	}

	/**
	 * The text `computeAppendEdit` splices right after a container's last content byte: the element bare
	 * into an empty container, after the existing trailing separator (and taking it over), after a new `,`,
	 * or on a line of its own.
	 */
	private static function appendedText(trimmed: String, empty: Bool, trailingSeparator: Bool, isComma: Bool): String {
		return if (empty)
			trimmed
		else if (trailingSeparator)
			' $trimmed,'
		else if (isComma)
			', $trimmed'
		else
			'\n$trimmed';
	}

	/**
	 * The elements of the array `container` as sorted-list entries, or `Left` naming why it is no sorted
	 * set: an element that is no constant string, or one that does not sort strictly after the one before.
	 */
	private static function sortedElements(
		container: QueryNode, source: String, fold: StringFoldSupport
	): Either<String, Array<SortedEntry>> {
		final out: Array<SortedEntry> = [];
		for (child in container.children) {
			final entry: Null<SortedEntry> = sortedEntryOf(child, source, fold);
			if (entry == null)
				return Left('${elementText(child, source)} is not a constant string — --sorted orders string entries only; use --append');
			final last: Null<SortedEntry> = out.length == 0 ? null : out[out.length - 1];
			if (last != null && last.key >= entry.key)
				return Left(
					'the array is not sorted without duplicates (${last.text} before ${entry.text}'
					+ ') — --sorted keeps a sorted set; use --append'
				);
			out.push(entry);
		}
		return Right(out);
	}

	/**
	 * One splice per gap of `existing` that receives entries, the gap's entries joined in order: before the
	 * first existing element sorting after them — clear of that element's leading doc, as `addElement`
	 * `Before` does — after the last element, or into the empty array at `containerSpan`.
	 */
	private static function gapEdits(
		source: String, containerSpan: Span, existing: Array<SortedEntry>, entries: Array<SortedEntry>, plugin: GrammarPlugin
	): Array<Splice> {
		final byGap: Array<Array<String>> = [for (_ in 0...existing.length + 1) []];
		for (entry in entries) {
			final at: Int = existing.findIndex(e -> e.key > entry.key);
			byGap[at < 0 ? existing.length : at].push(entry.text);
		}
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		return [
			for (gap => batch in byGap) if (batch.length > 0) {
				final joined: String = batch.join(', ');
				final at: Int = if (existing.length == 0)
					SourceText.firstTokenEnd(source, containerSpan.from)
				else if (gap == existing.length)
					existing[gap - 1].span.to
				else
					ElementSpan.docExtendedSpan(source, existing[gap].span, regions, true).from;
				final text: String = if (existing.length == 0)
					joined
				else if (gap == existing.length)
					', $joined'
				else
					'$joined, ';
				{ span: new Span(at, at), text: text };
			}
		];
	}

	/**
	 * The new entries of `insertSorted`, split by the parser: `trimmed` is spliced at the FRONT of the
	 * array at `containerSpan` (which holds `existingCount` elements) in a probe text, the probe is parsed,
	 * and the array's leading children past the old count are read back with their source. `Left` names
	 * why that failed — the probe does not parse, an entry is no constant string, or nothing was added.
	 */
	private static function parsedEntries(
		source: String, containerSpan: Span, existingCount: Int, trimmed: String, plugin: GrammarPlugin, arrayKind: String,
		fold: StringFoldSupport
	): Either<String, Array<SortedEntry>> {
		final open: Int = SourceText.firstTokenEnd(source, containerSpan.from);
		final probe: String = source.substring(0, open) + trimmed + (existingCount > 0 ? ', ' : '') + source.substring(open);
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, probe);
		final array: Null<QueryNode> = tree == null ? null : nodeAt(tree, containerSpan.from, arrayKind);
		if (array == null) return Left('the entries do not parse as elements of the array: $trimmed');
		final added: Int = array.children.length - existingCount;
		if (added <= 0) return Left('the entries add no element to the array: $trimmed');
		final out: Array<SortedEntry> = [];
		for (child in array.children.slice(0, added)) {
			final entry: Null<SortedEntry> = sortedEntryOf(child, probe, fold);
			if (entry == null) return Left('${elementText(child, probe)} is not a constant string — --sorted inserts string entries only');
			out.push(entry);
		}
		return Right(out);
	}

	/** The node of `kind` starting at `from` in `tree`, or null. */
	private static function nodeAt(tree: QueryNode, from: Int, kind: String): Null<QueryNode> {
		if (tree.kind == kind && tree.span?.from == from) return tree;
		for (c in tree.children) {
			final hit: Null<QueryNode> = nodeAt(c, from, kind);
			if (hit != null) return hit;
		}
		return null;
	}

	/** `node` as a sorted-list entry — its sort key, span and source text — or null when it is no constant string (`sortKeyOf`). */
	private static function sortedEntryOf(node: QueryNode, source: String, fold: StringFoldSupport): Null<SortedEntry> {
		final span: Null<Span> = node.span;
		final key: Null<String> = sortKeyOf(node, source, fold);
		return span == null || key == null ? null : { key: key, span: span, text: source.substring(span.from, span.to) };
	}

	/**
	 * The string VALUE of a constant string element: a plain literal (`StringFoldSupport.literalOf`) or a
	 * concatenation of them (`StringFoldSupport.concatKind`), the spelling an entry too wide for its line
	 * takes. Null for anything else — and for content holding a `\` or a `$`, whose raw text is not its value
	 * (an escape, an interpolation), so its position would be a guess.
	 */
	private static function sortKeyOf(node: QueryNode, source: String, fold: StringFoldSupport): Null<String> {
		final literal: Null<StringLiteral> = fold.literalOf(node, source);
		if (literal != null) return literal.content.contains('\\') || literal.content.contains('$$') ? null : literal.content;
		if (node.kind != fold.concatKind() || node.children.length != 2) return null;
		final left: Null<String> = sortKeyOf(node.children[0], source, fold);
		if (left == null) return null;
		final right: Null<String> = sortKeyOf(node.children[1], source, fold);
		return right == null ? null : '$left$right';
	}

	/** The source text of `node`, for a diagnostic. */
	private static function elementText(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? node.kind : source.substring(span.from, span.to);
	}

	/** `text` without one trailing `,` — an entry list copied out of an array keeps its separator. */
	private static function withoutTrailingComma(text: String): String {
		return text.endsWith(',') ? text.substr(0, text.length - 1).rtrim() : text;
	}

}

/** One element of a sorted string list (`AddElement.insertSorted`): its string value, its span and its source text. */
private typedef SortedEntry = {
	final key: String;
	final span: Span;
	final text: String;
}

/** One splice of an insert: the text `CanonicalEdit.canonicalize` puts at `span`. */
private typedef Splice = { span: Span, text: String };
