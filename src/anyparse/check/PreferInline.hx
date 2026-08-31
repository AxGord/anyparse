package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.OracleRelaxable;
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

using StringTools;
using Lambda;

/**
 * Flags a method whose inlining BUYS something and that can therefore be marked `inline`, per the user's rule: use
 * `inline` on trivial getters / setters, thin delegation wrappers and no-op stubs. `Severity.Info`; `--fix` inserts
 * `inline ` before the `function` keyword.
 *
 * A method qualifies when its body is one of three BENEFIT classes: (A) an EMPTY block — the call compiles away, and
 * a FUTURE override of an inlined method fails loudly at the overriding site (the same subtype-gate evidence the
 * other classes rely on); (B) a single accessor / thin-forward / trivial-mutator expression — a bare field chain, a
 * call through a chain with only chain / literal arguments, an assignment or increment over a chain — which collapses
 * into a direct read / write / forwarded call; (C) a constant / small-arithmetic expression (literals, chains and
 * operators only) which can fold at the call site. B and C are bounded by `MAX_BODY_NODES` (~32 AST nodes).
 * Everything else fails the class test by construction — an allocation (`new`, an array / object /
 * interpolated-string literal, a `macro` reification), a lambda argument, a computed forward argument, a loop, a
 * switch, a multi-statement body: none of them gain anything from `inline`, inlining would only duplicate their
 * codegen at every call site.
 *
 * ## Must-skip set (soundness — a miss over a wrong flag)
 *
 * - A method referenced anywhere in scope as a VALUE (callback registration, `.bind`,
 *   passed as an argument, stored in a var). A method-value reference cannot be inlined,
 *   so any value-position occurrence of the method's name — resolvable or not — skips it.
 *   Detected by a conservative name scan over every file: a name in value position (not a
 *   call callee) via `IdentExpr` / `FieldAccess` / `SafeFieldAccess` / `ForceFieldAccess`.
 * - An `override` method, and a method OVERRIDDEN by a subtype (`SymbolIndex.hasSubtype`
 *   plus a member-name lookup across strict subtypes) — inlining would break the override; and a method FILLING an
 *   abstract-superclass slot (`SymbolIndex.supertypeDeclaresMember` — Haxe requires no `override` on such an
 *   implementation).
 * - A method an implemented interface declares (`SymbolIndex.typeProvablyLacksMember`, which
 *   also refuses when the interface is unresolvable) — the interface requires a real method.
 * - EVERY method of a class whose own TYPE-level metadata is not `inlineNeutralMeta`
 *   (`metaBlockedClasses`). The whitelist is the gate, so `@:hlNative` /
 *   `@:nativeGen` / `@:cppFileCode` / `@:build` are examples and not the set. Such an annotation
 *   sits on a module-level sibling BEFORE the declaration, so no member-level modifier run can
 *   carry it, and what it binds is the whole type: a placeholder body the backend discards, or a
 *   member the host runtime calls BY NAME.
 * - EVERY method of a class under a build macro — its own, or one granted through a supertype /
 *   interface (`SymbolIndex.transitivelyCarriesBuildMacro`). The builder writes an `override` of the
 *   method into subclasses with no `override` keyword for the modifier gate to read and no declared
 *   member for the subtype lookup to find, and Haxe reports it at the GENERATED override site, in
 *   another file and possibly another project.
 * - A method a FRAMEWORK reaches by NAME rather than through a written call —
 *   `NamingSupport.frameworkReachable` through `CheckScan.frameworkReachableMethod`, the same
 *   predicate and the same `apqlint.json` `frameworks` roster the two unused-* rules read. NOT a
 *   soundness gate: marking a utest `test*` method `inline` is legal and changes nothing — utest
 *   discovers by NAME out of `Context.getBuildFields()` at compile time, and an A/B of a `setup` /
 *   sync test / async test / `spec` probe with and without `inline` gave identical discovery and
 *   identical results. It is a BENEFIT gate: the framework does emit a real call
 *   (`execute: function() { this.$test(); }`), one the compiler would fold an inline body into —
 *   but it is ONE call site, run once, so the fold buys nothing the rule exists to buy. The shape
 *   is the rule's largest false-positive class on a test tree.
 *   What the shared predicate costs in the other direction: `transitivelyExtends` matches a
 *   contract root by SIMPLE NAME and a prefix contract by bare `startsWith`, so a domain class
 *   extending a project type of its own called `Test` exempts its `spec…` / `setup…` / `test…`
 *   members too. Pre-existing for the two unused-* rules, and safe in the same direction for all
 *   three (a spurious yes only ever withholds a report), but it is a lost opportunity, not nothing.
 * - A `dynamic` method (re-bindable at runtime), a constructor (`new`), a `macro` method, a
 *   `@:keep` method, and any method whose name is passed to `Reflect.*` as a string literal
 *   anywhere in scope (reflection-accessed) — all skipped conservatively.
 * - A method whose single expression references itself (a bare `foo` / `this.foo`) — a
 *   potential recursive inline; a delegation to a same-named method on another receiver
 *   (`other.foo()`) is NOT a self-reference and stays a candidate.
 * - A method whose body carries a `null` literal in a VALUE slot (`bodyHasNullSafetyRisk`) — not a
 *   `==` / `!=` / `??` null-check operand. Haxe re-type-checks an inline body in the CALLER's
 *   null-safety mode, so a `null` argument / operand that compiles in its own (looser / off) context
 *   can fail Strict re-checking at a caller. Over-skips a safe null-value body (the sound direction;
 *   a precise split would need null-flow typing).
 *
 * Every class body — plain / `final` / `abstract class` (`CheckScan.isClassBodyKind`) — is inspected; already-`inline`
 * methods are skipped (nothing to do). The gates mirror `trivial-getter`'s soundness model.
 */
@:nullSafety(Strict)
final class PreferInline implements Check implements RiskyFix implements OracleRelaxable implements ConfigAware {

	/**
	 * The inline-candidate body budget in AST nodes. Calibrated on a large real tree: trivial getters
	 * run 3-6 nodes, thin delegations 8-16, small factories 15-25; past ~32 the bodies are string /
	 * object BUILDERS, `if`-chains, or comparator closures — real work whose codegen inlining would
	 * duplicate at every call site for no gain.
	 */
	private static inline final MAX_BODY_NODES: Int = 32;

	/** The `Call` node kind — shared by the forward classifier and both reference scans. */
	private static inline final CALL_KIND: String = 'Call';

	/** Field-access chain link kinds — a chain is `IdentExpr` at the leaf wrapped in any of these. */
	private static final CHAIN_KINDS: Array<String> = ['FieldAccess', 'SafeFieldAccess', 'ForceFieldAccess'];

	/** Scalar literal kinds — constants carrying no allocation (`NullLit` is mode-gated by the null-safety layer). */
	private static final SCALAR_LIT_KINDS: Array<String> = ['IntLit', 'FloatLit', 'HexLit', 'BoolLit', 'NullLit'];

	/** Assignment-family root kinds of a trivial mutator body (`x = v`, `_n += 1`, `_count++`). */
	private static final MUTATOR_KINDS: Array<String> = [
		      'Assign', 'AddAssign', 'SubAssign',      'MulAssign', 'DivAssign', 'ModAssign', 'BitOrAssign', 'BitAndAssign',
		'BitXorAssign', 'ShlAssign', 'ShrAssign', 'NullCoalAssign',  'PostIncr',   'PreIncr',    'PostDecr',      'PreDecr'
	];

	/** Operator kinds a constant / small-arithmetic body may consist of (plus chains and literals) — none allocate. */
	private static final CONST_OP_KINDS: Array<String> = [
		'Add',
		'Sub',
		'Mul',
		'Div',
		'Mod',
		'Neg',
		'Not',
		'And',
		'Or',
		'BitOr',
		'BitAnd',
		'BitXor',
		'Shl',
		'Shr',
		'UShr',
		'Eq',
		'NotEq',
		'Lt',
		'Gt',
		'LtEq',
		'GtEq',
		'NullCoal',
		'Ternary',
		'ParenExpr',
		'Is'
	];

	/** The class-body member kinds that END a modifier run — a method and the three field forms. */
	private static final MEMBER_KINDS: Array<String> = ['FnMember', 'VarMember', 'FinalMember', 'FinalModifiedMember'];


	/**
	 * Metadata that provably does not change what a method's BODY means, so `inline` stays
	 * behaviour-preserving under it. Any OTHER metadata refuses the candidate.
	 *
	 * Positive by construction, because the harmful side is open-ended and a negative list leaks by
	 * category: the first version listed `@:native` / `@:functionCode` / `@:extern` and a real-tree run
	 * still produced 634 wrong findings in one lime file, every one an `@:hlNative` stub whose body is
	 * `return 0;`. The whole target-binding family (`@:hlNative`, `@:cs.native`, `@:java.native`,
	 * `@:python.native`, `@:jsRequire`, `@:selfCall`, ...) and the code-injection family
	 * (`@:functionTailCode`) redirect or replace the generated call, so the written body is a
	 * placeholder the backend discards - inlining substitutes the placeholder at the call site and the
	 * redirect never happens, turning `native(x) == 0` into `0 == 0`.
	 *
	 * Refusing on an unrecognised annotation is this rule's declared bias (a miss over a wrong flag),
	 * and the accepted list is exactly the annotations that describe VISIBILITY, DOCUMENTATION or
	 * TYPING rather than code generation. `@:keep` is checked separately: it is about reachability, not
	 * about what the body means.
	 */
	private static final INLINE_NEUTRAL_METAS: Array<String> = [
		'@:access',
		'@:allow',
		'@:beta',
		'@:deprecated',
		'@:dox',
		'@:final',
		'@:from',
		'@:isVar',
		'@:noCompletion',
		'@:noDoc',
		'@:noUsing',
		'@:nullSafety',
		'@:op',
		'@:pure',
		'@:to',
		'@:unreflective',
		'@:value'
	];

	private var _oracleRelaxed: Bool = false;

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/**
	 * Enable RELAXED candidate selection: drop the null-safety gate (`bodyHasNullSafetyRisk`) so a
	 * benefit-class body carrying a `null` literal in a value slot (a null argument / operand) also
	 * becomes a candidate. The benefit classes themselves are unchanged — relaxed mode widens ONLY the
	 * null gate. Set by `Cli.applyLintFixes` ONLY when this check runs as a verified `RiskyFix` (a
	 * compiler oracle is configured), so the extra candidates are always applied through the
	 * typecheck-and-revert pipeline, never unverified.
	 */
	public function setOracleRelaxed(relaxed: Bool): Void {
		_oracleRelaxed = relaxed;
	}

	public function id(): String {
		return 'prefer-inline';
	}

	public function description(): String {
		return 'a method whose inlining buys something — empty body, accessor / thin forward / trivial mutator, or a foldable '
			+ 'constant/arithmetic expression (<=32 AST nodes); Info, --fix inserts inline. Allocations, builders, loops, switches, '
			+ 'lambda/computed args are never candidates. Skips methods referenced as a value, override / subtype-overridden, '
			+ 'interface-declared, dynamic / macro / constructor / @:keep / Reflect-accessed methods, and every method of a '
			+ 'class whose own type metadata is not provably inline-neutral (e.g. @:hlNative / @:nativeGen / @:cppFileCode) '
			+ 'or that is under a build macro, its own or inherited';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final shape: RefShape = plugin.refShape();
		// The framework carve-out's two halves: the grammar's own naming seam (which knows the
		// frameworks its language ships) and the project's declared roster. Resolved once per run
		// — `frameworksFor` reads a config per file, and the answer is the same for every method.
		final naming: Null<NamingSupport> = plugin.namingSupport();
		final contracts: Array<FrameworkContract> = LintConfig.frameworksFor(_resolveConfig, files);
		// The grammar's RETAINED tag (Haxe `@:keep`). Asked separately from the inline-neutral
		// whitelist below it: that set is about what a body MEANS, this is about reachability.
		final retained: Null<String> = shape.retainedDeclMetaName;
		final trees: Array<{ file: String, tree: QueryNode, branch: MemberBranchSeams }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) trees.push({ file: entry.file, tree: tree, branch: MemberBranchScan.seamsOf(shape, entry.source) });
		}
		// Pass A: the names of every LOCALLY-eligible method (single-expression / empty, and not
		// inline / dynamic / macro / override / @:keep / constructor / self-recursive) — the only
		// names the reference-kind scan below must resolve, keeping its blocked sets small.
		final candidateNames: Array<String> = [];
		for (t in trees) for (cls in CheckScan.classBodies(t.tree)) forEachMethod(cls, t.branch, (name, fn, mods, metas) -> {
			if (isCandidateMethod(name, fn, mods, metas, _oracleRelaxed, retained) && !candidateNames.contains(name))
				candidateNames.push(name);
		});
		// Pass B: the reference-kind gate over the whole scope — a candidate name used as a VALUE
		// (a method-value reference forbids inlining) or passed to `Reflect.*` as a string literal.
		final valueBlocked: Array<String> = [];
		final reflectBlocked: Array<String> = [];
		for (t in trees) {
			collectValueRefs(t.tree, false, candidateNames, valueBlocked);
			collectReflectNames(t.tree, candidateNames, reflectBlocked);
		}
		// Pass C: emit a finding for each candidate the cross-file gates leave standing. A class whose
		// own TYPE-level annotation is not inline-neutral is skipped whole (see `metaBlockedClasses`).
		final out: Array<Violation> = [];
		for (t in trees) {
			final metaBlocked: Array<QueryNode> = metaBlockedClasses(t.tree, t.branch);
			for (cls in CheckScan.classBodies(t.tree)) if (!metaBlocked.contains(cls))
				considerClass(
					out, cls, t.file, index, valueBlocked, reflectBlocked, _oracleRelaxed, t.branch, retained, naming, contracts, plugin
				);
		}
		return out;
	}

	/**
	 * Insert `inline ` before the `function` keyword of each wanted method (its FnMember span
	 * start). The report already applied every soundness gate — the fix only re-locates each
	 * violated method by span and emits the single insertion, skipping a method somehow already
	 * `inline`.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final wanted: Array<String> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s != null) wanted.push('${s.from}:${s.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		final branch: MemberBranchSeams = MemberBranchScan.seamsOf(plugin.refShape(), source);
		for (cls in CheckScan.classBodies(tree)) forEachMethod(cls, branch, (name, fn, mods, metas) -> {
			final span: Null<Span> = fn.span;
			if (span == null || mods.contains('Inline') || !wanted.contains('${span.from}:${span.to}')) return;
			edits.push({ span: new Span(span.from, span.from), text: 'inline ' });
		});
		return edits;
	}

	/** `node` with a wrapping `ReturnExpr` peeled (an arrow `return EXPR` body projects the wrapper). */
	private static inline function unwrapReturn(node: QueryNode): QueryNode {
		return node.kind == 'ReturnExpr' && node.children.length == 1 ? node.children[0] : node;
	}

	/**
	 * Whether `node` is an allocation-free literal — a scalar, or a string literal WITHOUT
	 * interpolation parts (a plain single-quoted string carries only `Literal` children; any `Ident` /
	 * `Block` part makes it a runtime concatenation).
	 */
	private static inline function isPlainLiteral(node: QueryNode): Bool {
		return SCALAR_LIT_KINDS.contains(node.kind) || (node.kind == 'SingleStringExpr' || node.kind == 'DoubleStringExpr')
			&& !node.children.exists(c -> c.kind != 'Literal');
	}

	/** Whether `node` qualifies as a thin-forward argument / mutator operand: a bare chain or a plain literal. */
	private static inline function isSimpleOperand(node: QueryNode): Bool {
		return isChain(node) || isPlainLiteral(node);
	}

	/** Whether `fn`'s body is an empty `BlockBody` (the no-op arm's message discriminator). */
	private static inline function isEmptyBody(fn: QueryNode): Bool {
		final body: Null<QueryNode> = bodyOf(fn);
		return body != null && body.kind == 'BlockBody' && body.children.length == 0;
	}

	/** Whether `fn`'s body exceeds the `MAX_BODY_NODES` inline budget (node count of the body subtree). */
	private static inline function bodyExceedsBudget(fn: QueryNode): Bool {
		final body: Null<QueryNode> = bodyOf(fn);
		return body != null && nodeCount(body) > MAX_BODY_NODES;
	}

	/** Whether `kind` is an identifier / field-access value node whose name could be a method-value reference. */
	private static inline function isAccessKind(kind: String): Bool {
		return kind == 'IdentExpr' || CHAIN_KINDS.contains(kind);
	}

	/** The last `.`-separated segment of `path` (its simple name). */
	private static inline function simpleName(path: String): String {
		final segments: Array<String> = path.split('.');
		return segments[segments.length - 1] ?? path;
	}

	/**
	 * Whether `node` is a `null` literal in a VALUE slot (not a `==` / `!=` / `??` null-check operand) —
	 * the one context-sensitive construct a benefit-class body can still carry: a `null` argument /
	 * operand re-typechecks in the CALLER's null-safety mode once inlined.
	 */
	private static inline function isRiskyHere(node: QueryNode, parentKind: String): Bool {
		return node.kind == 'NullLit' && parentKind != 'Eq' && parentKind != 'NotEq' && parentKind != 'NullCoal';
	}

	/**
	 * Whether `meta` provably leaves the method's BODY meaning unchanged. True for every USER
	 * annotation (a name not in the compiler's `@:` namespace is not read by any backend) and for the
	 * listed compiler annotations; false for every other `@:` one.
	 *
	 * The `@:` side is a whitelist on purpose. Its complement — the target-binding family
	 * (`@:native`, `@:hlNative`, `@:cs.native`, `@:java.native`, `@:python.native`, `@:jsRequire`,
	 * `@:selfCall`) and the code-injection family (`@:functionCode`, `@:functionTailCode`) — is
	 * open-ended, and a negative list leaks by category: the first version named only `@:native` /
	 * `@:functionCode` / `@:extern` and a real-tree run still produced 634 wrong findings in one lime
	 * file, every one an `@:hlNative` stub whose body is `return 0;`. Under those the written body is
	 * a placeholder the backend discards, so inlining substitutes the placeholder at the call site
	 * and the redirect never happens, turning `native(x) == 0` into `0 == 0`.
	 *
	 * Residual: a `@:build` macro reading a USER annotation could replace the body. That is the same
	 * optimism this rule already applies to an unresolvable supertype, and refusing all user metadata
	 * measurably costs real findings (`@:beta`, `@SuppressWarnings`, `@ignore` on openfl / lime).
	 */
	private static inline function inlineNeutralMeta(meta: String): Bool {
		return !meta.startsWith('@:') || INLINE_NEUTRAL_METAS.contains(meta);
	}

	/**
	 * Whether `name` is reserved rather than chosen — the constructor, or a member the COMPILER
	 * or the target runtime invokes by name. For the second kind there is no call site to
	 * compile away, so the rule's benefit model and its message both describe something that
	 * does not exist; the constructor is excluded for its own unrelated reasons, and was the
	 * whole of this test before.
	 *
	 * The reserved spelling is the dunder convention every such hook in the Haxe std is written
	 * in — `__init__` (58 declarations, e.g. `hl.UI`, whose body IS the class's static-init side
	 * effect), plus `__iter__`, `__add__`, `__call__`, `__str__`, `__next__`, `__setitem__`,
	 * `__import__`, `__unprotect__`, `__alloc__`. Gating on the CONVENTION rather than on a list
	 * keeps the next target's hook out by construction; the two-character over-reach costs one
	 * `Info` finding on a method somebody chose to name that way. `length > 4` is what stops the
	 * two affixes OVERLAPPING — without it `__`, `___` and `____` all read as hooks.
	 *
	 * `HaxeNamingSupport.isReservedName` asks the same question for the naming rules and reaches
	 * it the right way, through the grammar. It is not reused here: it surfaces only as
	 * `NamingPolicy.reservedName`, a field on a per-declaration record the naming PROJECTION
	 * produces, and `isBaseCandidateMethod` holds no plugin handle to run that projection with.
	 * Keep the two in step, or thread the projection in and delete this copy.
	 *
	 * `inline __init__` was probed on js, with and without `-dce full`: it is a silent no-op, not
	 * a miscompile. So this gate removes NOISE, unlike the `@:hlNative` / `@:nativeGen` type gate,
	 * which removes a real breakage.
	 */
	private static inline function isReservedMemberName(name: String): Bool {
		return name == 'new' || (name.length > 4 && name.startsWith('__') && name.endsWith('__'));
	}

	/**
	 * The class nodes of `tree` whose own TYPE-level annotation is not `inlineNeutralMeta` — every
	 * member of such a class is untouchable.
	 *
	 * A type annotation is a module-level sibling BEFORE the declaration, never a child of it, so the
	 * member modifier run `forEachMethod` reads can never carry one: a `@:hlNative` / `@:nativeGen` /
	 * `@:cppFileCode` class passed every metadata gate the rule had. What those bind is the whole
	 * type — under `@:hlNative` each member's body is a placeholder the backend discards, and under
	 * `@:nativeGen` the host runtime calls members BY NAME, which under `-dce full` is a name an
	 * inlined method no longer has. `@:build` / `@:autoBuild` land here too, the same verdict
	 * `transitivelyCarriesBuildMacro` reaches for a grant INHERITED from a supertype.
	 *
	 * The run is carried by `RefactorSupport.isModifierOrMetaKind` — metadata AND the modifier
	 * keywords, because `private` / `extern` project as SIBLING nodes BETWEEN the annotation and the
	 * declaration, and ending the run on them attributed the annotation to the keyword (which owns no
	 * class body) and handed the class out bare. Every other child ends the run, so an annotation
	 * cannot leak past its own declaration to the next type — verified for a typedef / enum /
	 * interface in between. `MemberBranchScan` descends into a `#if` region and folds each branch
	 * separately, so `#if A class X #else @:nativeGen class Y #end` blocks only `Y`, and an annotation
	 * wrapped in a region projects as a name-less `Meta` whose child carries the real name.
	 */
	private static function metaBlockedClasses(tree: QueryNode, branch: MemberBranchSeams): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		MemberBranchScan.eachMember(branch, tree, child -> !RefactorSupport.isModifierOrMetaKind(child.kind), (decl, run, _) -> {
			if (run.exists(carriesNonNeutralMeta)) for (cls in CheckScan.classBodies(decl)) out.push(cls);
		});
		return out;
	}

	/** Whether `node` is — or holds anywhere below it — a metadata node whose name is not `inlineNeutralMeta`. */
	private static function carriesNonNeutralMeta(node: QueryNode): Bool {
		final metaName: Null<String> = RefactorSupport.META_KINDS.contains(node.kind) ? node.name : null;
		// A NAMED annotation's own verdict is final — descending into its ARGUMENTS would let a
		// `@:privateAccess` inside a whitelisted `@:value(...)` refuse the class. Only the name-less
		// wrappers a `#if` region projects are worth recursing through.
		return metaName != null ? !inlineNeutralMeta(metaName) : node.children.exists(carriesNonNeutralMeta);
	}

	/**
	 * Flag each candidate method of `cls` (a benefit-class body) that passes every soundness gate:
	 * not value-referenced / reflection-named anywhere, not overridden by a subtype, not implementing
	 * an abstract-superclass slot, not required by an implemented interface, and — per
	 * `isCandidateMethod` — not a reserved name (a constructor or a compiler-invoked hook), an
	 * override, dynamic, macro, `@:keep`, already inline, or self-recursive, with its body in a
	 * benefit class.
	 */
	private static function considerClass(
		out: Array<Violation>, cls: QueryNode, file: String, index: SymbolIndex, valueBlocked: Array<String>,
		reflectBlocked: Array<String>, relaxed: Bool, branch: MemberBranchSeams, retained: Null<String>, naming: Null<NamingSupport>,
		contracts: Array<FrameworkContract>, plugin: GrammarPlugin
	): Void {
		final className: Null<String> = cls.name;
		if (className == null) return;
		// Re-bound to a non-null local: the narrowing does not reach into the nested callback below.
		final owner: String = className;
		// A build macro on the owner — or granted by a supertype / interface through `@:autoBuild` —
		// writes members no scan of this source can see, an `override` of this very method in every
		// subclass included, with no `override` keyword anywhere for the modifier gate to read and no
		// declared member for `subtypeMemberNames` to find. Haxe accepts `inline` on the declaration
		// silently and rejects it at the GENERATED override site ("Field <m> is inlined and cannot be
		// overridden") — another file, possibly another project.
		if (index.transitivelyCarriesBuildMacro(owner, file)) return;
		final subtypeMembers: Array<String> = index.hasSubtype(owner) ? index.subtypeMemberNames(owner) : [];
		final ifaces: Array<String> = implementedInterfaces(cls);
		forEachMethod(cls, branch, (name, fn, mods, metas) -> {
			if (!isCandidateMethod(name, fn, mods, metas, relaxed, retained)) return;
			if (valueBlocked.contains(name) || reflectBlocked.contains(name) || subtypeMembers.contains(name)) return;
			// An abstract-superclass implementation carries no `override` (Haxe does
			// not require it), so the modifier gate misses it — a resolvable
			// supertype declaring the member means this method fills a base slot and
			// must stay physical. An unresolvable supertype stays optimistic, like
			// the extends chain always was for this rule.
			if (index.supertypeDeclaresMember(owner, name)) return;
			if (interfaceRequires(index, ifaces, name, file)) return;
			final span: Null<Span> = fn.span;
			if (span == null) return;
			// A method a FRAMEWORK reaches by name has ONE call site, the one that framework's own
			// macro writes or its runtime dispatches, and it runs once — so the fold buys nothing
			// and the rule's premise ("inlining BUYS something") is unmet. Asked through the shared
			// adapter over `NamingSupport.frameworkReachable`, so a project that declares a
			// framework in `apqlint.json` gets the carve-out here and from the two unused-* rules at
			// once, and no framework NAME appears in this file.
			//
			// The index is the report UNION RESOLUTION scope, like the sibling rule's: a contract's
			// root can sit behind a base declared in a configured library
			// (`class T extends TestBase extends Test`), and the report index alone stops at the
			// first supertype it cannot name — which answers "no framework" and flags the method.
			// It is a THUNK built HERE rather than once per run, and that is the whole reason the
			// seam takes one: forcing the resolution index reads and parses the configured scope,
			// and `nominated` demands it only after a contract has CLAIMED the name. Measured with
			// it forced once per run instead, on this project's own config, a one-file
			// `--rule prefer-inline` run went 0.12s -> 2.88s while `--rule prefer-single-quotes`
			// stayed at 0.13s — a whole-tree lint hides that (other rules force the index anyway),
			// the edit loop and `tools/mutation-check.sh` do not. Every OTHER question this check
			// asks is answered on the report index, unchanged by this slice.
			if (CheckScan.frameworkReachableMethod(
				naming, name, owner, span, () -> RefactorSupport.resolutionIndexOf(plugin) ?? index, contracts
			))
				return;
			out.push({
				file: file,
				span: span,
				rule: 'prefer-inline',
				severity: Severity.Info,
				message: isEmptyBody(fn)
					? 'method \'$name\' has an empty body and no value references; mark it inline — the call compiles away'
					: 'method \'$name\' is a single-expression method with no value references; mark it inline'
			});
		});
	}

	/**
	 * Invoke `cb(name, fnNode, mods, metas)` for every `FnMember` of `cls`, where `mods` is the
	 * member's preceding modifier-kind run (`Public` / `Static` / `Inline` / …) and `metas` its
	 * preceding metadata names (`@:keep` / …), both reset at each member boundary. `final function`
	 * (`FinalModifiedMember`) and fields reset the run but are not methods.
	 */
	private static function forEachMethod(
		cls: QueryNode, branch: MemberBranchSeams, cb: (String, QueryNode, Array<String>, Array<String>) -> Void
	): Void {
		MemberBranchScan.eachMember(branch, cls, child -> MEMBER_KINDS.contains(child.kind), (member, run, certain) -> {
			// A modifier run only SOME builds see cannot answer this rule's gates — see
			// `MemberBranchScan.joinRuns`. It also closes the real shape `#if X inline #end function f`,
			// where the flat reading missed the guarded `inline` and told you to inline it again.
			if (!certain || member.kind != 'FnMember') return;
			final name: Null<String> = member.name;
			if (name == null) return;
			final mods: Array<String> = [];
			final metas: Array<String> = [];
			for (mod in run) if (RefactorSupport.META_KINDS.contains(mod.kind)) {
				final nm: Null<String> = mod.name;
				if (nm != null) metas.push(nm);
			} else
				mods.push(mod.kind);
			cb(name, member, mods, metas);
		});
	}

	/**
	 * Whether `name` / `fn` is an inline candidate: a non-constructor method with a benefit-class body, not already `inline` / `dynamic` / `macro` / `override`, not `@:keep`, not self-recursive (a bare `name` / `this.name` in its body), and whose body is a benefit class (see `isBaseCandidateMethod`).
	 */
	private static function isCandidateMethod(
		name: String, fn: QueryNode, mods: Array<String>, metas: Array<String>, relaxed: Bool, retained: Null<String>
	): Bool {
		return isBaseCandidateMethod(name, fn, mods, metas, retained) && (relaxed || !bodyHasNullSafetyRisk(fn));
	}

	/**
	 * The candidate gates EXCEPT the context-sensitive null-safety one: a non-constructor method, not
	 * already `inline` / `dynamic` / `macro` / `override`, not `@:keep`, not self-recursive, whose body
	 * is a BENEFIT class — EMPTY (the call compiles away), or a single accessor / thin-forward /
	 * trivial-mutator / constant expression within the `MAX_BODY_NODES` budget. A body outside these
	 * classes (an allocation — `new`, array / object / interpolated-string literal, a reification —
	 * a lambda argument, a loop, a switch, a computed forward argument) gains nothing from `inline`
	 * and is never a candidate. `isCandidateMethod` layers the null-safety gate on top, unless
	 * `relaxed` (the oracle path) drops it.
	 */
	private static function isBaseCandidateMethod(
		name: String, fn: QueryNode, mods: Array<String>, metas: Array<String>, retained: Null<String>
	): Bool {
		if (isReservedMemberName(name)) return false;
		if (
			mods.contains('Inline') || mods.contains('Dynamic') || mods.contains('Macro') || mods.contains('Override')
			|| mods.contains('Extern')
		)
			return false;
		if (retained != null && metas.contains(retained)) return false;
		if (metas.exists(m -> !inlineNeutralMeta(m))) return false;
		if (referencesSelf(fn, name)) return false;
		if (isEmptyBody(fn)) return true;
		final root: Null<QueryNode> = bodyRootExpr(fn);
		return root != null && (isAccessorOrForward(root) || isConstExpr(root)) && !bodyExceedsBudget(fn);
	}

	/**
	 * The single root expression of a candidate body: an `ExprBody`'s expression (a wrapping
	 * `ReturnExpr` peeled), or a one-statement `BlockBody`'s `ReturnStmt` / `ExprStmt` expression;
	 * null for every other shape (multi-statement, bodyless — the EMPTY body is class A, tested
	 * separately by `isEmptyBody`).
	 */
	private static function bodyRootExpr(fn: QueryNode): Null<QueryNode> {
		final body: Null<QueryNode> = bodyOf(fn);
		return body == null
			? null
			: switch body.kind {
				case 'ExprBody' if (body.children.length == 1): unwrapReturn(body.children[0]);
				case 'BlockBody' if (body.children.length == 1):
					final stmt: QueryNode = body.children[0];
					(stmt.kind == 'ReturnStmt' || stmt.kind == 'ExprStmt') && stmt.children.length == 1 ? stmt.children[0] : null;
				case _: null;
			}
	}

	/**
	 * Whether `node` is a bare field-access chain (`x`, `this.x`, `a.b.c`, `obj?.f`). A chain rooted at
	 * `super` is REJECTED — Haxe refuses `inline` on a body containing `super` ("Cannot inline function
	 * containing super"), and the no-oracle fix path would emit exactly that.
	 */
	private static function isChain(node: QueryNode): Bool {
		return switch node.kind {
			case 'IdentExpr': node.name != 'super';
			case k if (CHAIN_KINDS.contains(k)):
				node.children.length == 1 && isChain(node.children[0]);
			case _: false;
		}
	}

	/**
	 * Whether `root` is an accessor / thin-forward / trivial-mutator body: a bare chain read, a call
	 * whose callee is a chain and whose every argument is a simple operand, or an assignment-family
	 * node over a chain and a simple operand. Inlining any of these collapses the call into a direct
	 * read / write / forwarded call — the benefit class the rule exists for. A `.bind` callee is
	 * REJECTED: it allocates a closure, so the forward is not thin.
	 */
	private static function isAccessorOrForward(root: QueryNode): Bool {
		final kids: Array<QueryNode> = root.children;
		return isChain(root) || kids.length >= 1 && isChain(kids[0]) && kids[0].name != 'bind' && (
			root.kind == CALL_KIND
				? allSimpleOperands(kids, 1)
				: MUTATOR_KINDS.contains(root.kind) && (kids.length == 1 || isSimpleOperand(kids[1]))
		);
	}

	/** Whether every element of `nodes` from `start` on is a simple operand. */
	private static function allSimpleOperands(nodes: Array<QueryNode>, start: Int): Bool {
		for (i in start ... nodes.length) if (!isSimpleOperand(nodes[i])) return false;
		return true;
	}

	/**
	 * Whether `node` is a constant / small-arithmetic expression: literals, chains, and
	 * `CONST_OP_KINDS` operators only — nothing that allocates or calls, so the call site can fold
	 * it. The one non-expression child shape, `Is`'s type name (`Named`), is skipped.
	 */
	private static function isConstExpr(node: QueryNode): Bool {
		return isSimpleOperand(node) || CONST_OP_KINDS.contains(node.kind) && node.children.foreach(c ->
			c.kind == 'Named' || isConstExpr(c)
		);
	}

	/** `fn`'s body child — its `ExprBody` or `BlockBody`, else null (a bodyless declaration). */
	private static function bodyOf(fn: QueryNode): Null<QueryNode> {
		return fn.children.find(c -> c.kind == 'ExprBody' || c.kind == 'BlockBody');
	}

	/** The number of nodes in `node`'s subtree, itself included. */
	private static function nodeCount(node: QueryNode): Int {
		var total: Int = 1;
		for (c in node.children) total += nodeCount(c);
		return total;
	}

	/** Whether `node`'s subtree references `name` as a bare `IdentExpr` or a `this.<name>` `FieldAccess` — a self / recursive reference. */
	private static function referencesSelf(node: QueryNode, name: String): Bool {
		return selfRefName(node) == name || node.children.exists(c -> referencesSelf(c, name));
	}

	/** The name a node references as a bare `IdentExpr <name>` or `this.<name>` `FieldAccess`, else null. */
	private static function selfRefName(node: QueryNode): Null<String> {
		return switch node.kind {
			case 'IdentExpr': node.name;
			case 'FieldAccess':
				node.children.length == 1 && node.children[0].kind == 'IdentExpr' && node.children[0].name == 'this' ? node.name : null;
			case _: null;
		}
	}

	/**
	 * Record into `out` each name in `candidateNames` that appears in a VALUE position (not a call
	 * callee) via an `IdentExpr` / `FieldAccess` / `SafeFieldAccess` / `ForceFieldAccess` node — the
	 * method-value references that forbid inlining. `inCalleePos` marks `node` as the callee child
	 * (child 0) of a `Call`, where an occurrence is an invocation, not a value.
	 */
	private static function collectValueRefs(node: QueryNode, inCalleePos: Bool, candidateNames: Array<String>, out: Array<String>): Void {
		final name: Null<String> = node.name;
		if (name != null && !inCalleePos && isAccessKind(node.kind) && candidateNames.contains(name) && !out.contains(name)) out.push(name);
		final isCall: Bool = node.kind == CALL_KIND;
		final children: Array<QueryNode> = node.children;
		for (i in 0...children.length) collectValueRefs(children[i], isCall && i == 0, candidateNames, out);
	}

	/**
	 * Record into `out` each name in `candidateNames` passed to a `Reflect.<m>(...)` call as a string
	 * literal — a method reached by reflection is not safe to inline.
	 */
	private static function collectReflectNames(node: QueryNode, candidateNames: Array<String>, out: Array<String>): Void {
		if (node.kind == CALL_KIND && node.children.length >= 1) {
			final callee: QueryNode = node.children[0];
			if (
				callee.kind == 'FieldAccess' && callee.children.length == 1 && callee.children[0].kind == 'IdentExpr'
				&& callee.children[0].name == 'Reflect'
			) for (i in 1...node.children.length) {
				final lit: Null<String> = stringLiteralValue(node.children[i]);
				if (lit != null && candidateNames.contains(lit) && !out.contains(lit)) out.push(lit);
			}
		}
		for (c in node.children) collectReflectNames(c, candidateNames, out);
	}

	/**
	 * The unquoted value of a string-literal node, else null. A `DoubleStringExpr` carries the QUOTED
	 * text as its name; a plain `SingleStringExpr` carries the unquoted text in its one `Literal`
	 * child (an interpolated string has `Ident` / `Block` parts and yields null).
	 */
	private static function stringLiteralValue(node: QueryNode): Null<String> {
		return switch node.kind {
			case 'DoubleStringExpr':
				final raw: Null<String> = node.name;
				raw == null || raw.length < 2 ? null : raw.substring(1, raw.length - 1);
			case 'SingleStringExpr':
				node.children.length == 1 && node.children[0].kind == 'Literal' ? node.children[0].name : null;
			case _: null;
		}
	}

	/** The simple names of every interface in `cls`'s `implements` clauses. */
	private static function implementedInterfaces(cls: QueryNode): Array<String> {
		final out: Array<String> = [];
		for (child in cls.children) if (child.kind == 'ImplementsClause') for (named in child.children) {
			final nm: Null<String> = named.name;
			if (nm != null) out.push(simpleName(nm));
		}
		return out;
	}

	/**
	 * Whether an implemented interface declares `name` — so a physical (non-inline) method is
	 * required. `typeProvablyLacksMember` returns false for an unresolvable interface, so an
	 * unreachable interface conservatively blocks the candidate.
	 */
	private static function interfaceRequires(index: SymbolIndex, ifaces: Array<String>, name: String, file: String): Bool {
		return ifaces.exists(iface -> !index.typeProvablyLacksMember(iface, name, file));
	}


	/**
	 * Whether `fn`'s body contains a construct whose null-safety validity is CONTEXT-SENSITIVE, so
	 * inlining could break a caller: a `null` literal in a VALUE slot — a call argument, assignment
	 * RHS, return or ternary branch — but NOT a `==` / `!=` / `??` null-check operand (context-neutral).
	 * Haxe re-type-checks an inline body at every call site in the CALLER's null-safety mode, so a
	 * `null` that compiles in this class's (looser / off) context can fail Strict re-checking
	 * elsewhere. Over-skips a safe null-value body (the sound direction); a precise split would need
	 * null-flow typing.
	 */
	private static function bodyHasNullSafetyRisk(fn: QueryNode): Bool {
		final body: Null<QueryNode> = bodyOf(fn);
		return body != null && subtreeHasNullSafetyRisk(body, body.kind);
	}

	/** Whether `node`'s subtree contains a null literal in a value slot. */
	private static function subtreeHasNullSafetyRisk(node: QueryNode, parentKind: String): Bool {
		return isRiskyHere(node, parentKind) || node.children.exists(c -> subtreeHasNullSafetyRisk(c, node.kind));
	}

}
