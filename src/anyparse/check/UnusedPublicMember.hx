package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberBranchScan;
import anyparse.query.NamingPolicy.FrameworkContract;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * Flags a PUBLIC METHOD of a class whose NAME occurs NOWHERE in scope outside its own
 * declaration — dead weight that neither the compiler nor the formatter removes, and which
 * still reads like live behaviour. The public-facing sibling of `unused-private`, whose
 * confinement proof stops at the file boundary: a public member can be reached from anywhere,
 * so the only usable proof is that the name is not written anywhere at all. DEFAULT OFF
 * (`apqlint.json` `"rules": { "unused-public-member": { "enabled": true } }`, or an explicit
 * `--rule`).
 *
 * ## RUN IT WHOLE-PROJECT
 *
 * Report scope bounds every scan here — the token map, the occurrence confirm, and the
 * inheritance-chain walk all see the file set the lint was given (widened to the resolution
 * scope where one is configured). A subdirectory run is a PREVIEW, not a verdict: a call site
 * in an unlinted file reads as absent, so the report over-reports and `--fix` would delete a
 * method the rest of the project calls. That is also why the rule is registered in the
 * `--fix` loop's full-scope set.
 *
 * ## The reference test — two complementary text mechanisms
 *
 * 1. A GLOBAL identifier-token count map, built once per `run` — i.e. once per lint report and
 *    once per `--fix` PASS, not once per process — over every source in report UNION resolution
 *    scope. It is the cost-bounded pre-filter: a per-candidate scan of a scope that carries the
 *    configured libraries (lime / openfl / … — thousands of files) would be quadratic. The
 *    member is a candidate only when the map's count for its name EQUALS the count of the same
 *    tokens inside the member's OWN exclusion region — i.e. every occurrence in the whole scope
 *    is its own declaration. That comparison is a proof only because the map is built over a
 *    SUPERSET of the member's own file (`tokenCounts` unions the report set in by path).
 * 2. The authoritative confirm, on the REPORT index only: `SymbolIndex.nameOccursOutside`. Its
 *    ONE added power over the token map is `RefactorSupport.DOLLAR_ESCAPES`: a `\x24name` /
 *    `$name` interpolation escape relaxes the LEFT word boundary, and the plain tokenizer
 *    reads `\x24name` as the single token `x24name` instead. Nothing else about it is stronger,
 *    and it is the rule's dominant cost — a per-candidate scan of every report file — which is
 *    why it runs only on candidates the map already cleared.
 *
 * Both are raw-text scans, which makes the rule conservative in the SAFE direction: a name
 * that merely OCCURS — in a comment, in a string literal, in a library, in a `#if` branch, or
 * as an unrelated same-named member of another type — suppresses the finding. A common name
 * (`update`, `run`, `dispose`) is therefore almost never reported; what survives is a name
 * unique to its own declaration, which is exactly the shape a genuinely dead public method
 * has.
 *
 * The exclusion region is NOT the bare member span: it is
 * `docExtendedSpan(declGroupSpan(...))`, so the member's own doc comment and its modifier /
 * metadata run are excluded too — a doc comment naming the member must not read as a
 * reference to it.
 *
 * ## Gates — any of these and the member is never reported
 *
 * The modifier / metadata run preceding a member is walked as `OrphanAccessor` walks it, and
 * RESETS at every member: a `public` or a `@:keep` written on a preceding FIELD belongs to
 * that field, and reading it as the next method's would both invent and hide findings.
 *
 * - Not a method (`FnMember` / `FinalModifiedMember`).
 * - No explicit `public` modifier. A Haxe member with no visibility keyword is PRIVATE, and
 *   `unused-private` owns it.
 * - An `override` — reached polymorphically through the supertype's own call.
 * - ANY `@:meta` in the run (`RefactorSupport.META_KINDS`), and any `#if` region in it, which
 *   projects as a `Conditional` WRAPPING the metadata (`#if js @:keep #end` is
 *   `(Conditional (Meta (Meta @:keep)))`) — neither a meta kind nor a member decl, so a run
 *   walk that did not name it would leave the annotation count at zero. Metadata makes a
 *   member implicitly reachable — this is the Haxe grammar's own `isImplicitlyReachable` rule;
 *   `@:keep` is the motivating case, but the whole class of metadata is treated the same
 *   rather than enumerating a whitelist that would leak by category.
 * - A name reached without ever being written (`IMPLICIT_NAMES`), a dunder `__x__` (module
 *   init / target hook), or a `get_` / `set_` prefix — that last is `orphan-accessor`'s
 *   territory, skipped outright so the two rules can never claim the same method.
 * - A member a FRAMEWORK reaches with no written call: `NamingSupport.frameworkReachable`, the
 *   very predicate `unused-private` routes through, so the two unused-* rules cannot disagree
 *   about one member. In Haxe that is a utest `test*` method of a class transitively extending
 *   `Test`.
 * - An enclosing class the index says is out of reach: `@:keep` or `@:build` on the class
 *   (a build macro may generate the call), an `extern class` (its members are declarations
 *   over a foreign object), or `SymbolIndex.transitivelyCarriesRtti` (the hierarchy is
 *   reflected on field NAMES at runtime).
 * - An ancestor carrying `@:autoBuild` — that macro generates into DESCENDANTS, so it is
 *   read while walking the chain UPWARD, never off the class in hand.
 * - A supertype link that FAILS to resolve. Unresolvable anything means the chain cannot be
 *   read, and this rule has no report-only third arm the way `orphan-accessor` does: a
 *   doubtful chain yields NOTHING. (`OrphanAccessor`'s speculative unique-simple-name
 *   fallback is deliberately not reused — it exists to let a resolved slot SILENCE a finding
 *   while keeping the link marked unresolved, and here an unresolved link already silences.)
 * - (No skip-parse gate, in either scope. Both mechanisms count from RAW SOURCE, and the index
 *   RETAINS a skipped file's bytes, so a call hiding in one fails the test above like any other
 *   — while a file that spells the name nowhere no longer silences the rest of the run. A
 *   skipped file's DECLARATIONS are covered by the unresolvable-supertype bullet above.)
 *
 * There is deliberately NO separate "a supertype / interface / subtype declares this name"
 * query: the text scan SUBSUMES all three. A same-named declaration anywhere in scope — above,
 * beside or below the class — is itself an occurrence of the token, so such a candidate never
 * reaches an index-resolved gate at all.
 *
 * ## Autofix — `RiskyFix`
 *
 * The fix DELETES a public method, and the reachability gate list above is a NEGATIVE one:
 * every entry is a shape somebody found leaking, so the next implicitly-called name (the
 * `for`-desugaring and serializer names in `IMPLICIT_NAMES` were exactly that) leaks until
 * someone trips over it. Combined with the concatenated-reflection hole below, that is enough
 * to make the deletions `RiskyFix`: with a `compilerOracle` configured they are applied
 * through the typecheck-and-revert pipeline, and with none the rule is report-only.
 *
 * The deletion adds ONE gate of its own on top of every report gate
 * (`noRuntimeNameFragment`): no static `Literal` FRAGMENT of an INTERPOLATED string in report
 * scope may be CONTAINED IN the member name — `'do$suffix'` may name it at runtime, and
 * `literalOf` answers null for an interpolated string by contract, so its fragments are what
 * carry the intent. Fragments shorter than `MIN_FRAGMENT_LENGTH` carry no intent and would
 * block every deletion in scope.
 *
 * A reflection literal that carries the WHOLE name needs no gate: a string literal's content
 * is raw text in the source, so the token map and the occurrence confirm already see the name
 * inside it and the member is never even REPORTED. The gap is a name no single literal spells:
 * `Reflect.field(t, 'zqxwvDo' + 'Thing')` defeats BOTH mechanisms (neither literal carries the
 * whole token) AND both gates (the fragment gate inspects only INTERPOLATION fragments, and
 * these are whole literals), and it breaks SILENTLY at runtime rather than as a compile error.
 * Closing it by asking containment the other way round for every literal would veto far too
 * much; `RiskyFix` plus this paragraph is the answer.
 *
 * `fix` deletes the method with its modifier / metadata run and its leading doc comment,
 * whole-line, so nothing orphaned is left behind. The verdict itself is computed in `run`,
 * where the whole file set is in hand, and read back by span (`_deletable`) — `fix` sees one
 * file, and a `fix` with no preceding `run` edits nothing (fail-closed).
 *
 * Scope is class bodies (`CheckScan.classBodies`: `class` / `final class` / `abstract
 * class`). An `interface` declares a contract, an `abstract`'s members reach the underlying
 * type by rules the index does not model, and an `enum` / `typedef` declares no methods.
 */
@:nullSafety(Strict)
final class UnusedPublicMember implements Check implements DefaultOff implements RiskyFix implements ConfigAware {

	/** This check's stable id — named once so the literal is not itself a repeated string. */
	private static inline final RULE_ID: String = 'unused-public-member';

	/** The wrapper of a dunder name (`__init__`) — a compiler hook, not a call target. */
	private static inline final DUNDER: String = '__';

	/** The modifier sibling an explicit `public` projects as. */
	private static inline final PUBLIC_MODIFIER: String = 'Public';

	/** The modifier sibling `override` projects as. */
	private static inline final OVERRIDE_MODIFIER: String = 'Override';

	/**
	 * Method names the runtime or the compiler reaches with NO call token anywhere in source —
	 * so the reference test, which only ever sees written text, cannot possibly find one.
	 *
	 * - `new` — a constructor, reached through `new C(…)`.
	 * - `main` — the entry point the compiler names from the build arguments.
	 * - `toString` — implicit string coercion (`'$x'`, `Std.string(x)`, `'' + x`).
	 * - `iterator` / `keyValueIterator` — Haxe DESUGARS `for (v in x)` / `for (k => v in x)`
	 *   into a call to one of these; neither name appears as a token at the loop.
	 * - `hasNext` / `next` — the same desugaring then drives the returned iterator through
	 *   these two, so a hand-written iterator declares three methods nothing ever spells.
	 * - `hxSerialize` / `hxUnserialize` — `haxe.Serializer` / `haxe.Unserializer` call these by
	 *   name on the instance when a class defines them.
	 *
	 * Not a stylistic whitelist: each of these is a name the LANGUAGE calls, and a member
	 * deleted here breaks the build (or, for the serializer pair, the saved data) with nothing
	 * in source pointing back at it. Names that merely happen to occur in the Haxe std are NOT
	 * covered by this list — they survive only when a resolution scope carries that std, which
	 * is luck rather than a gate, which is why the list must name them here.
	 */
	private static final IMPLICIT_NAMES: Array<String> = [
		'new',
		'main',
		'toString',
		'iterator',
		'keyValueIterator',
		'hasNext',
		'next',
		'hxSerialize',
		'hxUnserialize'
	];

	/**
	 * `<file>#<from>:<to>` of every flagged method whose deletion `run` PROVED safe. Every gate is
	 * whole-project (the token map, the occurrence confirm, the chain walk, the reflection surface)
	 * and `fix` sees ONE file — so the verdict is computed once where the whole file set is in hand
	 * and read back by span. A finding with no entry here is report-only; `fix` called without a
	 * preceding `run` therefore edits nothing (fail-closed).
	 *
	 * Skip-parse is NOT one of them any more. The TWO textual mechanisms read a skipped file's
	 * retained source, so a name that file SPELLS is proven referenced there and no finding survives
	 * to be deleted. What they cannot read is the INTERPOLATED reflection surface: a parsed `Reflect.field(o, 'unused$n')` contributes the fragment `unused`, which
	 * `runtimeNameFragment` matches against a method named `unusedThing` and blocks its deletion,
	 * while a skipped file contributes no fragment at all. The fragment has to be a PROPER substring
	 * of the name for this to be the difference: were it the whole name, the skipped file would spell
	 * it and the two mechanisms above would suppress the finding by themselves. That one shape is the narrowing this rule takes for an unreadable file, in
	 * exchange for not going silent on the whole run. CONCATENATION (`'unused' + n`) is NOT part of
	 * it — no fragment is collected for that shape from a PARSED file either, and the class doc owns
	 * that hole above.
	 */
	private var _deletable: Array<String> = [];

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
		return 'a public method whose name occurs nowhere in scope outside its own declaration — dead weight nothing can reach';
	}

	/**
	 * Report every provably unreferenced public method across `files`, and record the ones whose
	 * deletion is proven safe. NEITHER scope carries a skip-parse gate. The reference proof is
	 * textual on both of its mechanisms and `SymbolIndexBuilder` RETAINS a skipped file's raw
	 * source, so `tokenCounts` counts that file's tokens like any other and `nameOccursOutside`
	 * walks it — a call hiding in an unreadable file still fails the proof, and one that is not
	 * there does not silence the rule for every other file. What a skipped file could otherwise
	 * invalidate is its DECLARATIONS, and `walkChain` answers that per class: a supertype it
	 * cannot resolve leaves the chain unresolved and the class is left alone.
	 */
	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_deletable = [];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		// Names resolve over report UNION resolution scope: a call from a configured library is a
		// real reference, and reading it as absent would report every method a library reaches.
		final wide: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final contracts: Array<FrameworkContract> = LintConfig.frameworksFor(_resolveConfig, files);
		final ctx: Ctx = {
			tokens: tokenCounts(files, wide, plugin),
			fragments: ReflectionScan.reflectionSurface(files, plugin).fragments,
			naming: plugin.namingSupport(),
			contracts: contracts
		};
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			// The resolution index carries the report files too, but only when a scope reached the
			// run at all — fall back to the report index rather than skipping the file. The token
			// map covers the file either way (`tokenCounts` unions the report set in by path).
			final scope: SymbolIndex = wide.fileInfo(entry.file) == null ? index : wide;
			final info: Null<FileInfo> = scope.fileInfo(entry.file);
			if (info == null) continue;
			final branch: MemberBranchSeams = MemberBranchScan.seamsOf(plugin.refShape(), entry.source);
			for (cls in CheckScan.classBodies(tree)) considerClass(out, cls, entry.source, index, scope, info, ctx, branch);
		}
		return out;
	}

	/**
	 * Delete each flagged method `run` proved deletable — the method with its modifier / metadata
	 * run (`declGroupSpan`) and its leading doc comment (`docExtendedSpan`), then the whole line
	 * (`lineExtendedSpan`), so no orphaned doc comment or blank modifier line is left behind. A
	 * finding absent from `_deletable` (an interpolation fragment naming it, or a bare `fix`)
	 * yields no edit. As a `RiskyFix` these edits reach the tree only through the compiler
	 * oracle's typecheck-and-revert pipeline.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return CheckScan.deleteMethodsFix(plugin, source, violations, _deletable);
	}

	/**
	 * Flag every unreferenced public method of `cls`, and record the ones whose deletion is proven
	 * safe. `host` is the class's own declaring file, `scope` the index the chain walk and the
	 * framework-reachability predicate resolve through, `index` the REPORT index the authoritative
	 * occurrence confirm runs over.
	 *
	 * The cheap candidate scan runs FIRST and the index-resolved gates only after it yields
	 * something: each of those walks the whole scope, and on a real tree almost no member survives
	 * the reference test, so paying for them per class would dominate the run.
	 */
	private function considerClass(
		out: Array<Violation>, cls: QueryNode, source: String, index: SymbolIndex, scope: SymbolIndex, host: FileInfo, ctx: Ctx,
		branch: MemberBranchSeams
	): Void {
		final owner: Null<String> = cls.name;
		if (owner == null) return;
		final declared: Null<TypeDeclInfo> = host.types.find(t -> t.name == owner);
		// A `@:build` macro can generate the call the scan cannot see; a `@:keep` class is reached
		// by machinery no scan models; an `extern class` declares members of a foreign object.
		if (declared == null || declared.hasKeep || declared.hasBuild || declared.isExtern) return;
		final candidates: Array<Candidate> = unreferencedCandidates(cls, source, host.file, index, ctx, branch);
		if (candidates.length == 0) return;
		if (scope.transitivelyCarriesRtti(owner)) return;
		final chain: Chain = { unresolved: false, generated: false };
		walkChain(scope, host, declared, chain, []);
		if (chain.unresolved || chain.generated) return;
		final deleting: Array<QueryNode> = [];
		for (candidate in candidates) {
			final name: String = candidate.name;
			if (frameworkReachable(ctx, name, owner, candidate.span, scope)) continue;
			out.push({
				file: host.file,
				span: candidate.span,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: 'unused public $name: no reference to it anywhere in scope'
			});
			if (noRuntimeNameFragment(ctx, name)) deleting.push(candidate.node);
		}
		// Emptying a `#if` region of members leaves a shape the grammar does not model, and the
		// re-parse gate would then drop EVERY edit the pass had for this file — so the question is
		// asked once over the whole class's edit set, not per member. The findings above stay.
		for (member in MemberBranchScan.survivingDeletions(branch, cls, deleting, isDeclKind)) {
			final span: Null<Span> = member.span;
			if (span != null) _deletable.push(CheckScan.spanKey(host.file, span));
		}
	}

	/**
	 * Whether a FRAMEWORK reaches `name` with no written call — a utest `test*` method of a class
	 * transitively extending `Test`, or any member a contract the project declared in `apqlint.json`
	 * (`frameworks`) names. Routed through `CheckScan.frameworkReachableMethod` — the shared adapter
	 * over `NamingSupport.frameworkReachable`, the same predicate `unused-private` consults and the
	 * one `prefer-inline` reads for its own carve-out — and asked with the same roster, so the three
	 * rules cannot disagree about one member's framework status.
	 *
	 * They do not all reach the same INDEX, and the difference is the GATE, not the scope: this rule
	 * and `prefer-inline` take `RefactorSupport.resolutionIndexOf`, which answers on
	 * `hasAnyResolutionScope()` (a std-only scope counts), while `unused-private` takes
	 * `widestScopeIndex`, which demands `hasDeclaredResolutionScope()`. On a project that declares
	 * roots or libs — this one does — all three resolve through the same wide index; on one that
	 * declares neither, `unused-private` falls back to its report index and the other two may not.
	 *
	 * A grammar exposing no naming support answers `false` and the member is judged on the text scan
	 * alone.
	 */
	private static inline function frameworkReachable(ctx: Ctx, name: String, owner: String, span: Span, scope: SymbolIndex): Bool {
		return CheckScan.frameworkReachableMethod(ctx.naming, name, owner, span, () -> scope, ctx.contracts);
	}

	/**
	 * The class's public methods that clear every CHEAP gate — the modifier / metadata run, the
	 * implicitly-reachable name list, and the two-mechanism reference test — each paired with the
	 * span its own declaration occupies.
	 */
	private static function unreferencedCandidates(
		cls: QueryNode, source: String, file: String, index: SymbolIndex, ctx: Ctx, branch: MemberBranchSeams
	): Array<Candidate> {
		final out: Array<Candidate> = [];
		// The run resets at EVERY member, not only at a method: a `public` or a `@:keep` written on a
		// preceding FIELD would otherwise carry onto the next method and answer for it — inventing a
		// finding in one direction and hiding one in the other. A member written inside a
		// member-position `#if` region is visited too, with the run of its own branch.
		MemberBranchScan.eachMember(branch, cls, child -> RefactorSupport.isMemberDeclKind(child.kind), (child, run, certain) -> {
			// A modifier run only SOME builds see cannot answer `public`, which this rule reads as
			// enabling — see `MemberBranchScan.joinRuns`. This is also what keeps the old
			// conservatism for `#if js public #end function f()`: a method public in one build only
			// is not judged, let alone deleted.
			if (!certain || !CheckScan.METHOD_KINDS.contains(child.kind)) return;
			final name: Null<String> = child.name;
			final span: Null<Span> = child.span;
			if (name == null || span == null) return;
			var isPublic: Bool = false;
			var isOverride: Bool = false;
			var annotated: Bool = false;
			for (mod in run) {
				if (mod.kind == PUBLIC_MODIFIER) isPublic = true;
				// A conditional region never reaches the run any more — `eachMember` descends into it
				// and the annotations written inside surface as ordinary `Meta` siblings, while a
				// region that merely CARRIES a modifier out makes the run uncertain and the member is
				// skipped above. Both readings are stricter than the old wrapper count.
				if (RefactorSupport.META_KINDS.contains(mod.kind)) annotated = true;
				if (mod.kind == OVERRIDE_MODIFIER) isOverride = true;
			}
			if (!isPublic || isOverride || annotated || !reportableName(name)) return;
			// Re-bound: a null-safety narrowing does not reach inside an anonymous structure literal.
			final memberName: String = name;
			final memberSpan: Span = span;
			final host: QueryNode = RefactorSupport.memberHostOf(cls, child);
			final region: Span = RefactorSupport.docExtendedSpan(source, RefactorSupport.declGroupSpan(child, host, memberSpan));
			if (provablyUnreferenced(memberName, file, source, region, index, ctx))
				out.push({ name: memberName, span: memberSpan, node: child });
		});
		return out;
	}

	/**
	 * Whether every occurrence of `name` in scope lies inside `region`, its own declaration. The
	 * cheap global token map decides it first (equal counts = nothing outside), then the
	 * authoritative report-scope confirm agrees — `nameOccursOutside` additionally reads the
	 * `\x24name` / `$name` interpolation ESCAPE (`RefactorSupport.DOLLAR_ESCAPES`), which the
	 * plain tokenizer swallows into one long token.
	 */
	private static function provablyUnreferenced(
		name: String, file: String, source: String, region: Span, index: SymbolIndex, ctx: Ctx
	): Bool {
		final own: Map<String, Int> = [];
		countTokens(source, region.from, region.to, own);
		// Short-circuit deliberate: the confirm is a per-candidate scan of every report file, so
		// it must never run for a name the cheap map already saw somewhere else.
		return ctx.tokens[name] == own[name] && !index.nameOccursOutside(name, file, region);
	}

	/**
	 * Whether NO interpolation fragment could spell the member `name` at runtime — the ONE gate
	 * `fix` adds over the report gates, and deliberately narrower than a full "safe to delete"
	 * verdict (see the type doc's Autofix section for what it does NOT cover). No static FRAGMENT
	 * of an interpolated string in report scope may be CONTAINED IN `name`: `literalOf` answers
	 * null for an interpolated string by contract, so a fragment is only ever PART of a runtime
	 * name (`'do$suffix'`) and containment is asked the other way round.
	 */
	private static function noRuntimeNameFragment(ctx: Ctx, name: String): Bool {
		return !ReflectionScan.runtimeNameFragment(ctx.fragments, name);
	}

	/**
	 * Whether `name` is a candidate at all: not one of the names the language itself calls with no
	 * written token (`IMPLICIT_NAMES`), not a dunder compiler hook, and not accessor-prefixed —
	 * a `get_` / `set_` method is `orphan-accessor`'s finding, and reporting it here would
	 * double-claim it.
	 */
	private static function reportableName(name: String): Bool {
		return !IMPLICIT_NAMES.contains(name) && !name.startsWith(CheckScan.GET_PREFIX) && !name.startsWith(CheckScan.SET_PREFIX)
			&& !(name.startsWith(DUNDER) && name.endsWith(DUNDER));
	}

	/**
	 * Accumulate into `chain` whether any ANCESTOR of `type` carries `@:autoBuild` (it generates
	 * members into this class, so its member set is unknowable) and whether any supertype
	 * reference resolved to no indexed declaration (the chain cannot be read at all). Either one
	 * takes the whole class out of scope.
	 */
	private static function walkChain(scope: SymbolIndex, host: FileInfo, type: TypeDeclInfo, chain: Chain, seen: Array<String>): Void {
		final visited: String = '${host.file}#${type.name}';
		if (seen.contains(visited)) return;
		seen.push(visited);
		for (raw in type.supertypesRaw) {
			final supers: Array<{ file: FileInfo, type: TypeDeclInfo }> = scope.resolveTypeRefsFrom(raw, host.file);
			if (supers.length == 0) {
				chain.unresolved = true;
				continue;
			}
			for (s in supers) {
				if (s.type.hasAutoBuild) chain.generated = true;
				walkChain(scope, s.file, s.type, chain, seen);
			}
		}
	}

	/**
	 * The identifier-token occurrence counts over report UNION resolution scope — the run's
	 * cost-bounded pre-filter.
	 *
	 * Two invariants the count comparison in `provablyUnreferenced` rests on, both established
	 * here by construction:
	 *
	 * 1. The map is a SUPERSET of every REPORT file, `files` included. `wide` may legitimately
	 *    lack one (`run` handles that case), and a map missing the declaration's OWN tokens can
	 *    make `global == own` hold by coincidence against unrelated library occurrences the
	 *    report-scope confirm cannot see — a false finding, and a deletion. The report set is
	 *    therefore unioned in, keyed by PATH so nothing is counted twice.
	 * 2. Nothing in the resolution scope is silently missing. Counting tokens is a RAW-TEXT
	 *    operation that needs no parse, so the scope's own sources are read when the host exposes
	 *    them — a library file the parser skipped still contributes. Reading them off the INDEX
	 *    instead would drop such a file from both `allFiles` and `sourceOf`, and a call inside it
	 *    would read as absent. The index path is the fallback for a plugin hosting no scope, where
	 *    `wide` IS the report index and the union below covers it whole anyway.
	 */
	private static function tokenCounts(
		files: Array<{ file: String, source: String }>, wide: SymbolIndex, plugin: GrammarPlugin
	): Map<String, Int> {
		final sources: Map<String, String> = [];
		final resolution: Null<Array<{ file: String, source: String }>> = RefactorSupport.resolutionSourcesOf(plugin);
		if (resolution == null)
			for (fi in wide.allFiles()) sources[fi.file] = indexedSource(wide, fi.file);
		else
			for (entry in resolution) sources[entry.file] = entry.source;
		for (entry in files) sources[entry.file] = entry.source;
		final out: Map<String, Int> = [];
		for (src in sources) countTokens(src, 0, src.length, out);
		return out;
	}

	/** `scope`'s source for `file`. The index writes it in lockstep with the `FileInfo`, so an absent one is a broken index. */
	private static function indexedSource(scope: SymbolIndex, file: String): String {
		final src: Null<String> = scope.sourceOf(file);
		if (src == null) throw new Exception('SymbolIndex lists \'$file\' but holds no source for it');
		return src;
	}

	/**
	 * Accumulate into `out` the occurrence count of every identifier token in `source[from, to)`,
	 * word-boundary by construction. Raw text, so tokens inside comments, string literals and
	 * `#if` branches all count — the conservative direction (an extra occurrence only ever keeps
	 * a member). A token STRADDLING `to` is counted truncated, which likewise can only under-count
	 * the region and so silence a finding.
	 */
	private static function countTokens(source: String, from: Int, to: Int, out: Map<String, Int>): Void {
		final stop: Int = to <= source.length ? to : source.length;
		var i: Int = from;
		while (i < stop) {
			if (!RefactorSupport.isIdentStartChar(source.fastCodeAt(i))) {
				i++;
				continue;
			}
			var end: Int = i + 1;
			while (end < stop && RefactorSupport.isIdentChar(source.fastCodeAt(end))) end++;
			final token: String = source.substring(i, end);
			out[token] = (out[token] ?? 0) + 1;
			i = end;
		}
	}

	/** `RefactorSupport.isMemberDeclKind` as a node predicate — the member set every region guard counts. */
	private static function isDeclKind(node: QueryNode): Bool {
		return RefactorSupport.isMemberDeclKind(node.kind);
	}

}

/** One public method that cleared every cheap gate: its name and its own declaration span. */
private typedef Candidate = {

	/** The method's name — the token the reference test proved absent everywhere else. */
	final name: String;

	/** The method declaration's own span, which the finding reports and `fix` looks up. */
	final span: Span;

	/** The declaration node — read to tell whether deleting it would empty a `#if` region. */
	final node: QueryNode;

};

/** The accumulated verdict of one inheritance-chain walk. */
private typedef Chain = {

	/** Whether a supertype reference resolved to no indexed declaration, leaving the chain unreadable. */
	var unresolved: Bool;

	/** Whether an ancestor carries `@:autoBuild` — it generates members into the class the walk started from. */
	var generated: Bool;

};

/** The whole-run reference evidence, gathered once where the entire file set is in hand. */
private typedef Ctx = {

	/** Identifier-token occurrence counts over every source in report UNION resolution scope. */
	final tokens: Map<String, Int>;

	/** The static text FRAGMENTS of every interpolated string in report scope — the deletion gate. */
	final fragments: Array<String>;

	/** The grammar's naming projection, for its framework-reachability predicate; null when it exposes none. */
	final naming: Null<NamingSupport>;

	/** The project's declared framework contracts, resolved once per run — the roster the reachability predicate is asked with. */
	final contracts: Array<FrameworkContract>;

};
