package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.VersionGated;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.SimplifyBooleanTernary;
import anyparse.check.SimplifyNegatedCompound;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin;

using Lambda;

/**
 * Runs a set of `Check`s over a file set and concatenates their
 * violations. Doubles as the built-in check registry: `builtins()` is the
 * default check set the `lint` CLI runs, and `byId` resolves a `--rule`
 * selection against it. A second registry abstraction is deliberately not
 * introduced — there is one check today and the registry is a one-line
 * factory; it grows into a richer form only when a real config / plugin
 * source of checks exists.
 */
@:nullSafety(Strict)
final class Linter {

	/**
	 * The default check set. New built-in checks are appended here; a
	 * grammar-specific check registers by being added alongside the
	 * generic ones (the `Check` contract is language-agnostic — it
	 * receives the plugin).
	 */
	public static function builtins(): Array<Check> {
		return [
			// Ahead of the import rules by convention — this check lifts a stranded doc off the
			// header region they own, so it reads (and runs) first: `Cli.computeFileLintEdits`
			// walks this list in order and defers a later check whose edits overlap an accepted
			// one. Not load-bearing today — `ImportBlockOrder`'s movable import chunk stops at a
			// block comment, so its reorder never covers this check's edits — but the order keeps
			// that true if either side's chunking widens.
			new MisplacedTypeDoc(),
			new UnusedImport(),
			new UnusedLocal(),
			new DuplicateImport(),
			new RedundantImport(),
			// After the import-removing rules on purpose: an import stranded above a whole-body `#if`
			// that is ALSO unused should be deleted by `unused-import`, not relocated by this one.
			new ImportOutsideGuard(),
			new Naming(),
			new UnusedPrivate(),
			new Complexity(),
			new FoldStringLiterals(),
			new DeadCode(),
			new IfFalseDeadCode(),
			new EmptyBlock(),
			new IdenticalOperands(),
			new SelfAssignment(),
			new DuplicateCase(),
			new CasePatternSeparator(),
			new RedundantParens(),
			new RedundantCondCompParens(),
			new CondRegionMerge(),
			new ConstantCondition(),
			new EmptyStatement(),
			new RedundantTrailingComma(),
			new EmptyComment(),
			new EmptyDocTag(),
			new DocCommentContinuation(),
			new RedundantElse(),
			new ComparisonToBoolean(),
			new CollapsibleIf(),
			new CollapsibleElseIf(),
			new DoubleNegation(),
			new InvertNegatedIfElse(),
			new PreferNullCoalescing(),
			new PreferArrayLiteral(),
			new PreferMapLiteral(),
			new PreferMapType(),
			// Ahead of `fold-adjacent-string-literals` (registered near the top, above) in
			// READING order only — not load-bearing, `lint --fix` iterates to a fixed point
			// either way: this rule builds the `+` chain a run of `+=` statements folds into,
			// which that rule then folds further into `$name` interpolation, e.g.
			// `str += ' line '; str += line;` -> `str += ' line ' + line;` -> `str += ' line $line';`.
			new JoinStringAppend(),
			new PreferInterpolation(),
			// Ahead of `prefer-final` in READING order only: this rule turns a multi-declarator
			// statement into the single-declarator ones `prefer-final` can then upgrade. Not
			// load-bearing -- the `--fix` driver loops to a fixed point, so the two compose whatever
			// the registry order.
			new SplitVarDeclaration(),
			new PreferFinal(),
			new SimplifyBooleanReturnChain(),
			new PreferTernaryReturn(),
			new PreferTernaryAssignment(),
			// Disjoint from `prefer-ternary-assignment` by target count: that one owns the
			// single-l-value collapse (via a ternary `simplify-boolean-ternary` then reduces),
			// this one the multi-target boolean-flag block no ternary would improve.
			new SimplifyBooleanBranchAssignment(),
			new PreferTernaryExpression(),
			// After `prefer-switch-expression` in intent, not in position: the two never both
			// claim a chain (this one asks that check first), so registry order is free.
			new PreferIfExpressionChain(),
			new ReturnReassignTernary(),
			new PreferIfExpressionReturn(),
			new PreferIfExpressionAssignment(),
			// Sinks a branching CALL into its one varying argument, where the assignment siblings
			// sink a branching ASSIGNMENT into its r-value. Emits the if-EXPRESSION form for a
			// 2-branch chain too and leaves the ternary downgrade to `prefer-ternary-expression`
			// above -- the `--fix` driver loops to a fixed point, so registry order is free.
			new JoinBranchCall(),
			new PreferSwitchExpressionAssignment(),
			new PreferTryExpressionAssignment(),
			new PreferTryExpressionReturn(),
			// Grouped after both try-expression collapses because it reads their output shape
			// (`x = try E catch (…) null;` followed by a null guard is what
			// `prefer-try-expression-assignment` makes out of a `try` statement). Readability
			// only — the `--fix` driver loops to a fixed point, so the two compose whatever the
			// registry order, and nothing here gates on the position.
			new TryCatchNullGuard(),
			// Registered ahead of `join-declaration-assignment`, which is the shape it PRODUCES: sinking a
			// bare declaration into the block that uses it lands it directly above its first assignment, and
			// the join then pairs them. Registry order is free -- the `--fix` driver loops to a fixed point,
			// and the two can never claim one site (a join needs the assignment to be the declaration's
			// immediate sibling, which this rule's "every occurrence is inside a nested block" gate refuses).
			new NarrowLocalScope(),
			new JoinDeclarationAssignment(),
			new JoinOverrideChain(),
			// Reads the ONE statement shape the statement-list rules deliberately skip — a
			// conditional-compilation region's branches. Registry order is free: no other check
			// claims a `Conditional` node's span, and the rebuilt `return` it emits is a shape
			// `fold-adjacent-string-literals` may fold further on a later fixed-point pass.
			new HoistBranchStringAffix(),
			// Registered AHEAD of `prefer-comprehension`, whose array-comprehension rewrite can cover
			// the loop a ladder sits in. Both edits are then in flight for one region and
			// `Cli.computeFileLintEdits` keeps the first, so this one lands and the comprehension is
			// re-detected on the next `--fix` pass -- the order that composes; the reverse loses the
			// ladder's `for` header and with it the literal range the fix is gated on. Measured
			// 2026-08-19: no other builtin claims a value-position `if` chain of string literals
			// (`prefer-ternary-expression` refuses a three-branch chain), so nothing else is ordered
			// against it.
			new PreferLpad(),
			new JoinReturn(),
			// Registry order is free: the two claim DISJOINT shapes. `join-return` needs the next
			// statement to BE `return <name>;`, and this check refuses exactly that shape (it would
			// emit the same text with none of `join-return`'s annotation handling), so no site is
			// ever claimed twice.
			new JoinSingleUseLocal(),
			new PreferSingleQuotes(),
			new SimplifyBooleanTernary(),
			// Registered after `double-negation`, and THAT ordering is load-bearing: on
			// `!(!(!x) || q)` the two rules claim distinct but NESTED nodes; the earlier
			// double-negation edit lands first and the shared fix pass converges (2 passes,
			// then stable). `simplify-boolean-ternary` is genuinely order-free — different
			// node kinds.
			new SimplifyNegatedCompound(),
			new AssignmentInCondition(),
			new DuplicateTernaryBranches(),
			new PreferBind(),
			new PreferArrowCallback(),
			// After `prefer-arrow-callback`, which normalises a `function` literal into the
			// arrow form this check then collapses — composed across fixed-point passes.
			new PreferLambdaExpressionBody(),
			// The ADD half of the same brace policy: `prefer-lambda-expression-body` refuses exactly
			// the branching bodies this one re-braces, so the pair reaches a fixpoint.
			new LambdaBranchingBodyBlock(),
			// Disjoint from both arrow rules above: they own a literal that is a DIRECT call argument,
			// this one owns a literal bound to a local — an assignment / declaration node always sits
			// between. Registered after `join-declaration-assignment`, which claims the adjacent
			// `var f; f = function(){};` pair first; this rule's overlapping edits are then deferred one
			// fixed-point pass and land on the joined `var f = function(){};` form.
			new PreferLocalFunction(),
			// The eta-reduction terminator of the same lambda cascade: `prefer-arrow-callback` and
			// `prefer-lambda-expression-body` normalise a wrapper into the `x -> f(x)` arrow form this
			// rule then removes entirely, so registering it AFTER them lets one fixed-point run reach
			// the bare `f` from a `function(x) { return f(x); }` literal. Never collides with
			// `prefer-bind`: that rule needs a zero-parameter lambda wrapping a call WITH arguments,
			// this one needs the argument list to BE the parameter list, and the only lambda both
			// could see — `() -> f()` — is the zero-argument call `prefer-bind` refuses outright.
			new RedundantLambdaWrapper(),
			new RedundantMapIterKey(),
			new UnusedParameter(),
			new SwallowedException(),
			new PreferSwitch(),
			new PreferSwitchExpression(),
			new MissingVisibility(),
			new ModifierOrder(),
			new MemberOrder(),
			new FragmentedDocComment(),
			new ExplicitType(),
			new PreferFinalField(),
			new PreferFinalPublicField(),
			new PreferReadOnlyField(),
			new UnnecessaryBlock(),
			new RedundantVoidReturn(),
			new MagicNumber(),
			new PreferEnumAbstract(),
			new RedundantThis(),
			new UnnecessaryNullCheck(),
			new RedundantCast(),
			new RedundantToString(),
			new RedundantNullCoalescing(),
			new UnnecessarySafeNav(),
			new RedundantIsCheck(),
			new ImpossibleIsCheck(),
			new UnreachableCatch(),
			new ImpossibleCast(),
			new RedundantUpcast(),
			new RedundantCastType(),
			new RedundantUncheckedCast(),
			new RedundantAscription(),
			new DeadNullGuard(),
			new DeadNullCoalescing(),
			new DeadSafeNav(),
			new AlwaysNullComparison(),
			new NullDereference(),
			new DeadStore(),
			new ThreadSafety(),
			new UncheckedNullable(),
			new PossibleNullDereference(),
			new UnguardedNullableDeref(),
			new OversizedType(),
			new PreferIndexAccess(),
			// Beside `prefer-index-access`, and the two COMPOSE rather than collide: that
			// rule turns `m.get(k)` into `m[k]`, which is one of the two halves this rule's
			// shape needs, and this one then claims the whole `m.exists(k) ? m[k] : d`
			// ternary. Disjoint from `prefer-null-coalescing` by CONDITION — that one wants a
			// null comparison, this one an `exists` call.
			new RedundantMapExists(),
			new CatchDynamic(),
			new PreferCaseWildcard(),
			new PreferCaseGuard(),
			new CollapseNestedSwitch(),
			new OptionalParamShorthand(),
			new PreferFinalClass(),
			new PreferSafeNav(),
			new PreferSafeNavComparison(),
			new EnglishComments(),
			new PreferComprehension(),
			// Registry order is free: this rule claims an empty-array binding followed by PUSH
			// STATEMENTS, `prefer-comprehension` one followed by a `for` / `while` LOOP — the
			// statement after the binding decides, and it cannot be both.
			new JoinArrayPushes(),
			new PreferFind(),
			// Beside `prefer-find`, and disjoint from it by what the loop RETURNS: that rule
			// requires `return <loopVar>`, these two a boolean LITERAL. The twins are disjoint
			// from each other for the same reason one step down — the loop's literal is `true`
			// for `prefer-exists` and `false` for `prefer-foreach`, so no site can be both.
			new PreferExists(),
			new PreferForeach(),
			new PreferStaticExtension(),
			new LoopGuard(),
			new GuardContinue(),
			new GuardReturn(),
			new MapKeysLookup(),
			new PreferRangeLoop(),
			// Sits beside `prefer-range-loop`: both turn a `while` into a `for`, and they cannot
			// collide — that one claims a counter loop whose condition is `i < B`, this one a loop
			// whose condition is exactly `it.hasNext()`.
			new PreferForIn(),
			// Beside the other loop-header rules, and disjoint from them by CONDITION: this one
			// claims a loop whose condition is the literal `true`, which `prefer-range-loop`
			// (`i < B`) and `prefer-for-in` (`it.hasNext()`) both refuse by shape.
			new WhileTrueCondition(),
			new PreferKeyValueLoop(),
			new DeadBinderCounterLoop(),
			new RedundantReplaceLoop(),
			new TrivialGetter(),
			new NullableSwitchMissingNull(),
			new ShadowingCaseBinder(),
			new ShadowingLocal(),
			new UnusedCaseBinder(),
			new RedundantCaseBody(),
			// Deletes a whole case arm, as `redundant-case-body`'s subsume does, and the two CAN
			// collide: `case 1: t(); case 2: case 3:` has that rule MERGE arms 2 and 3 while this
			// one deletes arm 3, and its subsume edit can land adjacent to this one's deletion
			// (`case 1: t(); case 2: case _:`). This rule's own finding is always the switch's LAST
			// child, which that rule never flags — but its merge EDIT reaches the last arm, so
			// disjointness is a property of the EDITS, not of the findings, and it does not hold.
			// Registry order is free anyway: `Cli.computeFileLintEdits` walks this list in order
			// and defers a check whose edits overlap an accepted one, and both shapes converge
			// across `--fix` passes whichever went first.
			new EmptyCaseArm(),
			// The TERMINATOR of the case-arm cascade: the three rules above each stop at a switch
			// holding one catch-all, and this one removes that husk. Registered after them so a
			// single `--fix` pass reduces the arms first; `Cli.computeFileLintEdits` defers any
			// check whose edits overlap an accepted one, and this rule's edit SPANS the whole
			// switch, so it contains theirs whenever both fire on the same one.
			new UnnecessarySwitch(),
			new DuplicateCode(),
			new ListenerSymmetry(),
			new StringLiteralDup(),
			// The TYPE-level twin of `string-literal-dup`, and the two can never claim the same
			// node: that rule groups string LITERALS, this one anonymous structure TYPES. Both are
			// report-only for the same reason — the name is a human's choice — so neither produces
			// an edit and registry order carries no meaning between them.
			new AnonTypeDup(),
			new AvoidDynamic(),
			new UnusedReturnValue(),
			new DocCoverage(),
			new ExplicitLocalType(),
			new PreferTypedThrow(),
			new RedundantBypassAccessor(),
			// Deletes `get_x` / `set_x` methods, as `trivial-getter` does — but the two can never
			// claim the same method: that check requires the property's read accessor to BE `get`
			// (the slot names the method), this one requires no slot to name it at all. Registry
			// order is therefore free; the comment records why nobody needs to re-derive it.
			new OrphanAccessor(),
			// Deletes public methods, as `orphan-accessor` deletes accessor ones — the two can never
			// claim the same method: this rule skips every `get_` / `set_`-prefixed name outright, and
			// that check claims nothing else. Registry order is therefore free.
			new UnusedPublicMember(),
			new FieldInitAtDeclaration(),
			// The mirror direction, and the two can never claim the same field: that rule needs a
			// field with NO declaration initializer, this one a field that has one. Registry order
			// is therefore free.
			new FieldInitInConstructor(),
			new PreferInline(),
			new InlineConstant(),
			new StaticConstant(),
			// Claims an `Assign` node that sits inside an array / object literal; every other
			// rule that touches an assignment claims either a whole statement or a condition
			// slot, so registry order is free.
			new HoistEmbeddedAssignment(),
			new ExtractRepeatedExpression(),
			new TailMerge(),
			new NoUnderscorePrefix(),
			new ShortenTypeRef(),
			new CondAssignMerge(),
			new RedundantPropertyAccess(),
			new ImportBlockOrder(),
			new PreferLineComment(),
			new PreferDocComment()
		];
	}

	/** The built-in check whose `id()` equals `id`, or null. */
	public static function byId(id: String): Null<Check> {
		return builtins().find(c -> c.id() == id);
	}

	/**
	 * Every registered check that declares a `VolatileMessage`, as rule id -> its
	 * `messageIdentity`. The map `apq lint-diff` keys its findings through.
	 *
	 * Built by ASKING the registry, never by naming rules: a rule whose message quotes a
	 * source coordinate joins by implementing the interface, and no consumer is edited. The
	 * seam replaces a hand-maintained pair of rule ids inside `LintDiff`, which could only
	 * ever list the rules someone had already been burned by — and which had no way to say
	 * that ONE number in a message drifts while its neighbour is the finding.
	 *
	 * A fresh `builtins()` per call rather than a cached map: a process-scoped cache is the
	 * global mutable state this project refuses, and a `lint-diff` run calls this ONCE —
	 * `Cli.runLintDiff` hoists the map above both `tally` calls, so the cost is one registry
	 * construction per process.
	 */
	public static function messageIdentities(): Map<String, (String) -> String> {
		final out: Map<String, (String) -> String> = [];
		for (check in builtins()) if (check is VolatileMessage) {
			final volatileMessage: VolatileMessage = cast check;
			out[check.id()] = volatileMessage.messageIdentity;
		}
		return out;
	}

	/**
	 * Every finding `checks` produce over `files`, with the central REIFICATION and inline-SUPPRESSION
	 * gates applied — the ONE entry point through which a `Check.run` result reaches the rest of the
	 * tool.
	 *
	 * That it is one entry point is the whole design. A finding inside a `macro …` quotation must be
	 * dropped for every check (see `ReificationScan`), and a gate written once per consumer is a rule
	 * each new consumer has to remember: two of them — `FixVerifier.verify` and `Cli`'s
	 * oracle-assisted batch — already existed unnoticed when the gate was first added, and were found
	 * by measuring rather than by reading. Both now come through here, as does `run` itself, so the
	 * filter cannot disagree between them and a new consumer inherits it by using the obvious call.
	 *
	 * A `// noqa` / `CHECKSTYLE:OFF` directive (see `Suppression`) is the same kind of gate and lives
	 * here for the same reason. It used to sit in `run` alone, so the report honoured it and every
	 * `--fix` path ignored it: a `noqa`-carrying line was reported clean and rewritten anyway, which
	 * is the exact failure the suppression mechanism exists to prevent — the user writes it BECAUSE
	 * the rule is wrong there. `run` still adds what is genuinely configuration (enablement, severity
	 * overrides) on top; a directive written in the source is not configuration.
	 */
	public static function collect(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, checks: Array<Check>
	): Array<Violation> {
		final raw: Array<Violation> = [for (check in checks) for (violation in check.run(files, plugin)) violation];
		final unquoted: Array<Violation> = ReificationScan.withoutQuoted(raw, files, plugin, ReificationScan.exemptIdsOf(checks));
		return Suppression.apply(unquoted, files);
	}

	/**
	 * Run each check in `checks` (default: `builtins()`) over `files` and
	 * return all violations, check by check in registry order. A check
	 * must be skip-parse tolerant (see `Check`); the linter does not catch
	 * per-check exceptions. `ConfigAware` checks receive `resolveConfig`
	 * (or null) before running, so they read their per-file options through it.
	 *
	 * `resolveConfig` maps a file path to the `apqlint.json` in effect there
	 * (walk-up discovered, per-directory memoised by the caller): each finding
	 * is remapped to its own file's configured severity, and — ONLY when
	 * `applyEnablement` is true — DROPPED when that file disables its rule. A
	 * null resolver leaves every finding untouched.
	 *
	 * `applyEnablement` defaults to FALSE: a programmatic caller passing a
	 * resolver for severity/options is NOT silently robbed of findings whose
	 * rule a config disables (the trap when it defaulted true) — matching
	 * `--rule` semantics, where an explicitly selected check runs regardless
	 * of `enabled`. The CLI's non-`--rule` path passes true explicitly to keep
	 * config-disabled rules out of a full report.
	 */
	public static function run(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?checks: Array<Check>,
		?resolveConfig: (String) -> LintConfig, applyEnablement: Bool = false
	): Array<Violation> {
		final active: Array<Check> = checks ?? builtins();
		// A DefaultOff rule is excluded from the default set: its finding survives only
		// when the file explicitly opts in (`enabled:true`) — the inverse default the
		// per-file enablement gate below applies via `enabledFor`'s `defaultOn`.
		final defaultOffIds: Array<String> = [for (c in active) if (c is DefaultOff) c.id()];
		// A rule whose FIX emits syntax newer than the project's declared `languageVersion`
		// is dropped for that file — see `Check.VersionGated`. Collected once; the per-file
		// question is answered against each finding's own config below.
		final minVersionById: Map<String, String> = [
			for (c in active) if (c is VersionGated) c.id() => (cast c: VersionGated).minLanguageVersion()
		];
		// Parse each file once and share the trees across all checks — each check
		// parses independently otherwise, so N checks over M files is N*M parses.
		final cached: GrammarPlugin = plugin is CachingGrammarPlugin ? plugin : new CachingGrammarPlugin(plugin);
		// Thread the caller's memoised per-file config resolver into the option-reading
		// checks so they don't re-walk ancestor dirs + re-parse the JSON per file; a null
		// resolver resets them to their own `LintConfig.discover` fallback.
		for (check in active) if (check is ConfigAware) (cast check: ConfigAware).setConfigResolver(resolveConfig);
		// `collect` has already applied the reification and inline-suppression gates.
		final out: Array<Violation> = collect(files, cached, active);
		if (resolveConfig == null) return out;
		// Per-file config: resolve the apqlint.json for each finding's OWN file, drop
		// it when its rule is disabled there (unless an explicit --rule selection
		// bypasses enablement), then apply that file's severity override.
		final kept: Array<Violation> = [];
		for (violation in out) {
			final config: LintConfig = resolveConfig(violation.file);
			if (applyEnablement && !config.enabledFor(violation.rule, !defaultOffIds.contains(violation.rule))) continue;
			final minVersion: Null<String> = minVersionById[violation.rule];
			if (applyEnablement && minVersion != null && !config.allowsLanguageVersion(minVersion)) continue;
			final sev: Null<Severity> = config.severityFor(violation.rule);
			if (sev != null) violation.severity = sev;
			kept.push(violation);
		}
		return kept;
	}

}
