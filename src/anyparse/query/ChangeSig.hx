package anyparse.query;

import anyparse.query.CallSites.CollectResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Outcome of a `ChangeSig.changeSig` call. `Ok` carries the
 * format-preserving rewritten source plus an optional advisory (a
 * non-fatal note printed to stderr — e.g. the cross-file caveat for a
 * method whose out-of-file callers cannot be seen); `Err` carries a
 * human-readable diagnostic (cursor not on a function, a non-permutation
 * argument, an unresolvable / receiver-qualified call site, an arity
 * mismatch, a post-rewrite re-parse failure). Modelled as a sum type so
 * the CLI maps it to stdout vs. stderr + a non-zero exit without a
 * sentinel-string convention. Mirrors `ExtractResult` / `InlineResult`.
 */
enum ChangeSigResult {

	Ok(text: String, advisory: Null<String>);
	Err(message: String);

}

/**
 * Scope-correct, format-preserving change-signature (parameter reorder)
 * — the fourth refactoring operation built on the query engine, the
 * sibling of `Rename` / `Inline` / `ExtractVar`.
 *
 * Given a cursor on a function declaration (or a resolvable bare call to
 * it), the reorder:
 *
 *  1. Parses the source and inverts the printed `apq refs` column to a
 *     raw offset, identically to `Rename` / `Inline` / `ExtractVar`.
 *  2. Resolves the function declaration at `line:col`. A cursor that
 *     lands directly on a `FnMember` (method), `FinalModifiedMember`
 *     (`final` method), or `LocalFnStmt` (named local function) decl IS
 *     the declaration; a cursor on a bare `name(...)` call resolves back
 *     to the method decl through the shared `Refs` binding resolver. This
 *     resolution and the call-site collection live in the shared
 *     `CallSites` so `RemoveParam` proves the same completeness invariant.
 *  3. Reads the function's parameters — the leading `Required` /
 *     `Optional` children of the decl, in source order (the trailing
 *     `Named` return-type child and the body are excluded).
 *  4. Validates `<perm>` as a true permutation of `0..n-1` and rejects
 *     the identity (a no-op).
 *  5. Collects every in-file call site and PROVES the set is complete —
 *     change-signature's failure mode is SILENT (a missed call keeps the
 *     old argument order against the new parameters), so any call that
 *     cannot be proven to target this function is a hard refusal.
 *  6. Overwrites each parameter / argument slot's span with the source
 *     text of the item that moves there (a SLOT SWAP: only the slot
 *     contents move; the commas and whitespace between slots stay put,
 *     so the existing layout is preserved verbatim).
 *  7. Re-parses the result; an unparseable rewrite is rejected.
 *
 * Call-site collection differs by declaration kind (`CallSites` routes
 * method vs. local-function) — see `CallSites` for the two strategies and
 * exactly what each accepts and refuses.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (`Span.lineCol().col - 1`), identical to
 * `Rename` / `Inline` / `ExtractVar`.
 */
@:nullSafety(Strict)
final class ChangeSig {

	/**
	 * Reorder the parameters of the function whose decl / binding is at
	 * `line:col` in `source` per `perm`, permuting the positional
	 * arguments at every resolvable call site to match. `perm` is a
	 * comma-separated 0-based list giving the NEW order of OLD parameter
	 * indices (for `g(a, b, c)`, `2,0,1` reorders to `c, a, b`). `plugin`
	 * / `shape` are the caller-owned grammar plugin and its `RefShape`
	 * (the same pair the `refs` CLI builds), so the resolver stays
	 * language-agnostic. Returns `Ok(rewritten, advisory)` or an `Err`
	 * describing why the reorder could not be applied. The source is never
	 * mutated — the caller decides whether to write the result.
	 */
	public static function changeSig(
		source: String, line: Int, col: Int, perm: String, plugin: GrammarPlugin, shape: RefShape
	): ChangeSigResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here so a
		// position copied from `refs` output maps back to the real offset.
		final cursor: Int = Span.offsetOf(source, line, col + 1);

		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return Err('position $line:$col is not on a function or a call');
		final cursorNode: QueryNode = node;
		final targetName: Null<String> = cursorNode.name;
		if (targetName == null) return Err('position $line:$col is not on a function or a call');
		final name: String = targetName;

		// Resolve the function declaration node. A cursor already on a
		// function decl IS that decl; otherwise (a bare call) resolve the
		// binding back to the decl through the shared resolver — this works
		// for methods (indexed by `Refs`) but not for local functions
		// reached via a call.
		final declNode: Null<QueryNode> = CallSites.resolveFnDecl(cursorNode, tree, name, shape);
		if (declNode == null) return Err('could not resolve a function binding for "$name" at $line:$col');
		final decl: QueryNode = declNode;
		if (!RefactorSupport.FN_DECL_KINDS.contains(decl.kind))
			return Err('"$name" is not a function (change-sig reorders function parameters)');
		final declSpan: Null<Span> = decl.span;
		if (declSpan == null) return Err('"$name" declaration has no source span');
		final binding: Int = declSpan.from;

		// Parameters: the leading Required / Optional children, in source
		// order. The scan stops at the first child that is neither (the
		// `Named` return type or the body).
		final params: Array<QueryNode> = CallSites.leadingParams(decl);
		final n: Int = params.length;
		if (n < 2) return Err('"$name" has fewer than 2 parameters — nothing to reorder');

		final order: Array<Int> = switch parsePerm(perm, n) {
			case POk(o): o;
			case PErr(message): return Err(message);
		};

		// Collect the call sites and prove the set is complete. The two
		// strategies (method vs. local function) live in `CallSites`.
		final isMethod: Bool = decl.kind != 'LocalFnStmt';
		final callSites: Array<QueryNode> = switch CallSites.collect(decl, tree, source, name, binding, shape) {
			case CErr(message): return Err(message);
			case COk(sites): sites;
		};

		// Arity: every collected call must have exactly `n` positional
		// arguments. A call with omitted optional / defaulted arguments
		// cannot be slot-swapped, so it is a hard refusal rather than a
		// silent misorder.
		for (call in callSites) {
			final argc: Int = call.children.length - 1;
			if (argc != n) {
				final at: String = CallSites.posOf(source, call.span);
				return Err('call at $at has $argc args, expected $n — change-sig cannot reorder calls with omitted optional arguments');
			}
		}

		// Build the slot-swap edits. Each new slot `i` is overwritten with
		// the source text of the item that the permutation moves into it
		// (`order[i]`). All spans are disjoint, so the splice is order-free.
		final edits: Array<{ span: Span, text: String }> = [];
		appendSlotSwap(edits, source, params, order);
		for (call in callSites) {
			final args: Array<QueryNode> = call.children.slice(1);
			appendSlotSwap(edits, source, args, order);
		}

		final rewritten: String = RefactorSupport.applyEdits(source, edits);
		if (rewritten == source) return Err('reorder of "$name" is a no-op');

		try
			plugin.parseFile(rewritten)
		catch (exception: ParseError)
			return Err('rewritten source does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten source does not parse: ${exception.message}');

		final advisory: Null<String> = isMethod
			? 'updated the declaration and ${callSites.length} in-file call site(s); if "$name" is called from other files, update those call sites too — cross-file resolution is out of scope'
			: null;
		return Ok(rewritten, advisory);
	}

	/**
	 * Append a slot-swap edit set: for each destination slot `i`, overwrite
	 * `slots[i].span` with the verbatim source text of `slots[order[i]]`.
	 * Only the slot contents move — the separators between slots are left
	 * untouched, so the existing layout is preserved. A no-move slot
	 * (`order[i] == i`) is still emitted; it is a harmless identity splice
	 * and the call-level no-op guard catches a fully-identity reorder.
	 */
	private static function appendSlotSwap(
		edits: Array<{ span: Span, text: String }>, source: String, slots: Array<QueryNode>, order: Array<Int>
	): Void {
		for (i in 0...slots.length) {
			final destSpan: Null<Span> = slots[i].span;
			final srcSpan: Null<Span> = slots[order[i]].span;
			if (destSpan == null || srcSpan == null) continue;
			edits.push({ span: new Span(destSpan.from, destSpan.to), text: source.substring(srcSpan.from, srcSpan.to) });
		}
	}

	/**
	 * Parse `perm` as a true permutation of `0..n-1`: exactly `n`
	 * comma-separated 0-based integers, each in range and all distinct.
	 * Rejects the identity permutation as a no-op. Returns the parsed order
	 * or a diagnostic.
	 */
	private static function parsePerm(perm: String, n: Int): PermResult {
		final parts: Array<String> = perm.split(',');
		if (parts.length != n) return PErr('permutation "$perm" lists ${parts.length} indices but the function has $n parameters');

		final order: Array<Int> = [];
		final seen: Array<Int> = [];
		for (part in parts) {
			final trimmed: String = StringTools.trim(part);
			final idx: Null<Int> = RefactorSupport.parseStrictInt(trimmed);
			if (idx == null) return PErr('permutation "$perm" contains a non-integer index "$trimmed"');
			final value: Int = idx;
			if (value < 0 || value >= n) return PErr('permutation "$perm" index $value is out of range 0..${n - 1}');
			if (seen.contains(value)) return PErr('permutation "$perm" repeats index $value — must be a true permutation');
			seen.push(value);
			order.push(value);
		}

		var identity: Bool = true;
		for (i in 0...n) if (order[i] != i) identity = false;
		if (identity) return PErr('permutation "$perm" is the identity — nothing to reorder');

		return POk(order);
	}

}

/** Parsed permutation or a diagnostic — internal to `ChangeSig`. */
private enum PermResult {

	POk(order: Array<Int>);
	PErr(message: String);

}
