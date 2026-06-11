package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Outcome of a `RemoveParam.removeParam` call. `Ok` carries the
 * format-preserving rewritten source plus an optional advisory (a
 * non-fatal note printed to stderr — the cross-file caveat for a method
 * whose out-of-file callers cannot be seen); `Err` carries a
 * human-readable diagnostic (cursor not on a function, an out-of-range
 * index, a parameter still used in the body, an unresolvable /
 * receiver-qualified call site, an arity mismatch, a post-rewrite
 * re-parse failure). Modelled as a sum type so the CLI maps it to stdout
 * vs. stderr + a non-zero exit without a sentinel-string convention.
 * Mirrors `ChangeSigResult` (methods carry the cross-file advisory).
 */
enum RemoveParamResult {

	Ok(text: String, advisory: Null<String>);
	Err(message: String);

}

/**
 * Scope-correct, format-preserving remove-parameter — the fifth
 * refactoring operation built on the query engine, the inverse of
 * `AddParam`.
 *
 * Given a cursor on a function declaration (or a resolvable bare call to
 * it) and a 0-based parameter index, the removal:
 *
 *  1. Parses the source and inverts the printed `apq refs` column to a
 *     raw offset, identically to `Rename` / `Inline` / `ExtractVar` /
 *     `ChangeSig`.
 *  2. Resolves the function declaration at `line:col` through the shared
 *     `CallSites.resolveFnDecl` (cursor-on-decl returns it directly;
 *     cursor-on-call resolves the binding via `Refs`), refusing a cursor
 *     that is not on a function.
 *  3. Reads the parameters — the leading `Required` / `Optional` children
 *     of the decl — and refuses an out-of-range index.
 *  4. SAFETY GUARD: refuses if the removed parameter is still referenced
 *     in the function body (or in a later parameter's default value).
 *     Removing a used parameter produces code that references an
 *     undefined identifier — a TYPING error the re-parse cannot catch — so
 *     it is refused outright rather than left broken.
 *  5. Collects every in-file call site and PROVES the set is complete via
 *     the shared `CallSites.collect`. Unlike `AddParam` (decl-only,
 *     backward-compat-safe), removing a parameter BREAKS calls — its
 *     failure mode is SILENT (a missed call keeps the now-deleted
 *     argument) — so any call that cannot be proven to target this
 *     function is a hard refusal, with the SAME completeness proof
 *     `ChangeSig` uses.
 *  6. Requires every call to have exactly `n` positional arguments (a
 *     call with omitted optional / defaulted arguments cannot have its
 *     slot removed unambiguously).
 *  7. SLOT-REMOVAL splice: deletes parameter `index` from the decl and
 *     argument `index` from every call, removing the corresponding
 *     separating comma so the surviving list stays well-formed.
 *  8. Re-parses the result; an unparseable rewrite is rejected.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (`Span.lineCol().col - 1`), identical to the
 * sibling operations.
 */
@:nullSafety(Strict)
final class RemoveParam {

	/**
	 * Remove the parameter at 0-based `index` from the function whose decl
	 * / binding is at `line:col` in `source`, deleting the corresponding
	 * positional argument at every resolvable in-file call site. `plugin`
	 * / `shape` are the caller-owned grammar plugin and its `RefShape`
	 * (the same pair the `refs` CLI builds), so the resolver stays
	 * language-agnostic. Returns `Ok(rewritten, advisory)` or an `Err`
	 * describing why the removal could not be applied. The source is never
	 * mutated — the caller decides whether to write the result.
	 */
	public static function removeParam(
		source: String, line: Int, col: Int, index: Int, plugin: GrammarPlugin, shape: RefShape
	): RemoveParamResult {
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

		final declNode: Null<QueryNode> = CallSites.resolveFnDecl(cursorNode, tree, name, shape);
		if (declNode == null) return Err('could not resolve a function binding for "$name" at $line:$col');
		final decl: QueryNode = declNode;
		if (!RefactorSupport.FN_DECL_KINDS.contains(decl.kind))
			return Err('"$name" is not a function (remove-param removes a function parameter)');
		final declSpan: Null<Span> = decl.span;
		if (declSpan == null) return Err('"$name" declaration has no source span');
		final binding: Int = declSpan.from;

		final params: Array<QueryNode> = CallSites.leadingParams(decl);
		final n: Int = params.length;
		if (index < 0 || index >= n) return Err('parameter index $index is out of range 0..${n - 1} — "$name" has $n parameter(s)');
		final target: QueryNode = params[index];
		final paramNameOpt: Null<String> = target.name;
		if (paramNameOpt == null) return Err('parameter at index $index of "$name" has no name slot — cannot prove it is unused');
		final paramName: String = paramNameOpt;

		// SAFETY GUARD: refuse if the parameter is still referenced inside
		// the function declaration's subtree (its body, or a later
		// parameter's default value). The parameter declaration node is a
		// `Required` / `Optional`, NOT an identifier-reference node, so it
		// contributes no reference of its own name — any reference named
		// `paramName` in the decl subtree is a genuine use whose binding
		// would become undefined after removal (a typing error the re-parse
		// cannot catch). Both bare `IdentExpr` reads AND string-interpolation
		// `Ident` nodes (`'$paramName'`) count — the interpolation form is
		// easy to miss because it is not an `IdentExpr`. Conservative by
		// design: over-refusing is safe.
		if (countParamRefs(decl, paramName) > 0) return Err('parameter "$paramName" is still used in the body — remove its uses first');

		// Collect the call sites and prove the set is complete — the SAME
		// completeness proof `change-sig` uses, because removing a
		// parameter silently breaks any call we fail to update.
		final isMethod: Bool = decl.kind != 'LocalFnStmt';
		final callSites: Array<QueryNode> = switch CallSites.collect(decl, tree, source, name, binding, shape) {
			case CErr(message): return Err(message);
			case COk(sites): sites;
		};

		// Arity: every collected call must have exactly `n` positional
		// arguments. A call with omitted optional / defaulted arguments
		// cannot have its slot removed unambiguously, so it is a hard
		// refusal rather than a silent mis-deletion.
		for (call in callSites) {
			final argc: Int = call.children.length - 1;
			if (argc != n) {
				final at: String = CallSites.posOf(source, call.span);
				return Err('call at $at has $argc args, expected $n — remove-param cannot update calls with omitted optional arguments');
			}
		}

		// Build the slot-removal edits: delete parameter `index` from the
		// decl and argument `index` from every call.
		final edits: Array<{ span: Span, text: String }> = [];
		appendSlotRemoval(edits, source, params, index);
		for (call in callSites) {
			final args: Array<QueryNode> = call.children.slice(1);
			appendSlotRemoval(edits, source, args, index);
		}

		final rewritten: String = RefactorSupport.applyEdits(source, edits);
		if (rewritten == source) return Err('removing parameter $index of "$name" is a no-op');

		try
			plugin.parseFile(rewritten)
		catch (exception: ParseError)
			return Err('rewritten source does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten source does not parse: ${exception.message}');

		final advisory: Null<String> = isMethod
			? 'removed the parameter and updated ${callSites.length} in-file call site(s); if "$name" is called from other files, update those call sites too — cross-file resolution is out of scope'
			: null;
		return Ok(rewritten, advisory);
	}

	/**
	 * Append the single edit that deletes slot `index` from `slots`,
	 * removing the corresponding separating comma so the surviving list
	 * stays well-formed. Removal range for a slot list `s[0..n-1]`:
	 *
	 *  - `n == 1`: delete `[s[0].from, s[0].to)` — the lone slot; the
	 *    delimiters `()` stay (an empty parameter / argument list).
	 *  - `index == 0` (n>1): delete `[s[0].from, s[1].from)` — the slot
	 *    plus the FOLLOWING comma + inter-slot whitespace.
	 *  - `index > 0`: delete `[s[index-1].to, s[index].to)` — the PRECEDING
	 *    comma + inter-slot whitespace plus the slot.
	 *
	 * A null span on either the target or the adjacency anchor aborts the
	 * edit (no removal pushed) rather than splicing a wrong range.
	 */
	private static function appendSlotRemoval(
		edits: Array<{ span: Span, text: String }>, source: String, slots: Array<QueryNode>, index: Int
	): Void {
		final n: Int = slots.length;
		final targetSpan: Null<Span> = slots[index].span;
		if (targetSpan == null) return;
		final target: Span = targetSpan;

		final range: Null<Span> = if (n == 1)
			new Span(target.from, target.to);
		else if (index == 0) {
			final nextSpan: Null<Span> = slots[1].span;
			nextSpan == null ? null : new Span(target.from, nextSpan.from);
		} else {
			final prevSpan: Null<Span> = slots[index - 1].span;
			prevSpan == null ? null : new Span(prevSpan.to, target.to);
		}
		if (range == null) return;
		edits.push({ span: range, text: '' });
	}

	/**
	 * Count identifier references named `name` anywhere in `node`'s subtree
	 * — bare `IdentExpr` reads AND string-interpolation `Ident` nodes
	 * (`'$name'`), both of which become an undefined reference if the
	 * parameter is removed. Braced interpolation (`'${name}'`) nests an
	 * `IdentExpr` inside a `Block`, so it is already covered by the
	 * `IdentExpr` arm; double-quoted `"$name"` is a literal (no interpolation
	 * in Haxe) and correctly contributes nothing.
	 */
	private static function countParamRefs(node: QueryNode, name: String): Int {
		var count: Int = 0;
		function walk(n: QueryNode): Void {
			if ((n.kind == 'IdentExpr' || n.kind == 'Ident') && n.name == name) count++;
			for (c in n.children) walk(c);
		}
		walk(node);
		return count;
	}

}
