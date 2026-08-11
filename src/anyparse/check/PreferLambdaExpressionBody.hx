package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.IfExpressionChain.ShieldSeams;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Flags an ARROW lambda whose `{ … }` body holds exactly one statement, and collapses the
 * block to a bare expression body:
 *
 * ```haxe
 * moves.sort((a:Item, b:Item) -> {
 *     return a.path < b.path ? -1 : 1;
 * });
 * // ->
 * moves.sort((a:Item, b:Item) -> a.path < b.path ? -1 : 1);
 * ```
 *
 * Purely structural (no type information). `Info` — the code is correct, this is the
 * canon-convergence half of the arrow-lambda family: `prefer-arrow-callback` turns a
 * `function` literal into an arrow, this check then drops the braces the literal needed.
 *
 * ## What is flagged
 *
 * A node of one of the ARROW lambda kinds — every `lambdaKinds` entry EXCEPT `fnExprKind`
 * — whose LAST child (the body; a lambda's other children are its parameters) is a block
 * (`ControlFlowSupport.blockKinds()`) holding exactly one statement, and that statement is
 * either
 *
 * - a VALUE `return` (`valueReturnKinds`) with exactly one child — the returned
 *   expression becomes the body. A value-less `return;` is a distinct kind and is absent
 *   from the set, so it never matches: `(…) -> return;` is not an expression body; or
 * - a single expression statement (`exprStatementKind`) with exactly one child — the
 *   expression becomes the body; or
 * - a SINGLE-ARM control-flow statement (`controlFlowKinds` minus what
 *   `branchesInternally` refuses: an else-less `if`, a `for`, a `while`, a `throw`) — the
 *   statement itself becomes the body, minus its own terminator. Each of these is an
 *   EXPRESSION in Haxe, so the collapse preserves the block's value exactly as the two arms
 *   above do (see below). This arm is checked FIRST: an `if` / `for` / `while` node carries
 *   two or more children and would otherwise be rejected by the single-child arity guard the
 *   other two arms share. A body that branches INTERNALLY — an `if` with an `else`, a
 *   `switch` — keeps its braces; `branchesInternally` states why, and
 *   `LambdaBranchingBodyBlock` puts them back when they are missing.
 *
 * Anything else — a local declaration, a `do … while`, a value-less `return;`, a `break`,
 * a `continue`, two statements, an empty body — is left alone. A `#if` region does NOT
 * match either: a conditional projects as ONE `Conditional` child of the block, which is
 * none of the accepted statement kinds, so a body whose single "statement" is
 * branch-dependent fails closed. That is why this check reads the PLAIN tree rather than
 * the branch-aware one: the branch-aware projection would split the region into
 * `CondBranch` statement lists and could present a one-statement branch as if it were the
 * whole body. `do … while` is outside the accepted set deliberately: its condition is the
 * LAST child, so the body-tail recursion the terminator strip below relies on does not
 * describe it.
 *
 * The `function` literal (`fnExprKind`) is deliberately NOT matched. `prefer-arrow-callback`
 * owns that node in call-argument position and normalises it INTO one of the arrow kinds;
 * this check then fires on the result in the next fixed-point pass. Matching both here would
 * double-report one site, and collapsing a `function` literal's block in place would emit
 * `function(v) return e`, a shape the canon does not want.
 *
 * ## Why the collapse is type-preserving
 *
 * A Haxe block IS an expression whose value is its last expression, so
 * `(v) -> { push(v); }` already has type `(v : Int) -> Int`, not `-> Void` — verified on
 * 4.3.7 for both the `return` and the bare-expression shape, standalone and in a generic
 * argument position (`array.map`). This check therefore carries none of the
 * expected-type machinery `prefer-arrow-callback` needs: THAT rewrite changes a
 * `function` literal's Void-by-default return into an inferred one, while dropping braces
 * around a single statement changes nothing.
 *
 * The SAME argument carries every control-flow kind, because each one is an expression in
 * its own right and the block's value is therefore already that construct's value:
 *
 * - `if` / `if … else` — an if-EXPRESSION. `() -> { if (c) 1 else 2; }` and
 *   `() -> if (c) 1 else 2` both yield `1` for a true `c` (verified on 4.3.7), and an
 *   else-less `if` is `Void`-typed in BOTH forms, so neither gains nor loses a value.
 * - `switch` — a switch-EXPRESSION, its value the matched arm's; the block's value was
 *   already that.
 * - `for` / `while` — `Void`-typed loops, so the block was `Void` before and after.
 * - `throw` — unifies with every type, and does so in both positions: a `Void -> Int`
 *   annotation is accepted by `() -> { throw "x"; }` and by `() -> throw "x"` alike.
 *
 * So the collapse never needs to know the enclosing expected type — the same reason the
 * two original arms do not.
 *
 * A comment TRAILING the single statement rides along — `trailingComment` appends it after the
 * emitted body, since the gap between the two is the terminator `emittedEnd` strips. Its
 * position relative to that terminator therefore changes: `tokenError(); // handlers` becomes
 * `tokenError() // handlers`. Any OTHER comment anywhere inside the block but outside the copied
 * expression is dropped by the rebuild (the braces, the `return` keyword and the `;` all go away), so the finding is
 * skipped rather than silently losing it — the family's fail-closed comment guard. A
 * comment INSIDE the expression rides along and the site still fires. That holds on the
 * control-flow arm unchanged: a comment trailing the statement is outside the kept span
 * (which `emittedEnd` lands on the last real token) and refuses the site.
 *
 * The kept span is additionally passed through `IfExpressionChain.tokenSpan`, the family's
 * shared trivia normaliser, for a grammar whose node spans run PAST their last token. On
 * the Haxe grammar no end `emittedEnd` can return is preceded by trivia — the two it emits
 * are a descendant's tight span end and a node's own span end, and the Haxe parser closes a
 * statement on its last real token — so the call is a measured NO-OP here and no test
 * discriminates it. It is kept as the family's one way of asking that question rather than
 * as a guard this grammar needs; the refusal of a trailing comment is `emittedEnd`'s doing,
 * not its.
 *
 * ## The dangling `else`
 *
 * Collapsing a control-flow body changes what may follow the emitted text, and one
 * position turns that into a silent semantics break:
 *
 * ```haxe
 * if (x) cb = () -> { if (c) g(); }; else h();
 * // collapsed, WITHOUT the gate below:
 * if (x) cb = () -> if (c) g(); else h();
 * ```
 *
 * Haxe allows a `;` before `else`, so the trailing `else h()` re-parents onto the INNER
 * `if (c)` and the outer else-branch stops running (reproduced with `--interp`). The
 * output still PARSES, so the `--fix` re-parse gate waves it through — nothing but a gate
 * here stops it.
 *
 * Whether an `else` can follow is a property of the lambda's POSITION, so the walk carries
 * one boolean, `shielded`, computed per child on the way down (`childShielded`):
 *
 * - a child of a SHIELD parent (`shieldKinds`: a block, a call, a `new`, a paren, an array
 *   literal, an index access, an object field, a case branch) is shielded — the parent
 *   closes every child with a `)` / `,` / `]` / `}` or a following statement, and none of
 *   those can be `else`;
 * - a child with a FOLLOWING SIBLING is shielded, because the token separating them is not
 *   an `else` — EXCEPT the then-branch of a conditional that has an else-branch after it,
 *   which is exactly the hazard above;
 * - a TAIL child inherits its parent's own value, since whatever can follow the parent can
 *   follow it. This is what makes the hazard reach through a brace-less body chain: a loop
 *   in that then-branch passes the exposure on to its body;
 * - EVERY child of a `#if` region (`RefactorSupport.isConditionalKind`) inherits, following
 *   sibling or not. The plain tree projects each branch's nodes as FLAT siblings of one
 *   `Conditional` / `ConditionalExpr`, so a following sibling proves nothing there: it may
 *   belong to a different branch, and under the defines that select THIS child's branch the
 *   child is the last thing the region emits. Without that arm
 *   `if (x) #if A cb = () -> { if (c) g(); }; #else … #end else h();` collapsed and the
 *   outer `else` re-parented — the identical break, reproduced with `--interp`.
 *
 * A `;` does NOT shield. That is the whole point of the reproduction: the statement in the
 * hazard IS terminated, and the `else` binds through the `;` anyway.
 *
 * In an UNSHIELDED position the site is refused when its body holds an else-less
 * conditional anywhere in its subtree (`IfExpressionChain.holdsElseLessConditional`, the
 * same scan the if-expression collapse rules use for the same reason). That scan is
 * deliberately the conservative WHOLE-subtree walk rather than a right-spine one: an
 * else-less `if` in a delimited interior (a call argument, a paren) could not absorb
 * anything, but proving which is which costs more than the rare cleanup it buys, and the
 * answer to any uncertainty is skip. The cost is bounded because the dominant position —
 * a lambda passed as a CALL ARGUMENT — is shielded and never reaches the scan at all,
 * which is what keeps the widened rule useful.
 *
 * The scan guards EVERY arm, not only the control-flow one. `() -> { return if (c) g(); }`
 * emits an else-less `if` exactly as `() -> { if (c) g(); }` does, so the value arms carry
 * the identical hazard — it predates the control-flow arm and was simply unanswerable until
 * the position walk existed to ask about it.
 *
 * ## Dropping the statement's terminator
 *
 * A statement's span covers the `;` that ended it: `a(() -> { if (c) f(); });` projects
 * `IfStmt @36-47` whose interior `ExprStmt @43-47` runs past the `Call @43-46` to include
 * that `;`. Emitting the raw slice would give `a(() -> if (c) f(););`, which does not
 * parse. `emittedEnd` recovers the tight end STRUCTURALLY — no scan of the source text for
 * a `;`, which would be a grammar leak — by walking the tail: a node whose span ends where
 * its last child's span ends is re-asked about that child, and a `terminatedKinds` node
 * (the kinds whose span covers a trailing terminator: value `return`, `throw`, the control
 * exits, a local declaration, an expression statement, an empty statement) whose last
 * child ends EARLIER gives up its own end in favour of the child's.
 *
 * The worked cases:
 *
 * - `if (c) f();` — `IfStmt` ends where its `ExprStmt` does, so descend; the `ExprStmt` is
 *   terminated and its `Call` ends earlier, so the end is the `Call`'s → `if (c) f()`.
 * - `if (c) f(); else g();` — the same descent through the ELSE-branch's `ExprStmt` →
 *   `if (c) f(); else g()`. The interior `;` stays, and is legal Haxe.
 * - `for (x in xs) f(x);` / `while (c) f();` / `throw "x";` — terminator dropped the same
 *   way (`throw` is itself a terminated kind, so it yields to its value's end).
 * - `switch v { … }` — a bare switch is NOT terminated and its last `CaseBranch` ends
 *   before the closing `}`, so the full span is kept and the `}` survives.
 * - `if (c) { a(); b(); }` — the descent reaches the inner block, which is not terminated
 *   and ends after its last statement, so the inner braces are KEPT.
 * - `while (c);` — the descent reaches a CHILDLESS `EmptyStmt`, which IS terminated, so
 *   there is no structural end to recover and the site is refused. Emitting `while (c)`
 *   would not compile.
 * - `if (c) return;` / `for (…) break;` — a childless `VoidReturnStmt` / `BreakStmt`, both
 *   terminated, refused for the same reason. Fail-closed: their terminator is not
 *   recoverable from any child span.
 * - `if (c) #if A f(); #end` — the descent reaches the `#if` region, which closes on `#end`
 *   with the `;` to drop INSIDE it. No child end recovers that, and the region's own end
 *   would emit `if (c) #if A f(); #end` — text the Haxe compiler rejects once the branch is
 *   active — so a conditional region on the tail is refused outright.
 *
 * The VALUE arms never run that walk — they emit the child's span verbatim, which is sound
 * only while the statement's terminator lies OUTSIDE that child. A GAPLESS terminated
 * statement, whose span ends exactly where its value's does, says the model swallowed the
 * terminator INTO the value, and the emitted text would carry it: `{ @:privateAccess if (c)
 * h(); }` as a block's sole statement projects one `MetaExpr` spanning the `;`, where the
 * same code with a sibling after it projects the `;` under an interior `ExprStmt`. Such a
 * site is refused. This one predates the control-flow arm and is not caught downstream: the
 * emitted `@:privateAccess if (c) h();` is text `haxe` rejects but THIS parser accepts, so
 * the `--fix` re-parse gate is no net for it.
 *
 * A reification subtree (`RefShape.opaqueKinds`, Haxe's `macro { … }`) is skipped wholesale,
 * matching the sibling rewrite rules: its interior is spliced code a consumer may
 * pattern-match on, not source a human reads.
 *
 * ## The writer-probe precondition
 *
 * Structural collapsibility is not enough. The collapse changes how the ENCLOSING construct
 * wraps, and nothing in the tree says whether the result reads better. Applied to a real
 * 800-file tree, two shapes came out materially WORSE — all layout, none visible to any gate
 * above:
 *
 * - ARG-LIST EXPLOSION. The collapsed head line stops fitting, so the writer breaks the
 *   enclosing CALL apart: `Api.login(email, password, cb -> { … }, false);` becomes
 *   `Api.login(` alone on its line with the arguments re-flowed under it. This clause is
 *   load-bearing on real code, not just on its suite witness: an attempt to exempt the
 *   trailing-argument population from this whole probe (on the theory that its canonicality is
 *   structural) re-flowed three sites in the 800-file tree — two `_thumbnailMethod(path, cb ->
 *   …)` calls opened their argument lists and a `getFolderContentAPI().loadContent(…)` split its
 *   method chain as well. The exemption was reverted; a site the layout probe refuses stays
 *   braced, and the add half leaves the trailing slot alone, so the braced form is simply what
 *   both halves agree on there.
 * - MULTI-LINE CONDITION HOISTED INTO THE ARROW HEAD. The collapsed `if`s own condition is
 *   itself wrapped, so that wrap lives inside the lambda head. This one is now the WRITERs
 *   answer rather than this checks: `BodyFit.arrowConstructHeadWidth` moves such a body to
 *   the continuation line instead of gluing it, so the shape no longer occurs and the
 *   collapse of a construct body is a plain de-brace.
 *
 * So a site fires only when the collapse leaves the file NO LONGER than it was and changes
 * the head line in exactly one of two ways:
 *
 * 1. it pulls content UP onto the head line (the collapsed head is longer than the original
 *    one) — the value arms payoff, a `return expr;` or a bare expression joining the `->`; or
 * 2. the head loses its body brace and NOTHING else (`headOnlyLostItsBrace`) — the
 *    de-brace-in-place shape, which is what the projects brace policy asks for whenever a
 *    body holds a single statement: braces are a function of the statement COUNT, so a
 *    one-statement body carries none and a body that grows past one gets them back.
 *
 * Clause 2 is why this check no longer requires the collapse to SAVE a line. A construct body
 * de-braces line-neutrally by construction — the `{` leaves the head line and the `}` leaves
 * the closing one, and the statements in between do not move — so a strictly-shrink test
 * refused the whole population on a criterion that says nothing about how the result reads.
 * What it must still refuse is a collapse that reflows some OTHER construct, and that is a
 * different measurement: the arg-list explosion also SHORTENS the head, by 46 columns
 * (measured on `testArgListExplosionRefused`: 63 to 17) where losing a brace shortens it by
 * exactly the two characters of ` {`. An exact string identity separates the two with no
 * threshold to calibrate.
 *
 * Measured on the same 800-file tree: 3 sites fired under the strictly-shrink rule and 8
 * under this one, and the 5 added sites are all pure de-braces — `{` off the head, `}` off
 * the closing line, no interior line touched.
 *
 * The de-brace clause carries a THIRD requirement the head test cannot express:
 * `interiorSurvives`. Removing the braces moves the body from statement position into
 * EXPRESSION position, where this project's config glues an `if`/`else`'s branches to their
 * conditions instead of keeping them on their own lines — so a site could pass "only a brace
 * left the head" while four interior lines silently became two. The interior must now match
 * line for line, modulo the one `;` the emitted body drops.
 *
 * RESIDUAL: the interior test compares TRIMMED lines, so a pure re-indent inside the body is
 * invisible to it — which is intended (the body does shift one level when its braces go). And a body whose block held
 * blank lines around its single statement loses them with the block (measured: 11 lines to
 * 9) — a content change the head test cannot see; the comment guard above covers comments,
 * blank lines are accepted as part of what de-bracing means here.
 *
 * Why the WHOLE FILE rather than a spliced-out statement: the collapse is the only edit, so
 * the file-level line delta IS the enclosing statement's line delta, and the first divergent
 * line IS the lambda's head line. Nothing to scaffold, no member-scope indent-equivalence to
 * assume, and no way for the probe to measure a different construct than the one being
 * changed.
 *
 * The layout config is discovered from the file's own path (`FormatConfigDiscovery`) — layout
 * policy belongs to the project's `hxformat.json`, and a probe against compiled defaults can
 * "prove" a one-line result the project renders as two. `fix` reads it from
 * `violations[0].file` and refuses a mixed-file call, so both passes measure under the same
 * settings.
 *
 * Cost: one extra `writeRoundTrip` per candidate, plus one per source that has any candidate at
 * all — and `collect` is called by `run` AND again by `fix`, with `lint --fix` iterating to a
 * fixpoint, so a `--fix` run pays that bill twice per pass rather than once. Measured on this
 * repo: `src/anyparse/core/CollapsePass.hx` (1358 lines, 6 structural candidates) goes 0.27s ->
 * 1.86s for a report-only run and 5.95s for `--fix` (2 passes); the whole tree under this rule
 * alone (653 files, 15 candidates in 8 files) goes 12.5s -> 28.5s, and under EVERY rule 32.8s ->
 * 34.5s (+5%); a subtree with no candidate at all pays nothing (`src/anyparse/grammar`, 263
 * files, 0.75s either way), because the BEFORE rendering is skipped when the structural walk
 * found none. A writer failure, including the documented `CommentLossException`, folds to null
 * and REFUSES, so a grammar with no writer makes this check inert rather than unguarded.
 *
 * ## Autofix
 *
 * `fix` replaces the BLOCK's span — braces included, nothing outside them — with the
 * expression's verbatim source. Trailing trivia is outside the block's span, so the
 * emitted body cannot weld onto what follows. Nested lambdas both match; the outer edit
 * contains the inner one and `RefactorSupport.dropContainedEdits` keeps the outer, the
 * inner surfacing on the next pass.
 *
 * `run` and `fix` share one `collect`, so neither can encode a gate the other misses.
 *
 * ## Grammar-agnostic
 *
 * `lambdaKinds` minus `fnExprKind` are the matched kinds, `ControlFlowSupport.blockKinds()`
 * the block bodies, `valueReturnKinds` / `exprStatementKind` the two value-carrying
 * collapsible statements and `opaqueKinds` the subtrees to skip. No `lambdaKinds` beyond
 * the function literal, no block kinds, or NEITHER value-carrying statement kind → the
 * check is a no-op.
 *
 * The control-flow arm reads four more seams (`conditionalKinds` and `shieldKinds` arrive
 * bundled as `shield: ShieldSeams`). Three of them unset simply narrow it; the fourth,
 * `conditionalKinds`, is the one that must be set for a grammar that HAS an `if`:
 *
 * - `controlFlowKinds` — `ifExpressionKinds` + `ifStatementKinds` + `switchKinds` +
 *   `loopStatementKinds` + `throwKinds`. EMPTY leaves the arm inert and the check exactly
 *   what it was before it existed, which is why no early `return null` guards it.
 * - `conditionalKinds` — the `if` forms, both expression and statement. NOT inert when
 *   unset: it is the set the dangling-else scan asks about, so leaving it unset for a
 *   grammar with an `if` silently deletes that refusal — on the VALUE arms too, which stay
 *   live even with `controlFlowKinds` empty. Optional only for a grammar whose `if` cannot
 *   absorb a following `else`.
 * - `shieldKinds` — the block kinds plus `callKind` / `newExprKind` / `parenKind` /
 *   `arrayLiteralKind` / `indexAccessKind` / `objectFieldKind` / `caseBranchKind`. Fewer
 *   entries means fewer positions proved safe, so the check refuses MORE: unset is the
 *   conservative direction.
 * - `terminatedKinds` — `valueReturnKinds` + `throwKinds` + `controlExitKinds` +
 *   `localDeclKinds` + `exprStatementKind` + `emptyStmtKind`. A kind missing here keeps
 *   its trailing terminator in the emitted text; the set is a UNION of existing seams
 *   rather than a new one so that a grammar already describing its statements gets the
 *   strip for free, and duplicates across those seams are harmless (membership only). It
 *   is a SUPERSET of the terminator-bearing kinds, not an exact one: the expression-form
 *   members those seams carry (`ReturnExpr` / `ThrowExpr` / `BreakExpr` / `VarMore` …)
 *   end on no terminator at all. Membership only ever makes the walk hand its end to a
 *   child or refuse, never keep a delimiter it should have dropped, so an over-wide set
 *   costs coverage, not correctness.
 */
@:nullSafety(Strict)
final class PreferLambdaExpressionBody implements Check {

	/** The rule id, spelled once — `run`, `fix` and the registry all quote it. */
	private static inline final RULE_ID: String = 'prefer-lambda-expression-body';

	/** A collapsible body block holds exactly one statement. */
	private static inline final SINGLE_STATEMENT: Int = 1;

	/**
	 * What the block body contributes to the lambda's head line, and therefore the ONLY
	 * difference the collapse may make to it — see `paysForItself`.
	 */
	private static inline final BODY_BRACE_TAIL: String = ' {';

	/** The closing brace the de-brace deletes from the block's last line — see `interiorSurvives`. */
	private static inline final BLOCK_CLOSE: String = '}';

	private static inline final LINE_COMMENT: String = '//';

	/** An `if` node with this many children carries an else-branch — see `branchesInternally`. */
	private static inline final IF_ELSE_CHILD_COUNT: Int = 3;

	/** A collapsible statement carries exactly one child — the value the body becomes. */
	private static inline final SINGLE_VALUE_CHILD: Int = 1;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return
			'an arrow lambda whose block body is a single return, expression or control-flow statement, collapsible to an expression body';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		return seams == null ? [] : [
			for (entry in files) for (m in collect(plugin, entry.source, seams, FormatConfigDiscovery.discover(entry.file)))
				{
					file: entry.file,
					span: m.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'this single-statement lambda body can be an expression body'
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		// The layout config comes from the violation's own path — the precondition renders the
		// whole file, so `fix` must measure under exactly the settings `run` measured with.
		final file: String = violations[0].file;
		for (violation in violations) if (violation.file != file)
			throw new Exception('$RULE_ID: fix() takes ONE file\'s violations, got $file and ${violation.file}');
		final byKey: Map<String, Match> = [];
		for (m in collect(plugin, source, seams, FormatConfigDiscovery.discover(file))) byKey['${m.span.from}:${m.span.to}'] = m;
		return RefactorSupport.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.span, text: m.text }))
		);
	}

	/** `lines[i]` without surrounding whitespace, or empty when the index is past the end. */
	private static inline function trimmedAt(lines: Array<String>, i: Int): String {
		return i < lines.length ? StringTools.trim(lines[i]) : '';
	}

	/**
	 * Every collapsible lambda body in `source` that also PAYS FOR ITSELF in the writer's own
	 * rendering (empty when the source does not parse, or when the writer declines it). `run`
	 * and `fix` both go through it, so neither can encode a gate the other misses.
	 *
	 * The BEFORE rendering is paid for ONCE per source, and only when the structural walk
	 * found something — a file with no candidate costs no round trip at all.
	 */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams, optsJson: Null<String>): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final found: Array<Match> = [];
		// The module root is shielded: nothing follows a top-level declaration but another
		// one, so no `else` can reach a lambda that inherits its exposure from there.
		walk(tree, source, RefactorSupport.collectCommentTokens(source), s, found, true, false);
		if (found.length == 0) return found;
		// No writer, or a writer that declines this file: fail closed. A grammar with no
		// writer makes the check inert rather than leaving every collapse unmeasured.
		final before: Null<Array<String>> = renderedLines(plugin, source, optsJson);
		if (before == null) return [];
		final beforeLines: Array<String> = before;
		return found.filter(m -> paysForItself(plugin, source, m, optsJson, beforeLines));
	}

	/**
	 * Whether collapsing `m` — and nothing else — makes the file read BETTER under the writer,
	 * measured rather than assumed. Both clauses must hold:
	 *
	 * 1. the AFTER rendering is STRICTLY shorter than the BEFORE one — the collapse must
	 *    remove at least one line;
	 * 2. at the FIRST line where the two renderings diverge, the AFTER line is longer once
	 *    trimmed — the collapse must pull content UP onto the lambda's head line, never push
	 *    it off.
	 *
	 * `firstDivergence` cannot answer -1 below: clause 1 has already established that the two
	 * renderings differ in length, and -1 means identical. A writer failure — including the
	 * documented `CommentLossException` — folds to null and REFUSES.
	 */
	private static function paysForItself(
		plugin: GrammarPlugin, source: String, m: Match, optsJson: Null<String>, before: Array<String>
	): Bool {
		final collapsed: String = source.substring(0, m.span.from) + m.text + source.substring(m.span.to);
		final after: Null<Array<String>> = renderedLines(plugin, collapsed, optsJson);
		if (after == null) return false;
		if (after.length > before.length) return false;
		final divergence: Int = firstDivergence(before, after);
		final head: String = trimmedAt(before, divergence);
		final collapsedHead: String = trimmedAt(after, divergence);
		return collapsedHead.length > head.length || headOnlyLostItsBrace(head, collapsedHead) && interiorSurvives(
			before, after, divergence
		);
	}

	/**
	 * Does the de-brace leave every line BETWEEN the head and the closing line untouched?
	 *
	 * The head test says the brace left the first line; it says nothing about the rest, and that
	 * was this check's documented residual until a real site walked into it. Removing a lambda's
	 * block braces moves its body from STATEMENT position into EXPRESSION position, where a
	 * different body policy applies — under this project's `hxformat.json`
	 * (`sameLine.ifBody: fitLine` for statements, `expressionIfArrowBodyReflow: true` for an
	 * arrow body) an `if`/`else` that had its branches on their own lines glues them to their
	 * conditions instead. Four lines became two, the head test still said "only a brace left",
	 * and a shape the author wrote deliberately was reflowed.
	 *
	 * So the de-brace path additionally requires the interior to SURVIVE: the changed region's
	 * lines, trimmed, must be the same sequence before and after, except for the two lines the
	 * braces themselves live on — the head (already checked) and the closing line, where a `}`
	 * disappears — plus the one `;` the emitted body drops.
	 *
	 * The value arms are exempt by construction: they return earlier, because their whole point
	 * is to pull content UP onto the head line.
	 */
	private static function interiorSurvives(before: Array<String>, after: Array<String>, divergence: Int): Bool {
		// A pure de-brace deletes two TOKENS, not lines: the `{` leaves the head line and the `}`
		// leaves the closing one, and nothing in between moves. So it preserves the line count,
		// and a different count is already proof that something else re-flowed. (The caller has
		// only refused GROWTH by this point — a shrink is what the blank-line case does.)
		if (before.length != after.length) return false;
		final tail: Int = commonTail(before, after, divergence);
		final beforeEnd: Int = before.length - tail;
		final afterEnd: Int = after.length - tail;
		// The LAST interior line is where the emitted body's own terminator was stripped (`f();`
		// becomes `f()`), so it is compared modulo that one `;`. Every other line must match
		// exactly — those are lines the collapse has no business touching.
		final lastInterior: Int = beforeEnd - 2;
		for (i in divergence + 1...beforeEnd - 1) {
			final was: String = trimmedAt(before, i);
			final now: String = trimmedAt(after, i);
			if (now == was) continue;
			if (i != lastInterior || now != withoutTerminator(was)) return false;
		}
		final closer: String = trimmedAt(before, beforeEnd - 1);
		final brace: Int = closer.indexOf(BLOCK_CLOSE);
		// No closing brace on the region's last line means it is not the block's closing line and
		// this walk has not understood the shape — refuse rather than compare a line to itself.
		return brace >= 0 && trimmedAt(after, afterEnd - 1) == closer.substr(brace + 1);
	}

	/**
	 * `line` with the one trailing `;` the emitted body drops — see `interiorSurvives`. A line
	 * that does not end on `;` comes back unchanged, so the comparison there stays exact.
	 */
	private static function withoutTerminator(line: String): String {
		final comment: Int = line.indexOf(LINE_COMMENT);
		if (comment < 0) return line.endsWith(';') ? line.substr(0, line.length - 1) : line;
		// A trailing comment rides ALONG with the statement (`f(); // why` re-emits as
		// `f() // why`), so the `;` to drop is the one closing the CODE, not the one closing
		// the line. A `//` inside a string literal only ever costs a refusal: the code part
		// then does not end in `;` and the line comes back unchanged.
		final code: String = line.substring(0, comment).rtrim();
		return code.endsWith(';') ? '${code.substr(0, code.length - 1)} ${line.substr(comment)}' : line;
	}

	/**
	 * How many lines at the END of the two renderings are identical — the boundary that turns
	 * "the first line that differs" into a bounded REGION. Never counts back past `divergence`,
	 * so the region is always well-formed even when the two renderings share a suffix that
	 * reaches into it.
	 */
	private static function commonTail(before: Array<String>, after: Array<String>, divergence: Int): Int {
		var tail: Int = 0;
		while (before.length - tail > divergence + 1 && after.length - tail > divergence + 1) {
			if (before[before.length - tail - 1] != after[after.length - tail - 1]) break;
			tail++;
		}
		return tail;
	}

	/**
	 * Is the collapsed head the original head with its body brace removed and NOTHING else
	 * changed?
	 *
	 * The de-brace-in-place shape: the statement stays exactly where it was and the block's `{` —
	 * the only thing the block contributed to that line — goes away. It is the shape the
	 * project's brace policy asks for whenever a body holds one statement, so it counts as
	 * paying for itself even though it pulls no content up and saves no line.
	 *
	 * The test is an EXACT string identity rather than a width threshold, and that is what
	 * separates it from the shape it must keep refusing: an arg-list explosion also shortens the
	 * head, by a lot (measured on the suite's witness: 63 columns to 17, because the enclosing
	 * call opened), and a threshold would have to guess where "lost a brace" ends and "reflowed
	 * the enclosing construct" begins.
	 */
	private static function headOnlyLostItsBrace(head: String, collapsedHead: String): Bool {
		return head.length > BODY_BRACE_TAIL.length && head.substr(head.length - BODY_BRACE_TAIL.length) == BODY_BRACE_TAIL
			&& collapsedHead == head.substr(0, head.length - BODY_BRACE_TAIL.length);
	}

	/** `text` as the writer would emit it, split into lines; null when the writer throws. */
	private static function renderedLines(plugin: GrammarPlugin, text: String, optsJson: Null<String>): Null<Array<String>> {
		final written: Null<String> = try plugin.writeRoundTrip(text, optsJson) catch (exception: Exception) null;
		return written?.split('\n');
	}

	private static function firstDivergence(before: Array<String>, after: Array<String>): Int {
		final shared: Int = before.length < after.length ? before.length : after.length;
		for (i in 0...shared) if (before[i] != after[i]) return i;
		return before.length == after.length ? -1 : shared;
	}

	/**
	 * Bundle the kinds this check reads, or null when the grammar leaves the check nothing to
	 * match: no anonymous-function-literal kind (see the body — without it the exclusion that
	 * keeps this check off `prefer-arrow-callback`'s node cannot be made), no arrow lambda
	 * kind, no block kind, or neither collapsible statement kind.
	 * The invocation kinds a TRAILING lambda argument can sit in — `callKind` and
	 * `newExprKind`. Both project the callee as their first child and the arguments after
	 * it, so "is the last child" answers "is the trailing argument". Either seam unset just
	 * narrows the relaxation `branchesInternally` grants.
	 */
	private static function callKindsOf(shape: RefShape): Array<String> {
		final kinds: Array<String> = [];
		final callKind: Null<String> = shape.callKind;
		if (callKind != null) kinds.push(callKind);
		final newExprKind: Null<String> = shape.newExprKind;
		if (newExprKind != null) kinds.push(newExprKind);
		return kinds;
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		// The ARROW forms are every lambda kind that is not the anonymous-function literal:
		// `prefer-arrow-callback` owns that one and normalises it into one of these, so
		// excluding it is what keeps a single site from being reported by both checks. With
		// the seam UNSET nothing would be excluded and this check would collapse a
		// `function` literal's block to `function(v) e`, which does not even compile — so an
		// unset seam is a no-op, not a wider match. `prefer-arrow-callback` is inert without
		// it too, so nothing is lost that this check could compose with.
		final fnExprKind: Null<String> = shape.fnExprKind;
		if (fnExprKind == null) return null;
		final arrowKinds: Array<String> = (shape.lambdaKinds ?? []).filter(k -> k != fnExprKind);
		final blockKinds: Array<String> = support.blockKinds();
		final valueReturnKinds: Array<String> = shape.valueReturnKinds ?? [];
		final exprStatementKind: Null<String> = shape.exprStatementKind;
		if (arrowKinds.length == 0 || blockKinds.length == 0) return null;
		if (valueReturnKinds.length == 0 && exprStatementKind == null) return null;
		final shield: ShieldSeams = IfExpressionChain.shieldSeams(shape, blockKinds);
		final throwKinds: Array<String> = shape.throwKinds ?? [];
		// A union of existing statement seams, so duplicates are expected and harmless —
		// membership is the only question ever asked of it.
		final terminatedKinds: Array<String> = valueReturnKinds.concat(throwKinds)
			.concat(shape.controlExitKinds ?? [])
			.concat(shape.localDeclKinds ?? []);
		if (exprStatementKind != null) terminatedKinds.push(exprStatementKind);
		final emptyStmtKind: Null<String> = shape.emptyStmtKind;
		if (emptyStmtKind != null) terminatedKinds.push(emptyStmtKind);
		return {
			arrowKinds: arrowKinds,
			blockKinds: blockKinds,
			valueReturnKinds: valueReturnKinds,
			exprStatementKind: exprStatementKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			controlFlowKinds: shield.conditionalKinds.concat(shape.switchKinds ?? [])
				.concat(shape.loopStatementKinds ?? [])
				.concat(throwKinds),
			branchingKinds: shape.switchKinds ?? [],
			callKinds: callKindsOf(shape),
			shield: shield,
			terminatedKinds: terminatedKinds
		};
	}

	/**
	 * Walk `node`, collecting every collapsible lambda body; a reification subtree is skipped
	 * whole. `shielded` is `node`'s own answer to "can an `else` follow what I emit here" —
	 * false only in the one position that can absorb one — and is re-derived per child.
	 */
	private static function walk(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, out: Array<Match>,
		shielded: Bool, tailArg: Bool
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.arrowKinds.contains(node.kind)) {
			final m: Null<Match> = match(node, source, comments, s, shielded, tailArg);
			if (m != null) out.push(m);
		}
		for (i => child in node.children)
			walk(
				child, source, comments, s, out, IfExpressionChain.childShielded(node, i, s.shield, shielded),
				isTrailingCallArg(node, i, s)
			);
	}

	/**
	 * Is child `index` of `parent` the TRAILING argument of an invocation — the position where
	 * nothing follows the argument but the closing `)`?
	 *
	 * Computed per child on the way down, exactly like `shielded`, because it is a property of
	 * the SLOT rather than of the node: the same lambda reads differently as `f(cb)` and as
	 * `f(cb, onError)`. Every other position answers false, which is the conservative side —
	 * `branchesInternally` only ever RELAXES on a true.
	 */
	private static function isTrailingCallArg(parent: QueryNode, index: Int, s: Seams): Bool {
		return s.callKinds.contains(parent.kind) && index == parent.children.length - 1;
	}

	/**
	 * The collapse of `node`'s body when it is a one-statement block whose statement is a
	 * value `return`, a bare expression or a control-flow construct, and whose rebuild drops
	 * no comment; else null. The body is the LAST child — a lambda's earlier children are its
	 * parameters.
	 */
	private static function match(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, shielded: Bool, tailArg: Bool
	): Null<Match> {
		if (node.children.length == 0) return null;
		final body: QueryNode = node.children[node.children.length - 1];
		if (!s.blockKinds.contains(body.kind) || body.children.length != SINGLE_STATEMENT) return null;
		// A block that is NOT the lambda's tail cannot be its body: `->` parses its body
		// greedily, so `v -> { return 1; } != null` projects as `ThinArrow(v, NotEq(…))` and
		// the block is a grandchild. That greediness is what spares this check the slot
		// analysis `prefer-ternary-expression` needs — nothing outside can bind INTO an
		// emitted body that the braces were not already shielding.
		final picked: Null<Collapsible> = collapsible(body.children[0], s, shielded, tailArg);
		if (picked == null) return null;
		final bodySpan: Null<Span> = body.span;
		final pickedSpan: Null<Span> = picked.node.span;
		if (bodySpan == null || pickedSpan == null) return null;
		final valueSpan: Null<Span> = picked.terminated ? emittedSpan(picked.node, pickedSpan, source, comments, s) : pickedSpan;
		if (valueSpan == null || valueSpan.to <= valueSpan.from) return null;
		final trailing: Null<{ span: Span, text: String }> = trailingComment(bodySpan, valueSpan, source, comments);
		final kept: Array<Span> = trailing == null ? [valueSpan] : [valueSpan, trailing.span];
		if (IfExpressionChain.droppedComment(bodySpan, kept, comments)) return null;
		final emitted: String = source.substring(valueSpan.from, valueSpan.to);
		return { span: bodySpan, text: trailing == null ? emitted : '$emitted ${trailing.text}\n' };
	}

	/**
	 * Does `stmt` branch INTERNALLY — an `if` with an `else`, or a `switch`?
	 *
	 * Such a body keeps its braces UNLESS the lambda is the TRAILING argument of its call
	 * (`isTrailingCallArg`) — USER decision, 2026-08-09, refined the same day. The braces are
	 * not noise in the non-trailing slot:
	 * they delimit a construct that already has more than one arm, and the collapsed shape puts
	 * that construct own branch keywords into the lambda argument position — measured on a real
	 * site, `success -> if (success) API.login(…); else LoadView.hideAsyncMask(),`, where a `;`,
	 * an `else` and the argument comma end up on one line and the reader has to separate the
	 * lambda body from the call argument list by eye. In the TRAILING slot nothing follows the
	 * body but `)`, so that run of punctuation cannot form and the same code reads fine — the
	 * shape existed hand-written in the target tree (`forEachChild(item -> if (item.folder)
	 * checkSessions(item); else addNewFile(item))`) before any rule touched it. A body with ONE
	 * arm — an else-less `if`, a `for`, a `while`, a `throw` — carries no ambiguity in either
	 * slot and always collapses.
	 *
	 * Anything that is not a trailing invocation argument (an assignment, a `return` value, a
	 * non-last argument) answers false and keeps the braces: fail-closed, since only the
	 * trailing slot was measured.
	 *
	 * The `else` test is the child COUNT, the same discriminator
	 * `IfExpressionChain.isElseLessConditional` uses from the other side, so an `else if` chain
	 * is caught by its outer `if`, whose else-branch child is the nested one.
	 *
	 * The refusal is deliberately confined to the CONTROL-FLOW arm. A value arm
	 * `return if (c) a else b;` collapses to an if-EXPRESSION in value position, which reads as
	 * one expression rather than as branching statements — a different shape from this one.
	 *
	 * `LambdaBranchingBodyBlock` is the other half of the same policy: it puts braces BACK on a
	 * body of this shape that has none, so the two directions agree on where the boundary sits
	 * and a `--fix` fixpoint cannot oscillate across it.
	 */
	private static function branchesInternally(stmt: QueryNode, s: Seams): Bool {
		return s.branchingKinds.contains(stmt.kind) || s.shield.conditionalKinds.contains(stmt.kind)
			&& stmt.children.length >= IF_ELSE_CHILD_COUNT;
	}

	/**
	 * What a one-statement block collapses to: a control-flow statement WHOLE (`terminated`,
	 * its own trailing terminator to be stripped), or the value of a value `return` / a bare
	 * expression statement (emitted verbatim, exactly as before this arm existed). Null for
	 * every other statement — a value-less `return;`, a declaration, a `do … while`, a control
	 * exit, or a `#if` region (one `Conditional` child, which is no accepted kind).
	 *
	 * The control-flow arm comes FIRST because an `if` / `for` / `while` carries two or more
	 * children and the arity guard below would reject it.
	 */
	private static function collapsible(stmt: QueryNode, s: Seams, shielded: Bool, tailArg: Bool): Null<Collapsible> {
		if (s.controlFlowKinds.contains(stmt.kind)) {
			// Unshielded, an emitted else-less `if` anywhere in the subtree would swallow the
			// `else` that follows the lambda. See the dangling-else section of the class doc.
			return if (!shielded && IfExpressionChain.holdsElseLessConditional(stmt, s.shield.conditionalKinds))
				null
			else if (!tailArg && branchesInternally(stmt, s))
				null
			else
				{ node: stmt, terminated: true };
		}
		if (stmt.children.length != SINGLE_VALUE_CHILD) return null;
		final valueCarrying: Bool = s.valueReturnKinds.contains(stmt.kind) || stmt.kind == s.exprStatementKind;
		if (!valueCarrying) return null;
		// The SAME gate on the value arms: `return if (c) g();` emits an else-less `if` just as
		// the control-flow arm does, so an unshielded position absorbs the following `else`
		// identically. Predates the control-flow arm; the position walk is what makes it
		// answerable.
		final value: QueryNode = stmt.children[0];
		if (!shielded && IfExpressionChain.holdsElseLessConditional(value, s.shield.conditionalKinds)) return null;
		// The value arm emits its child's span verbatim, which is sound only while the statement's
		// own terminator lies OUTSIDE that child. A gapless terminated statement means the model
		// swallowed the terminator into the value (`{ @:privateAccess if (c) h(); }` projects the
		// `;` inside the meta-wrapped value), and the emitted text would carry it. Refuse: the
		// re-parse gate is no net here, since this parser accepts the shape `haxe` rejects.
		final stmtSpan: Null<Span> = stmt.span;
		final valueSpan: Null<Span> = value.span;
		return if (stmtSpan == null || valueSpan == null)
			null
		else if (s.terminatedKinds.contains(stmt.kind) && stmtSpan.to == valueSpan.to)
			null
		else
			{ node: value, terminated: false };
	}

	/**
	 * `stmt`'s span cut back to its last real token: its own terminator dropped by
	 * `emittedEnd`, then the family's shared trivia normaliser applied on top for a grammar
	 * whose spans run past that token — a measured no-op on the Haxe grammar, see the class
	 * doc. Null when the terminator is not recoverable structurally and the site is refused.
	 * The comment that TRAILS the kept span inside the block — the last content before the `}`
	 * — as the text to append after the emitted statement, or null when there is none to take.
	 *
	 * Without this the comment falls outside the kept span and the family's fail-closed guard
	 * refuses the site, which left a real shape that neither half of the brace policy would
	 * fix: `waitToken(success -> { if (c) doRequest(); else tokenError(); // handlers })` kept
	 * its braces although the trailing slot says it should not have them.
	 *
	 * The comment is APPENDED rather than covered by widening the span, because the gap between
	 * the two is the statement's own TERMINATOR — the `;` that `emittedEnd` strips on purpose,
	 * since a `;` before the enclosing `)` does not parse. Widening the span would put it back.
	 *
	 * The appended text ends with a NEWLINE, and that is load-bearing rather than cosmetic: the
	 * splice puts the emitted body where the block was, so without it the enclosing construct's
	 * closing delimiter would follow a `//` comment ON THE SAME LINE and the collapsed source
	 * would not parse — measured, `renderedLines` returned null and the site was refused with no
	 * diagnostic. The writer normalises the break away for a block comment and keeps it for a
	 * line comment, which is exactly the difference between the two.
	 *
	 * Safe for both comment forms, and for a reason the WRITER supplies rather than this check:
	 * a `//` comment carries a forced break, so the enclosing construct's closing delimiter
	 * lands on the next line (measured: the collapsed body renders as
	 * `else tokenError() // handlers` with `)` below it) and cannot be commented out; a block
	 * comment closes itself. The `--fix` re-parse gate is the backstop either way — a swallowed
	 * delimiter does not parse, so it fails loudly rather than corrupting the file.
	 *
	 * Only a comment with nothing but whitespace and at most the one stripped terminator
	 * between it and the statement, and nothing but whitespace between it and the `}`,
	 * qualifies. A comment between two statements, a leading comment, or several comments leave
	 * this null and the caller refuses as before.
	 */
	private static function trailingComment(
		bodySpan: Span, kept: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Null<{ span: Span, text: String }> {
		var found: Null<{ span: Span, text: String }> = null;
		for (tok in comments) {
			if (tok.from < kept.to || tok.to > bodySpan.to) continue;
			if (!gapIsTerminatorOnly(source, kept.to, tok.from) || !blankBetween(source, tok.to, closeBraceOf(bodySpan, source))) continue;
			if (found != null) return null; // several trailing comments — one append slot only
			found = { span: new Span(tok.from, tok.to), text: source.substring(tok.from, tok.to) };
		}
		return found;
	}

	/** The offset of the block's closing `}` — its span may run past it over trailing trivia. */
	private static function closeBraceOf(bodySpan: Span, source: String): Int {
		var i: Int = bodySpan.to - 1;
		while (i > bodySpan.from && source.fastCodeAt(i) != '}'.code) i--;
		return i;
	}

	/** Is `[from, to)` whitespace plus at most the one terminator `emittedEnd` stripped? */
	private static function gapIsTerminatorOnly(source: String, from: Int, to: Int): Bool {
		var semicolons: Int = 0;
		if (to < from) return false;
		for (i in from ... to) {
			final c: Int = source.fastCodeAt(i);
			if (c == ';'.code) {
				semicolons++;
				if (semicolons > 1) return false;
			} else if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code)
				return false;
		}
		return true;
	}

	/** Is `[from, to)` whitespace only? */
	private static function blankBetween(source: String, from: Int, to: Int): Bool {
		if (to < from) return false;
		for (i in from ... to) {
			final c: Int = source.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) return false;
		}
		return true;
	}

	private static function emittedSpan(
		stmt: QueryNode, span: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Span> {
		final end: Null<Int> = emittedEnd(stmt, s);
		return end == null ? null : IfExpressionChain.tokenSpan(new Span(span.from, end), source, comments);
	}

	/**
	 * Where `node`'s emitted text ends with its trailing terminator dropped, or null when no
	 * such end exists and the site must be refused. Purely structural — the source text is
	 * never scanned for a `;`, which would be a grammar leak.
	 *
	 * A node whose span ends exactly where its LAST child's does is a pass-through: the answer
	 * is that child's. Otherwise the gap between the two is the node's own trailing token, and
	 * a `terminatedKinds` node yields its end to the child's while any other node keeps its
	 * own (a bare `switch`'s closing `}`, a block's). A terminated node with no child span to
	 * fall back on — a childless `EmptyStmt` / `return;` / `break;` — has nothing to recover
	 * and fails closed, as does a `#if` region, whose `#end` is mandatory and whose
	 * terminator sits ahead of it. Worked examples live in the class doc.
	 */
	private static function emittedEnd(node: QueryNode, s: Seams): Null<Int> {
		// A `#if` region closes on `#end` and the terminator to drop sits INSIDE it, ahead of
		// that keyword — no structural end recovers it, so the site is refused.
		if (RefactorSupport.isConditionalKind(node.kind)) return null;
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final terminated: Bool = s.terminatedKinds.contains(node.kind);
		if (node.children.length == 0) return terminated ? null : span.to;
		final last: QueryNode = node.children[node.children.length - 1];
		final lastSpan: Null<Span> = last.span;
		return if (lastSpan == null)
			terminated ? null : span.to
		else if (span.to == lastSpan.to)
			emittedEnd(last, s)
		else if (terminated)
			lastSpan.to
		else
			span.to;
	}

}

/** The kinds `PreferLambdaExpressionBody` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var arrowKinds: Array<String>;
	var blockKinds: Array<String>;
	var valueReturnKinds: Array<String>;
	var exprStatementKind: Null<String>;
	var opaqueKinds: Array<String>;

	/** The control-flow statements a body may hold whole — `if` / `switch` / loop / `throw`. Empty leaves that arm inert. */
	var controlFlowKinds: Array<String>;

	/** The kinds whose body branches internally and therefore keeps its braces — `switch`. */
	var branchingKinds: Array<String>;

	/**
	 * The invocation kinds whose LAST child is the trailing argument — a lambda there is
	 * followed by `)` and nothing else. See `branchesInternally`.
	 */
	var callKinds: Array<String>;

	/**
	 * The dangling-`else` gate's inputs: the parents that close every child with a delimiter,
	 * and every `if` form an emitted else-less conditional could be absorbed by.
	 */
	var shield: ShieldSeams;

	/** Statement kinds whose span covers a trailing terminator the emitted text must not carry. */
	var terminatedKinds: Array<String>;
}

/**
 * What a collapsible block yields: the node whose source becomes the body, and whether its
 * span carries a terminator that the strip must cut (true only for the control-flow arm —
 * the value arms emit a bare expression node's span verbatim).
 */
private typedef Collapsible = {
	var node: QueryNode;
	var terminated: Bool;
}

/** A collapsible lambda body: the block's span (the finding key AND the replaced region) and the expression text. */
private typedef Match = {
	var span: Span;
	var text: String;
}
