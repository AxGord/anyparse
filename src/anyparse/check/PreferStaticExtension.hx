package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.check.UsingScan.UsingHeader;
import anyparse.query.BoolExprShape;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Rewrites a STATIC UTILITY call on a configured module to extension-method form —
 * `Lambda.map(xs, f)` → `xs.map(f)`, `StringTools.trim(s)` → `s.trim()` — inserting a
 * `using <module>;` when the file lacks one. `Severity.Info` (a readability cleanup), with an
 * autofix. Configured per project in `apqlint.json`:
 *
 *     "prefer-static-extension": {
 *         "types":    ["Lambda", "StringTools", "utils.TextUtil"],
 *         "addUsing": true
 *     }
 *
 * `types` defaults to `["Lambda", "StringTools"]`. An entry may be QUALIFIED
 * (`utils.TextUtil`): the call site is matched by the SIMPLE name (`TextUtil.pad(…)`), while
 * the full entry drives the `using`-presence test, the inserted `using` text and the
 * `GrammarPlugin.knownExtensionMethods` lookup. `addUsing: false` keeps the finding but never
 * fixes it — a rewrite without the `using` in scope does not compile, so such a site is
 * refused outright rather than emitted half-done.
 *
 * ## The shape it accepts
 *
 * A `callKind` whose callee is a `fieldAccessKind` with exactly one `identKind` child named
 * after a configured module's simple name, and at least ONE argument (the receiver). A
 * zero-argument `Ext.now()` has no receiver to move and is never a candidate. Two further
 * structural gates: the type identifier must not be VALUE-BOUND (a local or parameter named
 * `Lambda` shadows the module, so `Lambda.map` is a field read, not a static call); and when
 * the grammar KNOWS the module's extension methods (`knownExtensionMethods` non-null — a
 * stdlib module) the called method must be among them, so a non-extension static is skipped.
 * A project-local module the grammar cannot know (null) is accepted on the structural shape.
 *
 * ## The shadow gate is the heart of the rule
 *
 * Haxe resolves an INSTANCE member before a static extension. So when the receiver's type (or
 * a supertype) declares a member of the same name, `Lambda.map(arr, f)` → `arr.map(f)` stops
 * calling `Lambda.map` and starts calling `Array.map` — which COMPILES, while changing the
 * result type (`List<T>` → `Array<T>`) and sometimes the semantics. No compiler oracle catches
 * that, so such a site is never rewritten. A member the index sees DIRECTLY on the receiver
 * type or on one of its supertypes (`SymbolIndex.memberShadowsExtension`) DROPS it entirely: no
 * finding at all, not even report-only. A
 * member reachable only through a link those two do not follow — a `typedef` alias, a
 * `@:forward` abstract's underlying — is caught one gate later, where
 * `typeProvablyLacksMember` (which DOES follow both) fails to prove absence: the site degrades
 * to REPORT-ONLY, still never rewritten but visible to a reader.
 *
 * ## Receiver verdicts
 *
 * The first argument is read WITHOUT its redundant parentheses (`Ext.deco((w), 1)` has the same
 * receiver as the bare form; the peeled `(` / `)` sit inside the deleted regions), and its
 * nominal type is resolved through `NominalTypes.expressionTypeNominal` in its DEEP mode (a bare
 * identifier via its binding annotation, or — for an unannotated `for` binder — via the iterable's
 * element type parameter; a plain field path cross-file through a `SymbolIndex`, with type-argument
 * substitution along the chain; a METHOD CALL on either through the called method's declared return
 * type, recursively along a chain, or through the `staticMethodReturns` table for a tabled stdlib
 * static), plus `literalTypeNames` for a `stringLiteralKinds` receiver. Everything else stays UNRESOLVED: an
 * operator expression, a ternary, a `?.` chain, a bare `this` outside an abstract body (inside one it
 * resolves to the underlying type the header names — the single host where `this` is not the
 * enclosing instance), a `Null<…>` / `Any` declared type — and a NUMERIC literal, which is a
 * deliberately skipped FIXABLE class rather than an unresolvable one: `255.hex(2)` compiles fine under
 * `using StringTools`, but `5.trim()` types as the float `5.` applied to `trim`, so the safe
 * rewrite depends on the literal's exact spelling. Given a resolved nominal `R` and the method
 * `m`:
 *
 *  - `R` is the grammar's `rawDynamicTypeName` → DROP. A `Dynamic` receiver dispatches nothing
 *    statically: the rewrite compiles and breaks at RUNTIME, which no oracle sees.
 *  - `R` or a supertype declares `m` → DROP (the shadow gate above).
 *  - `R`'s member closure provably lacks `m` → a FIXABLE finding.
 *  - the closure is unresolvable (a supertype outside the index, an unreadable `typedef` alias,
 *    a `@:forward` abstract) → a REPORT-ONLY finding whose message asks the reader to verify
 *    that no same-name member exists.
 *  - `R` unresolved, or no index at all → a REPORT-ONLY finding with its own message.
 *
 * ## The conflicting-`using` gate
 *
 * An explicit `Module.m(x)` written in a file that ALSO carries `using Other;` may be
 * deliberate disambiguation, and rewriting it to `x.m(…)` could silently dispatch to
 * `Other.m`. So every OTHER top-level `using` is tested for the method — by
 * `knownExtensionMethods` when the grammar knows that module, else by
 * `typeProvablyLacksMember` through the index — and any hit, or any doubt, DROPS the site.
 * Conservative by construction: an unresolvable second `using` counts as a conflict. The
 * verdict depends only on the (module, method) pair, so it is memoised across a file's call
 * sites.
 *
 * ## The rewrite
 *
 * Two edits per site, which is what lets NESTED candidates compose in one pass without
 * overlapping: `[call.from, recv.from)` is deleted (`Ext.deco(`) and `[recv.to, rest.from)`
 * becomes `.m(` — or `[recv.to, call.to)` becomes `.m()` for a single argument. A comment in
 * either deleted region refuses the edit and leaves the site a report-only finding. Every
 * receiver that reaches the fixable set is an identifier, a plain field path, a method call on
 * one of those, or a string literal — all postfix-safe — so the spliced receiver never needs
 * parentheses. That INVARIANT is enforced in `receiverNominal`, by a kind whitelist in front of
 * the resolution walk rather than by a test here: the walk is shared with a gate whose
 * conservative direction is the opposite one, so its own answer cannot be the guarantee.
 *
 * `fix` re-derives every gate against the PLUGIN's resolution index
 * (`RefactorSupport.resolutionIndexOf`) in preference to the report-scoped index it is handed,
 * because that is the scope `run` proved the verdicts on: the narrower one would silently
 * degrade every std-typed site to report-only, and could just as easily "prove" — from a name
 * the report scope happens to see only once — something the wider scope refused.
 *
 * ## Known limitations
 *
 * - A FULLY QUALIFIED call site (`haxe.io.Path.withoutExtension(p)`) is invisible: the callee's
 *   root is a `fieldAccessKind` chain, not a bare `identKind`, so it never matches the shape.
 *   Import the module and the site becomes a candidate.
 * - A receiver that is itself a STATIC call (`Ext.deco(Mk.make(), 1)`) stays report-only unless
 *   `Mk.make` is a `staticMethodReturns` entry: otherwise its nominal would have to come from
 *   reading the single unbound identifier `Mk` as a type name, which the resolution walk refuses to
 *   guess, and a type that declares a static and an instance member of one name would answer for
 *   the wrong one. An EXTENSION call is the same miss from the other end: the method is not a member
 *   of the receiver's type, so it names no return type to read — a chain of them never resolves
 *   however many `--fix` passes run.
 * - An `import.hx`-provided `using` is invisible (anyparse ignores `import.hx` repo-wide):
 *   worst case an inserted `using` that was already implied, or a conservative miss of a
 *   conflicting module. Neither breaks a build.
 * - `#if` bodies project as one opaque node, so a call inside conditional compilation is never
 *   found — the standard walker limitation. A `#if`-SPLIT type is a subtler one: the index
 *   keeps the first branch's declaration of a name, so the shadow gate reads that branch's
 *   member list only. The alias arm refuses such a decl outright; a split CLASS could still
 *   hide a member the other branch declares.
 * - The `using` declaration kind is spelled literally (`UsingScan.USING_DECL_KIND`, shared with
 *   `prefer-find`): the grammar exposes no seam for it, so a grammar naming it differently gets
 *   no `using`-awareness.
 *
 * ## Grammar-agnostic
 *
 * Driven by `identKind`, `callKind`, `fieldAccessKind`, `opaqueKinds`, `stringLiteralKinds`,
 * `literalTypeNames`, `nullableWrapperTypeNames`, `rawDynamicTypeName` and the OPTIONAL
 * `parenKind` — unset, a parenthesized receiver simply stays unresolved (a missing required
 * kind → no-op). The whole CHECK — not merely the receiver gate — also requires `plugin is
 * TypeInfoProvider`: without declared-type information no receiver could ever resolve, so every
 * site would be an unactionable report-only finding.
 */
@:nullSafety(Strict)
final class PreferStaticExtension implements Check implements ConfigAware {

	/** The rule id, also the `apqlint.json` option key. */
	private static inline final RULE_ID: String = 'prefer-static-extension';

	/** A candidate call has at least [callee, receiver] children. */
	private static inline final MIN_CALL_CHILDREN: Int = 2;

	/** The child index of the first argument AFTER the receiver — the rest the rewrite keeps. */
	private static inline final REST_INDEX: Int = 2;

	/** Cap on the receiver / argument excerpt length in the suggestion message. */
	private static inline final EXCERPT_MAX: Int = 40;

	/** The clause type-reference kind an abstract header's underlying type projects as — literal for the same reason. */
	private static inline final UNDERLYING_TYPE_KIND: String = 'Named';

	/**
	 * The two abstract declaration kinds, spelled literally: `RefShape.enumAbstractDeclKind` names
	 * only the enum spelling and no seam carries the plain one. They are the one host where a bare
	 * `this` denotes something other than the enclosing type's own instance.
	 */
	private static final ABSTRACT_DECL_KINDS: Array<String> = ['AbstractDecl', 'EnumAbstractDecl'];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a static utility call (Lambda.map(xs, f)) rewritable to extension style (xs.map(f)) with a using import';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final violations: Array<Violation> = [];
		// The receiver / conflict gates resolve cross-file; the index is built at most once, on
		// first demand, because most files hold no call on a configured module at all.
		final symbols: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		for (entry in files) {
			final options: Options = readOptions(LintConfig.resolveWith(_resolveConfig, entry.file));
			if (options.modules.length == 0) continue;
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (candidate in candidates(tree, entry.source, entry.file, s, options, plugin, symbols)) violations.push({
				file: entry.file,
				span: candidate.callSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: candidate.message,
				declineReason: declineReasonFor(candidate.verdict)
			});
		}
		return violations;
	}

	/**
	 * Rewrite each FIXABLE flagged call to extension form and insert the `using` declarations
	 * the rewrites need. The gates run again here — `run`'s verdicts are not carried across the
	 * call — so a null `index` (no cross-file resolution) leaves every site report-only and
	 * emits nothing. An edit pair overlapping an already-accepted one is skipped; the loser
	 * converges on a later `--fix` pass.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final s: Seams = seams;
		// The violations belong to ONE file; its path drives config resolution (an empty path
		// would silently resolve the wrong `apqlint.json`).
		final file: String = violations[0].file;
		final options: Options = readOptions(LintConfig.resolveWith(_resolveConfig, file));
		if (options.modules.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final header: UsingHeader = UsingScan.headerOf(root, source, plugin);
		// `Cli` hands `fix` the REPORT-scoped index, but the gates must re-derive on the SAME
		// scope `run` proved them on — the plugin's resolution index (report files UNION the
		// libraries and the std). Without this a std-typed receiver reads as unresolvable here,
		// every finding degrades to report-only, and the autofix silently never fires.
		final resolution: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final byKey: Map<String, Candidate> = [];
		for (candidate in candidates(root, source, file, s, options, plugin, () -> resolution))
			byKey['${candidate.callSpan.from}:${candidate.callSpan.to}'] = candidate;
		final edits: Array<{ span: Span, text: String }> = [];
		final rewritten: Array<String> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span == null) continue;
			final candidate: Null<Candidate> = byKey['${span.from}:${span.to}'];
			if (candidate == null || candidate.verdict != Verdict.Fixable) continue;
			// A rewrite without the module in scope does not compile, so a file that lacks the
			// `using` and forbids inserting one is refused before any edit is built.
			//
			// These three gates are PER-SITE and they fire on a finding `run` already judged `Fixable`,
			// so `declineReasonFor` wrote nothing on it — the reason has to be written here, at the gate
			// that decided, on the caller's own violation objects (`Cli` hands `fix` the array `run`
			// built, which is what makes a note here reach the reporter; `ImportBlockOrder.noteDecline`
			// is the same mechanism). Left unset, the ledger reported these as a rule that "withheld it,
			// without saying why" — the defect this rule's `run` side no longer has.
			if (!options.addUsing && !UsingScan.hasUsingModule(header, candidate.module)) {
				violation.declineReason = 'the file has no `using ${candidate.module}` and this project sets addUsing:false, so the'
					+ ' extension call would not resolve';
				continue;
			}
			final pair: Null<Array<{ span: Span, text: String }>> = rewriteEdits(candidate, source);
			if (pair == null) {
				violation.declineReason = 'a comment sits inside the region the rewrite deletes, and dropping a comment silently is'
					+ ' never acceptable';
				continue;
			}
			// No reason on THIS one, and that is not an oversight: the gate can only fire once `edits`
			// holds an accepted rewrite, so this `fix` call returns a non-empty edit set, and
			// `Cli.noteFixOutcome` returns on `editCount != 0` before it reads any `declineReason`. A
			// sentence here would be unreachable by construction — the site is genuinely deferred to the
			// next fixpoint pass, and the pass that reports it is the one where it gets no edit.
			if (CanonicalEdit.editsOverlapAny(pair, edits)) continue;
			for (edit in pair) edits.push(edit);
			if (!rewritten.contains(candidate.module)) rewritten.push(candidate.module);
		}
		appendUsingInserts(header, rewritten, edits);
		return edits;
	}

	/** Bundle the `RefShape` seams + type provider, or null when a required kind / type information is missing (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		if (callKind == null || fieldKind == null) return null;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		return provider == null ? null : {
			shape: shape,
			typed: provider,
			identKind: shape.identKind,
			callKind: callKind,
			fieldKind: fieldKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			stringLiteralKinds: shape.stringLiteralKinds ?? [],
			literalTypeNames: shape.literalTypeNames ?? [],
			nullableWrappers: shape.nullableWrapperTypeNames ?? [],
			dynamicTypeName: shape.rawDynamicTypeName,
			parenKind: shape.parenKind
		};
	}

	/** The per-file `types` / `addUsing` options, with each configured module paired to the simple name a call site is matched by. */
	private static function readOptions(config: LintConfig): Options {
		final modules: Array<String> = config.stringListOption(RULE_ID, 'types') ?? ['Lambda', 'StringTools'];
		return {
			modules: modules,
			simpleNames: [for (module in modules) CheckScan.simpleModuleName(module)],
			addUsing: config.boolOption(RULE_ID, 'addUsing') ?? true
		};
	}

	/** Every call in `tree` that cleared the structural + conflict gates, each carrying its receiver verdict and message. */
	private static function candidates(
		tree: QueryNode, source: String, file: String, s: Seams, options: Options, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>
	): Array<Candidate> {
		final calls: Array<QueryNode> = [];
		collectCalls(tree, s, calls);
		if (calls.length == 0) return [];
		final declaredTypes: Map<Int, String> = s.typed.declaredTypes(source);
		// DEEP-mode resolution context (see `receiverNominal`): built once per file, and only for a
		// file that actually holds a call on a configured module.
		final usings: Array<String> = UsingScan.usingModules(UsingScan.headerOf(tree, source, plugin));
		final chain: ChainTypeContext = { declaredTypeSources: s.typed.declaredTypeSources(source), source: source, usings: usings };
		// The conflict verdict depends only on (module, method), while a file repeats the same
		// pair across every call site — and each miss costs a whole-index member-closure query.
		final conflicts: Map<String, Bool> = [];
		final out: Array<Candidate> = [];
		for (call in calls) {
			final candidate: Null<Candidate> = classify(
				call, tree, source, file, s, options, plugin, symbols, declaredTypes, chain, usings, conflicts
			);
			if (candidate != null) out.push(candidate);
		}
		return out;
	}

	/** Append every call node in `node`'s subtree to `out`, skipping reification / conditional subtrees. */
	private static function collectCalls(node: QueryNode, s: Seams, out: Array<QueryNode>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (node.kind == s.callKind) out.push(node);
		for (child in node.children) collectCalls(child, s, out);
	}

	/**
	 * The candidate `call` describes, or null when ANY gate rejects it — a non-matching shape,
	 * a value-bound type name, a non-extension method, a conflicting second `using`, a
	 * `Dynamic` receiver, or a receiver type that SHADOWS the method with an instance member.
	 * A null result is a full DROP: the site produces no finding at all.
	 */
	private static function classify(
		call: QueryNode, root: QueryNode, source: String, file: String, s: Seams, options: Options, plugin: GrammarPlugin,
		symbols: () -> Null<SymbolIndex>, declaredTypes: Map<Int, String>, chain: ChainTypeContext, usings: Array<String>,
		conflicts: Map<String, Bool>
	): Null<Candidate> {
		if (call.children.length < MIN_CALL_CHILDREN) return null;
		final callee: QueryNode = call.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != s.fieldKind || method == null || callee.children.length != 1) return null;
		final typeIdent: QueryNode = callee.children[0];
		final typeName: Null<String> = typeIdent.name;
		if (typeIdent.kind != s.identKind || typeName == null) return null;
		final moduleIndex: Int = options.simpleNames.indexOf(typeName);
		if (moduleIndex == -1) return null;
		final module: String = options.modules[moduleIndex];
		// A local / parameter named after the module shadows it: `Lambda.map` is then a field read.
		if (TypeResolver.identBindingFrom(typeIdent, root, s.shape) != null) return null;
		final known: Null<Array<String>> = plugin.knownExtensionMethods(module);
		if (known != null && !known.contains(method)) return null;
		final callSpan: Null<Span> = call.span;
		// The receiver is the argument WITHOUT its redundant parentheses: `Ext.deco((w), 1)` splices
		// the same `w` an unparenthesized site would, and the peeled `(` / `)` fall inside the two
		// deleted regions, where the comment gate already guards them.
		final recv: QueryNode = BoolExprShape.unwrapParens(call.children[1], s.parenKind);
		if (callSpan == null || recv.span == null) return null;
		if (UsingScan.conflictingUsing(usings, module, method, plugin, symbols, conflicts)) return null;
		final nominal: Null<String> = receiverNominal(recv, root, s, declaredTypes, chain, symbols, file);
		// A `Dynamic` receiver dispatches no extension at RUNTIME while the rewrite still compiles.
		if (nominal != null && nominal == s.dynamicTypeName) return null;
		final verdict: Null<Verdict> = verdictFor(nominal, method, symbols, file);
		if (verdict == null) return null;
		final suggestion: Null<String> = suggestionOf(call, recv, method, source);
		return suggestion == null ? null : {
			call: call,
			callSpan: callSpan,
			recv: recv,
			method: method,
			module: module,
			verdict: verdict,
			message: messageFor(verdict, suggestion)
		};
	}

	/**
	 * The receiver verdict for the resolved nominal `nominal`, or null when the site must be
	 * DROPPED because the receiver type — or a supertype — declares `method` itself: Haxe picks
	 * that instance member over the extension, so the rewrite would silently retarget. That shadow
	 * question is `SymbolIndex.memberShadowsExtension`, shared with the four `Lambda`-targeting rules
	 * that emit the same call shape; this rule is the only one that also needs the ABSENCE half,
	 * because it reports a hedged finding where they simply keep quiet.
	 */
	private static function verdictFor(
		nominal: Null<String>, method: String, symbols: () -> Null<SymbolIndex>, file: String
	): Null<Verdict> {
		final resolved: Null<SymbolIndex> = symbols();
		if (nominal == null || resolved == null) return Verdict.UnresolvedReceiver;
		final receiverType: String = nominal;
		final index: SymbolIndex = resolved;
		return if (index.memberShadowsExtension(receiverType, method))
			null
		else if (index.typeProvablyLacksMember(receiverType, method, file))
			Verdict.Fixable
		else
			Verdict.UnresolvedClosure;
	}

	/**
	 * The receiver's nominal type name, or null when it does not resolve to one the extension
	 * gates can reason about. A `stringLiteralKinds` receiver takes its nominal from
	 * `literalTypeNames`; an identifier, a plain field path or a METHOD CALL on either goes
	 * through `NominalTypes.expressionTypeNominal`, which reads a call tail's nominal off the
	 * method's declared return type. A bare self-reference is refused because its meaning differs
	 * inside an abstract, and a nullable / top-type wrapper (`Null` / `Any`) names no member host —
	 * both read as unresolved. `Dynamic` passes through so the caller can drop it.
	 *
	 * The walk runs in DEEP mode (a `ChainTypeContext`), which adds four resolutions the shallow one
	 * structurally cannot have: a `for` BINDER's type read off the iterable's element parameter
	 * (`for (key in Reflect.fields(o)) StringTools.urlEncode(key)` — the binder carries no
	 * annotation, so shallow answers null and every such site stayed hedged), a TABLED stdlib static
	 * call's return type, type-argument substitution along a member chain, and a `using`-brought
	 * STATIC EXTENSION on a call tail (`StringTools.endsWith(s.rtrim(), '()')` — the receiver's own
	 * type was unresolvable before, so the site stayed hedged). Deep mode is an
	 * OPT-IN per consumer precisely because a resolved nominal is this rule's licence to ACT: the
	 * arms above are taken not because they resolve MORE but because each is type-CORRECT and fails
	 * closed — the element-parameter table carries the obligation that `iterator()` and
	 * `keyValueIterator()` agree, and the static table is refused for a type any non-std indexed
	 * file redeclares; and the extension arm answers only after `typeProvablyLacksMember` PROVES the
	 * receiver's own type declares no such name (a real member BEATS an extension), walks the `using`s in the compiler's reverse
	 * declaration order, and requires the extension's first parameter to accept the receiver — by
	 * exact nominal, by proven subtype, or by MEMBERSHIP of the two structural types the type layer
	 * models, refused there unless the parameter's element is the signature's own free parameter. A future arm that merely
	 * widens coverage without that guarantee does NOT belong under this opt-in.
	 *
	 * The substitution arm is the one whose failure is NOT closed, and the reason it is still safe
	 * here is a downstream gate rather than the walk: `pathReceiverMemberTypeSource`'s package-blind
	 * fallback can hand back a verbatim type-PARAMETER name (`T` off a `Box<T>` reached through a
	 * subtype) after the substituting walk has refused it. What neutralises that is `verdictFor` —
	 * `typeProvablyLacksMember` requires the nominal to resolve to exactly one indexed declaration,
	 * which a bare parameter name does not, so the site degrades to report-only instead of Fixable.
	 * Deep mode makes this strictly BETTER, not worse: with substitution the same receiver resolves
	 * to the real argument type and the shadow gate can DROP a site the shallow walk called fixable.
	 *
	 * The kind whitelist in front of the walk is the POSTFIX-SAFETY invariant made structural: a
	 * spliced receiver is written verbatim ahead of `.method(`, so only a form that already binds
	 * tighter than a field access may resolve here. It is not merely a restatement of what
	 * `expressionTypeNominal` happens to answer today — deep mode resolves MORE of the same kinds,
	 * never new ones, but a future widening of the shared walk to operators or ternaries would
	 * otherwise reach this rule as an unparenthesized splice that silently reassociates. No fixture
	 * can discriminate the whitelist while that widening has not happened — the walk answers null
	 * for every kind outside it — and that is the point: it is the guard that holds when it does.
	 */
	private static function receiverNominal(
		recv: QueryNode, root: QueryNode, s: Seams, declaredTypes: Map<Int, String>, chain: ChainTypeContext,
		symbols: () -> Null<SymbolIndex>, file: String
	): Null<String> {
		if (s.stringLiteralKinds.contains(recv.kind)) return s.literalTypeNames[recv.kind];
		if (recv.kind != s.identKind && recv.kind != s.fieldKind && recv.kind != s.callKind) return null;
		final selfText: Null<String> = s.shape.selfReferenceText;
		final self: Bool = recv.kind == s.identKind && selfText != null && recv.name == selfText;
		final nominal: Null<String> = self
			? abstractSelfNominal(recv, root)
			: NominalTypes.expressionTypeNominal(recv, root, s.shape, declaredTypes, symbols(), file, chain);
		return if (nominal == null || nominal == s.dynamicTypeName)
			nominal
		else if (s.nullableWrappers.contains(nominal))
			null
		else
			nominal;
	}

	/**
	 * The nominal type a bare `this` denotes at `recv` — the enclosing ABSTRACT's underlying type,
	 * which is what Haxe resolves a `this.member` access against inside an abstract body, and thus
	 * the type the shadow gate has to weigh. The abstract's OWN members are NOT reachable through
	 * `this` (an abstract declaring `hex` still gets `StringTools.hex` at `this.hex(6)` under a
	 * `using`, verified against the compiler), so reading the host's own name here would both gate
	 * on the wrong member list and drop sites that are safe.
	 *
	 * Null for every other host, a CLASS included: there `this` is the enclosing instance, whose
	 * name resolves perfectly well — but no configured module takes such a receiver, so resolving it
	 * would widen the rewrite surface without reaching a real site. Null too when the underlying type
	 * is not a plain nominal (an anonymous structure, a function type), which leaves those sites
	 * report-only rather than rewritten.
	 */
	private static function abstractSelfNominal(recv: QueryNode, root: QueryNode): Null<String> {
		final span: Null<Span> = recv.span;
		if (span == null) return null;
		final decl: Null<TypeDeclMatch> = TypeResolver.enclosingTypeDecl(root, span);
		if (decl == null || !ABSTRACT_DECL_KINDS.contains(decl.kind)) return null;
		final underlying: Array<QueryNode> = decl.nameNode.children;
		if (underlying.length == 0 || underlying[0].kind != UNDERLYING_TYPE_KIND) return null;
		final written: Null<String> = underlying[0].name;
		return written == null ? null : NominalTypes.outerNominalOf(written);
	}

	/** The `recv.method(rest)` form the message shows, excerpt-normalized, or null when a span is unavailable. */
	private static function suggestionOf(call: QueryNode, recv: QueryNode, method: String, source: String): Null<String> {
		final recvSpan: Null<Span> = recv.span;
		if (recvSpan == null) return null;
		final receiver: String = excerpt(source, recvSpan.from, recvSpan.to);
		if (call.children.length <= REST_INDEX) return '$receiver.$method()';
		final firstRest: Null<Span> = call.children[REST_INDEX].span;
		final lastRest: Null<Span> = call.children[call.children.length - 1].span;
		return firstRest == null || lastRest == null ? null : '$receiver.$method(${excerpt(source, firstRest.from, lastRest.to)})';
	}

	/**
	 * Why `verdict` gets no rewrite, in this check's own words, or null for the one that does.
	 *
	 * The two hedged verdicts already SAY why in the finding's message; what they did not do is put
	 * it where `apq lint --fix`'s unfixed ledger reads it (`Violation.declineReason`), so a run that
	 * declined every one of them reported "withheld it, without saying why" over findings whose text
	 * spelled the reason out.
	 *
	 * `Fixable` gets NULL here, and that is not a gap: such a finding can still be declined, but only
	 * by a PER-SITE gate inside `fix`, which writes its own reason there. Answering for those from
	 * here would invent a reason at a site that did not decide.
	 */
	private static function declineReasonFor(verdict: Verdict): Null<String> {
		return switch verdict {
			case Verdict.Fixable: null;
			case Verdict.UnresolvedReceiver:
				'the receiver\'s nominal type did not resolve in scope, so whether it declares a same-name member — which Haxe would '
					+ 'pick over the extension — cannot be answered';
			case _:
				'the receiver resolved but its member closure did not, so a same-name member the rewrite would silently retarget '
					+ 'cannot be ruled out';
		}
	}

	/** The finding text for `verdict`, carrying the suggested extension form. */
	private static function messageFor(verdict: Verdict, suggestion: String): String {
		return switch verdict {
			case Verdict.Fixable:
				'this static utility call can be the extension call $suggestion';
			case Verdict.UnresolvedReceiver:
				'this static utility call may be the extension call $suggestion'
					+ ' (receiver type unresolved: verify the receiver type declares no same-name member)';
			case _:
				'this static utility call may be the extension call $suggestion (verify the receiver type declares no same-name member)';
		}
	}

	/**
	 * The TWO span edits turning `Ext.m(recv, rest)` into `recv.m(rest)` — the head up to the
	 * receiver is deleted and the gap after it becomes `.m(` (or `.m()` when the receiver is the
	 * only argument). Two edits rather than one whole-call replacement is what lets a nested
	 * candidate inside an argument rewrite in the SAME pass without overlapping. Null when a
	 * comment sits in either deleted region: dropping it silently is never acceptable, so the
	 * site stays a report-only finding.
	 */
	private static function rewriteEdits(candidate: Candidate, source: String): Null<Array<{ span: Span, text: String }>> {
		final recvSpan: Null<Span> = candidate.recv.span;
		if (recvSpan == null) return null;
		final callSpan: Span = candidate.callSpan;
		final children: Array<QueryNode> = candidate.call.children;
		final restSpan: Null<Span> = children.length > REST_INDEX ? children[REST_INDEX].span : null;
		if (children.length > REST_INDEX && restSpan == null) return null;
		final tailTo: Int = restSpan != null ? restSpan.from : callSpan.to;
		final tailText: String = restSpan != null ? '.${candidate.method}(' : '.${candidate.method}()';
		return CheckScan.hasCommentMarker(source, callSpan.from, recvSpan.from) || CheckScan.hasCommentMarker(source, recvSpan.to, tailTo)
			? null
			: [
				{ span: new Span(callSpan.from, recvSpan.from), text: '' },
				{ span: new Span(recvSpan.to, tailTo), text: tailText }
			];
	}

	/**
	 * Append ONE insert edit carrying a `using` line for each rewritten module the file lacks.
	 * Every insert anchors at the same zero-width position, so they are merged into a single
	 * edit rather than pushed as several — two zero-width edits at one offset would apply in an
	 * unspecified order.
	 */
	private static function appendUsingInserts(
		header: UsingHeader, modules: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		var anchor: Null<Span> = null;
		var text: String = '';
		for (module in modules) if (!UsingScan.hasUsingModule(header, module)) {
			final insert: { span: Span, text: String } = UsingScan.usingInsertEdit(header, module);
			anchor = insert.span;
			text += insert.text;
		}
		final span: Null<Span> = anchor;
		if (span == null) return;
		final edit: { span: Span, text: String } = { span: span, text: text };
		if (!CanonicalEdit.editsOverlapAny([edit], edits)) edits.push(edit);
	}

	/** The whitespace-normalized `[from, to)` of `source`, truncated with an ellipsis beyond the excerpt cap. */
	private static function excerpt(source: String, from: Int, to: Int): String {
		final flat: String = CheckScan.normalizeSpan(source, from, to).norm;
		return flat.length > EXCERPT_MAX ? '${flat.substring(0, EXCERPT_MAX)}…' : flat;
	}

}

/** What the gates concluded about one static-utility call site. */
private enum abstract Verdict(Int) {

	/** Provably safe to rewrite: the receiver's member closure lacks the method. */
	final Fixable = 0;

	/** The receiver's nominal type did not resolve — reported, never rewritten. */
	final UnresolvedReceiver = 1;

	/** The receiver resolved but its member closure did not — reported, never rewritten. */
	final UnresolvedClosure = 2;

}

/** The `RefShape` kinds + type provider this check reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var shape: RefShape;
	var typed: TypeInfoProvider;
	var identKind: String;
	var callKind: String;
	var fieldKind: String;
	var opaqueKinds: Array<String>;
	var stringLiteralKinds: Array<String>;
	var literalTypeNames: Map<String, String>;
	var nullableWrappers: Array<String>;
	var dynamicTypeName: Null<String>;
	var parenKind: Null<String>;
};

/** One file's resolved `apqlint.json` options: the configured modules (full entry + simple name) and the `using`-insert toggle. */
private typedef Options = {
	var modules: Array<String>;
	var simpleNames: Array<String>;
	var addUsing: Bool;
};

/** A static-utility call site that cleared every structural + conflict gate, with its receiver verdict and message. */
private typedef Candidate = {
	var call: QueryNode;
	var callSpan: Span;
	var recv: QueryNode;
	var method: String;
	var module: String;
	var verdict: Verdict;
	var message: String;
};
