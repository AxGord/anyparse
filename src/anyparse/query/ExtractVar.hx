package anyparse.query;

import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Outcome of an `ExtractVar.extractVar` call. `Ok` carries the
 * format-preserving rewritten source; `Err` carries a human-readable
 * diagnostic (cursor not on an expression start, the enclosing statement
 * not inside a `{ }` block, a post-rewrite re-parse failure). Modelled as
 * a sum type so the CLI maps it to stdout vs. stderr + a non-zero exit
 * without a sentinel-string convention. Mirrors `InlineResult`.
 */
enum ExtractResult {
	Ok(text:String);
	Err(message:String);
}

/**
 * Scope-correct, format-preserving extract-variable — the third
 * refactoring operation built on the query engine, the inverse of
 * `Inline`.
 *
 * Given a cursor on the START of an expression, the extract:
 *
 *  1. Parses the source and inverts the printed `apq refs` column to a
 *     raw offset, identically to `Rename` / `Inline`.
 *  2. Selects the OUTERMOST expression node whose `span.from` equals the
 *     cursor — the expression with the maximum `span.to` among the
 *     expression-kind nodes starting there (structural nodes —
 *     statements, declarations, members, param wrappers — are excluded).
 *  3. Hoists that expression into a fresh `final <name> = <expr>;`
 *     inserted on its own line immediately before the nearest enclosing
 *     block-level statement, at that statement's indentation, and
 *     replaces the expression occurrence at the cursor with `<name>`.
 *  4. Re-parses the result; an unparseable rewrite is rejected.
 *
 * The enclosing statement must be a DIRECT CHILD of a `{ }` block
 * container (a function body or a nested brace block). The hoist is
 * therefore refused when the target's nearest statement ancestor is not
 * a block child — e.g. an expression buried in a braceless
 * `if (c) return expr;` then-branch, whose `ReturnStmt` parent is the
 * `IfStmt`, not a block. Extracting the CONDITION of such an `if` / `while`
 * is allowed, because the `IfStmt` / `WhileStmt` that owns the condition
 * IS a block child.
 *
 * No parenthesisation is needed: the hoisted decl is a fresh assignment
 * context and the use-site replacement is a bare identifier. The temp is
 * declared `final` — it is single-assignment, matching the project's
 * immutability default — and carries no type annotation (Haxe infers).
 * A single occurrence is replaced; replace-all is out of scope. A
 * type-ambiguous extraction (bare `[]` / `null`) is a documented
 * syntactic-tool limitation — type inference is not attempted.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (`Span.lineCol().col - 1`), identical to
 * `Rename` / `Inline`.
 */
@:nullSafety(Strict)
final class ExtractVar {

	/**
	 * Node kinds that are STRUCTURAL — never a valid extraction target.
	 * The exclusion is suffix-based so the few literal members below cover
	 * only the kinds that have no distinguishing suffix. A node is
	 * structural when its kind ends with one of `STRUCTURAL_SUFFIXES` or
	 * equals one of these literals; everything else (operators, calls,
	 * literals, identifiers, field/index access, collections, `new`,
	 * ternaries, …) is an expression and eligible.
	 */
	private static final STRUCTURAL_KINDS:Array<String> = ['module', 'Module', 'Body', 'ClassDecl'];

	/**
	 * Kind suffixes that mark a node as structural (statements,
	 * declarations, members, fields, param wrappers). A target whose kind
	 * ends with any of these is excluded from selection.
	 */
	private static final STRUCTURAL_SUFFIXES:Array<String> = [
		'Stmt', 'Member', 'Field', 'Decl', 'Named', 'Required', 'Optional',
	];

	/**
	 * Block-container kinds: a `{ }` block whose direct children are
	 * statements. A function body parses as `BlockBody`; a nested brace
	 * block (loop / branch / bare block) parses as `BlockStmt`. The
	 * enclosing statement must be a direct child of one of these for the
	 * hoist to be safe.
	 */
	private static final BLOCK_KINDS:Array<String> = ['BlockBody', 'BlockStmt'];

	/**
	 * Extract the expression starting at `line:col` in `source` into a
	 * fresh `final <name> = <expr>;` hoisted before the enclosing
	 * block-level statement, replacing the occurrence with `name`.
	 * `plugin` is the caller-owned grammar plugin (the same the `refs` CLI
	 * builds), so the operation stays language-agnostic. Returns
	 * `Ok(rewritten)` or an `Err` describing why the extraction could not
	 * be applied. The source is never mutated — the caller decides whether
	 * to write the result.
	 */
	public static function extractVar(source:String, line:Int, col:Int, name:String, plugin:GrammarPlugin):ExtractResult {
		if (!RefactorSupport.isIdentifier(name))
			return Err('new name "$name" is not a valid identifier');

		final tree:QueryNode = try plugin.parseFile(source)
			catch (exception:ParseError) return Err('source does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('source does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here so a
		// position copied from `refs` output maps back to the real offset.
		final cursor:Int = Span.offsetOf(source, line, col + 1);

		final target:Null<QueryNode> = selectTargetExpr(tree, cursor);
		if (target == null)
			return Err('no expression starts at position $line:$col (point at the first token of an expression)');
		final expr:QueryNode = target;
		final exprSpan:Null<Span> = expr.span;
		if (exprSpan == null)
			return Err('no expression starts at position $line:$col (point at the first token of an expression)');
		final targetSpan:Span = exprSpan;

		final enclosingStmt:Null<QueryNode> = findEnclosingBlockStmt(tree, expr);
		if (enclosingStmt == null)
			return Err('"$name": cannot extract — the enclosing statement is not inside a { } block');
		final stmt:QueryNode = enclosingStmt;
		final stmtSpan:Null<Span> = stmt.span;
		if (stmtSpan == null)
			return Err('"$name": cannot extract — the enclosing statement has no source span');
		final hoistSpan:Span = stmtSpan;

		// The hoisted decl is inserted at the start of the enclosing
		// statement's line, carrying that statement's leading indentation.
		final lineStart:Int = lineStartOf(source, hoistSpan.from);
		final indent:String = source.substring(lineStart, hoistSpan.from);
		if (!isAllWhitespace(indent))
			return Err('"$name": enclosing statement shares its line — cannot extract cleanly');

		final exprText:String = source.substring(targetSpan.from, targetSpan.to);

		final insertEdit:{span:Span, text:String} = {
			span: new Span(lineStart, lineStart),
			text: indent + 'final ' + name + ' = ' + exprText + ';\n',
		};
		final replaceEdit:{span:Span, text:String} = {
			span: new Span(targetSpan.from, targetSpan.to),
			text: name,
		};

		final rewritten:String = RefactorSupport.applyEdits(source, [insertEdit, replaceEdit]);
		if (rewritten == source)
			return Err('extract of "$name" is a no-op');

		try plugin.parseFile(rewritten)
			catch (exception:ParseError) return Err('rewritten source does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('rewritten source does not parse: ${exception.message}');

		return Ok(rewritten);
	}

	/**
	 * The outermost EXPRESSION node whose `span.from` equals `cursor`: the
	 * expression-kind node starting at the cursor with the maximum
	 * `span.to`. Structural nodes (statements, declarations, members,
	 * param wrappers) are skipped so pointing at the first token of
	 * `a + b * 2` selects the whole `Add`, not the bare `IdentExpr a`.
	 * Null when no expression starts at the cursor.
	 */
	private static function selectTargetExpr(tree:QueryNode, cursor:Int):Null<QueryNode> {
		var best:Null<QueryNode> = null;
		function walk(node:QueryNode):Void {
			final span:Null<Span> = node.span;
			if (span != null && span.from == cursor && !isStructural(node.kind)) {
				final current:Null<QueryNode> = best;
				final bestSpan:Null<Span> = current == null ? null : current.span;
				if (bestSpan == null || span.to > bestSpan.to) best = node;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * The nearest statement ancestor of `target` that is a DIRECT CHILD of
	 * a `{ }` block container, or null when the target's nearest statement
	 * ancestor is not a block child (e.g. a sub-node of a braceless
	 * branch). Walks the tree carrying, per node, the innermost enclosing
	 * statement and whether that statement sits directly inside a block.
	 * When the walk reaches `target` (by identity), the carried statement
	 * is the hoist anchor — returned only if it is a block child.
	 */
	private static function findEnclosingBlockStmt(tree:QueryNode, target:QueryNode):Null<QueryNode> {
		var result:Null<QueryNode> = null;
		var found:Bool = false;
		function walk(node:QueryNode, nearestStmt:Null<QueryNode>, nearestIsBlockChild:Bool):Void {
			if (found) return;
			if (node == target) {
				found = true;
				if (nearestStmt != null && nearestIsBlockChild) result = nearestStmt;
				return;
			}
			final nodeIsBlock:Bool = BLOCK_KINDS.contains(node.kind);
			for (c in node.children) {
				if (found) return;
				if (isStatement(c.kind)) walk(c, c, nodeIsBlock);
				else walk(c, nearestStmt, nearestIsBlockChild);
			}
		}
		walk(tree, null, false);
		return result;
	}

	/** Is `kind` a statement node (its kind ends with `Stmt`)? */
	private static inline function isStatement(kind:String):Bool {
		return StringTools.endsWith(kind, 'Stmt');
	}

	/**
	 * Is `kind` structural (a statement / declaration / member / param
	 * wrapper) rather than an expression? Suffix-based with a short list
	 * of suffix-less literals.
	 */
	private static function isStructural(kind:String):Bool {
		if (STRUCTURAL_KINDS.contains(kind)) return true;
		for (suffix in STRUCTURAL_SUFFIXES) if (StringTools.endsWith(kind, suffix)) return true;
		return false;
	}

	/** Offset of the first byte after the previous `\n` before `at` (or 0). */
	private static function lineStartOf(source:String, at:Int):Int {
		var i:Int = at;
		while (i > 0 && source.charAt(i - 1) != '\n') i--;
		return i;
	}

	/** Is every character of `s` an ASCII space / tab / carriage return? */
	private static function isAllWhitespace(s:String):Bool {
		for (i in 0...s.length) {
			final c:Int = StringTools.fastCodeAt(s, i);
			if (c != ' '.code && c != '\t'.code && c != '\r'.code) return false;
		}
		return true;
	}
}
