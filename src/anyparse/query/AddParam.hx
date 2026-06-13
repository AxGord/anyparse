package anyparse.query;

import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Outcome of an `AddParam.addParam` call. `Ok` carries the
 * format-preserving rewritten source; `Err` carries a human-readable
 * diagnostic (cursor not on a function, a required parameter rejected by
 * the backward-compat guard, a name collision, a post-rewrite re-parse
 * failure). Modelled as a sum type so the CLI maps it to stdout vs.
 * stderr + a non-zero exit without a sentinel-string convention. Mirrors
 * `ExtractResult`.
 */
enum AddParamResult {

	Ok(text: String);
	Err(message: String);

}

/**
 * Add a trailing parameter to a function declaration — a deliberately
 * DECL-ONLY refactoring operation built on the query engine.
 *
 * Given a cursor on a function declaration and the full source text of a
 * new parameter, the operation:
 *
 *  1. Parses the source and inverts the printed `apq refs` column to a
 *     raw offset, identically to `Rename` / `Inline` / `ExtractVar`.
 *  2. Resolves the innermost `FnMember` (method) / `FinalModifiedMember`
 *     (`final` method) / `LocalFnStmt` (local function) whose span
 *     contains the cursor.
 *  3. Verifies the new parameter is BACKWARD-COMPATIBLE — it must be
 *     optional (`?name:T`) or defaulted (`name:T = v`). A required
 *     parameter is refused.
 *  4. Refuses a name that already names a parameter of the function.
 *  5. Inserts the parameter text at the param-list tail (after the last
 *     existing parameter, or just inside the `(` for a zero-param
 *     function) as a single splice.
 *  6. Re-parses the result; an unparseable rewrite is rejected — the
 *     hard gate that catches a malformed parameter text.
 *
 * WHY DECL-ONLY IS SAFE — and why no call site is touched: the
 * backward-compat guard is the load-bearing invariant. Because the new
 * parameter is always optional or defaulted, every existing call site
 * that omitted it continues to compile unchanged — there is no
 * type-wall and no arity mismatch to repair. A required parameter would
 * break those call sites, so it is refused outright rather than silently
 * leaving the codebase broken. This is what makes the operation safe for
 * ANY function (methods, local functions, callbacks) without resolving a
 * single call site: there is nothing at the call sites to update.
 *
 * The operation is purely textual at the insertion point — it preserves
 * the existing parameter-list formatting (single-line, trailing-comma,
 * or multi-line) and only adds the new parameter. The re-parse is the
 * backstop for a syntactically invalid parameter text.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (`Span.lineCol().col - 1`), identical to
 * `Rename` / `Inline` / `ExtractVar`.
 */
@:nullSafety(Strict)
final class AddParam {

	/** Parameter-node kinds in a function declaration's leading children. */
	private static final PARAM_KINDS: Array<String> = ['Required', 'Optional'];

	/**
	 * Add `paramText` as a new trailing parameter to the function whose
	 * declaration is at `line:col` in `source`. `plugin` is the
	 * caller-owned grammar plugin (the same the `refs` CLI builds), so the
	 * operation stays language-agnostic. Returns `Ok(rewritten)` or an
	 * `Err` describing why the parameter could not be added. The source is
	 * never mutated — the caller decides whether to write the result.
	 */
	public static function addParam(source: String, line: Int, col: Int, paramText: String, plugin: GrammarPlugin): AddParamResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final fn: Null<QueryNode> = RefactorSupport.innermostWhere(tree, cursor, node -> RefactorSupport.FN_DECL_KINDS.contains(node.kind));
		if (fn == null) return Err('position $line:$col is not on a function');
		final fnNode: QueryNode = fn;
		final fnSpan: Null<Span> = fnNode.span;
		if (fnSpan == null) return Err('position $line:$col is not on a function');
		final declSpan: Span = fnSpan;

		// Backward-compat guard: a required parameter would break existing
		// call sites. Accept only an optional (`?name:T`) or defaulted
		// (`name:T = v`) parameter. The textual check (leading `?` or a
		// top-level `=`) is intentionally simple — the re-parse-validate is
		// the backstop. A `=` buried inside the parameter's type is
		// acceptable; it still satisfies "has a default" textually.
		final trimmed: String = StringTools.trim(paramText);
		if (trimmed.length == 0) return Err('add-param requires a non-empty parameter text');
		if (!StringTools.startsWith(trimmed, '?') && trimmed.indexOf('=') < 0)
			return
				Err(
					'add-param requires a default value (`name:T = v`) or optional `?name:T` — a required parameter would break existing call sites'
				);

		final paramName: Null<String> = parseParamName(trimmed);
		if (paramName == null) return Err('cannot read a parameter name from "$paramText"');
		final newName: String = paramName;

		final params: Array<QueryNode> = [for (c in fnNode.children) if (PARAM_KINDS.contains(c.kind)) c];
		if (Lambda.exists(params, p -> p.name == newName)) return Err('"$newName" is already a parameter');

		final insertOffset: Int = if (params.length > 0)
			tailInsertOffset(source, params[params.length - 1])
		else
			emptyParenInsertOffset(source, declSpan);
		if (insertOffset < 0) return Err('could not locate the parameter list of the function at $line:$col');

		final insertText: String = params.length > 0 ? ', ' + trimmed : trimmed;
		final edit: { span: Span, text: String } = {
			span: new Span(insertOffset, insertOffset),
			text: insertText,
		};

		final rewritten: String = RefactorSupport.applyEdits(source, [edit]);
		if (rewritten == source) return Err('adding "$newName" is a no-op');

		try
			plugin.parseFile(rewritten)
		catch (exception: ParseError)
			return Err('rewritten source does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten source does not parse: ${exception.message}');

		return Ok(rewritten);
	}

	/**
	 * The parameter name carried by `paramText`: the leading identifier
	 * after an optional `?` (and any leading whitespace). `?flag:Bool` →
	 * `flag`, `count:Int = 0` → `count`. Null when no identifier starts
	 * there.
	 */
	private static function parseParamName(paramText: String): Null<String> {
		var i: Int = 0;
		while (i < paramText.length && RefactorSupport.isSpace(StringTools.fastCodeAt(paramText, i))) i++;
		if (i < paramText.length && StringTools.fastCodeAt(paramText, i) == '?'.code) i++;
		while (i < paramText.length && RefactorSupport.isSpace(StringTools.fastCodeAt(paramText, i))) i++;
		final start: Int = i;
		if (i >= paramText.length || !RefactorSupport.isIdentStartChar(StringTools.fastCodeAt(paramText, i))) return null;
		i++;
		while (i < paramText.length && RefactorSupport.isIdentChar(StringTools.fastCodeAt(paramText, i))) i++;
		return paramText.substring(start, i);
	}

	/**
	 * Insertion offset for a function that already has parameters: the end
	 * of the last parameter's CONTENT (its `span.to` walked back over
	 * trailing whitespace, so a multi-line parameter list does not glue
	 * the new parameter onto the closing-paren line). Verified to be at
	 * the parameter-list tail — the next significant character from the
	 * last parameter's `span.to` must be `)` or a trailing `,` then `)`.
	 * Returns -1 when that tail check fails.
	 */
	private static function tailInsertOffset(source: String, lastParam: QueryNode): Int {
		final span: Null<Span> = lastParam.span;
		if (span == null) return -1;
		final spanTo: Int = span.to;

		// Tail check: from the last parameter's span end, the next
		// significant character closes the list (`)`) — optionally after a
		// trailing comma. Anything else means the resolved node is not the
		// final parameter and the insertion would be unsafe.
		var j: Int = spanTo;
		while (j < source.length && RefactorSupport.isSpace(StringTools.fastCodeAt(source, j))) j++;
		if (j < source.length && StringTools.fastCodeAt(source, j) == ','.code) {
			j++;
			while (j < source.length && RefactorSupport.isSpace(StringTools.fastCodeAt(source, j))) j++;
		}
		if (j >= source.length || StringTools.fastCodeAt(source, j) != ')'.code) return -1;

		// Insert right after the parameter content: trim trailing
		// whitespace included in the span (multi-line parameter lists carry
		// the newline / indentation up to the next token in the span).
		var k: Int = spanTo;
		while (k > span.from && RefactorSupport.isSpace(StringTools.fastCodeAt(source, k - 1))) k--;
		return k;
	}

	/**
	 * Insertion offset for a zero-parameter function: just inside the `(`
	 * that opens the parameter list. The decl span starts at the
	 * `function` keyword, so the first `(` at / after the span start opens
	 * the parameter list (an empty `()` becomes `(paramText)`). The scan
	 * is bounded by the declaration span so a `(` in a body / return type
	 * is never reached. Returns -1 when no `(` is found.
	 */
	private static function emptyParenInsertOffset(source: String, declSpan: Span): Int {
		final to: Int = declSpan.to <= source.length ? declSpan.to : source.length;
		var i: Int = declSpan.from < 0 ? 0 : declSpan.from;
		while (i < to) {
			if (StringTools.fastCodeAt(source, i) == '('.code) return i + 1;
			i++;
		}
		return -1;
	}

}
