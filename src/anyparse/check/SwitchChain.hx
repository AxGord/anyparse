package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

/**
 * The shared scanner / renderer behind BOTH switch checks: `prefer-switch` (an `if` /
 * `else if` chain in STATEMENT position) and `prefer-switch-expression` (a ternary /
 * if-expression chain in VALUE position). The two rules differ only in which node kinds
 * head a chain, which parents may host the result, and whether a rendered branch body needs
 * a terminator — the first and third are `ChainSeams` fields the rule supplies, the host
 * gate a predicate it passes in. Everything else (what a rung's condition may look like,
 * which constants are valid `case` patterns, how the discriminants must line up, how the
 * switch is spelled, and the whole of each rule's `run` / `fix` body) is one body of rules
 * and lives here. Pure statics, no state: a check parses independently in `run` and in
 * `fix`, so nothing may be cached across the two.
 *
 * ## What a chain is
 *
 * A right-nested run of `chainKinds` nodes, each `[cond, then, else]`, reached from a
 * HEAD (a chain node that is not itself another chain node's else-slot). The run ends at
 * an else-slot that is not a chain node — that slot's value becomes `case _`. Every rung
 * must satisfy every gate below or the WHOLE chain is skipped: a partial conversion is
 * never emitted.
 *
 * ## Gates, and why each exists
 *
 * 1. **At least two rungs.** A lone `if` / a single ternary is not a chain, and a
 *    one-arm switch reads worse than the conditional it replaced.
 * 2. **Condition shape.** After stripping `parenKind` wrappers, the condition must be a
 *    flat left-associative `andKind` conjunction of `eqKind` nodes (a single `Eq` being
 *    the one-discriminant case). ANY other node in the conjunction — a `!=`, an ordering
 *    comparison, a call, a bare identifier — skips the chain: only `==` maps to a `case`
 *    pattern, and a `||` is not `andKind` so a mixed `&&` / `||` condition is rejected by
 *    the same test.
 * 3. **One constant per equality.** Each `Eq` must have EXACTLY one pattern-valid
 *    constant operand (gate 6); the other operand is that position's discriminant. Both
 *    constant or neither means there is no discriminant to switch on.
 * 4. **Uniform discriminant tuple.** Every rung must yield the SAME discriminants,
 *    positionally, compared with `RefactorSupport.sameSource`. A rung testing a SUBSET of
 *    the tuple is NOT wildcard-padded in this version (`a == C` -> `case [C, _]` is
 *    sound, first-match order being preserved, but it needs a per-position padding pass
 *    this scanner does not do) and a rung whose conjuncts are written in a different ORDER
 *    is likewise skipped — both are follow-ups.
 * 5. **Call-free discriminants.** Every discriminant must be free of `callKind`: a switch
 *    evaluates its subject ONCE where the chain evaluates it per rung, so a call there is
 *    a behaviour change. Branch BODIES are deliberately unconstrained — a body is one
 *    value evaluated once either way, so a call in it is safe. A grammar that declares no
 *    `callKind` cannot prove call-freedom at all, so this gate then rejects EVERY chain
 *    rather than waving one through unchecked.
 * 6. **Pattern-valid constants.** An operand qualifies as a `case` pattern when it is
 *    either
 *    (a) a non-string literal kind (`litKinds`) or an interpolation-free string (via
 *        `stringFold.literalOf`, which yields null for an interpolated `'$x'`, whose
 *        value is not a compile-time constant); or
 *    (b) a QUALIFIED STATIC reference `T.M` — a `fieldAccessKind` node over a bare
 *        `identKind` receiver — that the `SymbolIndex` resolves to at least one member
 *        declaration, EVERY one of which is an unguarded field that is either an
 *        enum-abstract VALUE (a member of an `enumAbstractDeclKind` with no `static`
 *        modifier — always a compile-time constant) or a `static inline` field. The
 *        `inline` requirement is the LANGUAGE's own constness proof: Haxe refuses
 *        `inline` on a non-constant initializer (`Inline variable initialization must be
 *        a constant value`), so a `static inline` field is constant by construction. A
 *        plain `static final` is NOT accepted — it may hold anything, and
 *        `public static final A:Array<Int> = [1];` written as `case T.A` is
 *        `Incompatible pattern` (verified on 4.3.7). A member declared inside `#if` is
 *        branch-dependent while the index is branch-blind. Anything unresolvable,
 *        guarded or non-inline skips the whole chain — the index has documented blind
 *        spots (anonymous fields, `> Base` extension scope, conditional types), so the
 *        answer to any uncertainty is SKIP, never guess. A DOTTED receiver
 *        (`pkg.Mod.CONST`) and a plain-enum constructor (`E.X`, provable but needing a
 *        constructor-arity check) are follow-ups.
 * 7. **A trailing `else`, unconditionally.** The chain must end in an else-slot, whose value
 *    is rendered as `case _`; a converted chain therefore ALWAYS carries a wildcard, and an
 *    else-less chain is not flagged at all. This is a deliberate retreat. A waiver did ship,
 *    asking whether the SUBJECT's declared-type nominal was one the compiler does not
 *    enumerate, and it kept leaking non-compiling output. Every case below was reproduced on
 *    4.3.7:
 *    - a `Bool` subject: `if (b == true) … else if (b == null) …` renders
 *      `switch (b) { case true: … case null: … }` — `Unmatched patterns: false`, two values
 *      being few enough for the compiler to enumerate them;
 *    - an `enum abstract Mode(Int) from Int to Int` subject tested with plain `Int` literals
 *      — `Unmatched patterns: C`: the PATTERN's type says nothing about the subject's;
 *    - the same chain with the constants declared on an unrelated CLASS — the declaring type
 *      is open while the subject stays closed, so reading the pattern side answers nothing;
 *    - a tuple subject: `switch [a, b] { case [1, 2]: … case [3, 4]: … }` over two `Int`s is
 *      `Unmatched patterns: _`, an array pattern always being exhaustiveness-checked;
 *    - a project type SHADOWING a built-in's name. An allowlist of open type names matches a
 *      SIMPLE nominal, so `enum abstract Int32(Int)` has to be refused — and the refusal
 *      cannot be made to hold. The legacy spelling `@:enum abstract Int32(Int)` projects as
 *      `AbstractDecl`, a kind no closed-kind list may contain (std's `Int` / `Float` / `UInt`
 *      / `haxe.Int32` are all abstracts, so listing it would switch the waiver off wholesale
 *      under any std-bearing resolution scope); `import pkg.Kind as Int32;` BINDS the name
 *      without DECLARING it, so a declaration scan never sees it; and a shadowing type in the
 *      subject's own package is invisible to a single-file `lint Main.hx --fix` altogether —
 *      the guard is only ever as wide as the lint's REPORT scope, which the caller chooses;
 *    - a `#if`-guarded trailing `else`. `if (n == 1) a(); else if (n == 2) b(); #if js else
 *      c(); #end` projects as `(IfStmt cond then (IfStmt …)) (Conditional (OrphanElseStmt …))`
 *      — the guarded `else` is a SIBLING of the chain, never the inner `if`'s else-slot — so
 *      the chain reads as else-less, and converting it stranded an `#if` block that no longer
 *      parses (`Expected }`). The unconditional rule closes this one BY CONSTRUCTION: an
 *      else-less chain is refused, so the shape is never reached.
 *    A purely STRUCTURAL guard was tried and cannot be completed. The first four cases say
 *    exhaustiveness is a property of the SUBJECT's type, not of the patterns; the last two
 *    say no index can be trusted to say what a type NAME resolves to, the answer depending on
 *    imports and on scope the lint run may not have been given. FOLLOW-UP: restoring the
 *    else-less conversion needs the COMPILER's answer, not a resolver's. Its home is the
 *    `OracleAssisted` / `RiskyFix` machinery (`Check.hx`, `FixVerifier`), which typechecks an
 *    emitted fix and reverts it when the build breaks. Neither switch rule implements those
 *    interfaces today; this paragraph is the record of why a structural guard must not be
 *    re-derived.
 * 8. **Comments.** A chain whose span carries a comment token is report-only: comments
 *    between rungs live in trivia the verbatim-body rebuild would drop, and losing one is
 *    worse than leaving the chain alone. Enforced in `editsOf`, so the finding still
 *    reports.
 *
 * ## Rendering
 *
 * With one discriminant: `switch (D) { case P: BODY … case _: ELSE }` — byte-identical to
 * what `prefer-switch` emitted before this module existed. With several:
 * `switch [D1, D2] { case [P1, P2]: … }`, written with `tuplePatternDelimiters` and NO
 * outer parentheses (a parenthesised tuple subject would draw a `redundant-parens` finding
 * on the result). The `case _` line is unconditional, gate 7 having already refused every
 * chain that could not supply its body. `seams.bodyTerminator` is appended after each branch
 * body — empty for the statement rule, whose bodies already carry their own `;` / `{}`, and
 * `;` for the expression rule, whose bodies are bare expressions. Bodies and patterns are
 * taken VERBATIM from the source; the emitted text is tabs and newlines only, and the
 * canonical pipeline reformats it.
 *
 * ## Two documented behaviour deltas, both deliberate
 *
 * - A TUPLE switch evaluates every discriminant eagerly where the `&&` chain
 *   short-circuits. Gate 5 keeps calls out, so the only way to observe the difference is
 *   a member access that THROWS (a null receiver) in a position the chain would have
 *   skipped. Both checks are `Info` — a suggestion an author reviews — and narrowing
 *   further would cost the axis its realistic inputs.
 * - A single-discriminant switch over a NULLABLE subject inherits the exposure
 *   `nullable-switch-missing-null` already documents for hand-written switches: `case _`
 *   does not run the null check on every target. That is unchanged from what
 *   `prefer-switch` has always emitted, and that rule is the designed net. A TUPLE
 *   subject is a fresh array literal and is never null, so `case _` there is
 *   unconditionally reachable.
 *
 * ## Grammar-agnostic
 *
 * Every kind is a `RefShape` seam resolved once per run by `seamsOf`; no language name is
 * written here. A grammar that leaves `tuplePatternDelimiters` unset simply never gets
 * past a multi-discriminant rung, and one that leaves `fieldAccessKind` or
 * `enumAbstractDeclKind` unset stays on literal patterns — each of those degrades toward
 * reporting LESS. `callKind` is the one seam whose absence would degrade the other way, a
 * call-bearing discriminant sailing through, so gate 5 inverts it: no call kind means
 * call-freedom is unprovable, and the chain is skipped.
 */
@:nullSafety(Strict)
final class SwitchChain {

	/** A chain node carrying an else-slot has children `[cond, then, else]`. */
	private static inline final CHAIN_WITH_ELSE_CHILD_COUNT: Int = 3;

	/** The else-slot's index among a chain node's children. */
	private static inline final ELSE_SLOT_INDEX: Int = 2;

	/** A binary operator node has exactly `[left, right]` children. */
	private static inline final BINARY_CHILD_COUNT: Int = 2;

	/**
	 * Resolve the configuration both switch checks scan and render against: the caller's
	 * `chainKinds` and `bodyTerminator`, and the `RefShape` seams. Null when a REQUIRED seam
	 * is unset — an empty `chainKinds`, no `eqKind` (without `==` nothing maps to a `case`
	 * pattern) or no `caseLiteralKinds`. The optional seams degrade individually: no
	 * `andKind` leaves only single-discriminant conditions, no `tuplePatternDelimiters`
	 * rejects a multi-discriminant chain at scan time, no `fieldAccessKind` /
	 * `enumAbstractDeclKind` keeps patterns literal, and no `callKind` rejects every chain
	 * (gate 5 cannot prove call-freedom without it).
	 */
	public static function seamsOf(plugin: GrammarPlugin, chainKinds: Array<String>, bodyTerminator: String): Null<ChainSeams> {
		final shape: RefShape = plugin.refShape();
		final eqKind: Null<String> = shape.eqKind;
		final litKinds: Array<String> = shape.caseLiteralKinds ?? [];
		if (chainKinds.length == 0 || eqKind == null || litKinds.length == 0) return null;
		return {
			chainKinds: chainKinds,
			bodyTerminator: bodyTerminator,
			eqKind: eqKind,
			litKinds: litKinds,
			fieldKinds: shape.fieldDeclKinds ?? [],
			andKind: shape.logicalAndKind,
			parenKind: shape.parenKind,
			callKind: shape.callKind,
			fieldAccessKind: shape.fieldAccessKind,
			identKind: shape.identKind,
			enumAbstractDeclKind: shape.enumAbstractDeclKind,
			tuple: shape.tuplePatternDelimiters,
			stringFold: plugin.stringFoldSupport()
		};
	}

	/**
	 * The whole `Check.run` body of a switch rule: one `Info` per accepted chain head
	 * across `files`, tagged `rule` and described by `message(subject)`. `hostAccepts`
	 * gates a head by its PARENT kind — the statement rule accepts any host, the
	 * expression rule a whitelist.
	 */
	public static function violationsOf(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, seams: ChainSeams, hostAccepts: Null<String> -> Bool,
		rule: String, message: (String) -> String
	): Array<Violation> {
		final resolveIndex: () -> Null<SymbolIndex> = lazyIndexOf(files, plugin);
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final file: String = entry.file;
			final source: String = entry.source;
			eachHead(tree, seams, hostAccepts, head -> {
				final span: Null<Span> = head.span;
				final scanned: Null<ChainScan> = span == null ? null : scan(source, head, seams, resolveIndex);
				if (span == null || scanned == null) return;
				final subject: Null<String> = subjectText(scanned, seams);
				if (subject == null) return;
				out.push({
					file: file,
					span: span,
					rule: rule,
					severity: Severity.Info,
					message: message(subject)
				});
			});
		}
		return out;
	}

	/**
	 * The whole `Check.fix` body of a switch rule: re-parse `source`, re-find the chain
	 * heads, and emit one replace edit per head whose span matches a passed violation. A
	 * head carrying a comment is skipped (report-only) — comments between rungs live in
	 * trivia the verbatim-body rebuild would drop — as is one that no longer scans or
	 * renders. `index` is the lint run's cross-file index when the caller has one; without
	 * it a constant declared in another file is unresolvable and its chain stays
	 * report-only, the conservative direction. An empty flagged set returns at once, before
	 * the source is parsed or re-tokenised for comments.
	 */
	public static function editsOf(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, seams: ChainSeams, hostAccepts: Null<String> -> Bool,
		?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		if (flagged.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final resolveIndex: () -> Null<SymbolIndex> = lazyIndexOf([{ file: '', source: source }], plugin, index);
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final edits: Array<{ span: Span, text: String }> = [];
		eachHead(tree, seams, hostAccepts, head -> {
			final span: Null<Span> = head.span;
			if (span == null || !flagged.contains(span.from) || carriesComment(comments, span.from, span.to)) return;
			final scanned: Null<ChainScan> = scan(source, head, seams, resolveIndex);
			if (scanned == null) return;
			final text: Null<String> = render(scanned, source, seams);
			if (text != null) edits.push({ span: span, text: text });
		});
		return edits;
	}

	/**
	 * Visit every chain HEAD under `node`: a `chainKinds` node NOT reached as another
	 * chain node's else-slot (so an inner rung is never re-reported as its own head)
	 * and whose PARENT kind `hostAccepts`. The parent kind is null at the root only.
	 */
	private static function eachHead(
		node: QueryNode, seams: ChainSeams, hostAccepts: Null<String> -> Bool, visit: QueryNode -> Void
	): Void {
		walkHeads(node, null, false, seams, hostAccepts, visit);
	}

	/**
	 * Scan the chain at `head` into the pieces a switch is rendered from, or null when any
	 * gate rejects it (see the type doc). `resolveIndex` is consulted ONLY for a
	 * qualified-static constant candidate — a structurally cheap pre-check runs first — so
	 * a file whose chains are all literal never pays for building an index; it may return
	 * null, which makes every qualified-static candidate unprovable and skips those chains.
	 */
	private static function scan(
		source: String, head: QueryNode, seams: ChainSeams, resolveIndex: () -> Null<SymbolIndex>
	): Null<ChainScan> {
		var discs: Null<Array<QueryNode>> = null;
		var discTexts: Null<Array<String>> = null;
		final rungs: Array<ChainRung> = [];
		var elseBody: Null<Span> = null;
		var cur: QueryNode = head;
		// `head` is a chain node by construction and `cur` is only ever re-bound to one, so
		// the loop condition can never turn false on re-entry: every exit is a `break` or a
		// `return null`, and the arity guard inside the body is the one remaining rejection.
		// A fall-out would in any case leave `elseBody` null, which `completeScan` rejects.
		while (seams.chainKinds.contains(cur.kind)) {
			if (cur.children.length < BINARY_CHILD_COUNT) return null;
			final pairs: Null<Array<EqPair>> = conditionPairs(cur.children[0], seams, resolveIndex, source);
			// A tuple subject cannot be spelled without the grammar's delimiters.
			if (pairs == null || (pairs.length > 1 && seams.tuple == null) || cannotProveCallFree(pairs, seams.callKind)) return null;
			final nullableBody: Null<Span> = cur.children[1].span;
			if (nullableBody == null) return null;
			// Re-bind to a non-null local — Strict null-safety takes a struct literal's
			// field type from the declared type, not the narrowed one.
			final bodySpan: Span = nullableBody;
			final known: Null<Array<QueryNode>> = discs;
			if (known == null) {
				final texts: Null<Array<String>> = discriminantTexts(pairs, source);
				if (texts == null) return null;
				discs = [for (p in pairs) p.disc];
				discTexts = texts;
			} else if (!sameDiscriminants(known, pairs, source))
				return null;
			rungs.push({ patterns: [for (p in pairs) p.pattern], body: bodySpan });
			final elseChild: Null<QueryNode> = cur.children.length >= CHAIN_WITH_ELSE_CHILD_COUNT ? cur.children[ELSE_SLOT_INDEX] : null;
			if (elseChild == null) break;
			if (seams.chainKinds.contains(elseChild.kind)) {
				cur = elseChild;
				continue;
			}
			elseBody = elseChild.span;
			if (elseBody == null) return null;
			break;
		}
		return completeScan(discTexts, rungs, elseBody);
	}

	/**
	 * The switch source for `scan`, with `seams.bodyTerminator` appended after each branch
	 * body and a trailing `case _` — unconditional, gate 7 having already refused every chain
	 * with no else-slot to render it from. Null only for a multi-discriminant scan with no
	 * `tuplePatternDelimiters` — unreachable by construction (`scan` refuses that chain), kept
	 * as a skip rather than a throw so a grammar seam gap can never fail a lint run.
	 */
	private static function render(scan: ChainScan, source: String, seams: ChainSeams): Null<String> {
		final subject: Null<String> = subjectText(scan, seams);
		if (subject == null) return null;
		// A lone discriminant is parenthesised (`switch (x)`); a tuple carries its own
		// delimiters and adding parens would only draw a `redundant-parens` finding.
		final head: String = scan.discTexts.length == 1 ? '($subject)' : subject;
		final lines: Array<String> = ['switch $head {'];
		for (rung in scan.rungs) {
			final pattern: Null<String> = groupText(rung.patterns, seams);
			if (pattern == null) return null;
			lines.push('\tcase $pattern: ${spanText(source, rung.body)}${seams.bodyTerminator}');
		}
		lines.push('\tcase _: ${spanText(source, scan.elseBody)}${seams.bodyTerminator}');
		lines.push('}');
		return lines.join('\n');
	}

	/**
	 * Whether any token of `comments` starts within `[from, to)` — the flagged chain's own
	 * span. The list is collected ONCE per file by `editsOf`, because
	 * `RefactorSupport.collectCommentTokens` re-tokenises the whole source and asking it per
	 * flagged head would rescan the file once per finding; every sibling check (`JoinReturn`,
	 * `CondAssignMerge`, `MemberOrder`, `JoinDeclarationAssignment`) hoists it the same way.
	 * That scanner is string-aware, so a `//` inside a string literal is correctly not
	 * counted.
	 */
	private static function carriesComment(comments: Array<{ from: Int, to: Int, isLine: Bool }>, from: Int, to: Int): Bool {
		for (token in comments) if (token.from >= from && token.from < to) return true;
		return false;
	}

	/**
	 * The switch SUBJECT source for `scan` — the lone discriminant verbatim, or the
	 * delimited tuple `[d1, d2]` — or null when a tuple is needed and the grammar spells
	 * none. Both checks build their violation message from it, so the message names the
	 * same subject the fix would emit.
	 */
	private static inline function subjectText(scan: ChainScan, seams: ChainSeams): Null<String> {
		return groupText(scan.discTexts, seams);
	}

	/**
	 * A memoised resolver for the cross-file `SymbolIndex` a qualified-static pattern is
	 * proved against: the caller's `given` index when it has one, else the plugin's
	 * resolution-scope index, else one built from `files`. Returned as a THUNK so a run
	 * whose chains are all literal never builds anything — `scan` calls it only after a
	 * structural qualified-reference pre-check has already matched.
	 */
	private static function lazyIndexOf(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?given: SymbolIndex
	): () -> Null<SymbolIndex> {
		var cached: Null<SymbolIndex> = given;
		function resolve(): Null<SymbolIndex> {
			final have: Null<SymbolIndex> = cached;
			if (have != null) return have;
			final built: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? SymbolIndex.build(files, plugin);
			cached = built;
			return built;
		}
		return resolve;
	}

	/**
	 * The scanned pieces as a `ChainScan`, or null when the chain as a whole is rejected: no
	 * discriminant resolved, fewer than two rungs (a lone conditional is not a chain, and a
	 * one-arm switch reads worse than what it replaced), or no trailing else-slot at all —
	 * gate 7 of the type doc, which every converted chain satisfies, so `elseBody` is non-null
	 * on every `ChainScan` and `render` emits `case _` unconditionally.
	 */
	private static function completeScan(discTexts: Null<Array<String>>, rungs: Array<ChainRung>, elseBody: Null<Span>): Null<ChainScan> {
		if (discTexts == null || rungs.length < 2 || elseBody == null) return null;
		return {
			discTexts: discTexts,
			rungs: rungs,
			elseBody: elseBody
		};
	}

	private static function groupText(parts: Array<String>, seams: ChainSeams): Null<String> {
		if (parts.length == 1) return parts[0];
		final tuple: Null<{ open: String, close: String }> = seams.tuple;
		return tuple == null ? null : '${tuple.open}${parts.join(', ')}${tuple.close}';
	}

	/** The trimmed source text of `span`. */
	private static inline function spanText(source: String, span: Span): String {
		return StringTools.trim(source.substring(span.from, span.to));
	}

	/**
	 * Whether call-freedom CANNOT be proved for the discriminants of `pairs` — gate 5, which
	 * keeps a per-rung evaluation from collapsing into one. True when a discriminant contains
	 * a call, and true when the grammar declares no `callKind` at all: an unprovable answer
	 * rejects the chain rather than waving it through unchecked.
	 */
	private static function cannotProveCallFree(pairs: Array<EqPair>, callKind: Null<String>): Bool {
		if (callKind == null) return true;
		for (p in pairs) if (RefactorSupport.subtreeContainsKind(p.disc, callKind)) return true;
		return false;
	}

	/** The verbatim source of each discriminant of `pairs`, or null when one lacks a coordinate. */
	private static function discriminantTexts(pairs: Array<EqPair>, source: String): Null<Array<String>> {
		final texts: Array<String> = [];
		for (p in pairs) {
			final sp: Null<Span> = p.disc.span;
			if (sp == null) return null;
			texts.push(spanText(source, sp));
		}
		return texts;
	}

	/** Whether `pairs` tests exactly the `known` discriminants, positionally — the uniform-tuple gate. */
	private static function sameDiscriminants(known: Array<QueryNode>, pairs: Array<EqPair>, source: String): Bool {
		if (pairs.length != known.length) return false;
		for (i in 0...pairs.length) if (!RefactorSupport.sameSource(known[i], pairs[i].disc, source)) return false;
		return true;
	}

	/** `eachHead`'s recursion, carrying the parent kind and whether `node` sits in a chain's else-slot. */
	private static function walkHeads(
		node: QueryNode, parentKind: Null<String>, inElseSlot: Bool, seams: ChainSeams, hostAccepts: Null<String> -> Bool,
		visit: QueryNode -> Void
	): Void {
		final isChain: Bool = seams.chainKinds.contains(node.kind);
		if (isChain && !inElseSlot && hostAccepts(parentKind)) visit(node);
		final elseSlot: Int = isChain ? ELSE_SLOT_INDEX : -1;
		for (i in 0...node.children.length) walkHeads(node.children[i], node.kind, i == elseSlot, seams, hostAccepts, visit);
	}

	/**
	 * One rung's condition as a positional list of `(pattern, discriminant)` pairs — the
	 * flattened `andKind` conjunction with every conjunct read as an equality against a
	 * pattern-valid constant — or null when any conjunct fails that shape.
	 */
	private static function conditionPairs(
		cond: QueryNode, seams: ChainSeams, resolveIndex: () -> Null<SymbolIndex>, source: String
	): Null<Array<EqPair>> {
		final out: Array<EqPair> = [];
		for (conjunct in flattenConjunction(cond, seams)) {
			final pair: Null<EqPair> = eqPair(conjunct, seams, resolveIndex, source);
			if (pair == null) return null;
			out.push(pair);
		}
		return out;
	}

	/**
	 * `node`'s operands as a flat left-to-right list, splitting every nested `andKind`
	 * (`a && b && c` parses left-associatively) and stripping `parenKind` wrappers on the
	 * way. A node that is not a conjunction yields itself, so the caller's per-conjunct
	 * shape test is the single place a bad condition is rejected.
	 */
	private static function flattenConjunction(node: QueryNode, seams: ChainSeams): Array<QueryNode> {
		final n: QueryNode = unwrapParens(node, seams.parenKind);
		final andKind: Null<String> = seams.andKind;
		if (andKind != null && n.kind == andKind && n.children.length == BINARY_CHILD_COUNT)
			return flattenConjunction(n.children[0], seams).concat(flattenConjunction(n.children[1], seams));
		return [n];
	}

	/** `node` with every `parenKind` wrapper stripped. */
	private static function unwrapParens(node: QueryNode, parenKind: Null<String>): QueryNode {
		var n: QueryNode = node;
		while (parenKind != null && n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return n;
	}

	/**
	 * `node` read as `D == C` (either operand order): the constant's `case`-pattern text
	 * paired with the discriminant node, or null when `node` is not an equality or its
	 * operands are both / neither pattern-valid constants.
	 */
	private static function eqPair(
		node: QueryNode, seams: ChainSeams, resolveIndex: () -> Null<SymbolIndex>, source: String
	): Null<EqPair> {
		if (node.kind != seams.eqKind || node.children.length != BINARY_CHILD_COUNT) return null;
		final a: QueryNode = node.children[0];
		final b: QueryNode = node.children[1];
		final aPattern: Null<String> = patternTextOf(a, seams, resolveIndex, source);
		final bPattern: Null<String> = patternTextOf(b, seams, resolveIndex, source);
		if (aPattern != null && bPattern == null) return { pattern: aPattern, disc: b };
		if (bPattern != null && aPattern == null) return { pattern: bPattern, disc: a };
		return null;
	}

	/**
	 * The verbatim `case`-pattern source for `node` when it is a pattern-valid constant
	 * (gate 6 of the type doc), else null.
	 */
	private static function patternTextOf(
		node: QueryNode, seams: ChainSeams, resolveIndex: () -> Null<SymbolIndex>, source: String
	): Null<String> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		if (seams.stringFold?.literalOf(node, source) != null || seams.litKinds.contains(node.kind)) return spanText(source, span);
		return provesConstantReference(node, seams, resolveIndex) ? spanText(source, span) : null;
	}

	/**
	 * Whether `node` is a `T.M` reference the index proves usable as a `case` pattern: a
	 * `fieldAccessKind` over a bare `identKind` receiver whose `T.M` the index resolves to at
	 * least one member declaration, every one of which passes `isPatternConstant`. An empty
	 * resolution means "unknown", never "absent", so it is a rejection too. Every structural
	 * test runs BEFORE the index is demanded, so a chain with no such candidate never
	 * triggers the build.
	 */
	private static function provesConstantReference(node: QueryNode, seams: ChainSeams, resolveIndex: () -> Null<SymbolIndex>): Bool {
		final accessKind: Null<String> = seams.fieldAccessKind;
		if (accessKind == null || node.kind != accessKind || node.children.length != 1) return false;
		final memberName: Null<String> = node.name;
		final typeName: Null<String> = node.children[0].name;
		if (memberName == null || typeName == null || node.children[0].kind != seams.identKind) return false;
		final index: Null<SymbolIndex> = resolveIndex();
		if (index == null) return false;
		final decls: Array<{ type: TypeDeclInfo, member: MemberInfo }> = index.memberDeclarationsOf(typeName, memberName);
		if (decls.length == 0) return false;
		for (decl in decls) if (!isPatternConstant(decl.type, decl.member, seams)) return false;
		return true;
	}

	/**
	 * Whether ONE resolved declaration of `T.M` is a compile-time constant the language
	 * accepts in a `case` pattern: an unguarded field that is either an enum-abstract value
	 * (a non-`static` member of an `enumAbstractDeclKind`) or a `static inline` field. The
	 * `inline` modifier is the proof: Haxe refuses it on a non-constant initializer (`Inline
	 * variable initialization must be a constant value`), so an inline field's value is a
	 * constant by construction. A plain `static final` is NOT enough — it may hold anything,
	 * and a non-scalar one (`public static final A:Array<Int> = [1];`) is `Incompatible
	 * pattern` at the case site. A guarded (`#if`) declaration is branch-dependent while the
	 * index is branch-blind.
	 */
	private static function isPatternConstant(type: TypeDeclInfo, member: MemberInfo, seams: ChainSeams): Bool {
		if (member.guarded || !seams.fieldKinds.contains(member.kind)) return false;
		final enumAbstractKind: Null<String> = seams.enumAbstractDeclKind;
		// An enum-abstract VALUE carries no `static` modifier — the hosting type's kind is
		// what makes it a compile-time constant.
		if (enumAbstractKind != null && type.kind == enumAbstractKind && !member.isStatic) return true;
		return member.isStatic && member.isInline;
	}

}

/** One rung of a scanned chain: the `case`-pattern text per discriminant position, and the branch body's source range. */
private typedef ChainRung = {
	final patterns: Array<String>;
	final body: Span;
};

/**
 * A scanned chain ready to render: the discriminant source texts (one entry = a plain
 * subject, several = a tuple), the rungs in source order, and the trailing else-slot's body
 * range, which is rendered as `case _`. `elseBody` is non-null BY CONSTRUCTION — gate 7
 * refuses a chain with no else-slot, so the invariant lives in the type and `render` emits
 * `case _` unconditionally.
 */
private typedef ChainScan = {
	final discTexts: Array<String>;
	final rungs: Array<ChainRung>;
	final elseBody: Span;
};

/**
 * The per-rule configuration a switch chain is scanned and rendered against, resolved once
 * per run by `SwitchChain.seamsOf`. The first two fields are the CALLER's policy:
 * `chainKinds` (the statement rule passes `ifStatementKinds`, the expression rule
 * `ternaryKind` plus `ifExpressionKinds`) and `bodyTerminator` (appended after each rendered
 * branch body — empty for statement bodies, which already carry their own `;` / `{}`). The
 * rest are `RefShape` seams, each degrading on its own when the grammar leaves it unset.
 */
typedef ChainSeams = {
	final chainKinds: Array<String>;
	final bodyTerminator: String;
	final eqKind: String;
	final litKinds: Array<String>;
	final fieldKinds: Array<String>;
	final andKind: Null<String>;
	final parenKind: Null<String>;
	final callKind: Null<String>;
	final fieldAccessKind: Null<String>;
	final identKind: String;
	final enumAbstractDeclKind: Null<String>;
	final tuple: Null<{ open: String, close: String }>;
	final stringFold: Null<StringFoldSupport>;
};

/**
 * One equality of a rung condition, split into the constant text a `case` pattern is
 * written from and the discriminant it tests.
 */
private typedef EqPair = {
	final pattern: String;
	final disc: QueryNode;
};
