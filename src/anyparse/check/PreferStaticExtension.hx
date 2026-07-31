package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
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
 * that, so such a site is DROPPED entirely (`SymbolIndex.typeDeclaresMember` /
 * `supertypeDeclaresMember`): no finding at all, not even report-only.
 *
 * ## Receiver verdicts
 *
 * The first argument's nominal type is resolved through `RefactorSupport.valueTypeNominal` (a
 * bare identifier via its binding annotation; a plain field path cross-file through a
 * `SymbolIndex`), plus `literalTypeNames` for a `stringLiteralKinds` receiver. Everything else
 * stays UNRESOLVED: a call, a ternary, a numeric literal (`5.trim()` does not even parse), a
 * `?.` chain, a bare `this` (whose meaning differs inside an abstract), and a `Null<…>` / `Any`
 * declared type. Given a resolved nominal `R` and the method `m`:
 *
 *  - `R` is the grammar's `rawDynamicTypeName` → DROP. A `Dynamic` receiver dispatches nothing
 *    statically: the rewrite compiles and breaks at RUNTIME, which no oracle sees.
 *  - `R` or a supertype declares `m` → DROP (the shadow gate above).
 *  - `R`'s member closure provably lacks `m` → a FIXABLE finding.
 *  - the closure is unresolvable (a supertype outside the index) → a REPORT-ONLY finding whose
 *    message asks the reader to verify that no same-name member exists.
 *  - `R` unresolved, or no index at all → a REPORT-ONLY finding with its own message.
 *
 * ## The conflicting-`using` gate
 *
 * An explicit `Module.m(x)` written in a file that ALSO carries `using Other;` may be
 * deliberate disambiguation, and rewriting it to `x.m(…)` could silently dispatch to
 * `Other.m`. So every OTHER top-level `using` is tested for the method — by
 * `knownExtensionMethods` when the grammar knows that module, else by
 * `typeProvablyLacksMember` through the index — and any hit, or any doubt, DROPS the site.
 * Conservative by construction: an unresolvable second `using` counts as a conflict.
 *
 * ## The rewrite
 *
 * Two edits per site, which is what lets NESTED candidates compose in one pass without
 * overlapping: `[call.from, recv.from)` is deleted (`Ext.deco(`) and `[recv.to, rest.from)`
 * becomes `.m(` — or `[recv.to, call.to)` becomes `.m()` for a single argument. A comment in
 * either deleted region refuses the edit and leaves the site a report-only finding. Every
 * receiver that reaches the fixable set is an identifier, a plain field path or a string
 * literal — all postfix-safe — so the spliced receiver never needs parentheses; that is an
 * INVARIANT of the verdict table above, not a test performed here.
 *
 * ## Known limitations
 *
 * - An `import.hx`-provided `using` is invisible (anyparse ignores `import.hx` repo-wide):
 *   worst case an inserted `using` that was already implied, or a conservative miss of a
 *   conflicting module. Neither breaks a build.
 * - `#if` bodies project as one opaque node, so a call inside conditional compilation is never
 *   found — the standard walker limitation.
 * - The `using` declaration kind is spelled literally (`UsingDecl`, shared with `prefer-find`
 *   through `CheckScan`): the grammar exposes no seam for it, so a grammar naming it
 *   differently gets no `using`-awareness.
 *
 * ## Grammar-agnostic
 *
 * Driven by `identKind`, `callKind`, `fieldAccessKind`, `opaqueKinds`, `stringLiteralKinds`,
 * `literalTypeNames`, `nullableWrapperTypeNames` and `rawDynamicTypeName` (a missing required
 * kind → no-op); the receiver gate additionally requires `plugin is TypeInfoProvider`, without
 * which no receiver would ever resolve.
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

	/** The grammar's `using` declaration kind, spelled literally (see the class doc's limitations). */
	private static inline final USING_DECL_KIND: String = 'UsingDecl';

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
				message: candidate.message
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
		final byKey: Map<String, Candidate> = [];
		for (candidate in candidates(root, source, file, s, options, plugin, () -> index))
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
			if (!options.addUsing && !CheckScan.hasUsingModule(root, candidate.module)) continue;
			final pair: Null<Array<{ span: Span, text: String }>> = rewriteEdits(candidate, source);
			if (pair == null || RefactorSupport.editsOverlapAny(pair, edits)) continue;
			for (edit in pair) edits.push(edit);
			if (!rewritten.contains(candidate.module)) rewritten.push(candidate.module);
		}
		appendUsingInserts(root, rewritten, edits);
		return edits;
	}

	/** Bundle the `RefShape` seams + type provider, or null when a required kind / type information is missing (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		if (callKind == null || fieldKind == null) return null;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return null;
		return {
			shape: shape,
			typed: provider,
			identKind: shape.identKind,
			callKind: callKind,
			fieldKind: fieldKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			stringLiteralKinds: shape.stringLiteralKinds ?? [],
			literalTypeNames: shape.literalTypeNames ?? [],
			nullableWrappers: shape.nullableWrapperTypeNames ?? [],
			dynamicTypeName: shape.rawDynamicTypeName
		};
	}

	/** The per-file `types` / `addUsing` options, with each configured module paired to the simple name a call site is matched by. */
	private static function readOptions(config: LintConfig): Options {
		final modules: Array<String> = config.stringListOption(RULE_ID, 'types') ?? ['Lambda', 'StringTools'];
		return {
			modules: modules,
			simpleNames: [for (module in modules) simpleNameOf(module)],
			addUsing: config.boolOption(RULE_ID, 'addUsing') ?? true
		};
	}

	/** The last dot-segment of `path` — the name a call site spells (`utils.TextUtil` -> `TextUtil`). */
	private static inline function simpleNameOf(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot == -1 ? path : path.substring(dot + 1);
	}

	/** Every call in `tree` that cleared the structural + conflict gates, each carrying its receiver verdict and message. */
	private static function candidates(
		tree: QueryNode, source: String, file: String, s: Seams, options: Options, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>
	): Array<Candidate> {
		final calls: Array<QueryNode> = [];
		collectCalls(tree, s, calls);
		if (calls.length == 0) return [];
		final declaredTypes: Map<Int, String> = s.typed.declaredTypes(source);
		final usings: Array<String> = usingModules(tree);
		final out: Array<Candidate> = [];
		for (call in calls) {
			final candidate: Null<Candidate> = classify(call, tree, source, file, s, options, plugin, symbols, declaredTypes, usings);
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

	/** The module paths of every top-level `using` declaration in `tree`. */
	private static function usingModules(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		for (child in tree.children) if (child.kind == USING_DECL_KIND) {
			final name: Null<String> = child.name;
			if (name != null) out.push(name);
		}
		return out;
	}

	/**
	 * The candidate `call` describes, or null when ANY gate rejects it — a non-matching shape,
	 * a value-bound type name, a non-extension method, a conflicting second `using`, a
	 * `Dynamic` receiver, or a receiver type that SHADOWS the method with an instance member.
	 * A null result is a full DROP: the site produces no finding at all.
	 */
	private static function classify(
		call: QueryNode, root: QueryNode, source: String, file: String, s: Seams, options: Options, plugin: GrammarPlugin,
		symbols: () -> Null<SymbolIndex>, declaredTypes: Map<Int, String>, usings: Array<String>
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
		final recv: QueryNode = call.children[1];
		if (callSpan == null || recv.span == null) return null;
		if (conflictingUsing(usings, module, method, plugin, symbols)) return null;
		final nominal: Null<String> = receiverNominal(recv, root, s, declaredTypes, symbols, file);
		// A `Dynamic` receiver dispatches no extension at RUNTIME while the rewrite still compiles.
		if (nominal != null && nominal == s.dynamicTypeName) return null;
		final verdict: Null<Verdict> = verdictFor(nominal, method, symbols);
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
	 * that instance member over the extension, so the rewrite would silently retarget.
	 */
	private static function verdictFor(nominal: Null<String>, method: String, symbols: () -> Null<SymbolIndex>): Null<Verdict> {
		final resolved: Null<SymbolIndex> = symbols();
		if (nominal == null || resolved == null) return Verdict.UnresolvedReceiver;
		final receiverType: String = nominal;
		final index: SymbolIndex = resolved;
		if (index.typeDeclaresMember(receiverType, method) || index.supertypeDeclaresMember(receiverType, method)) return null;
		return index.typeProvablyLacksMember(receiverType, method) ? Verdict.Fixable : Verdict.UnresolvedClosure;
	}

	/**
	 * The receiver's nominal type name, or null when it does not resolve to one the extension
	 * gates can reason about. A `stringLiteralKinds` receiver takes its nominal from
	 * `literalTypeNames`; an identifier or plain field path goes through
	 * `RefactorSupport.valueTypeNominal`. A bare self-reference is refused because its meaning
	 * differs inside an abstract, and a nullable / top-type wrapper (`Null` / `Any`) names no
	 * member host — both read as unresolved. `Dynamic` passes through so the caller can drop it.
	 */
	private static function receiverNominal(
		recv: QueryNode, root: QueryNode, s: Seams, declaredTypes: Map<Int, String>, symbols: () -> Null<SymbolIndex>, file: String
	): Null<String> {
		if (s.stringLiteralKinds.contains(recv.kind)) return s.literalTypeNames[recv.kind];
		if (recv.kind == s.identKind && recv.name == s.shape.selfReferenceText) return null;
		final nominal: Null<String> = RefactorSupport.valueTypeNominal(recv, root, s.shape, declaredTypes, symbols(), file);
		if (nominal == null || nominal == s.dynamicTypeName) return nominal;
		return s.nullableWrappers.contains(nominal) ? null : nominal;
	}

	/**
	 * Whether another top-level `using` in the file could also supply `method`, making the
	 * explicit static call deliberate disambiguation the rewrite would silently undo. A module
	 * naming the same type as `module` is skipped; for the rest a known extension table decides,
	 * and without one the index must PROVE the module declares no such member. Every doubt —
	 * an unknown module with no index, or an unresolvable one — counts as a conflict.
	 */
	private static function conflictingUsing(
		usings: Array<String>, module: String, method: String, plugin: GrammarPlugin, symbols: () -> Null<SymbolIndex>
	): Bool {
		final simple: String = simpleNameOf(module);
		for (path in usings) if (path != module && simpleNameOf(path) != simple) {
			final known: Null<Array<String>> = plugin.knownExtensionMethods(path);
			if (known != null) {
				if (known.contains(method)) return true;
				continue;
			}
			final index: Null<SymbolIndex> = symbols();
			if (index == null || !index.typeProvablyLacksMember(simpleNameOf(path), method)) return true;
		}
		return false;
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

	/** The finding text for `verdict`, carrying the suggested extension form. */
	private static function messageFor(verdict: Verdict, suggestion: String): String {
		return switch verdict {
			case Verdict.Fixable:
				'this static utility call can be the extension call $suggestion';
			case Verdict.UnresolvedReceiver:
				'this static utility call may be the extension call $suggestion (receiver type unresolved: verify the receiver type declares no same-name member)';
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
		if (CheckScan.hasCommentMarker(source, callSpan.from, recvSpan.from) || CheckScan.hasCommentMarker(source, recvSpan.to, tailTo))
			return null;
		return [
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
	private static function appendUsingInserts(tree: QueryNode, modules: Array<String>, edits: Array<{ span: Span, text: String }>): Void {
		var anchor: Null<Span> = null;
		var text: String = '';
		for (module in modules) if (!CheckScan.hasUsingModule(tree, module)) {
			final insert: { span: Span, text: String } = CheckScan.usingInsertEdit(tree, module);
			anchor = insert.span;
			text += insert.text;
		}
		final span: Null<Span> = anchor;
		if (span == null) return;
		final edit: { span: Span, text: String } = { span: span, text: text };
		if (!RefactorSupport.editsOverlapAny([edit], edits)) edits.push(edit);
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
