package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags an empty-array local declaration immediately followed by a `for` loop
 * whose only effect is `a.push(<expr>)`, which an array comprehension replaces —
 * `final a = []; for (x in xs) a.push(e);` collapses to `final a = [for (x in xs) e];`.
 * `Severity.Info` (a modernization cleanup toward the idiomatic comprehension),
 * with an autofix. Grammar-agnostic over `RefShape`.
 *
 * ## The shape it accepts
 *
 * Two ADJACENT statements in one block: a local `var` / `final` whose initializer
 * is EXACTLY the empty array literal `[]` (a `new Array()` is left to
 * `prefer-array-literal`; after its `--fix` produces `[]` this check catches it on
 * the next run), then a `for` whose body — descending through braces, nested
 * `for`s and ONE trailing `if` guard — bottoms out in exactly one `a.push(e)` call
 * statement. The comprehension is assembled by transcribing each `for (...)` header
 * and the `if (cond)` guard verbatim from source (so a key-value `for (k => v in m)`
 * and a nested `for (a) for (b)` transfer intact), with the push argument as the
 * produced element.
 *
 * ## The chain form
 *
 * A braced body may also hold a CHAIN of single-use `final` locals feeding the final
 * `a.push(e)`; each local's initializer is inlined into its one use, so
 *
 * ```
 * for (o in sel) if (isLineTool(o.data.type)) {
 *     final tool:LineToolBase = cast o;
 *     final cmd:Command = new ChangeArrowStrokeCommand(tool, stroke);
 *     commands.push(cmd);
 * }
 * ```
 *
 * becomes `[for (o in sel) if (isLineTool(o.data.type)) new ChangeArrowStrokeCommand((cast o : LineToolBase), stroke)]`.
 *
 * The inlining is EVALUATION-ORDER PRESERVING because each link is used exactly
 * once; that use lies in a LATER sibling statement than the declaration (so the
 * recursion terminates); every ancestor of the use, from that statement's root down,
 * is an EAGER HOST, which is a WHITELIST — an unknown construct refuses; nothing
 * impure in the host's VALUE REGION lies ENTIRELY BEFORE the use, since inlining
 * moves the initializer to the use position and whatever that region evaluated first
 * would otherwise now run before it; and sorting the uses by source position must
 * reproduce declaration order — `out.push(h(b, a))` after
 * `final a = f(); final b = g();` would run `g` before `f` and is refused.
 *
 * An inlined initializer keeps its declaration's type annotation as an ASCRIPTION
 * (`(cast o : LineToolBase)`) unless the boundary provably restates it. The
 * annotation can be what TYPES the initializer — an unchecked `cast e` takes its
 * result type from the CONTEXT, `final d:Dynamic = x` widens, and
 * `final m:Map<String, Int> = new Map()` binds the type parameters — so dropping it
 * changes the expression's type, or fails to compile outright. The ONE position
 * where the boundary restates it is the whole push argument of an array declaration
 * whose annotation names an ELEMENT type textually equal to the link's: the fix
 * preserves that annotation verbatim, so an `Array<Command>` around a `cmd:Command`
 * link pins exactly what the link declared. A DIFFERENT element type restates
 * nothing — an `Array<Dynamic>` around a `m:Map<String, Int>` link would leave a
 * bare `new Map()` whose type parameters are unknown — so the ascription stays.
 *
 * An inlined initializer gains PARENTHESES when the use position is not already
 * delimited (a call or `new` argument, an array element, a grouping paren, an
 * object-literal value, an index subscript) and the initializer is not itself
 * self-delimiting — which is what keeps `final a = p + q; out.push(a * 2);` correct
 * as `(p + q) * 2` rather than the mis-parsing `p + q * 2`. A local declaration's
 * INITIALIZER is not a delimited position: this very fix dissolves it, so it
 * delimits nothing.
 *
 * ## Comment hoisting
 *
 * A comment sitting in a GAP of the dissolved body's statement list — before the
 * first statement, between two of them, or after the last — is lifted ABOVE the
 * resulting declaration at its indent, rather than dropped (which is what the merge
 * did before, silently, even for a single-statement body). So is one sitting inside
 * the terminal push STATEMENT but outside its ARGUMENT, since the element text is
 * sliced from the argument span alone. Three refusals come with it: a comment
 * INTERSECTING a chain link's declaration (dissolving the statement would strand the
 * comment inside an expression), a comment inside a transcribed `for` / `if` HEADER
 * (the header is copied verbatim, so a `//` there would comment out the rest of the
 * comprehension), and a declaration that does not start its own line (a hoisted
 * comment there would comment out whatever shares the line). A comment inside the
 * push ARGUMENT keeps today's behaviour — it rides along in the verbatim argument
 * text.
 *
 * ## Soundness gates
 *
 * - **Empty literal only.** The initializer's source, whitespace-stripped, must be
 *   `[]` — an array with elements, a `new Array()` or anything else is skipped.
 * - **Push-only body.** Every layer is a `for`, a braced block, a single-branch `if`
 *   (no `else`), or the terminal `a.push(e)`; a second statement is admitted only as
 *   the chain form above, and an `else`, a non-push call or an assignment breaks the
 *   match. A `break` / `continue` therefore cannot hide — it is not a declaration, so
 *   the chain arm rejects it exactly as the single-statement arm does.
 * - **The last statement IS the push.** A block ending in `if (a > 0) out.push(a);`
 *   is not a push statement and never matches — which is what refuses a local used
 *   across an `if`-guard boundary, where inlining would move the initializer inside
 *   the guard.
 * - **Chain links are single-assignment.** A `var` link (reassignable between its
 *   declaration and the push) and a multi-variable list (`final a = 1, b = 2;`) are
 *   both refused — the latter by the declaration's single-child requirement, since
 *   Haxe projects the continuation as a CHILD; the continuation KIND gate is
 *   cross-grammar defence, for a grammar that projects it as a SIBLING instead.
 * - **Chain links run exactly once, in place.** A link used twice is refused (its
 *   initializer would run twice), as is one used anywhere OFF the eager-host spine —
 *   a lambda, a local function, an `if` / `switch` / `try` expression, a block
 *   expression, an expression loop (the array comprehension included), a ternary, a
 *   short-circuiting operator, a compound assignment, or any binding construct that
 *   could REBIND the link's name, which matters because the use scan matches on NAME
 *   with no scope awareness. A `$name` STRING INTERPOLATION counts as a use that can
 *   never be rewritten in place, and a reification subtree refuses outright — that is
 *   the one region where nothing can be proven. A link is refused too when anything
 *   impure in its use's VALUE REGION runs before it, when that region holds a `?.`
 *   anywhere (which makes a whole argument list conditional from a position neither
 *   walk reaches), or when the link is named after the array itself.
 * - **No self-reference.** `a` must not appear in the produced element `e`, any
 *   iterable, a guard condition, or a chain link's initializer (`final n = a.length;
 *   a.push(n);` would read the array being built) — whether as a plain identifier or
 *   as a `$a` string interpolation; only the push receiver is the bound name, and it
 *   is not scanned.
 * - **Read after the loop.** `a` must be referenced somewhere after the `for`
 *   within its scope, else the comprehension feeds no one (`unused-local`'s
 *   territory).
 * - **Strictly adjacent.** The `for` must be the very next statement; a comment in
 *   the gap between the two would be lost by the merge, so such a pair is skipped.
 *
 * ## Autofix
 *
 * Both statements are replaced by `final a<:T?> = [<comprehension>];`, preceded by
 * each hoisted body comment on its own line at the declaration's indent. The binding
 * becomes single-assignment, so the keyword is emitted as `final` regardless of the
 * original `var` / `final` (consistent with `prefer-final`); the declaration's own
 * type annotation, if written, is preserved verbatim.
 *
 * ## Grammar-agnostic
 *
 * `readSeams` names the REQUIRED seams — the loop, local-declaration, call,
 * field-access, expression-statement, block and identifier kinds — and returns null
 * when any of them is unset, which makes the check a no-op. Every other seam it
 * reads is OPTIONAL and costs only REACH: an unset one narrows what the check can
 * recognise, or leaves a redundant pair of parentheses, never a wrong rewrite.
 *
 * The two evaluation-order gates read DERIVED vocabularies, assembled by
 * `readPureKinds` and `readEagerKinds` from existing seams rather than from new
 * ones. Both are WHITELISTS, so an unset seam costs REACH and never soundness —
 * which is why a blacklist of deferring constructs does not do: it leaks by
 * category, and every leak is a silent miscompile. The two are built from SEPARATE
 * lists on purpose: "can evaluation be observed?" and "does this evaluate its
 * children exactly once, in place?" are orthogonal questions, and a field access, an
 * index access and a checked cast answer yes to the second while answering no to the
 * first.
 */
@:nullSafety(Strict)
final class PreferComprehension implements Check {

	/** A `for` node has exactly [iterable, body] OPERAND children — a key-value VALUE binder is not one. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** A `push` call has exactly [callee, single-argument] children. */
	private static inline final PUSH_CALL_CHILD_COUNT: Int = 2;

	/** The declaration keyword the fix always emits, and its length for the `var`→`final` swap. */
	private static inline final VAR_KEYWORD: String = 'var';

	public function new() {}

	public function id(): String {
		return 'prefer-comprehension';
	}

	public function description(): String {
		return 'an empty-array local plus a push-only for loop replaceable with an array comprehension ([for])';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (m in collectMatches(tree, entry.source, seams)) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'prefer-comprehension',
				severity: Severity.Info,
				message: 'this empty-array declaration and push-only for loop can be an array comprehension ([for])'
			});
		}
		return violations;
	}

	/** Replace each flagged declaration-plus-loop pair with the assembled comprehension declaration. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final textBySpan: Map<String, String> = [];
		for (m in collectMatches(tree, source, seams)) textBySpan['${m.span.from}:${m.span.to}'] = m.text;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final text: Null<String> = textBySpan['${span.from}:${span.to}'];
			if (text != null) edits.push({ span: span, text: text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final forStmtKind: Null<String> = shape.forStmtKind;
		if (forStmtKind == null) return null;
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		if (localDeclKinds.length == 0) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		return blockStmtKind == null ? null : {
			forStmtKind: forStmtKind,
			localDeclKinds: localDeclKinds,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			identKind: shape.identKind,
			ifKinds: shape.ifStatementKinds ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			interpIdentKind: shape.stringInterpIdentKind,
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			mutableDeclKinds: shape.mutableLocalDeclKinds ?? [],
			continuationKinds: shape.localDeclContinuationKinds ?? [],
			nullSafeKind: shape.nullSafeAccessKind,
			newExprKind: shape.newExprKind,
			parenKind: shape.parenKind,
			arrayLiteralKind: shape.arrayLiteralKind,
			indexAccessKind: shape.indexAccessKind,
			objectFieldKind: shape.objectFieldKind,
			elementTypeParams: shape.indexedElementTypeParams ?? [],
			atomKinds: readAtomKinds(shape),
			pureKinds: readPureKinds(shape),
			eagerKinds: readEagerKinds(shape)
		};
	}

	/**
	 * Walk `tree` and return every declaration-plus-loop pair that qualifies, each with its
	 * replacement span and text. The file's comment tokens are lexed ONCE here and carried in the
	 * `Ctx` — `collectCommentTokens` re-lexes the whole source on every call.
	 */
	private static function collectMatches(tree: QueryNode, source: String, s: Seams): Array<Match> {
		final ctx: Ctx = { source: source, seams: s, comments: RefactorSupport.collectCommentTokens(source) };
		final out: Array<Match> = [];
		walk(tree, ctx, out);
		return out;
	}

	/**
	 * Descend `node`, testing each adjacent child pair `(decl, for)` and recursing.
	 * `node` doubles as the enclosing scope for the read-after gate (the pair are its
	 * direct children). A reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function walk(node: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		if (ctx.seams.opaqueKinds.contains(node.kind)) return;
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length - 1) {
			final m: Null<Match> = tryMatch(kids[i], kids[i + 1], node, ctx);
			if (m != null) out.push(m);
		}
		for (c in kids) walk(c, ctx, out);
	}

	/**
	 * Whether `decl` is an empty-array local immediately followed by the qualifying
	 * push-only loop `forNode` inside `scope`; returns the replacement span and text
	 * when so, else null.
	 */
	private static function tryMatch(decl: QueryNode, forNode: QueryNode, scope: QueryNode, ctx: Ctx): Null<Match> {
		final s: Seams = ctx.seams;
		final source: String = ctx.source;
		if (!s.localDeclKinds.contains(decl.kind) || decl.children.length != 1) return null;
		if (forNode.kind != s.forStmtKind) return null;
		final declName: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final initSpan: Null<Span> = decl.children[0].span;
		final forSpan: Null<Span> = forNode.span;
		final scopeSpan: Null<Span> = scope.span;
		if (declName == null || declSpan == null || initSpan == null || forSpan == null || scopeSpan == null) return null;
		if (!isEmptyArrayLiteral(source.substring(initSpan.from, initSpan.to))) return null;
		if (CheckScan.hasCommentMarker(source, declSpan.to, forSpan.from)) return null;
		final annotation: Null<String> = annotationOf(declSpan, initSpan, declName, ctx);
		final element: Null<String> = annotation == null ? null : elementTypeOf(annotation, s.elementTypeParams);
		final acc: Acc = { checks: [], hoisted: [], elementType: element };
		final inner: Null<String> = buildInner(forNode, declName, ctx, acc);
		if (inner == null) return null;
		for (cn in acc.checks) if (referencesName(cn, declName, s)) return null;
		if (!RefactorSupport.referencedInRange(source, declName, forSpan.to, scopeSpan.to, [])) return null;
		final lead: Null<String> = hoistLeadOrRefuse(declSpan, ctx, acc);
		if (lead == null) return null;
		final prefix: String = source.substring(declSpan.from, initSpan.from);
		final keyword: String = source.substring(declSpan.from, declSpan.from + VAR_KEYWORD.length);
		final normalized: String = keyword == VAR_KEYWORD ? 'final${prefix.substring(VAR_KEYWORD.length)}' : prefix;
		return { span: new Span(declSpan.from, forSpan.to), text: '$lead$normalized[$inner];' };
	}

	/**
	 * Transcribe the comprehension body of a qualifying `for` — recursing through `for` headers, braced
	 * bodies and one no-`else` `if` guard down to the terminal `<name>.push(e)` — returning the text
	 * between the comprehension brackets, or null when any layer is off-shape. Appends every iterable,
	 * guard condition and the produced element to `acc.checks` (for the self-reference gate); the push
	 * receiver, being the bound name itself, is never appended.
	 *
	 * A comment on the LAST line of either transcribed HEADER refuses the match — see
	 * `transcribeHeader` for why only that line is the hazard.
	 */
	private static function buildInner(node: QueryNode, name: String, ctx: Ctx, acc: Acc): Null<String> {
		final s: Seams = ctx.seams;
		if (node.kind == s.forStmtKind) {
			final operands: Array<QueryNode> = RefactorSupport.loopOperands(node, s.valueBinderKinds);
			if (operands.length != FOR_CHILD_COUNT) return null;
			final iterable: QueryNode = operands[0];
			final body: QueryNode = operands[1];
			final nodeSpan: Null<Span> = node.span;
			final bodySpan: Null<Span> = body.span;
			if (nodeSpan == null || bodySpan == null) return null;
			final header: Null<String> = transcribeHeader(nodeSpan.from, bodySpan.from, ctx);
			if (header == null) return null;
			acc.checks.push(iterable);
			final rest: Null<String> = buildInner(body, name, ctx, acc);
			return rest == null ? null : '$header $rest';
		}
		if (node.kind == s.blockStmtKind) return buildBlock(node, name, ctx, acc);
		if (s.ifKinds.contains(node.kind)) {
			if (node.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
			final cond: QueryNode = node.children[0];
			final then: QueryNode = node.children[1];
			final nodeSpan: Null<Span> = node.span;
			final thenSpan: Null<Span> = then.span;
			if (nodeSpan == null || thenSpan == null) return null;
			final header: Null<String> = transcribeHeader(nodeSpan.from, thenSpan.from, ctx);
			if (header == null) return null;
			acc.checks.push(cond);
			final rest: Null<String> = buildInner(then, name, ctx, acc);
			return rest == null ? null : '$header $rest';
		}
		final arg: Null<QueryNode> = pushArgument(node, name, ctx, acc);
		if (arg == null) return null;
		final argSpan: Null<Span> = arg.span;
		return argSpan == null ? null : ctx.source.substring(argSpan.from, argSpan.to);
	}

	/**
	 * The verbatim header text `source[from … to)`, right-trimmed, or null when its LAST line carries a
	 * comment marker. The comprehension appends the rest of the body to this text, so only a marker on
	 * that final line can swallow what follows; an EARLIER line's comment is followed by a newline
	 * inside the copied text and transfers intact — which is what keeps a multi-line iterable whose
	 * elements carry trailing `// …` notes eligible. Refusing matters more than a loud failure here:
	 * the reparse validator does catch a broken emission, but it then skips the WHOLE FILE, discarding
	 * every other rule's fix in it. String-blind like every other consumer of the marker scan, and it
	 * also refuses a `/* … *\/` on that line, which would in fact transcribe safely — both are the
	 * conservative direction.
	 */
	private static function transcribeHeader(from: Int, to: Int, ctx: Ctx): Null<String> {
		final header: String = StringTools.rtrim(ctx.source.substring(from, to));
		final lastLine: Int = header.lastIndexOf('\n');
		return RefactorSupport.textHasCommentMarker(header.substring(lastLine + 1)) ? null : header;
	}

	/**
	 * The single argument NODE of a terminal `<name>.push(e)` statement — the produced
	 * element — appended to `acc.checks`, or null when `node` is not exactly that call.
	 * Returning the node rather than its text is what lets the chain arm rewrite inside it.
	 *
	 * The statement's two NON-argument regions are comment-hoisted here, so both the single-
	 * statement arm and the chain arm get it: the element text is `source[argSpan]`, so a comment
	 * sitting inside the push CALL but outside its ARGUMENT would otherwise be dropped — the exact
	 * failure this arm set out to remove. A comment INSIDE the argument span still rides along in
	 * that verbatim text.
	 */
	private static function pushArgument(node: QueryNode, name: String, ctx: Ctx, acc: Acc): Null<QueryNode> {
		final arg: Null<QueryNode> = pushCallArgument(node, name, ctx.seams);
		if (arg == null) return null;
		final argSpan: Null<Span> = arg.span;
		final stmtSpan: Null<Span> = node.span;
		if (argSpan == null || stmtSpan == null) return null;
		hoistCommentsIn(new Span(stmtSpan.from, argSpan.from), ctx, acc);
		hoistCommentsIn(new Span(argSpan.to, stmtSpan.to), ctx, acc);
		acc.checks.push(arg);
		return arg;
	}

	/**
	 * Whether any identifier in `node`'s subtree carries `name` — the self-reference test. A `$name`
	 * string interpolation counts: it projects as its own identifier kind, and `out.push('$out-$x')` reads
	 * the array being built exactly as a bare `out` would. A reification subtree answers TRUE, since
	 * nothing about its contents can be proven.
	 */
	private static function referencesName(node: QueryNode, name: String, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return true;
		if (node.name == name && (node.kind == s.identKind || node.kind == s.interpIdentKind)) return true;
		for (c in node.children) if (referencesName(c, name, s)) return true;
		return false;
	}

	/** Whether `s`, ignoring whitespace, is exactly the empty array literal `[]`. */
	private static function isEmptyArrayLiteral(source: String): Bool {
		return stripWhitespace(source) == '[]';
	}

	/** `source` with every space, tab, carriage return and newline removed. */
	private static function stripWhitespace(source: String): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...source.length) {
			final c: Int = source.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) buf.addChar(c);
		}
		return buf.toString();
	}

	/**
	 * Whether the array declaration's own annotation PROVABLY restates `annotation` at this link's
	 * position — the link must be the whole push argument, and the array's ELEMENT type must be
	 * textually the same type. "The array carries SOME annotation" does not imply that it restates
	 * THIS one: `final out:Array<Dynamic> = []` fed by `final m:Map<String, Int> = new Map()` would
	 * emit a bare `new Map()`, whose type parameters are then unknown and which does not compile.
	 */
	private static function restatesElementType(l: ChainLocal, annotation: String, acc: Acc): Bool {
		final element: Null<String> = acc.elementType;
		return l.wholeArgument && element != null && stripWhitespace(element) == stripWhitespace(annotation);
	}

	/**
	 * The ELEMENT type named by a container annotation `Name<A0, A1, …>` — the argument at the index
	 * `RefShape.indexedElementTypeParams` records for `Name` (Haxe `Array<T>` → 0, `Map<K, V>` → 1).
	 * Null when the annotation is not of that shape, names an unlisted container, or carries too few
	 * arguments; null means NOTHING is restated, so the link keeps its annotation.
	 */
	private static function elementTypeOf(annotation: String, params: Map<String, Int>): Null<String> {
		final trimmed: String = annotation.trim();
		final open: Int = trimmed.indexOf('<');
		final close: Int = trimmed.lastIndexOf('>');
		if (open < 0 || close != trimmed.length - 1) return null;
		final at: Null<Int> = params[trimmed.substring(0, open).trim()];
		if (at == null) return null;
		final args: Array<String> = splitTypeArguments(trimmed.substring(open + 1, close));
		return at < args.length ? args[at] : null;
	}

	/**
	 * Split a type-argument list on its TOP-LEVEL commas. Bracket depth counts `<`, `(`, `[` and
	 * `{` against their closers, and a `>` immediately preceded by `-` is the tail of a function
	 * arrow rather than a closer — without that, `Array<Int -> Int>` mis-splits.
	 */
	private static function splitTypeArguments(list: String): Array<String> {
		final out: Array<String> = [];
		var depth: Int = 0;
		var at: Int = 0;
		for (i in 0...list.length) {
			final c: Int = list.fastCodeAt(i);
			if (c == '<'.code || c == '('.code || c == '['.code || c == '{'.code)
				depth++;
			else if (c == ')'.code || c == ']'.code || c == '}'.code)
				depth--;
			else if (c == '>'.code && (i == 0 || list.fastCodeAt(i - 1) != '-'.code))
				depth--;
			else if (c == ','.code && depth == 0) {
				out.push(list.substring(at, i).trim());
				at = i + 1;
			}
		}
		out.push(list.substring(at).trim());
		return out;
	}

	/**
	 * The comprehension body of a braced block. A single-statement block descends as before
	 * (a nested `for`, one `if` guard, or the terminal push); a longer one is accepted only as
	 * a CHAIN of single-use `final` locals feeding the final `<name>.push(e)`, each local's
	 * initializer inlined into its one use. Every gate refuses by returning null.
	 */
	private static function buildBlock(node: QueryNode, name: String, ctx: Ctx, acc: Acc): Null<String> {
		final kids: Array<QueryNode> = node.children;
		final blockSpan: Null<Span> = node.span;
		if (kids.length == 0 || blockSpan == null) return null;
		hoistGapComments(kids, blockSpan, ctx, acc);
		if (kids.length == 1) return buildInner(kids[0], name, ctx, acc);
		final locals: Null<Array<ChainLocal>> = chainLocals(kids, name, ctx);
		if (locals == null) return null;
		final arg: Null<QueryNode> = pushArgument(kids[kids.length - 1], name, ctx, acc);
		if (arg == null) return null;
		final argSpan: Null<Span> = arg.span;
		if (argSpan == null) return null;
		for (l in locals) {
			l.wholeArgument = l.useSpan.from == argSpan.from && l.useSpan.to == argSpan.to;
			acc.checks.push(l.init);
		}
		return renderSpan(argSpan, locals, ctx, acc);
	}

	/**
	 * Append every comment token sitting in a GAP of the block's statement list — before the
	 * first child, between two adjacent children, or after the last — to `acc.hoisted`. Such a
	 * comment documents the body being dissolved into the comprehension, so the fix lifts it above
	 * the declaration instead of dropping it (which is what the merge did before, silently, even
	 * for a single-statement body). Each token carries its offset: a nested block contributes its
	 * own gaps after this one, so source order is restored by sorting, not by append order.
	 */
	private static function hoistGapComments(kids: Array<QueryNode>, blockSpan: Span, ctx: Ctx, acc: Acc): Void {
		var at: Int = blockSpan.from;
		for (kid in kids) {
			final kidSpan: Null<Span> = kid.span;
			if (kidSpan == null) continue;
			hoistCommentsIn(new Span(at, kidSpan.from), ctx, acc);
			at = kidSpan.to;
		}
		hoistCommentsIn(new Span(at, blockSpan.to), ctx, acc);
	}

	/** Append every comment token lying FULLY inside `span` to `acc.hoisted`, with its offset. */
	private static function hoistCommentsIn(span: Span, ctx: Ctx, acc: Acc): Void {
		for (tok in ctx.comments) if (tok.from >= span.from && tok.to <= span.to)
			acc.hoisted.push({ from: tok.from, text: ctx.source.substring(tok.from, tok.to) });
	}

	/**
	 * The chain links of a multi-statement block — `kids` minus its last statement — or null when
	 * any of them fails a `chainLink` gate, or when the uses do not appear in DECLARATION order.
	 * Ordering the links against EACH OTHER is only half of evaluation-order preservation:
	 * `out.push(h(b, a))` after `final a = f(); final b = g();` would run `g` before `f` and is
	 * refused here, while a link overtaking code that is not a link at all — `out.push(next() + a)`
	 * after `final a = pop();` — is `chainLink`'s preceding-purity gate.
	 */
	private static function chainLocals(kids: Array<QueryNode>, name: String, ctx: Ctx): Null<Array<ChainLocal>> {
		final locals: Array<ChainLocal> = [];
		for (i in 0...kids.length - 1) {
			final link: Null<ChainLocal> = chainLink(kids, i, name, ctx, locals);
			if (link == null) return null;
			locals.push(link);
		}
		for (i in 1...locals.length) if (locals[i].useSpan.from <= locals[i - 1].useSpan.from) return null;
		return locals;
	}

	/**
	 * `kids[i]` as one chain link — a single-use `final` local whose initializer may be inlined into its
	 * one use somewhere in `kids[i + 1 …]` — or null when a gate refuses: a `var` (reassignable between
	 * declaration and use), a multi-variable list (whose continuation projects as a second child), a name
	 * already `taken` or equal to the array's own, a comment INTERSECTING the declaration (dissolving it
	 * would strand the comment inside an expression — a comment inside the terminal push statement is
	 * fine, it rides along in the verbatim argument text), or a use count other than one.
	 *
	 * Three gates then guard the ONE use's evaluation, against `kids[j]`, the sibling statement the use
	 * lives in, and specifically its VALUE REGION: every ancestor from that statement's root down must be
	 * an EAGER HOST, so the use runs exactly once, in place; the region must hold no `?.` anywhere, since
	 * a safe-nav call makes its whole argument list conditional from a position the spine walk cannot see;
	 * and nothing impure in the region may lie ENTIRELY BEFORE the use, because inlining moves the
	 * initializer there and everything the region evaluated first would then run ahead of it.
	 */
	private static function chainLink(kids: Array<QueryNode>, i: Int, name: String, ctx: Ctx, taken: Array<ChainLocal>): Null<ChainLocal> {
		final s: Seams = ctx.seams;
		final decl: QueryNode = kids[i];
		if (!s.localDeclKinds.contains(decl.kind) || s.mutableDeclKinds.contains(decl.kind)) return null;
		if (s.continuationKinds.contains(decl.kind) || decl.children.length != 1) return null;
		final declName: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final init: QueryNode = decl.children[0];
		final initSpan: Null<Span> = init.span;
		if (declName == null || declSpan == null || initSpan == null || declName == name) return null;
		for (l in taken) if (l.name == declName) return null;
		if (commentIntersects(declSpan, ctx)) return null;
		final uses: Array<Use> = [];
		var useHost: Null<QueryNode> = null;
		for (j in i + 1...kids.length) {
			final before: Int = uses.length;
			collectUses(kids[j], null, 0, declName, true, s, uses);
			if (useHost == null && uses.length > before) useHost = kids[j];
		}
		if (uses.length != 1) return null;
		final useSpan: Null<Span> = uses[0].node.span;
		final host: Null<QueryNode> = useHost;
		if (useSpan == null || host == null || !useRunsInPlace(host, uses[0], useSpan, name, s)) return null;
		// Re-bound as non-null locals: field narrowing does not reach an anonymous struct literal.
		final boundName: String = declName;
		final declRange: Span = declSpan;
		final initRange: Span = initSpan;
		final useRange: Span = useSpan;
		return {
			name: boundName,
			init: init,
			initSpan: initRange,
			annotation: annotationOf(declRange, initRange, boundName, ctx),
			useSpan: useRange,
			useParent: uses[0].parent,
			useIndex: uses[0].index,
			wholeArgument: false
		};
	}

	/**
	 * Collect every identifier named `name` in `node`'s subtree, each with the tree parent and child index
	 * its inlining would land in, and whether EVERY ancestor from the scanned statement down to it is an
	 * eager host — only then does the use run exactly once, right where the declaration ran.
	 *
	 * Two shapes are recorded as NON-eager uses, so they refuse the link either on the count or on the
	 * spine gate. A `$name` string interpolation projects as its own identifier kind and is a real read
	 * that can never be rewritten in place; a reification subtree is the one region where nothing can be
	 * proven, so it refuses wholesale rather than being skipped (a `macro` anywhere in a later sibling
	 * therefore refuses the chain — conservative, and the kind is rare).
	 */
	private static function collectUses(
		node: QueryNode, parent: Null<QueryNode>, index: Int, name: String, eager: Bool, s: Seams, out: Array<Use>
	): Void {
		if (s.opaqueKinds.contains(node.kind) || (node.kind == s.interpIdentKind && node.name == name)) {
			out.push({
				node: node,
				parent: parent,
				index: index,
				eager: false
			});
			return;
		}
		if (node.kind == s.identKind && node.name == name) {
			out.push({
				node: node,
				parent: parent,
				index: index,
				eager: eager
			});
			return;
		}
		final inner: Bool = eager && s.eagerKinds.contains(node.kind);
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length) collectUses(kids[i], node, i, name, inner, s, out);
	}

	/**
	 * Whether inlining a link's initializer into its single `use` — which lives in the sibling statement
	 * `host` — leaves it running exactly once, in the same order. Three independent hazards, each closed
	 * by its own walk:
	 *
	 * - an ancestor of the use that is not an EAGER HOST defers, skips, repeats or REBINDS it;
	 * - a `?.` anywhere in the host's value region makes a whole argument list conditional from a position
	 *   the ancestor walk cannot see — the safe-nav node is a SIBLING of the use, not an ancestor;
	 * - anything impure lying ENTIRELY BEFORE the use ran AFTER the declaration and would now run in front
	 *   of it.
	 *
	 * Both walks run over the host's VALUE REGION rather than the whole statement, so the push callee —
	 * which is before the argument by construction and provably harmless — cannot refuse them.
	 */
	private static function useRunsInPlace(host: QueryNode, use: Use, useSpan: Span, name: String, s: Seams): Bool {
		if (!use.eager) return false;
		final region: Null<QueryNode> = valueRegion(host, name, s);
		if (region == null) return false;
		final nullSafeKind: Null<String> = s.nullSafeKind;
		if (nullSafeKind != null && containsKind(region, nullSafeKind, s)) return false;
		return precedingNodesPure(region, useSpan.from, s);
	}

	/**
	 * The part of `host` whose evaluation an inlined use must not overtake: a local declaration's
	 * INITIALIZER, or the terminal push statement's ARGUMENT. A host of neither shape refuses.
	 *
	 * The push CALLEE is deliberately outside the region. It is a field access lying entirely before
	 * the argument, so scanning it would refuse every match once a field access stopped counting as
	 * pure — and it is no hazard: its receiver is the array LOCAL by construction, which
	 * `pushArgument` proves before any of this runs.
	 */
	private static function valueRegion(host: QueryNode, name: String, s: Seams): Null<QueryNode> {
		return s.localDeclKinds.contains(host.kind)
			? (host.children.length == 1 ? host.children[0] : null)
			: pushCallArgument(host, name, s);
	}

	/**
	 * Whether every node of `node`'s subtree lying ENTIRELY before offset `at` is pure. Inlining
	 * moves a link's initializer from before the whole statement to the use position, so everything
	 * the target evaluates first now runs before it — which the declaration-order gate, ordering the
	 * links only against EACH OTHER, says nothing about. A flat walk suffices: an impure child of a
	 * pure parent is itself entirely-before and is caught. Nodes that merely CONTAIN the use are
	 * ancestors, which the eager-host spine gate covers instead.
	 */
	private static function precedingNodesPure(node: QueryNode, at: Int, s: Seams): Bool {
		final span: Null<Span> = node.span;
		if (span != null && span.to <= at && !s.pureKinds.contains(node.kind)) return false;
		for (c in node.children) if (!precedingNodesPure(c, at, s)) return false;
		return true;
	}

	/**
	 * Whether any comment token overlaps `span`. Dissolving a declaration a comment sits across
	 * would strand that comment inside an expression; a comment inside the terminal push statement
	 * is a different matter — `pushArgument` hoists it, or the argument text carries it verbatim.
	 */
	private static function commentIntersects(span: Span, ctx: Ctx): Bool {
		for (tok in ctx.comments) if (tok.from < span.to && tok.to > span.from) return true;
		return false;
	}

	/** Whether `kind` appears anywhere in `node`'s subtree, reification aside. */
	private static function containsKind(node: QueryNode, kind: String, s: Seams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return false;
		if (node.kind == kind) return true;
		for (c in node.children) if (containsKind(c, kind, s)) return true;
		return false;
	}

	/**
	 * The type annotation written on a local declaration, or null when it carries none. The tree
	 * holds no type child for a local, so it is read off the source head: everything before the
	 * LAST `=`, then the first `:` at or after the last STANDALONE occurrence of the declared name
	 * (standalone so a leading `@:meta` cannot be mistaken for the annotation, and a type whose own
	 * spelling ends in the name — `t:MyToolt` — cannot swallow it).
	 */
	private static function annotationOf(declSpan: Span, initSpan: Span, name: String, ctx: Ctx): Null<String> {
		final prefix: String = ctx.source.substring(declSpan.from, initSpan.from);
		final eq: Int = prefix.lastIndexOf('=');
		if (eq < 0) return null;
		final head: String = prefix.substring(0, eq);
		final at: Int = lastIdentIndex(head, name);
		if (at < 0) return null;
		final colon: Int = head.indexOf(':', at);
		if (colon < 0) return null;
		final text: String = head.substring(colon + 1).trim();
		return text == '' ? null : text;
	}

	/** The index of the LAST occurrence of `name` in `head` that stands alone as an identifier, or -1. */
	private static function lastIdentIndex(head: String, name: String): Int {
		var at: Int = head.lastIndexOf(name);
		while (at >= 0) {
			final after: Int = at + name.length;
			final openLeft: Bool = at == 0 || !isIdentChar(head.fastCodeAt(at - 1));
			final openRight: Bool = after >= head.length || !isIdentChar(head.fastCodeAt(after));
			if (openLeft && openRight) return at;
			if (at == 0) return -1;
			at = head.lastIndexOf(name, at - 1);
		}
		return -1;
	}

	/** Whether `c` may appear inside an identifier — a letter, a digit or an underscore. */
	private static function isIdentChar(c: Int): Bool {
		return c == '_'.code || (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code);
	}

	/** `source[span]` with every chain local's single use replaced by its (recursively rendered) initializer. */
	private static function renderSpan(span: Span, locals: Array<ChainLocal>, ctx: Ctx, acc: Acc): String {
		final inside: Array<ChainLocal> = [for (l in locals) if (l.useSpan.from >= span.from && l.useSpan.to <= span.to) l];
		inside.sort((a, b) -> a.useSpan.from - b.useSpan.from);
		final buf: StringBuf = new StringBuf();
		var at: Int = span.from;
		for (l in inside) {
			buf.add(ctx.source.substring(at, l.useSpan.from));
			buf.add(renderLocal(l, locals, ctx, acc));
			at = l.useSpan.to;
		}
		buf.add(ctx.source.substring(at, span.to));
		return buf.toString();
	}

	/**
	 * One local's inlined text: its rendered initializer, ASCRIBED with the declaration's type annotation
	 * unless the boundary provably restates it, and parenthesised when the use position is not already
	 * delimited and the initializer is not self-delimiting.
	 *
	 * An annotation can be what TYPES the initializer — an unchecked `cast e` takes its result type from
	 * the context, `final d:Dynamic = x` widens, `final m:Map<String,Int> = new Map()` binds the type
	 * parameters — so dropping it changes the expression's type or fails to compile outright.
	 */
	private static function renderLocal(l: ChainLocal, locals: Array<ChainLocal>, ctx: Ctx, acc: Acc): String {
		final inner: String = renderSpan(l.initSpan, locals, ctx, acc);
		final annotation: Null<String> = l.annotation;
		if (annotation != null && !restatesElementType(l, annotation, acc)) return '($inner : $annotation)';
		final delimited: Bool = ctx.seams.atomKinds.contains(l.init.kind) || isDelimitedUse(l, ctx.seams);
		return delimited ? inner : '($inner)';
	}

	/**
	 * Whether the use sits in a position the surrounding construct already brackets — a call
	 * argument, a `new` argument, an array element, a grouping paren, an object-literal value or an
	 * index subscript — so no operator outside can bind into what replaces it. An incomplete list
	 * only costs a redundant pair of parentheses, which is the safe direction.
	 *
	 * A local declaration's INITIALIZER is deliberately not among them: that position is DISSOLVED
	 * by this very fix, so it delimits nothing. Treating it as delimited let `final a = x + 1;
	 * final b = a; out.push(b * 2);` render as `x + 1 * 2` — a silently wrong value, since `b`'s
	 * own kind is an atom and the outer test then declines to wrap too.
	 */
	private static function isDelimitedUse(l: ChainLocal, s: Seams): Bool {
		final parent: Null<QueryNode> = l.useParent;
		if (parent == null) return false;
		final kind: String = parent.kind;
		if (kind == s.callKind) return l.useIndex >= 1;
		final bracketed: Bool = kind == s.newExprKind || kind == s.parenKind || kind == s.arrayLiteralKind || kind == s.objectFieldKind;
		return bracketed || (kind == s.indexAccessKind && l.useIndex == 1);
	}

	/**
	 * The SELF-DELIMITING expression kinds: the grammar's own atom vocabulary plus every
	 * bracket-closed form it publishes (a call, a `new`, an index access, a grouping paren, an
	 * array literal and the typed casts). An initializer rooted at one of these needs no
	 * parentheses in any operand position.
	 */
	private static function readAtomKinds(shape: RefShape): Array<String> {
		final out: Array<String> = (shape.atomExprKinds ?? []).concat(shape.atomChainKinds ?? []);
		pushNonNull(out, [
			shape.callKind,
			shape.newExprKind,
			shape.indexAccessKind,
			shape.parenKind,
			shape.arrayLiteralKind
		]);
		return out.concat(shape.typedCastKinds ?? []);
	}

	/**
	 * The PURE expression vocabulary: kinds whose evaluation cannot be observed, so moving code across
	 * them changes nothing — identifiers, literals, grouping parens, array and structure literals and
	 * their fields, the unary operators, the arithmetic / equality / value-comparison operators, the `is`
	 * test and the UNCHECKED cast. Assembled from EXISTING `RefShape` seams; an unset one only costs
	 * reach, because an unlisted kind REFUSES.
	 *
	 * Deliberately NOT here, though each is EAGER: a field access (which may be a property getter), an
	 * index access (which may be `Map.get` or an `@:arrayAccess` abstract) and a CHECKED cast (which
	 * throws on a non-null mismatch). The two vocabularies answer orthogonal questions and are built from
	 * separate lists for that reason. `comparisonKinds` stays out too: it lumps the short-circuiting `&&`
	 * / `||` in with the value comparisons, while `comparisonOperandHostKinds` is the same tier without
	 * them.
	 *
	 * The RESIDUAL is named rather than claimed away: a property getter behind a BARE identifier and an
	 * `@:op` overload behind an operator can still hide an effect. This is a bounded, known gap, not a
	 * proof of purity.
	 */
	private static function readPureKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [shape.identKind].concat(shape.numericLiteralKinds ?? [])
			.concat(shape.stringLiteralKinds ?? [])
			.concat(shape.atomExprKinds ?? [])
			.concat(shape.structureFieldHostKinds ?? [])
			.concat(shape.numericOperatorKinds ?? [])
			.concat(shape.equalityKinds ?? [])
			.concat(shape.additiveKinds ?? [])
			.concat(shape.unaryMinusKinds ?? [])
			.concat(shape.comparisonOperandHostKinds ?? []);
		pushNonNull(out, [
			shape.boolLitKind,
			shape.nullLiteralKind,
			shape.parenKind,
			shape.arrayLiteralKind,
			shape.objectFieldKind,
			shape.isExprKind,
			shape.notKind,
			shape.negationKind,
			shape.uncheckedCastKind
		]);
		return out;
	}

	/**
	 * The EAGER HOST vocabulary: kinds that evaluate their children exactly once, in place. A use whose
	 * whole ancestor spine is one of these runs precisely where its declaration ran. Everything else
	 * refuses BY ABSENCE: a lambda, a local function, an `if` / `switch` / `try` expression, a block
	 * expression, an expression loop (the array comprehension included), a ternary, a short-circuiting
	 * operator, a compound assignment, and every binding construct that could REBIND the link's name (the
	 * use scan matches on name, with no scope awareness).
	 *
	 * Built from its OWN seam list, NOT from `pureKinds`. "Can evaluation be observed?" and "does this
	 * evaluate its children exactly once, in place?" are orthogonal questions, and the overlap of the two
	 * answers is a coincidence of vocabularies: a field access, an index access and a checked cast are
	 * eager but NOT pure, so deriving one list from the other would force a wrong answer on one side.
	 */
	private static function readEagerKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [shape.identKind].concat(shape.numericLiteralKinds ?? [])
			.concat(shape.stringLiteralKinds ?? [])
			.concat(shape.atomExprKinds ?? [])
			.concat(shape.atomChainKinds ?? [])
			.concat(shape.structureFieldHostKinds ?? [])
			.concat(shape.typedCastKinds ?? [])
			.concat(shape.numericOperatorKinds ?? [])
			.concat(shape.equalityKinds ?? [])
			.concat(shape.additiveKinds ?? [])
			.concat(shape.unaryMinusKinds ?? [])
			.concat(shape.comparisonOperandHostKinds ?? [])
			.concat(shape.localDeclKinds ?? []);
		pushNonNull(out, [
			shape.boolLitKind,
			shape.nullLiteralKind,
			shape.fieldAccessKind,
			shape.forceFieldAccessKind,
			shape.indexAccessKind,
			shape.parenKind,
			shape.arrayLiteralKind,
			shape.objectFieldKind,
			shape.isExprKind,
			shape.notKind,
			shape.negationKind,
			shape.uncheckedCastKind,
			shape.callKind,
			shape.newExprKind,
			shape.exprStatementKind
		]);
		return out;
	}

	/** Append every non-null entry of `kinds` to `out` — the optional-seam idiom the vocabulary builders share. */
	private static function pushNonNull(out: Array<String>, kinds: Array<Null<String>>): Void {
		for (kind in kinds) if (kind != null) out.push(kind);
	}

	/**
	 * The text prefixing the replacement: each hoisted body comment on its own line at the
	 * declaration's indent, in source order, or the empty string when none was hoisted. Null
	 * REFUSES the match — the declaration does not start its line, so a comment placed above it
	 * would also comment out whatever shares that line.
	 */
	private static function hoistLeadOrRefuse(declSpan: Span, ctx: Ctx, acc: Acc): Null<String> {
		if (acc.hoisted.length == 0) return '';
		final lineStart: Int = RefactorSupport.startOfLine(ctx.source, declSpan.from);
		final indent: String = ctx.source.substring(lineStart, declSpan.from);
		if (indent.trim() != '') return null;
		acc.hoisted.sort((a, b) -> a.from - b.from);
		final buf: StringBuf = new StringBuf();
		for (comment in acc.hoisted) {
			buf.add(comment.text);
			buf.add('\n');
			buf.add(indent);
		}
		return buf.toString();
	}


	/**
	 * The single argument NODE of a `<name>.push(e)` expression statement, or null when `node` is
	 * not exactly that call — the shape test alone, with no side effects, so both the transcriber
	 * and the evaluation-order gate can ask it.
	 */
	private static function pushCallArgument(node: QueryNode, name: String, s: Seams): Null<QueryNode> {
		if (node.kind != s.exprStmtKind || node.children.length != 1) return null;
		final call: QueryNode = node.children[0];
		if (call.kind != s.callKind || call.children.length != PUSH_CALL_CHILD_COUNT) return null;
		final callee: QueryNode = call.children[0];
		if (callee.kind != s.fieldAccessKind || callee.name != 'push' || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind == s.identKind && receiver.name == name ? call.children[1] : null;
	}

}

/** The `RefShape` kinds `PreferComprehension` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var forStmtKind: String;
	var localDeclKinds: Array<String>;
	var callKind: String;
	var fieldAccessKind: String;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var identKind: String;
	var ifKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var interpIdentKind: Null<String>;
	var valueBinderKinds: Array<String>;
	var mutableDeclKinds: Array<String>;
	var continuationKinds: Array<String>;
	var nullSafeKind: Null<String>;
	var newExprKind: Null<String>;
	var parenKind: Null<String>;
	var arrayLiteralKind: Null<String>;
	var indexAccessKind: Null<String>;
	var objectFieldKind: Null<String>;
	var elementTypeParams: Map<String, Int>;
	var atomKinds: Array<String>;
	var pureKinds: Array<String>;
	var eagerKinds: Array<String>;
}

/** A flagged declaration-plus-loop pair: the full replacement span and its comprehension text. */
private typedef Match = {
	var span: Span;
	var text: String;
}

/** Per-file inputs the walkers share: the source, the resolved seams and the file's comment tokens (lexed once). */
private typedef Ctx = {
	var source: String;
	var seams: Seams;
	var comments: Array<{ from: Int, to: Int, isLine: Bool }>;
}

/**
 * Per-match accumulators: nodes the self-reference gate must scan, comment texts to hoist above the
 * result, and the ARRAY declaration's ELEMENT type — the one thing that can restate a link sitting at
 * the whole-push-argument position, letting it drop its own annotation.
 */
private typedef Acc = {
	var checks: Array<QueryNode>;
	var hoisted: Array<{ from: Int, text: String }>;
	var elementType: Null<String>;
}

/**
 * One link of the inlining chain: the declared local, its initializer, the single use the initializer
 * replaces, and whether that use is the ENTIRE push argument — the one position where the array
 * declaration's own annotation restates the link's.
 */
private typedef ChainLocal = {
	var name: String;
	var init: QueryNode;
	var initSpan: Span;
	var annotation: Null<String>;
	var useSpan: Span;
	var useParent: Null<QueryNode>;
	var useIndex: Int;
	var wholeArgument: Bool;
}

/**
 * One identifier occurrence found by the chain's use scan, with the slot it would be inlined into and
 * whether every ancestor down to it is an eager host.
 */
private typedef Use = {
	var node: QueryNode;
	var parent: Null<QueryNode>;
	var index: Int;
	var eager: Bool;
}
