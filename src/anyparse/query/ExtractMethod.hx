package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.Span;

using StringTools;
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

	/** The binding offset of its declaration in the range — where a member extraction reads its written type. */
	var from: Int;
}

/** A free local a member extraction passes in: its name, binding offset and the type its declaration writes. */
private typedef MemberParam = {
	var name: String;
	var from: Int;
	var type: String;
}

/** The member of a type that holds the range, its modifier run, and every member name the type declares. */
private typedef MemberHost = {
	var node: QueryNode;
	var run: Array<QueryNode>;
	var names: Array<String>;
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
 *  - A binding the range declares — a local, or a local `function` — whose
 *    name is ALSO declared on a conditional-compilation arm another configuration
 *    compiles out is refused: a read past that `#end` belongs to a different
 *    declaration per build, so whether the binding is read after the range holds
 *    for one configuration and not the other — the same shape `rename` refuses on.
 *    A SEQUENTIAL re-declaration in one block is not this shape and extracts.
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
		// The VALUE binder of `for (k => v in m)` — the loop node names only the KEY, so
		// without this a collision with `v` goes unseen and the new binding captures it.
		'KeyValueBinder',
		'CatchClause'
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
		shape: RefShape, ?optsJson: String, member: Bool = false
	): EditResult {
		if (!SourceText.isIdentifier(name)) return Err('new name "$name" is not a valid identifier');

		final tree: QueryNode = switch ParseGate.parse(plugin, source, 'source') {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};

		// line:col is 1-based, as apq refs / ast --at / source print.
		final startOffset: Int = Span.offsetOf(source, startLine, startCol);
		final endOffset: Int = Span.offsetOf(source, endLine, endCol);
		if (endOffset < startOffset) return Err('end position is before start position');

		final range: Null<StmtRange> = selectStmtRange(tree, startOffset, endOffset);
		if (range == null)
			return Err(
				'no statement range at $startLine:$startCol..$endLine:$endCol'
				+ ' — point START at the first token of a statement and END within the last, both direct children of one { } block'
			);
		final sel: StmtRange = range;

		// Control-flow escape: a return / break / continue would change
		// target once wrapped in a function of its own.
		if (containsControlFlowEscape(sel.stmts))
			return Err('the selected range contains return / break / continue — cannot extract into a ${member ? 'member' : 'closure'}');

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
		final decls: Array<LocalDecl> = collectLocalDecls(sel.stmts, LOCAL_DECL_KINDS);
		final declNames: Array<String> = [for (d in decls) d.name];

		// A range binding whose name is also declared on a conditional-compilation arm that
		// another configuration compiles out has ONE declaration answering every read past
		// the `#end`, so the escape analysis below decides "read after the range" for one
		// build configuration and against the other. Refuse it, exactly as `rename` does on
		// this shape. A SEQUENTIAL re-declaration in one block is a different shape and is
		// NOT refused: it resolves by position, and the extraction it enables is correct.
		// The scope swept is the enclosing FUNCTION, `rename`'s own, so a region
		// ELSEWHERE in that function carrying the name on an arm refuses too -
		// deliberately: the range's own binding does resolve there, but narrowing it would
		// mean a second predicate answering the question the shared one already answers.
		// Swept over the guard's OWN vocabulary, not `LOCAL_DECL_KINDS`: a local
		// `function g()` on an arm is the same ambiguity, and moving the range's own
		// `function g()` into the closure is what makes the later `g()` call the wrong body.
		// That function is the one owning the range's BLOCK, not the innermost one at
		// `sel.fromOffset`: a range whose first statement IS a local `function` puts that
		// offset inside it, and the sweep would then see only that function's own body.
		final block: Null<QueryNode> = TreePath.parentOf(tree, sel.stmts[0]);
		final blockSpan: Null<Span> = block?.span;
		final scope: QueryNode = blockSpan == null ? tree : BinderScan.enclosingFunctionSubtree(tree, blockSpan.from, shape);
		final boundNames: Array<String> = [
			for (d in collectLocalDecls(sel.stmts, TypeResolver.blockScopedValueDeclarationKinds(shape))) d.name
		];
		for (nm in boundNames) {
			// Same question, asked of a region with no nodes: whether a name the range binds is
			// read after it cannot be decided when an unparsed conditional region may hold that read.
			final opaque: Null<String> = CondRegionScan.opaqueCondRegionDiagnostic(
				source, scope, nm, shape, 'extract of a range binding "$nm"'
			);
			if (opaque != null) return Err(opaque);
			final dup: Null<Span> = CondRegionScan.exclusiveBranchRedeclaration(scope, source, nm, plugin, shape);
			if (dup == null) continue;
			final at: Position = dup.lineCol(source);
			return Err(
				'cannot extract: local "$nm" has a declaration at ${at.line}:${at.col} on a conditional-compilation arm another'
				+ ' configuration compiles out, while a second declaration of the name can be in effect past the same #end — a read'
				+ ' there belongs to a different declaration per build, so whether the extracted local is read after the range holds'
				+ ' for one configuration and not the other. Split the scopes first'
			);
		}

		final returnVars: Array<ReturnVar> = [];
		for (d in decls) {
			final hits: Array<RefHit> = Refs.find(d.name, tree, shape);
			if (readAfterBinding(hits, d.from, sel.toOffset) && !returnVars.exists(r -> r.name == d.name))
				returnVars.push({ name: d.name, writtenAfter: writtenAfterBinding(hits, d.from, sel.toOffset), from: d.from });
		}

		if (member) return extractIntoMember(source, tree, sel, name, returnVars, reformat, plugin, shape, optsJson);

		final outerWrite: Null<String> = outerLocalMutatedAndUsedAfter(sel, declNames, tree, shape);
		if (outerWrite != null)
			return Err(
				'local "$outerWrite'
				+ '" is modified inside the range and read after it — cannot extract (closure capture of a mutated local is out of scope)'
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
		return CanonicalEdit.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/** `from` offset of a hit's binding span, or -1 when unbound. */
	private static inline function bindFrom(hit: RefHit): Int {
		final b: Null<Span> = hit.bindingSpan;
		return b == null ? -1 : b.from;
	}

	/** Is `kind` a statement node (its kind ends with `Stmt`)? */
	private static inline function isStatement(kind: String): Bool {
		return kind.endsWith('Stmt');
	}

	/** `var` when the returned local is reassigned after the range, else `final`. */
	private static inline function bindKeyword(returnVar: ReturnVar): String {
		return returnVar.writtenAfter ? 'var' : 'final';
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
		for (i => stmt in stmts) {
			final sp: Null<Span> = stmt.span;
			if (sp != null && sp.from == offset) return i;
		}
		return -1;
	}

	/** Index (>= `from`) of the statement whose span contains `offset`, or -1. */
	private static function indexContaining(stmts: Array<QueryNode>, from: Int, offset: Int): Int {
		for (i in from ... stmts.length) {
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
			if (node.kind == 'BreakStmt' || node.kind == 'ContinueStmt') {
				found = true;
				return;
			}
			for (c in node.children) walk(c);
		}
		for (s in stmts) walk(s);
		return found;
	}

	/**
	 * The `kinds` declarations made in `stmts`, each with its declaration
	 * `span.from` — the binding offset that a later read's `bindingSpan.from`
	 * carries, used to bind the after-the-range checks to THIS declaration
	 * rather than any same-named local.
	 *
	 * `kinds` is a parameter because the two callers ask different questions:
	 * the escape analysis wants only the `LOCAL_DECL_KINDS` values it can hand
	 * back through a return, the redeclaration guard every binding the block
	 * scope carries — including a local `function`, which is a value binding
	 * the guard's own vocabulary knows and this one must not silently drop.
	 */
	private static function collectLocalDecls(stmts: Array<QueryNode>, kinds: Array<String>): Array<LocalDecl> {
		final out: Array<LocalDecl> = [];
		function walk(node: QueryNode): Void {
			if (kinds.contains(node.kind)) {
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
		for (nm in distinctIdentNames(sel.stmts)) if (!declNames.contains(nm)) {
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
			if (bindNode == null || MemberKinds.isFieldMemberKind(bindNode.kind)) continue;
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
		final fn: Null<QueryNode> = RefactorSupport.innermostWhere(tree, cursor, node -> MemberKinds.FN_DECL_KINDS.contains(node.kind));
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

	/**
	 * The closure's return expression for `returnVars`: empty when nothing is
	 * returned, the bare name for a single value, or an anonymous struct
	 * `{a: a, b: b}` of the names for two-plus.
	 */
	private static function returnExprText(returnVars: Array<ReturnVar>): String {
		return switch returnVars.length {
			case 0: '';
			case 1: returnVars[0].name;
			case _: '{${returnVars.map(r -> '${r.name}: ${r.name}').join(', ')}}';
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

	/**
	 * `--member`: the run becomes a new PRIVATE member of the enclosing type, right after the
	 * member holding it, and the run is replaced with a call — the inverse of `inline-method`,
	 * and the form that does not leave the work inside the function it was taken from.
	 *
	 * A member captures nothing, so every local of the enclosing function the run reads is
	 * passed as a PARAMETER (in declaration order), typed by the type its declaration WRITES
	 * (refusing what `TypeResolver.paramTypeSourceUnsafe` names); the run's locals read after it come back as
	 * the return value, typed the same way — one bare, two-plus as an anonymous structure. A
	 * parameter is a copy, so the op refuses rather than guesses whenever that could differ from
	 * the shared local the run read: a free local ASSIGNED anywhere in the function (a write the
	 * run makes, or one a closure makes while the run calls it, would no longer reach it), and a
	 * local whose written type is not the type its reads have, or that has none. Static-ness
	 * follows the enclosing member. Refused outright: a constructor (`super(…)` and `final`
	 * field initialisation are legal only there), a function with type parameters (the
	 * projection carries none to copy), a `macro` / `extern` member, and a name the type already
	 * declares.
	 */
	private static function extractIntoMember(
		source: String, tree: QueryNode, sel: StmtRange, name: String, returnVars: Array<ReturnVar>, reformat: Bool, plugin: GrammarPlugin,
		shape: RefShape, ?optsJson: String
	): EditResult {
		final regions: () -> Array<LexRegion> = plugin.lexicalRegions.bind(source);
		final decl: Null<TypeDeclMatch> = TypeResolver.enclosingTypeDeclAt(tree, sel.fromOffset, sel.toOffset);
		final found: Null<MemberHost> = decl == null ? null : memberHost(decl, sel, source, shape, regions);
		if (found == null)
			return Err('the range is not in a function that is a member of a type — `--member` needs a type to add the new member to');
		final host: MemberHost = found;
		final hostName: String = host.node.name ?? '';
		final hostSpan: Null<Span> = host.node.span;
		if (hostSpan == null) return Err('the enclosing member has no source span');
		final refusal: Null<String> = hostRefusal(source, host, hostName, hostSpan, name, shape);
		if (refusal != null) return Err(refusal);

		final declared: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, source);
		final params: Array<MemberParam> = [];
		final paramFailure: Null<String> = collectMemberParams(tree, sel, host.node, hostSpan, declared, shape, params);
		if (paramFailure != null) return Err(paramFailure);
		final returnTypes: Array<String> = [];
		for (r in returnVars) {
			final type: Null<String> = declared()[r.from];
			if (type == null)
				return Err(
					'local "${r.name}" is read after the range, so the new member returns it, and its declaration writes no type to '
					+ 'declare the return with — annotate it first'
				);
			returnTypes.push(type.trim());
		}

		final isStatic: Bool = shape.staticModifierKind != null && host.run.exists(m -> m.kind == shape.staticModifierKind);
		final retType: String = switch returnVars.length {
			case 0: 'Void';
			case 1: returnTypes[0];
			case _: '{ ${[for (k => r in returnVars) '${r.name}: ${returnTypes[k]}'].join(', ')} }';
		};
		final returnExpr: String = returnExprText(returnVars);
		final retLine: String = returnExpr != '' ? '\nreturn $returnExpr;' : '';
		final memberText: String = '${isStatic ? 'private static' : 'private'} function $name(${params.map(p -> '${p.name}: ${p.type}').join(', ')}): '
			+ '$retType {\n${source.substring(sel.fromOffset, sel.toOffset)}$retLine\n}';
		final call: String = '$name(${params.map(p -> p.name).join(', ')})';
		final callText: String = switch returnVars.length {
			case 0: '$call;';
			case 1: '${bindKeyword(returnVars[0])} ${returnVars[0].name}: $retType = $call;';
			case _:
				final tmp: String = freshReturnName(tree, sel.fromOffset, returnVars, name);
				'final $tmp: $retType = $call;\n'
					+ [
						for (k => r in returnVars) '${bindKeyword(r)} ${r.name}: ${returnTypes[k]} = $tmp.${r.name};'
					].join('\n');
		};
		final after: Int = ElementSpan.declEditSpan(source, tree, host.node, hostSpan, regions).to;
		return CanonicalEdit.canonicalize(source, [
			{ span: new Span(sel.fromOffset, sel.toOffset), text: callText },
			{ span: new Span(after, after), text: '\n\n$memberText' }
		], reformat, plugin, optsJson);
	}

	/**
	 * The function MEMBER of `decl` whose span holds the range (a local function inside it does not
	 * count — the new member goes beside a member), with its modifier run and the names of every
	 * member the type declares, on every conditional branch.
	 */
	private static function memberHost(
		decl: TypeDeclMatch, sel: StmtRange, source: String, shape: RefShape, regions: () -> Array<LexRegion>
	): Null<MemberHost> {
		var host: Null<MemberHost> = null;
		final names: Array<String> = [];
		MemberBranchScan.eachTypeMember(decl, shape, source, n -> n.name != null, (child, run) -> {
			final childName: Null<String> = child.name;
			if (childName != null) names.push(childName);
			final span: Null<Span> = child.span;
			if (MemberKinds.FN_DECL_KINDS.contains(child.kind) && span != null && span.from <= sel.fromOffset && sel.toOffset <= span.to)
				host = { node: child, run: run, names: names };
		}, regions);
		return host;
	}

	/** Why the enclosing member cannot take a sibling extracted from it, or null when it can. */
	private static function hostRefusal(
		source: String, host: MemberHost, hostName: String, hostSpan: Span, name: String, shape: RefShape
	): Null<String> {
		if (hostName == 'new')
			return 'cannot extract out of a constructor into a member — `super(…)` and `final` field initialisation are legal only in '
				+ 'the constructor; extract without --member';
		for (kind in [shape.macroModifierKind, shape.externModifierKind]) if (kind != null && host.run.exists(m -> m.kind == kind))
			return 'cannot extract out of a ${kind.toLowerCase()} member into a member — extract without --member';
		// The projection carries no type parameter, so `function f<T>(x:T)` cannot hand its `T` on:
		// only a header whose name is followed directly by `(` is known to declare none.
		final nameAt: Int = SourceText.identTokenOffset(source, hostSpan, hostName);
		var at: Int = nameAt < 0 ? -1 : nameAt + hostName.length;
		while (at >= 0 && at < source.length && SourceText.isSpace(source.fastCodeAt(at))) at++;
		return if (at < 0 || at >= source.length || source.fastCodeAt(at) != '('.code)
			'"$hostName" declares type parameters (or its header could not be read), which the new member would need and the '
				+ 'projection does not carry — extract without --member'
		else if (host.names.contains(name))
			'"$name" already names a member of the enclosing type — choose a different name'
		else
			null;
	}

	/**
	 * The enclosing function's locals the range reads, as parameters in declaration order, pushed
	 * into `params`; or why one of them cannot be passed. A local is the range's when a read in the
	 * range binds to a declaration inside `host` that precedes the range.
	 */
	private static function collectMemberParams(
		tree: QueryNode, sel: StmtRange, host: QueryNode, hostSpan: Span, declared: () -> Map<Int, String>, shape: RefShape,
		params: Array<MemberParam>
	): Null<String> {
		final kinds: Array<String> = BinderScan.binderKinds(shape);
		final names: Array<String> = [];
		function collect(n: QueryNode): Void {
			final span: Null<Span> = n.span;
			final nm: Null<String> = n.name;
			if (span != null && span.from < sel.fromOffset && nm != null && kinds.contains(n.kind) && !names.contains(nm)) names.push(nm);
			for (c in n.children) collect(c);
		}
		collect(host);
		for (nm in names) {
			final hits: Array<RefHit> = Refs.find(nm, tree, shape);
			for (h in hits) if (h.kind != RefKind.Decl && h.span.from >= sel.fromOffset && h.span.from < sel.toOffset) {
				final b: Int = bindFrom(h);
				if (b < hostSpan.from || b >= sel.fromOffset || params.exists(p -> p.from == b)) continue;
				if (hits.exists(w -> w.kind == RefKind.Write && bindFrom(w) == b))
					return 'local "$nm" is assigned in this function, and the new member would receive a COPY of it — a write the range '
						+ 'makes, or one a closure makes while the range calls it, would no longer reach the local; extract without '
						+ '--member, or make it final first';
				final type: Null<String> = TypeResolver.paramTypeSourceUnsafe(tree, shape, b) ? null : declared()[b];
				if (type == null)
					return
						'local "$nm" has no written type a parameter can copy (an untyped local, a loop or catch variable, an optional, '
							+ 'null-defaulted or rest parameter) — annotate it first, or extract without --member';
				params.push({ name: nm, from: b, type: type.trim() });
			}
		}
		params.sort((a, c) -> a.from - c.from);
		return null;
	}

}
