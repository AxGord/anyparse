package anyparse.check;

import anyparse.check.CaseValueKey.CaseValueSeams;
import anyparse.check.Check.Violation;
import anyparse.query.BoolExprShape;
import anyparse.query.CondRegionScan;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceComments;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

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
 * 5. **Mutation-free discriminants.** Every discriminant must be free of every
 *    `CheckScan.mutationKinds` node — a call (`callKind`), a construction (`newExprKind`)
 *    and an assignment / increment (`writeParentKinds`): a switch evaluates its subject
 *    ONCE where the chain evaluates it per rung, so anything observable there is a
 *    behaviour change. The write half is not theoretical —
 *    `if (arr[i++] == 1) 'one' else if (arr[i++] == 2) 'two' else 'other'` over
 *    `arr = [9, 2]` answers `'two'`, and `switch (arr[i++])` answers `'other'`. Branch
 *    BODIES are deliberately unconstrained — a body is one value evaluated once either
 *    way, so a call in it is safe. A grammar that declares no `callKind` cannot prove
 *    call-freedom at all, so this gate then rejects EVERY chain rather than waving one
 *    through unchecked. The same gate and the same `CheckScan.mutationKinds` seam set
 *    that `prefer-null-coalescing` and `prefer-safe-nav-comparison` use for their own
 *    two-evaluations-to-one collapse.
 * 6. **Pattern-valid constants.** An operand qualifies as a `case` pattern when it is
 *    one of
 *    (a) a non-string literal kind (`litKinds`) or an interpolation-free string (via
 *        `stringFold.literalOf`, which yields null for an interpolated `'$x'`, whose
 *        value is not a compile-time constant);
 *    (c) a BARE identifier (`identKind` leaf) whose OCCURRENCE the resolver binds to a
 *        `fieldKinds` declaration — `TypeResolver.bareFieldOwner` — whose owning type then
 *        satisfies the same index proof as (b). The binding, not the name, is what decides:
 *        written bare, a `case` pattern naming a static inline field COMPARES, while one
 *        naming a LOCAL is a CAPTURE that matches everything and silently kills every later
 *        arm (`case target:` over a local leaves `pick('a','a')` and
 *        `pick('zzz','a')` both returning the first arm, with only a `WUnusedPattern` on the
 *        dead `case _`). A local SHADOWING a same-named constant reads identically to the
 *        constant, so a name-keyed lookup cannot separate them and a positive binding proof
 *        can. `Refs` is per-FILE, so an import-static, an inherited or a cross-file constant
 *        resolves to nothing and is refused — a miss, which costs a finding, where a wrong
 *        yes costs a behaviour; or
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
 *        constructor-arity check) are follow-ups. The dotted one is a legal PATTERN in
 *        Haxe; what is missing is not the language's permission but the index's key —
 *        `memberDeclarationsOf` is keyed by a type NAME, and matching a whole module PATH
 *        is its own piece of work.
 *
 *    (b) and (c) share ONE proof (`provesConstantMember`), so the qualified and the bare
 *    spelling of a constant can never disagree about whether it is a legal pattern. Both
 *    refuse a non-inline `static final`, which the compiler DOES accept when it holds a
 *    scalar: the index cannot see the initializer, and a non-scalar one
 *    (`static final A:Array<Int> = [1]`) is `Incompatible pattern` at the case site.
 * 7. **A wildcard, always.** A chain ending in an else-slot renders it as `case _`; an
 *    else-less chain closes with an EMPTY `case _:` — it does nothing when no rung matches, and
 *    neither does that arm. Every converted switch therefore carries a wildcard, and so never
 *    depends on what the compiler enumerates. That is the lesson of a waiver that OMITTED the
 *    wildcard for an else-less chain whose subject type looked open, and kept leaking output
 *    that did not compile: a `Bool` subject (`Unmatched patterns: false`), an enum-abstract
 *    subject tested with plain literals (`Unmatched patterns: C`), constants declared on an
 *    unrelated class, a tuple subject (an array pattern is always exhaustiveness-checked), and a
 *    project type SHADOWING a built-in's name (`@:enum abstract Int32(Int)`, an aliasing
 *    `import pkg.Kind as Int32;`, a shadow invisible to a narrow lint scope) — exhaustiveness is a
 *    property of the SUBJECT's type, which no resolver can be trusted to name. The empty wildcard
 *    asks none of those questions. Two structural conditions remain, both statement-rule only
 *    (`ChainSeams.elselessHosts`; the expression rule's chains are values and keep requiring an
 *    else-slot):
 *    - the head stands in a statement LIST — a function's block body anywhere, any other block
 *      only before another statement (a block's last statement may be its value, and an
 *      else-less `if` and a switch with an empty arm do not type alike) — never as a brace-less
 *      body, where the switch would stop holding the `else` a dangling one binds to;
 *    - the next sibling is not a conditional-compilation region. `if (n == 1) a(); else if
 *      (n == 2) b(); #if js else c(); #end` projects as
 *      `(IfStmt cond then (IfStmt …)) (Conditional (OrphanElseStmt …))` — the guarded `else` is
 *      a SIBLING, never the inner `if`'s else-slot — and converting it strands an `#if` block
 *      that no longer parses (`Expected }`).
 * 8. **Comments.** A chain whose span carries a comment token is report-only: comments
 *    between rungs live in trivia the verbatim-body rebuild would drop, and losing one is
 *    worse than leaving the chain alone. Enforced in `editsOf`, so the finding still
 *    reports.
 * 9. **Distinct, KNOWN values.** Every pattern's value must be proved (`CaseValueKey`) and no
 *    two rungs may test the same value tuple. A repeated value is already dead in the chain
 *    and stays dead in the switch — first match wins in both — so the behaviour is kept, but
 *    the switch carries a `case` the compiler reports unused (`WUnusedPattern`), and the duplicate is invisible in the text: under
 *    `enum abstract M(Int) { var DEFAULT = 0; var AUTO = 0; var LINES = 1; }`, `M.DEFAULT`
 *    and `M.AUTO` are one value, and so are `M.LINES` and `1`, or `16` and `0x10`. A member's
 *    value is read off its initializer (`MemberInfo.initializerKind` / `initializerSource`)
 *    or, for an enum-abstract value written without one, off the value the language fills in
 *    (`RefShape.enumAbstractImplicitValues`). Unknown means refused: a reference initializer
 *    (`var B = A;`), an escape in a string, a literal suffix, a build-macro declaration.
 * 10. **The language's own `==`.** A switch matches a pattern by the BUILT-IN comparison, so
 *    an abstract overloading `==` (`@:op(A == B)`) is bypassed: over
 *    `enum abstract Op(Int) { var A = 1; var B = 2; }` declaring an `@:op(A == B)` that
 *    answers `true`, `m = Op.B` takes the `A` rung as a chain and the `B` case as a switch,
 *    on `--interp` and `-js` alike. Two halves. The DISCRIMINANT is asked of
 *    `OperatorSelection` through `ChainScope` — free where no type overloads `==`, bound by
 *    the operand's declared type where one does. The PATTERN is proved from its own
 *    declaration (`selectsBuiltinEq`): a literal, an enum-abstract value of a type
 *    overloading no `==` and carrying no build macro, or a `static inline` field of a
 *    built-in type. It cannot go through `OperatorSelection`, which binds no type to a
 *    qualified `T.M` and so answers `Unproven` for every one of them in any scope whose std
 *    declares an `==` overload.
 *
 * ## Rendering
 *
 * With one discriminant: `switch (D) { case P: BODY … case _: ELSE }` — byte-identical to
 * what `prefer-switch` emitted before this module existed. With several:
 * `switch [D1, D2] { case [P1, P2]: … }`, written with `tuplePatternDelimiters` and NO
 * outer parentheses (a parenthesised tuple subject would draw a `redundant-parens` finding
 * on the result). The `case _` line is unconditional — the else-slot's body, or nothing for an else-less
 * chain (gate 7). `seams.bodyTerminator` (`;` for both rules) is appended after each
 * branch body unless it already ends with one of `seams.selfTerminatingEndings` — `;` or `}` for the
 * statement rule, whose bodies mostly carry their own terminator but lose it before an `else` (`if (c) a
 * else b;`), and nothing for the expression rule, whose bodies are bare expressions. Bodies and patterns are
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
 * call-freedom is unprovable, and the chain is skipped. `writeParentKinds` is always
 * present, and `newExprKind` degrades toward reporting MORE only for a grammar that has
 * constructions and does not declare them — the exposure every `mutationKinds` consumer
 * carries.
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
	 * Resolve the configuration both switch checks scan and render against: the caller's `chainKinds`,
	 * `bodyTerminator` and `selfTerminatingEndings`, and the `RefShape` seams. Null when a REQUIRED seam
	 * is unset — an empty `chainKinds`, no `eqKind` (without `==` nothing maps to a `case`
	 * pattern) or no `caseLiteralKinds`. The optional seams degrade individually: no
	 * `andKind` leaves only single-discriminant conditions, no `tuplePatternDelimiters`
	 * rejects a multi-discriminant chain at scan time, no `fieldAccessKind` /
	 * `enumAbstractDeclKind` keeps patterns literal, and no `callKind` rejects every chain
	 * (gate 5 cannot prove call-freedom without it). `mutationKinds` is derived once here
	 * rather than per rung — gate 5 tests it on every discriminant of every rung.
	 */
	public static function seamsOf(
		plugin: GrammarPlugin, chainKinds: Array<String>, bodyTerminator: String, selfTerminatingEndings: Array<String>,
		closesElseless: Bool = false
	): Null<ChainSeams> {
		final shape: RefShape = plugin.refShape();
		final eqKind: Null<String> = shape.eqKind;
		final litKinds: Array<String> = shape.caseLiteralKinds ?? [];
		return chainKinds.length == 0 || eqKind == null || litKinds.length == 0 ? null : {
			shape: shape,
			chainKinds: chainKinds,
			bodyTerminator: bodyTerminator,
			selfTerminatingEndings: selfTerminatingEndings,
			eqKind: eqKind,
			litKinds: litKinds,
			fieldKinds: shape.fieldDeclKinds ?? [],
			andKind: shape.logicalAndKind,
			parenKind: shape.parenKind,
			callKind: shape.callKind,
			mutationKinds: CheckScan.mutationKinds(shape),
			fieldAccessKind: shape.fieldAccessKind,
			identKind: shape.identKind,
			enumAbstractDeclKind: shape.enumAbstractDeclKind,
			tuple: shape.tuplePatternDelimiters,
			stringFold: plugin.stringFoldSupport(),
			values: CaseValueKey.seamsOf(shape),
			builtinTypeNames: OperandBinder.builtinNamesOf(shape),
			elselessHosts: closesElseless ? elselessHostsOf(plugin) : null
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
		final selection: Null<OperatorSelection> = OperatorSelection.of(plugin, files);
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			final file: String = entry.file;
			final source: String = entry.source;
			final scope: ChainScope = scopeOf(plugin, file, source, tree, resolveIndex, selection);
			eachHead(tree, seams, hostAccepts, (head, elseless) -> {
				final span: Null<Span> = head.span;
				final scanned: Null<ChainScan> = span == null ? null : scan(source, head, elseless, seams, scope);
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
		});
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
		final flagged: Array<Int> = RunScan.spanStarts(violations);
		if (flagged.length == 0) return [];
		final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (parsed == null) return [];
		final tree: QueryNode = parsed;
		// Every flagged violation names the file `source` came from; gate 10 binds operand types in it.
		final file: String = violations[0].file;
		final files: Array<{ file: String, source: String }> = [{ file: file, source: source }];
		final scope: ChainScope = scopeOf(
			plugin, file, source, tree, lazyIndexOf(files, plugin, index), OperatorSelection.of(plugin, files)
		);
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		final edits: Array<{ span: Span, text: String }> = [];
		eachHead(tree, seams, hostAccepts, (head, elseless) -> {
			final span: Null<Span> = head.span;
			if (span == null || !flagged.contains(span.from) || carriesComment(comments, span.from, span.to)) return;
			final scanned: Null<ChainScan> = scan(source, head, elseless, seams, scope);
			if (scanned == null) return;
			final text: Null<String> = render(scanned, source, seams);
			if (text != null) edits.push({ span: span, text: text });
		});
		return edits;
	}

	/**
	 * Whether the chain at `head` is one a switch rule would REPORT — every SCAN gate of the
	 * type doc passes and a subject can be spelled. Gate 8 (comments) is deliberately not
	 * applied: it lives in `editsOf`, so a comment-carrying equality chain still REPORTS as a
	 * switch finding and must still be deferred to, even though no edit is emitted for it.
	 *
	 * The deferral seam a sibling rewrite asks before taking a chain of its own
	 * (`prefer-if-expression-chain`), so the two never double-report one site. It asks THIS
	 * scanner rather than mirroring its gates structurally: a mirror is a second implementation
	 * of one question and drifts the moment a gate here moves.
	 *
	 * `scope` must be the SAME pair the switch rule would use — the file's own parsed ROOT and
	 * a resolver built with `lazyIndexOf` over the same file set. A caller handing in a thunk
	 * that yields null makes every qualified-static constant unprovable, and a caller handing
	 * in another file's root makes every BARE constant unprovable; both under-report the claim,
	 * which is the direction that DOUBLE-claims a site.
	 */
	public static function claims(source: String, head: QueryNode, seams: ChainSeams, scope: ChainScope): Bool {
		// No caller hands the head's siblings in, so an else-less chain is never claimed: the narrower answer.
		final scanned: Null<ChainScan> = scan(source, head, false, seams, scope);
		return scanned != null && subjectText(scanned, seams) != null;
	}

	/**
	 * A memoised resolver for the cross-file `SymbolIndex` a qualified-static pattern is
	 * proved against: the caller's `given` index when it has one, else the plugin's
	 * resolution-scope index, else one built from `files`. Returned as a THUNK so a run
	 * whose chains are all literal never builds anything — `scan` calls it only after a
	 * structural qualified-reference pre-check has already matched.
	 *
	 * Public because a rule that DEFERS to the switch claim (`claims`) has to ask with the
	 * same resolver the switch rule itself would use; a weaker one under-reports the claim,
	 * which is the direction that double-claims a site.
	 */
	public static function lazyIndexOf(
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
	 * The `ChainScope` of ONE file: its parsed `root`, the run's `resolveIndex`, and gate 10 asked of
	 * `selection` — the run's `OperatorSelection` (`OperatorSelection.of`), null when the grammar
	 * declares no operator-overload annotation and every `==` is therefore the language's own.
	 *
	 * Public for the same reason `lazyIndexOf` is: a rule deferring to `claims` must ask with the scope
	 * the switch rule itself would build, or a chain the switch refuses for an overloaded `==` reads
	 * as claimed and neither rule reports it.
	 */
	public static function scopeOf(
		plugin: GrammarPlugin, file: String, source: String, root: QueryNode, resolveIndex: () -> Null<SymbolIndex>,
		selection: Null<OperatorSelection>
	): ChainScope {
		final eqKind: Null<String> = plugin.refShape().eqKind;
		final eqKinds: Array<String> = eqKind == null ? [] : [eqKind];
		if (selection == null) return { root: root, resolveIndex: resolveIndex, operandBuiltin: _ -> true };
		final operators: OperatorSelection = selection;
		// `declared` first: a scope where nothing overloads `==` never binds an operand's type at all.
		function builtin(operand: QueryNode): Bool {
			return !operators.declared(eqKinds)
				|| operators.verdictOfOperands([operand], eqKinds, operators.typingFor(file, source, root)).match(Builtin);
		}
		return { root: root, resolveIndex: resolveIndex, operandBuiltin: builtin };
	}

	/**
	 * Visit every chain HEAD under `node`: a `chainKinds` node NOT reached as another
	 * chain node's else-slot (so an inner rung is never re-reported as its own head)
	 * and whose PARENT kind `hostAccepts`. The parent kind is null at the root only.
	 */
	private static inline function eachHead(
		node: QueryNode, seams: ChainSeams, hostAccepts: Null<String> -> Bool, visit: (QueryNode, Bool) -> Void
	): Void {
		walkHeads(node, null, 0, false, seams, hostAccepts, visit);
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

	/** The trimmed source text of `span`. */
	private static inline function spanText(source: String, span: Span): String {
		return source.substring(span.from, span.to).trim();
	}

	/**
	 * Scan the chain at `head` into the pieces a switch is rendered from, or null when any
	 * gate rejects it (see the type doc). `scope.resolveIndex` is consulted ONLY for a
	 * NAMED-constant candidate — a structurally cheap pre-check runs first — so a file whose
	 * chains are all literal never pays for building an index; it may return null, which makes
	 * every named candidate unprovable and skips those chains.
	 */
	private static function scan(source: String, head: QueryNode, elseless: Bool, seams: ChainSeams, scope: ChainScope): Null<ChainScan> {
		var discs: Null<Array<QueryNode>> = null;
		var discTexts: Null<Array<String>> = null;
		final rungs: Array<ChainRung> = [];
		var elseBody: Null<Span> = null;
		var cur: QueryNode = head;
		// `head` is a chain node by construction and `cur` is only ever re-bound to one, so
		// the loop condition can never turn false on re-entry: every exit is a `break` or a
		// `return null`, and the arity guard inside the body is the one remaining rejection.
		// A fall-out would in any case leave `elseBody` null, which `completeScan` rejects unless gate 7 lets the chain close else-less.
		while (seams.chainKinds.contains(cur.kind)) {
			if (cur.children.length < BINARY_CHILD_COUNT) return null;
			final pairs: Null<Array<EqPair>> = conditionPairs(cur.children[0], seams, scope, source);
			// A tuple subject cannot be spelled without the grammar's delimiters.
			if (pairs == null || (pairs.length > 1 && seams.tuple == null) || cannotProveEvaluationSafe(pairs, seams)) return null;
			// Gate 10: a `switch` matches by the language's own equality, so an overloaded `==` is bypassed.
			if (!pairs.foreach(p -> p.patternBuiltin && scope.operandBuiltin(p.disc))) return null;
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
			rungs.push({ patterns: [for (p in pairs) p.pattern], values: [for (p in pairs) p.value], body: bodySpan });
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
		return completeScan(discTexts, rungs, elseBody, elseless);
	}

	/**
	 * The switch source for `scan`, with `seams.bodyTerminator` appended after each branch
	 * body and a trailing `case _` — unconditional, its body the else-slot's or nothing for an
	 * else-less chain (gate 7). Null only for a multi-discriminant scan with no
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
			lines.push('\tcase $pattern: ${terminatedBody(source, rung.body, seams)}');
		}
		// An else-less chain does nothing when no rung matches, and neither does an EMPTY wildcard arm.
		final elseBody: Null<Span> = scan.elseBody;
		lines.push(elseBody == null ? '\tcase _:' : '\tcase _: ${terminatedBody(source, elseBody, seams)}');
		lines.push('}');
		return lines.join('\n');
	}

	/**
	 * The branch body at `span` as a `case` body: its trimmed source followed by
	 * `seams.bodyTerminator`, unless the body already ends with one of
	 * `seams.selfTerminatingEndings`. A statement-position branch body does not always carry its
	 * own terminator: in `if (c) a else b;` the `;` before `else` is elided and the one after `b`
	 * belongs to the whole chain, so `a` arrives bare and a `case` body built from it verbatim
	 * would not compile.
	 */
	private static function terminatedBody(source: String, span: Span, seams: ChainSeams): String {
		final text: String = spanText(source, span);
		return seams.selfTerminatingEndings.exists(ending -> text.endsWith(ending)) ? text : '$text${seams.bodyTerminator}';
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
		return comments.exists(token -> token.from >= from && token.from < to);
	}

	/**
	 * The scanned pieces as a `ChainScan`, or null when the chain as a whole is rejected: no
	 * discriminant resolved, fewer than two rungs (a lone conditional is not a chain, and a
	 * one-arm switch reads worse than what it replaced), a value tuple not proved distinct (gate 9), or no trailing else-slot
	 * on a chain the caller did not let close with an empty wildcard (`elseless`, gate 7).
	 */
	private static function completeScan(
		discTexts: Null<Array<String>>, rungs: Array<ChainRung>, elseBody: Null<Span>, elseless: Bool
	): Null<ChainScan> {
		return discTexts == null || rungs.length < 2 || (elseBody == null && !elseless) || !distinctValues(rungs) ? null : {
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

	/**
	 * Whether evaluation-safety CANNOT be proved for the discriminants of `pairs` — gate 5,
	 * which keeps a per-rung evaluation from collapsing into one. True when a discriminant
	 * contains any `seams.mutationKinds` node (a call, a construction, an assignment or an
	 * increment), and true when the grammar declares no `callKind` at all: an unprovable
	 * answer rejects the chain rather than waving it through unchecked.
	 *
	 * The write half is load-bearing, not defensive. `callKind` alone let
	 * `arr[i++] == 1 ? 'one' : arr[i++] == 2 ? 'two' : 'other'` through, and the switch it
	 * produced reads `arr[i++]` once where the chain read it per rung — a different answer
	 * for `arr = [9, 2]` (`'two'` before, `'other'` after), with nothing downstream able to
	 * notice, the rewrite compiling either way.
	 */
	private static function cannotProveEvaluationSafe(pairs: Array<EqPair>, seams: ChainSeams): Bool {
		return seams.callKind == null || pairs.exists(p -> seams.mutationKinds.exists(k -> MemberKinds.subtreeContainsKind(p.disc, k)));
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
		for (i in 0...pairs.length) if (!MemberKinds.sameSource(known[i], pairs[i].disc, source)) return false;
		return true;
	}

	/** `eachHead`'s recursion, carrying the parent kind and whether `node` sits in a chain's else-slot. */
	private static function walkHeads(
		node: QueryNode, parent: Null<QueryNode>, index: Int, inElseSlot: Bool, seams: ChainSeams, hostAccepts: Null<String> -> Bool,
		visit: (QueryNode, Bool) -> Void
	): Void {
		final isChain: Bool = seams.chainKinds.contains(node.kind);
		if (isChain && !inElseSlot && hostAccepts(parent?.kind)) visit(node, closesWithWildcard(parent, index, seams));
		final elseSlot: Int = isChain ? ELSE_SLOT_INDEX : -1;
		for (i in 0...node.children.length) walkHeads(node.children[i], node, i, i == elseSlot, seams, hostAccepts, visit);
	}

	/**
	 * One rung's condition as a positional list of `(pattern, discriminant)` pairs — the
	 * flattened `andKind` conjunction with every conjunct read as an equality against a
	 * pattern-valid constant — or null when any conjunct fails that shape.
	 */
	private static function conditionPairs(cond: QueryNode, seams: ChainSeams, scope: ChainScope, source: String): Null<Array<EqPair>> {
		final out: Array<EqPair> = [];
		for (conjunct in flattenConjunction(cond, seams)) {
			final pair: Null<EqPair> = eqPair(conjunct, seams, scope, source);
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
		final n: QueryNode = BoolExprShape.unwrapParens(node, seams.parenKind);
		final andKind: Null<String> = seams.andKind;
		return andKind != null && n.kind == andKind && n.children.length == BINARY_CHILD_COUNT
			? flattenConjunction(n.children[0], seams).concat(flattenConjunction(n.children[1], seams))
			: [n];
	}

	/**
	 * `node` read as `D == C` (either operand order): the constant's `case`-pattern text
	 * paired with the discriminant node, or null when `node` is not an equality or its
	 * operands are both / neither pattern-valid constants.
	 */
	private static function eqPair(node: QueryNode, seams: ChainSeams, scope: ChainScope, source: String): Null<EqPair> {
		if (node.kind != seams.eqKind || node.children.length != BINARY_CHILD_COUNT) return null;
		final a: QueryNode = node.children[0];
		final b: QueryNode = node.children[1];
		final aPattern: Null<CasePattern> = patternOf(a, seams, scope, source);
		final bPattern: Null<CasePattern> = patternOf(b, seams, scope, source);
		return if (aPattern != null && bPattern == null)
			{
				pattern: aPattern.text,
				value: aPattern.value,
				disc: b,
				patternBuiltin: aPattern.builtinEq
			}
		else if (bPattern != null && aPattern == null)
			{
				pattern: bPattern.text,
				value: bPattern.value,
				disc: a,
				patternBuiltin: bPattern.builtinEq
			}
		else
			null;
	}

	/**
	 * `node` as a `case` pattern when it is a pattern-valid constant (gate 6 of the type doc): its
	 * verbatim source and its `CaseValueKey` (gate 9), else null. A constant MEMBER's value is read off
	 * every declaration the index resolves it to, and is known only when they all agree.
	 */
	private static function patternOf(node: QueryNode, seams: ChainSeams, scope: ChainScope, source: String): Null<CasePattern> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final text: String = spanText(source, span);
		if (seams.stringFold?.literalOf(node, source) != null || seams.litKinds.contains(node.kind))
			return { text: text, value: CaseValueKey.of(node.kind, text, seams.values), builtinEq: true };
		final decls: Null<Array<MemberDecl>> = constantReferenceDecls(node, seams, scope) ?? bareConstantDecls(node, span, seams, scope);
		return decls == null
			? null
			: { text: text, value: agreedValue(decls, seams), builtinEq: decls.foreach(d -> selectsBuiltinEq(d, seams)) };
	}

	/**
	 * The declarations of `T.M` when `node` is a `T.M` reference the index proves usable as a `case` pattern, else null: a
	 * `fieldAccessKind` over a bare `identKind` receiver whose `T.M` the index resolves to at
	 * least one member declaration, every one of which passes `isPatternConstant`. An empty
	 * resolution means "unknown", never "absent", so it is a rejection too. Every structural
	 * test runs BEFORE the index is demanded, so a chain with no such candidate never
	 * triggers the build.
	 */
	private static function constantReferenceDecls(node: QueryNode, seams: ChainSeams, scope: ChainScope): Null<Array<MemberDecl>> {
		final accessKind: Null<String> = seams.fieldAccessKind;
		if (accessKind == null || node.kind != accessKind || node.children.length != 1) return null;
		final memberName: Null<String> = node.name;
		final typeName: Null<String> = node.children[0].name;
		return memberName == null || typeName == null || node.children[0].kind != seams.identKind
			? null
			: constantMemberDecls(typeName, memberName, seams, scope);
	}

	/**
	 * The declarations `node` binds to when it is a BARE identifier the resolver proves usable as a `case` pattern, else null: an
	 * `identKind` leaf whose occurrence BINDS to a `fieldKinds` declaration
	 * (`TypeResolver.bareFieldOwner`), that declaration's owning type resolving through the
	 * index to members that all pass `isPatternConstant`.
	 *
	 * The binding proof is the whole point, and it is POSITIVE. Written bare, a `case` pattern
	 * that names a static inline field COMPARES against it, while one that names a LOCAL is a
	 * capture variable that matches everything and silently kills every later arm: `case target:`
	 * over a local leaves `pick('a','a')` and `pick('zzz','a')` both returning the first arm,
	 * with nothing louder than a `WUnusedPattern` on the dead `case _`.
	 * A name-keyed lookup cannot tell the two apart: a local SHADOWING a same-named constant
	 * reads identically. Asking what the occurrence binds to answers both at once, and answers
	 * null — a refusal — for every reference the per-file resolver cannot place (an
	 * import-static, an inherited or a cross-file constant), which is the safe direction.
	 *
	 * Structurally cheap first: the leaf test rejects every discriminant before the resolver is
	 * touched, and the resolver runs against `shape.refsCache` in a real lint run, so the walk
	 * is one memoised `Refs.findMulti` per file rather than one per candidate.
	 */
	private static function bareConstantDecls(node: QueryNode, span: Span, seams: ChainSeams, scope: ChainScope): Null<Array<MemberDecl>> {
		if (node.kind != seams.identKind || node.children.length != 0) return null;
		final name: Null<String> = node.name;
		if (name == null) return null;
		final owner: Null<String> = TypeResolver.bareFieldOwner(name, span, scope.root, seams.shape, seams.fieldKinds);
		return owner == null ? null : constantMemberDecls(owner, name, seams, scope);
	}

	/**
	 * The declarations of `T.M` when the index resolves it to at least one, EVERY one of which
	 * `isPatternConstant` accepts; else null. An empty resolution means "unknown", never "absent", so
	 * it is a rejection too. Shared by the qualified and the bare arm so the two spellings of one
	 * constant can never disagree about whether it is a legal pattern.
	 */
	private static function constantMemberDecls(
		typeName: String, memberName: String, seams: ChainSeams, scope: ChainScope
	): Null<Array<MemberDecl>> {
		final index: Null<SymbolIndex> = scope.resolveIndex();
		if (index == null) return null;
		final decls: Array<MemberDecl> = index.members.memberDeclarationsOf(typeName, memberName);
		return decls.length != 0 && decls.foreach(decl -> isPatternConstant(decl.type, decl.member, seams)) ? decls : null;
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

	/**
	 * Gate 9: whether every rung's patterns have a KNOWN value and no two rungs test the same value tuple.
	 * A tuple is keyed by its values length-prefixed, so no two different tuples can spell one key.
	 */
	private static function distinctValues(rungs: Array<ChainRung>): Bool {
		final seen: Array<String> = [];
		for (rung in rungs) {
			var key: String = '';
			for (value in rung.values) {
				if (value == null) return false;
				key += '${value.length}:$value';
			}
			if (seen.contains(key)) return false;
			seen.push(key);
		}
		return true;
	}

	/**
	 * The `CaseValueKey` every one of `decls` agrees on, or null when one is unknown or two differ: a name the
	 * index resolves to several declarations (one per same-named type) denotes whichever the compiler binds,
	 * so only a value they all share is known.
	 */
	private static function agreedValue(decls: Array<MemberDecl>, seams: ChainSeams): Null<String> {
		final values: Array<Null<String>> = [for (decl in decls) CaseValueKey.ofMember(decl.type, decl.member, seams.values)];
		final first: Null<String> = values[0];
		return first != null && values.foreach(v -> v == first) ? first : null;
	}

	/**
	 * Gate 10's pattern half: whether a constant declared as `decl` leaves the language's `==` selected. Its
	 * declaring type must overload no `==` and carry no build macro (whose members no index sees), and the
	 * constant's own TYPE must be one that cannot overload — the enum abstract itself for a value, a built-in
	 * type for a `static inline` field: written, or inferred from the literal initializer gate 9 demands.
	 */
	private static function selectsBuiltinEq(decl: MemberDecl, seams: ChainSeams): Bool {
		final type: TypeDeclInfo = decl.type;
		if (type.hasBuild || type.members.exists(m -> m.operatorOverloads.contains(seams.eqKind))) return false;
		if (type.kind == seams.enumAbstractDeclKind && !decl.member.isStatic) return true;
		final written: Null<String> = decl.member.typeSource;
		return written == null ? decl.member.initializerKind != null : seams.builtinTypeNames.contains(written);
	}

	/**
	 * Gate 7: whether a chain head standing at `index` among `parent`'s children may close an else-less
	 * chain with an empty `case _:`. The parent must be a statement list (`ElselessHosts`) — a chain that
	 * is a brace-less body could lend its missing `else` to an enclosing `if` once it is a switch — and the
	 * next sibling must not be a conditional-compilation region: `if (n == 1) a(); else if (n == 2) b();
	 * #if js else c(); #end` projects the guarded `else` as that sibling, never as the chain's else-slot.
	 */
	private static function closesWithWildcard(parent: Null<QueryNode>, index: Int, seams: ChainSeams): Bool {
		final hosts: Null<ElselessHosts> = seams.elselessHosts;
		if (hosts == null || parent == null) return false;
		final next: Null<QueryNode> = index + 1 < parent.children.length ? parent.children[index + 1] : null;
		if (next != null && CondRegionScan.isConditionalKind(next.kind, seams.shape)) return false;
		return hosts.anywhere.contains(parent.kind) || (next != null && hosts.beforeAnother.contains(parent.kind));
	}

	/**
	 * The statement lists the statement rule closes an else-less chain in: a function's block body
	 * (`RefShape.blockBodyKind`) anywhere, and every other statement list (`ControlFlowSupport.blockKinds`)
	 * only before another statement, its last one possibly being the list's value.
	 */
	private static function elselessHostsOf(plugin: GrammarPlugin): ElselessHosts {
		final body: Null<String> = plugin.refShape().blockBodyKind;
		return { anywhere: body == null ? [] : [body], beforeAnother: plugin.controlFlowSupport()?.blockKinds() ?? [] };
	}

}

/** One rung of a scanned chain: the `case`-pattern text per discriminant position, and the branch body's source range. */
private typedef ChainRung = {
	final patterns: Array<String>;

	/** The value key of each pattern, parallel to `patterns` (null = unknown). */
	final values: Array<Null<String>>;
	final body: Span;
};

/**
 * A scanned chain ready to render: the discriminant source texts (one entry = a plain
 * subject, several = a tuple), the rungs in source order, and the trailing else-slot's body
 * range, which is rendered as `case _` — null for an else-less chain, which `render` closes with
 * an EMPTY `case _:` (gate 7).
 */
private typedef ChainScan = {
	final discTexts: Array<String>;
	final rungs: Array<ChainRung>;
	final elseBody: Null<Span>;
};

/**
 * The statement lists an else-less chain may stand in and still close with an empty `case _:`:
 * `anywhere` holds a list whose last statement is never a value (a function's block body),
 * `beforeAnother` one whose last statement may be (a nested block, a block expression), where the
 * chain must have a statement after it.
 */
private typedef ElselessHosts = {
	final anywhere: Array<String>;
	final beforeAnother: Array<String>;
};

/**
 * The two per-FILE services a constant proof asks for: the file's own parsed `root`, against
 * which a BARE identifier's binding is resolved, and the lazy cross-file `SymbolIndex` a named
 * constant's modifiers are read from.
 *
 * A pair rather than two parameters because they must describe the SAME file — a root from one
 * file with an index over another silently answers "unprovable" for every bare constant, and a
 * check that under-reports its claim is the direction that lets a sibling rewrite double-claim
 * the site. Both are values the caller owns for the length of one run; nothing here is cached
 * across a `run` / `fix` pair, `SwitchChain` holding no state of its own.
 */
typedef ChainScope = {
	final root: QueryNode;
	final resolveIndex: () -> Null<SymbolIndex>;

	/**
	 * Whether an equality with this DISCRIMINANT operand selects the LANGUAGE's `==` as far as the
	 * discriminant's type decides it — gate 10's discriminant half (the pattern half is proved from the
	 * constant's own declaration). Built by `SwitchChain.scopeOf` from the run's `OperatorSelection`,
	 * so it is free in a scope where no type overloads `==` and binds the operand's declared type only
	 * where one does.
	 */
	final operandBuiltin: (QueryNode) -> Bool;
};

/**
 * The per-rule configuration a switch chain is scanned and rendered against, resolved once
 * per run by `SwitchChain.seamsOf`. The first two fields are the CALLER's policy:
 * `chainKinds` (the statement rule passes `ifStatementKinds`, the expression rule `ternaryKind`
 * plus `ifExpressionKinds`), `bodyTerminator` (appended after each rendered branch body) and
 * `selfTerminatingEndings` (the endings that make that append unnecessary). The
 * rest are `RefShape` seams, each degrading on its own when the grammar leaves it unset.
 */
typedef ChainSeams = {
	/**
	 * The whole `RefShape`, carried because the bare-identifier constant proof asks the
	 * RESOLVER (`TypeResolver.bareFieldOwner`) rather than a kind list, and the resolver takes
	 * a shape. The individual kind fields below stay because the scanner reads them per node.
	 */
	final shape: RefShape;

	final chainKinds: Array<String>;
	final bodyTerminator: String;

	/**
	 * Trailing texts that mean a rendered body already terminates itself, so
	 * `bodyTerminator` is not appended — empty for the expression rule, whose bodies are bare
	 * values.
	 */
	final selfTerminatingEndings: Array<String>;

	final eqKind: String;
	final litKinds: Array<String>;
	final fieldKinds: Array<String>;
	final andKind: Null<String>;
	final parenKind: Null<String>;
	final callKind: Null<String>;

	/**
	 * `CheckScan.mutationKinds(shape)` — every kind whose presence in a discriminant makes
	 * the per-rung-to-once collapse observable. Derived once by `seamsOf`; gate 5's set.
	 */
	final mutationKinds: Array<String>;

	final fieldAccessKind: Null<String>;
	final identKind: String;
	final enumAbstractDeclKind: Null<String>;
	final tuple: Null<{ open: String, close: String }>;
	final stringFold: Null<StringFoldSupport>;

	/** What a `case` pattern's VALUE is read through — gate 9's distinctness proof. */
	final values: CaseValueSeams;

	/** The built-in type names (`OperandBinder.builtinNamesOf`), none of which can overload `==` — gate 10. */
	final builtinTypeNames: Array<String>;

	/**
	 * Where an else-less chain may close with an empty `case _:` (gate 7), or null when the rule never
	 * closes one — the expression rule, whose chains are values.
	 */
	final elselessHosts: Null<ElselessHosts>;
};

/**
 * One equality of a rung condition, split into the constant text a `case` pattern is
 * written from and the discriminant it tests.
 */
private typedef EqPair = {
	final pattern: String;
	final disc: QueryNode;

	/** The pattern's `CaseValueKey`, or null when its value is not provably known — gate 9 then refuses the chain. */
	final value: Null<String>;

	/** Whether the PATTERN leaves the language's `==` selected — gate 10's pattern half (`CasePattern.builtinEq`). */
	final patternBuiltin: Bool;
};

/** A pattern-valid operand: its verbatim `case`-pattern source and its `CaseValueKey` (null = unknown). */
private typedef CasePattern = {
	final text: String;
	final value: Null<String>;

	/** Whether the pattern's own type leaves the language's `==` selected (`selectsBuiltinEq`). */
	final builtinEq: Bool;
};

/** One declaration a constant reference resolves to, as `MemberLookup.memberDeclarationsOf` returns it. */
private typedef MemberDecl = { type: TypeDeclInfo, member: MemberInfo };
