package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * The resolved statement range to extract: the enclosing block, the
 * contiguous run of its direct-child statements, and the byte range they
 * span. Internal to `ExtractMethod`.
 */
private typedef StmtRange = {
	var stmts: Array<QueryNode>;
	var fromOffset: Int;
	var toOffset: Int;
}

/** A local declaration in the range: its name and its binding `span.from`. */
private typedef LocalDecl = {
	var name: String;
	var from: Int;
}

/**
 * A range-local returned from the extracted function: its name and whether
 * it is reassigned after the range (so its call-site binding must be `var`,
 * not `final`).
 */
private typedef ReturnVar = {
	var name: String;
	var writtenAfter: Bool;
}

/**
 * Extract a run of statements into a local function (closure) — the
 * method analog of `ExtractVar`, and the inverse-ish of `InlineMethod`.
 *
 * Given a START and an END position bounding a contiguous run of sibling
 * statements, the extract wraps them in a fresh `function <name>() { … }`
 * inserted at the run's position, and replaces the run with a call to it.
 * Because a local function CAPTURES the enclosing scope, every variable
 * the range only READS needs neither a parameter nor a synthesised type —
 * which is what makes the operation possible on a platform with no
 * type-checker (the reason it extracts to a closure, not a sibling
 * method).
 *
 * Unlike `Inline` / `ExtractVar`, this op SYNTHESISES new code (the
 * function scaffold), so it finalises through `RefactorSupport.canonicalize`
 * — the writer formats the new function + the call site and re-parse-
 * validates the whole file, exactly like the insert layer
 * (`AddMember` / `ReplaceNode`). The source is therefore canonical-gated
 * unless `reformat` is passed.
 *
 * ## What is and is NOT extractable (MVP — refuse the unknown)
 *
 *  - The range must be a contiguous run of statements that are ALL direct
 *    children of ONE `{ }` block (a function body or a nested brace
 *    block). A range crossing a block boundary is refused.
 *  - A `return` / `break` / `continue` anywhere in the range is refused —
 *    inside a closure it would change control-flow target.
 *  - A local declared OUTSIDE the range that is WRITTEN in the range and
 *    READ after it is refused — closure capture-by-reference of a mutated
 *    local is target-dependent, out of scope here. (Read-only captures are
 *    always fine; field / `this` writes persist via capture and are fine.)
 *  - The range may DEFINE locals used after it: zero (the call returns
 *    nothing), one (the call returns it, bound at the call site), or
 *    two-plus (the call returns an anonymous struct of them, destructured
 *    back into the original names at the call site).
 *
 * Coordinate convention: `startLine` / `startCol` / `endLine` / `endCol`
 * are interpreted exactly as `apq refs` PRINTS them
 * (1-based). START points at the first token of the first
 * statement; END points within the last statement of the run.
 */
@:nullSafety(Strict)
final class ExtractMethod {

	/**
	 * Block-container kinds whose direct children are statements — a
	 * function body (`BlockBody`) or a nested brace block (`BlockStmt`).
	 * The range must be a run of one block's direct children.
	 */
	private static final BLOCK_KINDS: Array<String> = ['BlockBody', 'BlockStmt'];

	/** Local-variable declaration kinds — a range local that may be returned. */
	private static final LOCAL_DECL_KINDS: Array<String> = ['VarStmt', 'FinalStmt'];

	/**
	 * Binding-introducing kinds whose name would collide with the
	 * synthesised local function `function <name>()`: parameters, locals,
	 * nested local functions, loop iterators, catch variables.
	 */
	private static final BINDING_DECL_KINDS: Array<String> = [
		'Required',
		'Optional',
		'VarStmt',
		'FinalStmt',
		'LocalFnStmt',
		'ForStmt',
		'CatchClause',
	];

	/**
	 * Extract the statement run bounded by `startLine:startCol` ..
	 * `endLine:endCol` in `source` into a local function `name`, replacing
	 * the run with a call. `reformat` opts into a whole-file
	 * canonicalisation when the source is not already writer-canonical.
	 * `plugin` / `shape` are the caller-owned grammar plugin and its
	 * `RefShape`; `optsJson` is the project writer config. Returns
	 * `Ok(rewritten)` or an `Err`. The source is never mutated.
	 */
	public static function extractMethod(
		source: String, startLine: Int, startCol: Int, endLine: Int, endCol: Int, name: String, reformat: Bool, plugin: GrammarPlugin,
		shape: RefShape, ?optsJson: String
	): EditResult {
		if (!RefactorSupport.isIdentifier(name)) return Err('new name "$name" is not a valid identifier');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final startOffset: Int = Span.offsetOf(source, startLine, startCol);
		final endOffset: Int = Span.offsetOf(source, endLine, endCol);
		if (endOffset < startOffset) return Err('end position is before start position');

		final range: Null<StmtRange> = selectStmtRange(tree, startOffset, endOffset);
		if (range == null)
			return
				Err(
					'no statement range at $startLine:$startCol..$endLine:$endCol — point START at the first token of a statement and END within the last, both direct children of one { } block'
				);
		final sel: StmtRange = range;

		// Control-flow escape: a return / break / continue would change
		// target once wrapped in a closure.
		if (containsControlFlowEscape(sel.stmts))
			return Err('the selected range contains return / break / continue — cannot extract into a closure');

		// A synthesised-function name that already binds in this function
		// would shadow or redeclare it.
		if (nameDeclaredInEnclosingFunction(tree, startOffset, name))
			return Err('"$name" already names a parameter or local in this function — choose a different name');

		// Data-flow. Locals DECLARED in the range that are READ after it
		// become the return value(s) — one returned bare, two-plus as an
		// anonymous struct; an outer local MUTATED in the range and read
		// after it is out of scope. All after-the-range checks bind to the
		// SPECIFIC declaration (its `span.from`), so a same-named local in a
		// LATER function is never mistaken for a use.
		final decls: Array<LocalDecl> = collectLocalDecls(sel.stmts);
		final declNames: Array<String> = [for (d in decls) d.name];

		final returnVars: Array<ReturnVar> = [];
		for (d in decls) {
			final hits: Array<RefHit> = Refs.find(d.name, tree, shape);
			if (readAfterBinding(hits, d.from, sel.toOffset) && !returnVars.exists(r -> r.name == d.name))
				returnVars.push({ name: d.name, writtenAfter: writtenAfterBinding(hits, d.from, sel.toOffset) });
		}

		final outerWrite: Null<String> = outerLocalMutatedAndUsedAfter(sel, declNames, tree, shape);
		if (outerWrite != null)
			return
				Err(
					'local "$outerWrite" is modified inside the range and read after it — cannot extract (closure capture of a mutated local is out of scope)'
				);

		// Build the local-function scaffold + the replacing call. The
		// writer re-formats both, so this text need only PARSE.
		final rangeSource: String = source.substring(sel.fromOffset, sel.toOffset);
		final returnExpr: String = returnExprText(returnVars);
		final retLine: String = returnExpr != '' ? '\nreturn $returnExpr;' : '';
		final fnText: String = 'function $name() {\n$rangeSource$retLine\n}';
		final callText: String = callSiteText(name, returnVars, tree, startOffset);
		final newText: String = '$fnText\n$callText';

		final edit: { span: Span, text: String } = { span: new Span(sel.fromOffset, sel.toOffset), text: newText };
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * The contiguous run of direct-child statements of a single block that
	 * START at `startOffset` and END within `endOffset`. A statement's
	 * `span.from` is unique, so the start statement (and hence its parent
	 * block) is unambiguous; the end is the run member whose span CONTAINS
	 * `endOffset`. Null when no statement starts at `startOffset`, the end
	 * is not within a later sibling, or the two are not children of one
	 * block.
	 */
	private static function selectStmtRange(tree: QueryNode, startOffset: Int, endOffset: Int): Null<StmtRange> {
		var result: Null<StmtRange> = null;
		function walk(node: QueryNode): Void {
			if (result != null) return;
			if (BLOCK_KINDS.contains(node.kind)) {
				final stmts: Array<QueryNode> = [for (c in node.children) if (isStatement(c.kind)) c];
				final si: Int = indexStartingAt(stmts, startOffset);
				if (si >= 0) {
					final ei: Int = indexContaining(stmts, si, endOffset);
					if (ei >= si) {
						final run: Array<QueryNode> = stmts.slice(si, ei + 1);
						final fromSpan: Null<Span> = run[0].span;
						final toSpan: Null<Span> = run[run.length - 1].span;
						if (fromSpan != null && toSpan != null) result = { stmts: run, fromOffset: fromSpan.from, toOffset: toSpan.to };
						return;
					}
				}
			}
			for (c in node.children) {
				if (result != null) return;
				walk(c);
			}
		}
		walk(tree);
		return result;
	}

	/** Index of the statement whose `span.from == offset`, or -1. */
	private static function indexStartingAt(stmts: Array<QueryNode>, offset: Int): Int {
		for (i in 0...stmts.length) {
			final sp: Null<Span> = stmts[i].span;
			if (sp != null && sp.from == offset) return i;
		}
		return -1;
	}

	/** Index (>= `from`) of the statement whose span contains `offset`, or -1. */
	private static function indexContaining(stmts: Array<QueryNode>, from: Int, offset: Int): Int {
		for (i in from...stmts.length) {
			final sp: Null<Span> = stmts[i].span;
			if (sp != null && sp.from <= offset && offset <= sp.to) return i;
		}
		return -1;
	}

	/**
	 * Does any statement in `stmts` contain a `return` (`ReturnStmt` /
	 * `ReturnExpr`) or a `break` / `continue` (each an `IdentExpr` named
	 * for the keyword, since the grammar emits them as bare idents)?
	 * Conservative: a control-flow node inside a nested function / loop of
	 * the range is also flagged (over-refusal is safe).
	 */
	private static function containsControlFlowEscape(stmts: Array<QueryNode>): Bool {
		var found: Bool = false;
		function walk(node: QueryNode): Void {
			if (found) return;
			if (node.kind == 'ReturnStmt' || node.kind == 'ReturnExpr') {
				found = true;
				return;
			}
			if (node.kind == 'IdentExpr' && (node.name == 'break' || node.name == 'continue')) {
				found = true;
				return;
			}
			for (c in node.children) walk(c);
		}
		for (s in stmts) walk(s);
		return found;
	}

	/**
	 * The `VarStmt` / `FinalStmt` locals declared in `stmts`, each with its
	 * declaration `span.from` — the binding offset that a later read's
	 * `bindingSpan.from` carries, used to bind the after-the-range checks
	 * to THIS declaration rather than any same-named local.
	 */
	private static function collectLocalDecls(stmts: Array<QueryNode>): Array<LocalDecl> {
		final out: Array<LocalDecl> = [];
		function walk(node: QueryNode): Void {
			if (LOCAL_DECL_KINDS.contains(node.kind)) {
				final nm: Null<String> = node.name;
				final sp: Null<Span> = node.span;
				if (nm != null && sp != null) {
					final n: String = nm;
					out.push({ name: n, from: sp.from });
				}
			}
			for (c in node.children) walk(c);
		}
		for (s in stmts) walk(s);
		return out;
	}

	/** Does a Read hit bound to `declFrom` fall at or after `toOffset`? */
	private static function readAfterBinding(hits: Array<RefHit>, declFrom: Int, toOffset: Int): Bool {
		return hits.exists(h -> h.kind == RefKind.Read && bindFrom(h) == declFrom && h.span.from >= toOffset);
	}

	/** Does a Write hit bound to `declFrom` fall at or after `toOffset`? */
	private static function writtenAfterBinding(hits: Array<RefHit>, declFrom: Int, toOffset: Int): Bool {
		return hits.exists(h -> h.kind == RefKind.Write && bindFrom(h) == declFrom && h.span.from >= toOffset);
	}

	/** `from` offset of a hit's binding span, or -1 when unbound. */
	private static inline function bindFrom(hit: RefHit): Int {
		final b: Null<Span> = hit.bindingSpan;
		return b == null ? -1 : b.from;
	}

	/**
	 * The first local NAME that is (a) declared OUTSIDE the range, (b)
	 * a non-field local / parameter, (c) WRITTEN inside the range, and (d)
	 * READ after the range — the unsupported mutated-capture case. Returns
	 * null when no such local exists. A name declared inside the range
	 * (`declNames`) is skipped — it is a return candidate, not an outer
	 * capture.
	 */
	private static function outerLocalMutatedAndUsedAfter(
		sel: StmtRange, declNames: Array<String>, tree: QueryNode, shape: RefShape
	): Null<String> {
		for (nm in distinctIdentNames(sel.stmts)) {
			if (declNames.contains(nm)) continue;
			final hits: Array<RefHit> = Refs.find(nm, tree, shape);
			final writeIn: Null<RefHit> = hits.find(h ->
				h.kind == RefKind.Write && h.span.from >= sel.fromOffset && h.span.from < sel.toOffset
			);
			if (writeIn == null) continue;
			final bindingSpan: Null<Span> = writeIn.bindingSpan;
			if (bindingSpan == null) continue;
			final bindingFrom: Int = bindingSpan.from;
			// Declared inside the range → handled as a return candidate.
			if (bindingFrom >= sel.fromOffset) continue;
			// A field / member binding persists via `this`-capture — fine.
			final bindNode: Null<QueryNode> = RefactorSupport.nodeAtFrom(tree, bindingFrom);
			if (bindNode == null || RefactorSupport.isFieldMemberKind(bindNode.kind)) continue;
			// An outer local / parameter, mutated in the range — refuse if read after.
			if (hits.exists(h -> h.kind == RefKind.Read && bindFrom(h) == bindingFrom && h.span.from >= sel.toOffset)) return nm;
		}
		return null;
	}

	/** Distinct `IdentExpr` names referenced anywhere in `stmts`. */
	private static function distinctIdentNames(stmts: Array<QueryNode>): Array<String> {
		final out: Array<String> = [];
		function walk(node: QueryNode): Void {
			if (node.kind == 'IdentExpr') {
				final nm: Null<String> = node.name;
				if (nm != null && !out.contains(nm)) out.push(nm);
			}
			for (c in node.children) walk(c);
		}
		for (s in stmts) walk(s);
		return out;
	}

	/**
	 * Is `name` already declared as a parameter or local within the
	 * function enclosing `cursor`? Mirrors `ExtractVar`'s same-named guard:
	 * scans the whole enclosing function for any binding-introducing node
	 * named `name`. Returns false when `cursor` is not inside a function.
	 */
	private static function nameDeclaredInEnclosingFunction(tree: QueryNode, cursor: Int, name: String): Bool {
		final fn: Null<QueryNode> = RefactorSupport.innermostWhere(tree, cursor, node -> RefactorSupport.FN_DECL_KINDS.contains(node.kind));
		if (fn == null) return false;
		var found: Bool = false;
		function scan(node: QueryNode): Void {
			if (found) return;
			if (node.name == name && BINDING_DECL_KINDS.contains(node.kind)) found = true;
			for (c in node.children) scan(c);
		}
		scan(fn);
		return found;
	}

	/** Is `kind` a statement node (its kind ends with `Stmt`)? */
	private static inline function isStatement(kind: String): Bool {
		return StringTools.endsWith(kind, 'Stmt');
	}

	/**
	 * The closure's return expression for `returnVars`: empty when nothing is
	 * returned, the bare name for a single value, or an anonymous struct
	 * `{a: a, b: b}` of the names for two-plus.
	 */
	private static function returnExprText(returnVars: Array<ReturnVar>): String {
		return switch returnVars.length {
			case 0: '';
			case 1: returnVars[0].name;
			case _: '{' + returnVars.map(r -> '${r.name}: ${r.name}').join(', ') + '}';
		};
	}

	/**
	 * The statement(s) replacing the extracted range: a bare call when nothing
	 * is returned, one `final`/`var <name> = call()` for a single value, or
	 * `final <tmp> = call();` plus one rebind per returned local for the struct
	 * case — rebinding each into its original name so uses after the range stay
	 * valid.
	 */
	private static function callSiteText(name: String, returnVars: Array<ReturnVar>, tree: QueryNode, cursor: Int): String {
		return switch returnVars.length {
			case 0: '$name();';
			case 1:
				final single: ReturnVar = returnVars[0];
				'${bindKeyword(single)} ${single.name} = $name();';
			case _:
				final tmp: String = freshReturnName(tree, cursor, returnVars, name);
				final binds: Array<String> = returnVars.map(r -> '${bindKeyword(r)} ${r.name} = $tmp.${r.name};');
				'final $tmp = $name();\n' + binds.join('\n');
		};
	}

	/** `var` when the returned local is reassigned after the range, else `final`. */
	private static inline function bindKeyword(returnVar: ReturnVar): String {
		return returnVar.writtenAfter ? 'var' : 'final';
	}

	/**
	 * A fresh local name for the struct-return temporary that collides with
	 * neither an existing binding in the enclosing function nor a returned
	 * local — `_<name>Result`, suffixed with `_` until free.
	 */
	private static function freshReturnName(tree: QueryNode, cursor: Int, returnVars: Array<ReturnVar>, base: String): String {
		var candidate: String = '_${base}Result';
		while (nameDeclaredInEnclosingFunction(tree, cursor, candidate) || returnVars.exists(r -> r.name == candidate)) candidate += '_';
		return candidate;
	}

}
