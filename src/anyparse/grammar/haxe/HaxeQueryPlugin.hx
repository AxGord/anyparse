package anyparse.grammar.haxe;

import anyparse.format.IndentChar;
import anyparse.format.comment.CommentInventory;
import anyparse.format.comment.CommentLossException;
import anyparse.format.comment.FormatterOff;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.CondBranchProjection;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.ParsedRootProvider;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.SpanTypeInfoProvider;
import anyparse.query.StdResolver;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Haxe grammar binding for the `apq` query engine.
 *
 * Parses with the macro-generated span-mode `HaxeModuleSpanParser` and
 * translates the typed AST into a generic `QueryNode` tree using
 * runtime type introspection (`Type` / `Reflect`). The span-mode parser
 * returns the paired `HxModuleS` typed AST directly — each enum value
 * carries its own `_span:Span` as the trailing positional arg
 * (`SpanTypeSynth` synthesises these on every Alt ctor).
 *
 *  - **Enum values become nodes.** `kind` is the constructor name
 *    verbatim (`ClassDecl`, `FnDecl`, `IfStmt`, …). The span is read
 *    directly from the value's last positional arg (post-Phase-2:
 *    in-AST instead of side-channel) so Reflect ordering of struct
 *    fields can no longer desynchronise span attribution.
 *  - **Anonymous structs are transparent.** Their fields contribute
 *    children to the enclosing enum-ctor node. A struct's `name` field
 *    (when a String) becomes the parent ctor's `name` slot.
 *  - **Arrays are transparent.** Their elements contribute children.
 *  - **Trivial-mode wrappers** (`{ node:T, leadingComments:…, … }`) are
 *    transparent on the `node` slot; the span-mode parser does not
 *    produce them, but the descent is in place for a future Trivia +
 *    Spans composition.
 *  - **Primitive leaves** (`String`/`Int`/`Float`/`Bool`/`Span`) do not
 *    emit nodes — they are absorbed into name detection or, in the
 *    case of `Span`, attached to the enclosing enum node.
 *
 * The root is a synthetic `module` node so users have a single
 * top-level handle in selectors and JSON output. The root carries no
 * span — `HxModule` itself is a Seq (struct) so no enum-ctor span
 * applies. Its children (top-level decls) carry their own spans.
 */
@:nullSafety(Strict)
final class HaxeQueryPlugin implements GrammarPlugin implements TypeInfoProvider implements SpanTypeInfoProvider
		implements ParsedRootProvider {

	/**
	 * Binding-declaration kinds shared by `refShape` and `metaShape`
	 * so the two contracts cannot drift. Top-level type decls,
	 * statement-level var bindings (plus their expression-position
	 * `VarExpr` / `FinalExpr` twins — `macro var x = e` — wrapping the
	 * same `HxVarDecl`), class-member bindings, function
	 * parameters (`HxParam`'s three Alt branches), the
	 * `@:spanned('LambdaParam')` lambda-parameter struct, and enum
	 * constructors (`SimpleCtor` / `ParamCtor`) so an annotation on
	 * an `enum E { @:kw('x') A; }` ctor attributes to that ctor — the
	 * `MetaCall` and ctor nodes flatten as spanned siblings, so
	 * `Meta.followingDeclHost` resolves once the kind is a host.
	 * Anon-struct fields (`VarField` / `FinalField` / `FnField`, the
	 * `var` / `final` / `function` forms of `HxAnonField`) so
	 * `typedef T = { @:meta var f; }` field metadata + the field
	 * binding surface — the bare `name:Type` forms reuse the
	 * `Required` / `Optional` entries above. Reached only once
	 * `appendNodes` descends the anon `type` (see `isAnonType`).
	 * `VarMore` is the `@:spanned('VarMore')` struct carrying every binding
	 * AFTER the first in `var a = 1, b = 2;` — without it those bindings had
	 * no declaration node at all, so `Refs` could not resolve their uses and
	 * every declaration-walking check was blind to them. `KeyValueBinder` is
	 * the same lift for the VALUE binder of `for (k => v in m)`: the loop
	 * node's own name is the KEY, so `v` had no declaration node either. It
	 * is a decl host rather than a `selfScopeDeclKinds` entry because it
	 * opens no scope of its own — it binds into the frame the LOOP opens,
	 * which is what `Refs.collectIntoMulti` does with a decl-host child.
	 * `LocalFnStmt` and `LocalInlineFnStmt` are the two projections of a local
	 * `function` statement - the grammar folds the `inline` keyword into its own
	 * ctor instead of pairing a modifier - and both bind their name into the
	 * ENCLOSING body while opening a scope of their own for their parameters
	 * (see the matching pair in `scopeKinds`). They are decl hosts, not
	 * `selfScopeDeclKinds` entries, for the mirror of `KeyValueBinder`'s reason:
	 * the scope they open is not the one their own name lives in.
	 *
	 * The three `final` / `abstract` type-declaration forms name themselves through
	 * their own ctors, so each needs its own entry. `ClassForm` is the inner form of a
	 * `final class`, which projects as `FinalDecl(ClassForm …)`: the NAME sits on the
	 * inner node and `FinalDecl` carries none, so the wrapper is deliberately absent
	 * here - the same normalisation `SELECT_KIND_EQUIVALENCE` and
	 * `RefactorSupport.typeDeclOf` already apply. `AbstractClassDecl` (`abstract
	 * class`) and `EnumAbstractDecl` (`enum abstract`) are ctors of their own rather
	 * than modifier variants of `ClassDecl` / `AbstractDecl`, and both name
	 * themselves. Without the three, such a type name was no declaration at all:
	 * `refs` reported zero hits on the definition itself, and every consumer pairing a
	 * declaration with its uses was blind to it. They join `HOISTING_SCOPE_KINDS`,
	 * which already names all three for the mirror reason.
	 */
	private static final DECL_HOST_KINDS: Array<String> = [
		'VarDecl',
		'FnDecl',
		'LocalFnStmt',
		'LocalInlineFnStmt',
		'ClassDecl',
		'ClassForm',
		'AbstractClassDecl',
		'InterfaceDecl',
		'EnumDecl',
		'AbstractDecl',
		'EnumAbstractDecl',
		'TypedefDecl',
		'VarMember',
		'FinalMember',
		'FnMember',
		'FinalModifiedMember',
		'VarStmt',
		'FinalStmt',
		'StaticVarStmt',
		'StaticFinalStmt',
		'VarMore',
		'VarExpr',
		'FinalExpr',
		'Required',
		'Optional',
		'Rest',
		'LambdaParam',
		'SimpleCtor',
		'ParamCtor',
		'VarField',
		'FinalField',
		'FnField',
		'KeyValueBinder'
	];

	/**
	 * The assignment-operator kinds — plain `=` plus every compound form, in
	 * declaration order. Shared so `refShape`'s `writeParentKinds` (which adds the
	 * increment / decrement mutators) and its `delimitedTailChildKinds` (which adds
	 * `Call`) cannot drift: a new assignment operator is added here once and both
	 * lists follow.
	 */
	private static final ASSIGN_KINDS: Array<String> = [
		'Assign',
		'AddAssign',
		'SubAssign',
		'MulAssign',
		'DivAssign',
		'ModAssign',
		'ShlAssign',
		'ShrAssign',
		'UShrAssign',
		'BitOrAssign',
		'BitAndAssign',
		'BitXorAssign',
		'NullCoalAssign',
		'BoolAndAssign',
		'BoolOrAssign'
	];

	/**
	 * Scope kinds whose declarations ARE forward-visible - the type bodies. A method may read a
	 * field declared below it and the compiler binds it, so these frames hoist.
	 *
	 * `final class` projects as `FinalDecl(ClassForm …)` and `abstract class` as
	 * `AbstractClassDecl`; both hold instance fields whose bare (non-`this`) references resolve
	 * only if the class body opens a scope frame.
	 *
	 * `enum abstract` gets its own ctor rather than reusing `AbstractDecl`, so it needs its own
	 * entry. Its members hoist like any other type body's: `final A = B + 1; final B = 1;`
	 * compiles and evaluates `A` to 2 — measured, not assumed.
	 */
	private static final HOISTING_SCOPE_KINDS: Array<String> = [
		'ClassDecl',
		'ClassForm',
		'AbstractClassDecl',
		'InterfaceDecl',
		'AbstractDecl',
		'EnumAbstractDecl',
		'EnumDecl',
		'TypedefDecl'
	];

	/**
	 * Scope kinds whose declarations take effect only from their own position onward - every
	 * construct above whose body is a statement list or a parameter list. Haxe hoists neither a
	 * local `var` nor a local `function` (a call before its declaration is `Unknown identifier`),
	 * so a reference that precedes one binds to whatever encloses it: the member of the same
	 * name, most often.
	 *
	 * `CatchClause` is surfaced by `appendNodes` from the `@:spanned('CatchClause')` paired
	 * struct; it opens a scope (the clause body) and self-binds the exception name into that
	 * frame (see `selfScopeDeclKinds`).
	 *
	 * A local `function f(...) {...}` statement opens its own frame - without it sibling local
	 * fns' same-named params collect into the ENCLOSING function's frame and reads mis-bind
	 * across siblings (the CallGraph `span` collision). `inline function` is the same construct
	 * with the keyword folded into its own ctor, and it is the form this project's Haxe style
	 * prescribes for a local helper - the two must never diverge HERE. They deliberately do
	 * diverge in `functionKinds` / `localFunctionKinds` below, which measure complexity units
	 * rather than scopes; a consumer that wants the scope reading unions `inlineFunctionKinds`
	 * back in - there are several, so enumerate them with
	 * `hxq mentions inlineFunctionKinds src/` rather than trusting a list here.
	 *
	 * A parameter needs no entry of its own: a function frame pre-collects only its own params
	 * (the walk stops at the body's `BlockBody`), so they stay visible to the whole body while
	 * the body's own declarations become position-scoped.
	 *
	 * `ThinArrow` is the bare `arg -> body` lambda, and it belongs here for the same reason the
	 * two parenthesised forms and `FnExpr` do: it binds a parameter, and that parameter dies at
	 * the body's end. The grammar spells it as a Pratt infix ctor rather than a lambda ctor, so
	 * its parameter reaches the tree as an `IdentExpr` - `HxArrowParamProjection` re-labels it
	 * `Required` before any consumer sees it. Without BOTH halves the parameter was a read of
	 * whatever enclosed the lambda: `refs` mis-bound it, and `rename` rewrote the two together.
	 */
	private static final POSITION_SCOPED_SCOPE_KINDS: Array<String> = [
		'FnDecl',
		'FnExpr',
		'FnMember',
		'FinalModifiedMember',
		'LocalFnStmt',
		'LocalInlineFnStmt',
		'ThinParenLambdaExpr',
		'ParenLambdaExpr',
		'ThinArrow',
		'BlockBody',
		'BlockExpr',
		'BlockStmt',
		'ForStmt',
		'ForExpr',
		'CatchClause'
	];

	/**
	 * The `switch` arms - see `RefShape.branchScopeKinds`. Position-scoped like any other
	 * statement list, so they join `positionScopedKinds` too; kept apart from
	 * `POSITION_SCOPED_SCOPE_KINDS` because an arm is NOT a `scopeKinds` entry (a dozen checks
	 * read that vocabulary as "lexical container of a declaration", which an arm is not).
	 */
	private static final BRANCH_SCOPE_KINDS: Array<String> = ['CaseBranch', 'DefaultBranch'];


	/**
	 * The value-position hosts a conditional chain may be rewritten inside. Shared so
	  * `switchExpressionHostKinds` and `ifExpressionChainHostKinds` (which adds the
	 * arrow-lambda bodies and the two switch-ARM kinds) cannot drift: a new value host is
	 * added here once and both follow. A `case` arm is deliberately absent from THIS
	 * constant — a `switch` spliced into a `switch` arm reads worse than the chain it
	 * replaced, while an if-chain there is the ladder the formatter already renders, so
	 * only the if-chain seam adds it. A bare expression STATEMENT is absent from both: a
	 * chain there yields no value anyone reads, and rewriting it would hand the site to
	 * the statement-side rule family instead.
	 */
	private static final SWITCH_EXPRESSION_HOST_KINDS: Array<String> = [
		'ReturnStmt',
		'ReturnExpr',
		'VarStmt',
		'FinalStmt',
		'VarMember',
		'FinalMember',
		'Assign'
	];

	/**
	 * Search-only kind-equivalence. One Haxe declaration keyword surfaces as
	 * several position-specific `QueryNode` kinds — a `var` is module-level
	 * `VarDecl`, class-field `VarMember`, local `VarStmt`; a `function` is
	 * `FnDecl` / `FnMember` / `LocalFnStmt`; a `final` binding is `VarForm` /
	 * `FinalMember` / `FinalStmt` — while a pattern always parses through the
	 * Decl attempt and lands on the module-level kind. Without an equivalence
	 * such a pattern matches NOTHING outside module scope (the S2 dogfood gap),
	 * and `search --explain` says so: `pattern root kind "FnDecl" NOT present in
	 * any scanned file`.
	 *
	 * Carried on the `Pattern` and consulted only by the search `Matcher`, so the
	 * `QueryNode` tree keeps the precise per-position kinds: `ast` / `--select` /
	 * `refs` / `meta` vocabulary — including the published `--on VarMember` — is
	 * unchanged, and `DECL_HOST_KINDS` above stays correct (it intentionally
	 * distinguishes the positions for scope/decl-host resolution).
	 *
	 * A module-level `final` names itself ONE LEVEL DOWN: `final x = 1;` projects
	 * as `FinalDecl(VarForm x …)`, the same wrapper shape as `final class`
	 * (`FinalDecl(ClassForm …)`). `FinalDecl` therefore carries no name and one
	 * extra child, and can never unify with the flat `FinalMember` / `FinalStmt` —
	 * the matcher compares the name slot and the child COUNT. So the group is keyed
	 * on the named inner `VarForm`, and `parsePattern` re-roots the pattern onto it
	 * (`HaxePatternFragment.rerootFinalVarDecl`), the same normalisation
	 * `moduleValueDeclKinds` below already applies.
	 *
	 * A group holds only the variants whose span carries NOTHING but the family
	 * keyword, and that is a correctness rule rather than taste: this same relation
	 * drives `Rewrite.rewrite` and `--match` addressing, which splice over the
	 * MATCHED node's span. A variant that consumes an extra modifier keyword into
	 * its own span therefore loses it — measured, `final function sealed()`
	 * (`FinalModifiedMember`, span starts at `final`) and a local `inline function`
	 * (`LocalInlineFnStmt`, span starts at `inline`) both come back stripped of
	 * their modifier by a `function $n(…)` rewrite, silently and re-parseably.
	 * `(Public)` / `(Static)` are safe for the opposite reason: they project as
	 * SIBLING leaves outside the member's span. The same rule retroactively explains
	 * the var family's omission of `StaticVarStmt` / `StaticFinalStmt` — their spans
	 * start at `static`.
	 *
	 * That settles the one question `--select` cannot: `SELECT_KIND_EQUIVALENCE`
	 * below DOES fold `FinalModifiedMember` onto `FnMember`, and search deliberately
	 * does not follow it. `--select` is a read-only projection with no rewriting
	 * consumer, so folding there costs nothing; the same fold here would deform
	 * code. The residual gap — no pattern reaches a `final function` or a local
	 * `inline function` at all — is left open on purpose: closing it needs a
	 * rewrite-safe split (a wider relation for the read-only `search` command, or a
	 * refusal in `Rewrite` for modifier-carrying variants), not a wider constant.
	 *
	 * The groups also stay per-keyword: `var $v = 0` must not match a `final`
	 * binding (different keyword, immutability semantics) and neither matches a
	 * function. Expression-position forms (`FnExpr`, `NamedFnExpr`, the lambdas,
	 * `VarExpr` / `FinalExpr`) are outside the criterion — the relation covers
	 * declaration positions only.
	 *
	 * One asymmetry is kept because the alternative is worse: a module-level `final`
	 * matches AS the `VarForm`, whose span starts after the `final` keyword, so a
	 * rewrite through it re-emits the keyword and the canonical gate rejects the
	 * whole result (`result does not parse`) instead of writing it. Loud, and that
	 * spelling occurs zero times in either corpus measured (TM `src/`, this repo's
	 * `src/`); a member or local `final`, whose span does start at the keyword,
	 * rewrites correctly.
	 */
	private static final SEARCH_KIND_EQUIVALENCE: KindEquivalence = new KindEquivalence([
		['VarDecl', 'VarMember', 'VarStmt'],
		['FnDecl', 'FnMember', 'LocalFnStmt'],
		['VarForm', 'FinalMember', 'FinalStmt']
	]);

	/**
	 * `--select` kind-equivalence: folds the `final` modifier-wrapper
	 * shapes onto their plain counterparts so `--select ClassDecl` matches
	 * a `final class` (projected as `FinalDecl(ClassForm …)` — the named
	 * node is `ClassForm`) and `--select FnMember` matches a `final
	 * function` (`FinalModifiedMember`). Distinct from
	 * `SEARCH_KIND_EQUIVALENCE` — `--select` keeps its precise per-position
	 * kinds; only the final-wrapper folding is shared. NOT the Var/Final
	 * family (a `final` FIELD is a separate kind by design, not a wrapper).
	 */
	private static final SELECT_KIND_EQUIVALENCE: KindEquivalence = new KindEquivalence(
		[['ClassDecl', 'ClassForm'], ['FnMember', 'FinalModifiedMember']]
	);

	/**
	 * FALLBACK table of `using`-eligible extension-method names, consulted only when `StdResolver` cannot discover the std sources `knownExtensionMethods` derives these from at runtime. Its entries were themselves sourced from the installed std (every static `FnMember` of each module, private helpers included), so it is a subset of what the live extraction returns — a superset there is harmless (it only makes the `unused-import` "used" test more generous).
	 */
	private static final EXTENSION_METHODS: Map<String, Array<String>> = [
		'StringTools' => [
			'_charAt',
			'contains',
			'endsWith',
			'fastCodeAt',
			'hex',
			'htmlEscape',
			'htmlUnescape',
			'isEof',
			'isSpace',
			'iterator',
			'keyValueIterator',
			'lpad',
			'ltrim',
			'postProcessUrlEncode',
			'quoteUnixArg',
			'quoteWinArg',
			'replace',
			'rpad',
			'rtrim',
			'startsWith',
			'trim',
			'unsafeCodeAt',
			'urlDecode',
			'urlEncode',
			'utf16CodePointAt'
		],
		'Lambda' => [
			'array',
			'concat',
			'count',
			'empty',
			'exists',
			'filter',
			'find',
			'findIndex',
			'flatMap',
			'flatten',
			'fold',
			'foldi',
			'foreach',
			'has',
			'indexOf',
			'iter',
			'list',
			'map',
			'mapi'
		]
	];

	/** Per-module-path cache of the std extension-method extraction; a cached null (a non-std / missing module) is retained via `exists`, not recomputed. */
	private static final extMethodsCache: Map<String, Null<Array<String>>> = [];

	/** Member-modifier node kinds — a `Static` among these marks the following `FnMember` static; any other is a non-`Static` modifier that preserves the accumulated flag (used by `collectStaticMethodsWithParam`). */
	private static final MODIFIER_KINDS: Array<String> = [
		'Static',
		'Public',
		'Private',
		'Inline',
		'Override',
		'Final',
		'Dynamic',
		'Extern',
		'Macro',
		'Abstract'
	];

	/** Non-function member kinds that end a modifier run (a static var / final field), so their `Static` never leaks onto a following method (used by `collectStaticMethodsWithParam`). */
	private static final FIELD_BOUNDARY_KINDS: Array<String> = ['VarMember', 'FinalMember', 'FinalModifiedMember'];

	public function new() {}

	public function langName(): String return 'haxe';

	public function parseFile(source: String): QueryNode {
		return treeFromRoot(parseRoot(source), source, false);
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		return treeFromRoot(parseRoot(source), source, true);
	}

	public function projectBranchAware(tree: QueryNode, source: String): QueryNode {
		return CondBranchProjection.branchAwareTree(tree, source, refShape(), controlFlowSupport());
	}

	/**
	 * Parse + write round-trip via the Trivia pipeline so comments and
	 * blank lines survive. Defaults to `HaxeFormat.instance.defaultWriteOptions`
	 * — the same defaults the corpus harness uses when no `hxformat.json`
	 * config is provided. When `optsJson` is non-null, it is parsed as an
	 * `hxformat.json`-shaped payload via `HaxeFormatConfigLoader` so a
	 * `.hxtest` fixture's section-1 config (or any inline JSON) drives the
	 * writer for this one call. `loadHxFormatJson('{}')` is byte-identical
	 * to the defaults, so an empty config is a true no-op. Used by `apq ast
	 * --writer-output` for writer-bug probes without going through the full
	 * test runner.
	 *
	 * FAIL-CLOSED on comment loss: the Trivia parser only captures a
	 * comment where a capture slot exists, so an inline comment in a
	 * slot-less seam (`if (/* c *\/ x)`, `return /* r *\/ x;`, a type
	 * annotation, a class header) never reaches the AST and the writer
	 * re-emits the construct without it. Rather than hand back output
	 * that silently deletes an author's bytes, such a round trip throws
	 * `CommentLossException`: `fmt` names the file and leaves it byte-
	 * identical, and the ops' `RefactorSupport.canonicalize` refuses the
	 * edit instead of writing a file without the comment. Every whole-file
	 * consumer inherits the guard from this one seat — including the
	 * read-only probes (`ast --writer-output`, `writer-probe`,
	 * `writer-equals`, `recon --writer-equals`), which report the refusal
	 * on stderr and emit nothing. `APQ_ALLOW_COMMENT_LOSS` (any value but
	 * empty / `0`) declines the guard for the whole process, so writer
	 * development can see the raw emission; the CLI warns when it is set,
	 * because it re-arms the data loss on the WRITE paths too.
	 */
	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> {
		final tree: Dynamic = HaxeModuleTriviaParser.parse(source);
		final emitted: Null<String> = HaxeModuleTriviaWriter.write(tree, writeOptionsOf(optsJson));
		if (emitted == null) return null;
		// Before the guard, not after: restoring an `@formatter:off` region
		// puts the source bytes back, so a comment living only inside one is
		// present again by the time the inventory compares the two sides.
		final written: String = FormatterOff.restore(source, emitted);
		if (written == source || CommentInventory.guardDeclined()) return written;
		final lost: Null<String> = CommentInventory.firstMissing(source, written);
		if (lost != null) throw new CommentLossException(lost);
		return written;
	}

	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		final opts: HxModuleWriteOptions = writeOptionsOf(optsJson);
		return {
			lineWidth: opts.lineWidth,
			indentWidth: opts.indentChar == Tab ? opts.tabWidth : opts.indentSize
		};
	}

	/**
	 * Parse + write round-trip via the PLAIN (non-trivia) pipeline.
	 * Mirrors the unit-test entry
	 * `HxModuleWriter.write(HaxeModuleParser.parse(source))` — flattens
	 * source layout, drops comments. Used by `apq ast
	 * --writer-output-plain` and `apq writer-equals` (default) so
	 * expected strings built off the probe match what unit tests
	 * actually see. The two pipelines emit different bytes on the same
	 * input (anon-struct flattens, terminators differ); always probe
	 * the pipeline that matches the test entry being constructed.
	 *
	 * `optsJson` follows the same convention as `writeRoundTrip`
	 * (`writeOptionsOf`) — an `hxformat.json`-shaped payload routes
	 * through `HaxeFormatConfigLoader.loadHxFormatJson`; `null`, and
	 * equally a BLANK payload, keeps the defaults.
	 */
	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String> {
		return HxModuleWriter.write(HaxeModuleParser.parse(source), writeOptionsOf(optsJson));
	}

	/**
	 * Trivia-mode strict parse for `apq recon`. Returns `true` on
	 * success; the surrounding `ParseError` propagates to the CLI on
	 * failure so the recon clusters by `error.span` locus. Same entry
	 * point the corpus harness drives, so a recon-OK fixture is a
	 * fixture the harness can attempt to format (the byte-comparison
	 * may still fail downstream, but the parse no longer blocks).
	 */
	public function reconParse(source: String): Bool {
		HaxeModuleTriviaParser.parse(source);
		return true;
	}

	public function typeRefShape(): TypeRefShape {
		// Type-position references reach the `parseFileTypeRefs` tree via
		// two complementary kinds, and `uses` must match both for a
		// complete blast-radius answer:
		//  - `TypeRef` — emitted by `appendTypeRefs` for the name-slot
		//    `type` fields that the default projection deliberately drops
		//    (var / class-member / anon / enum-ctor-param / fn-param
		//    annotations), one node per nominal name (head + each param).
		//  - `Named` / `NewExpr` — already present in BOTH projections
		//    (they were never on the dropped `type` path): function/lambda
		//    return types and type-param constraints (`Named`), `extends`
		//    / `implements` heritage (a `Named` child of the clause), and
		//    `new T(...)` (`NewExpr`).
		// Listing them here only widens the `Uses` walker (kind-filtered);
		// the `parseFile` tree and `ast`/`search`/`refs`/`meta` are
		// untouched — zero regression by construction.
		return { typeRefKinds: ['TypeRef', 'Named', 'NewExpr'] };
	}

	public function refShape(): RefShape {
		// Identifier references come exclusively through `HxExpr.IdentExpr(v)`
		// — the bare-identifier branch of the expression enum. Field-access
		// (`obj.foo`), method names, type references, and string-literal
		// fragments live under different ctors and never match.
		//
		// Decl-host kinds: any enum-ctor whose `extractName` walk resolves
		// to a binding declaration. Top-level type decls (`ClassDecl`, …),
		// statement-level var bindings (`VarStmt`, `FinalStmt`, plus the
		// expression-position `VarExpr`/`FinalExpr` twins, top-level
		// `VarDecl`/`FnDecl`), class-member bindings (`VarMember`,
		// `FinalMember`, `FnMember`, plus `FinalModifiedMember` — the `final`
		// METHOD form, whose name `extractName` lifts off the inner
		// `HxFinalModifierMember.fn`), and function-parameter bindings via
		// `HxParam`'s three Alt branches (`Required`/`Optional`/`Rest`).
		//
		// Scope kinds: every node that opens a fresh lexical scope. The
		// walker pushes a frame on enter and pops on exit; decl-hosts
		// found in that scope's subtree (until the next inner scope
		// boundary) become the frame's bindings, shadowing same-named
		// outer bindings for any Read encountered inside.
		//
		// For-loop iterator variables (`HxForStmt.varName` /
		// `HxForExpr.varName`) are resolved (Phase 3.2b-alpha): the
		// `varName` alias in `extractName` surfaces the iterator on the
		// `ForStmt` / `ForExpr` ctor's `name` slot, and both kinds are
		// listed in `selfScopeDeclKinds` so the iterator self-binds into
		// the loop's own scope frame, visible to reads inside the body,
		// not after the loop.
		//
		// Catch-clause exception names and lambda-parameter names are
		// resolved (Phase 3.2b-beta): their grammar typedefs are tagged
		// `@:spanned('CatchClause')` / `@:spanned('LambdaParam')`, so the
		// paired struct carries a per-instance `_span` + `_kind` and
		// `appendNodes` surfaces it as an addressable node. `CatchClause`
		// is a self-scoped decl (the exception var is visible only inside
		// the clause body, like a for-loop iterator); `LambdaParam` is a
		// decl-host that binds into the enclosing lambda scope frame.
		//
		// Write-parent kinds: ctors on `HxExpr` whose first positional
		// child carries the binding being modified. `Assign(left, right)`
		// plus every compound `*Assign(left, right)` variant, and the
		// four increment/decrement ctors `PreIncr` / `PreDecr` /
		// `PostIncr` / `PostDecr` (`HxExpr`, P5 Slice H — their single
		// operand at child-0 is the mutated binding). `x++` / `++x` both
		// read and write `x`; mirroring the compound-assign convention
		// they classify as a single Write. Per the `RefShape` docstring,
		// only the direct child-0 IdentExpr is reclassified Write;
		// `obj.x = …` and `arr[i] = …` keep `obj` / `arr` / `i` as Reads.
		return {
			identKind: 'IdentExpr',
			selfReferenceText: 'this',
			superReferenceText: 'super',
			underlyingThisTypeKinds: ['AbstractDecl', 'EnumAbstractDecl'],
			declHostKinds: DECL_HOST_KINDS,
			// A `switch` arm confines the locals declared in it — see `RefShape.branchScopeKinds`.
			branchScopeKinds: BRANCH_SCOPE_KINDS,

			// `package a.b;` / `import c.d.E;` are dotted module paths, not references.
			modulePathKinds: ['PackageDecl', 'ImportDecl'],
			// Every module-level VALUE binding this grammar can spell, and nothing else: a top-level
			// `var` / `function` (Haxe 4.2+) plus `VarForm`, the inner node of the `final` spelling,
			// which projects as `FinalDecl(VarForm name …)` with the name one level down and is
			// absent from `DECL_HOST_KINDS`. Every type-declaration kind is deliberately OUT — a
			// module-level type named after a value shadows nothing, and a `final class` reaches the
			// same wrapper as `FinalDecl(ClassForm …)`. Enumerated against `HxDecl`'s ctors, where
			// these three are the only value binders. See `RefShape.moduleValueDeclKinds`.
			moduleValueDeclKinds: ['VarDecl', 'FnDecl', 'VarForm'],
			// Every lexical scope, hoisting ones first. The two halves are named separately so
			// `positionScopedKinds` below is their difference by construction rather than by hand:
			// a kind added to one list can no longer go missing from the other.
			scopeKinds: HOISTING_SCOPE_KINDS.concat(POSITION_SCOPED_SCOPE_KINDS),
			// The non-hoisting half of `scopeKinds`, plus the `switch` arms — which are
			// position-scoped statement lists too, but live in `branchScopeKinds` rather than
			// `scopeKinds`. `RefShape.positionScopedKinds` is keyed by kind, not by vocabulary.
			positionScopedKinds: POSITION_SCOPED_SCOPE_KINDS.concat(BRANCH_SCOPE_KINDS),
			writeParentKinds: ASSIGN_KINDS.concat(['PreIncr', 'PreDecr', 'PostIncr', 'PostDecr']),
			// Self-scoped decl kinds: scope-introducers whose own name binds
			// into the frame they open (the for-loop iterator pattern). Listed
			// in scopeKinds, absent from declHostKinds — the binding is visible
			// only inside the loop, not to enclosing-scope siblings.
			selfScopeDeclKinds: [
				'ForStmt',
				'ForExpr',
				'CatchClause'
			],
			// A data member of an abstract is static whether or not it says so: Haxe refuses
			// `Cannot declare member variable in abstract`, which is what makes every value of
			// an `enum abstract` a static field with no modifier to read.
			implicitStaticFieldHostKinds: ['AbstractDecl', 'EnumAbstractDecl'],
			upperInitialNeverCaptures: true,
			// All THREE `macro` quotation spellings, not just the expression one: `macro : T`
			// (`MacroTypeExpr`) and `macro class { … }` (`MacroClassExpr`) reify a type and a type
			// declaration exactly as `macro { … }` reifies an expression. Leaving the two out made every
			// central reification gate — `ReificationScan.withoutQuoted` and each check's own descent stop
			// — blind to them, and `shorten-type-ref` then rewrote `macro :pony.events.Signal2<…>` to a
			// short name whose import it added to THIS file, while the reified type is spliced into
			// another module where that import does not apply.
			opaqueKinds: ['MacroExpr', 'MacroTypeExpr', 'MacroClassExpr'],
			interpolationKinds: ['DollarBlockExpr', 'DollarReifExpr'],
			branchKinds: [
				'IfStmt',
				'IfExpr',
				'WhileStmt',
				'DoWhileStmt',
				'ForStmt',
				'ForExpr',
				'CaseBranch',
				'CatchClause',
				'And',
				'Or',
				'Ternary',
				'NullCoal'
			],
			functionKinds: ['FnMember', 'FinalModifiedMember', 'FnDecl', 'LocalFnStmt'],
			localFunctionKinds: ['LocalFnStmt'],
			inlineFunctionKinds: ['LocalInlineFnStmt'],
			lambdaKinds: ['ThinArrow', 'ThinParenLambdaExpr', 'ParenLambdaExpr', 'FnExpr'],
			comparisonKinds: ['Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq', 'And', 'Or'],
			assignKind: 'Assign',
			addAssignKind: 'AddAssign',
			callKind: 'Call',
			caseBranchKind: 'CaseBranch',
			orPatternKind: 'BitOr',
			switchKinds: ['SwitchStmt', 'SwitchStmtBare', 'SwitchExpr', 'SwitchExprBare'],
			// The two statement-position forms of the four above: a bare subject and a
			// parenthesised one. Their arms need not be exhaustive, which is what a case
			// guard's fall-through to the next pattern requires.
			switchStatementKinds: ['SwitchStmt', 'SwitchStmtBare'],
			// The subject types Haxe never exhaustiveness-checks a statement switch over, so
			// an arm may be deleted without the compiler noticing the arm list shrank. Every
			// enum / enum abstract / Bool is deliberately absent: those ARE checked.
			openSwitchSubjectTypes: ['Int', 'UInt', 'Float', 'Single', 'String'],
			parenKind: 'ParenExpr',
			parenDelimiters: { open: '(', close: ')' },
			macroModifierKind: 'Macro',
			boolLitKind: 'BoolLit',
			nonNullBoolTypeName: 'Bool',
			branchConditionKinds: ['IfStmt', 'IfExpr'],
			emptyStmtKind: 'EmptyStmt',
			emptyMemberKind: 'EmptySemiMember',
			// `VarMore` IS a local declaration — the binding after the comma in
			// `var a = 1, b = 2;`. Listed here so every declaration-walking check reaches it
			// with its existing logic. NOT in `mutableLocalDeclKinds`: the kind alone cannot
			// say whether the list it continues is `var` or `final`, and Haxe has no way to
			// mark ONE binding of a multi-var `final` anyway.
			localDeclKinds: ['VarStmt', 'FinalStmt', 'VarMore'],
			localDeclContinuationKinds: ['VarMore'],
			localDeclExprKinds: ['VarExpr', 'FinalExpr'],
			staticLocalDeclKinds: ['StaticVarStmt', 'StaticFinalStmt'],
			mutableLocalDeclKinds: ['VarStmt'],
			ifStatementKinds: ['IfStmt'],
			ifExpressionKinds: ['IfExpr'],
			tryStatementKinds: ['TryCatchStmt', 'TryCatchStmtBare'],
			tryExpressionKinds: ['TryExpr'],
			equalityKinds: ['Eq', 'NotEq'],
			optionalParamKind: 'Optional',
			restParamKind: 'Rest',
			structureFieldHostKinds: ['Anon', 'ObjectLit'],
			nullableWrapperTypeNames: ['Null', 'Dynamic', 'Any'],
			memberTransparentWrapperTypeNames: ['Null'],
			nullSafetyDisableArg: 'Off',
			nonNullableTypeNames: ['Int', 'Float', 'Bool', 'UInt'],
			nullSafetyMetaName: '@:nullSafety',
			typedCastKinds: ['TypedCastExpr', 'ECheckTypeExpr'],
			checkedCastKind: 'TypedCastExpr',
			// `cast e` takes its result type from the CONTEXT; `cast(e, T)` / `(e : T)` carry their own.
			uncheckedCastKind: 'CastExpr',
			checkTypeKind: 'ECheckTypeExpr',
			nullSafeAccessKind: 'SafeFieldAccess',
			forceFieldAccessKind: 'ForceFieldAccess',
			indexAccessKind: 'IndexAccess',
			isExprKind: 'Is',
			nullableOperandKinds: ['Call', 'FieldAccess', 'SafeFieldAccess'],
			notKind: 'Not',
			blockStmtKind: 'BlockStmt',
			breakStatementKind: 'BreakStmt',
			continueStatementKind: 'ContinueStmt',
			loopStatementKinds: ['ForStmt', 'WhileStmt'],
			doWhileLoopKinds: ['DoWhileStmt'],
			intervalKind: 'Interval',
			whileStmtKind: 'WhileStmt',
			whileExprKind: 'WhileExpr',
			ltKind: 'Lt',
			postIncrKind: 'PostIncr',
			andLowerPrecedenceKinds: [
				'Or',
				'Ternary',
				'NullCoal',
				'Assign',
				'AddAssign',
				'SubAssign',
				'MulAssign',
				'DivAssign',
				'ModAssign',
				'ShlAssign',
				'ShrAssign',
				'UShrAssign',
				'BitOrAssign',
				'BitAndAssign',
				'BitXorAssign',
				'NullCoalAssign',
				'BoolAndAssign',
				'BoolOrAssign'
			],
			andOperatorText: '&&',
			ternaryKind: 'Ternary',
			switchExpressionHostKinds: SWITCH_EXPRESSION_HOST_KINDS,
			// The switch hosts plus the three arrow-lambda bodies: a comparator written as
			// `(a, b) -> if (…) -1 else if (…) 1 else 0` is the established TM shape, while a
			// `switch` in that slot is not — so the if-chain seam is a proper superset.
			// …plus the switch ARMS, taken from the one list that already names them. An arm's
			// value is delimited by the `:` that opens it and the `;` that ends it, exactly as a
			// `return` value is, and the formatter renders the ladder there under
			// `expressionIf: "next"`. The arm is reached through the expression-STATEMENT
			// wrapper, which `prefer-if-expression-chain` makes transparent only inside an arm —
			// a bare expression statement in a block is no host. `concat` copies, so the shared
			// static array is never aliased into the shape.
			// …plus an explicit `ParenExpr`. A ternary the author already wrapped in parens has the
			// same clean delimiters the other hosts do — the `(` and `)` themselves — so the ladder
			// goes INSIDE the existing parens and the rule adds no punctuation. This matters for a
			// ternary in operand position: `h - ih - (c ? a : b)` is legal as `h - ih - (if …)`, but
			// only WITH the parens; drop them and a following operand binds into the `else` branch
			// (measured: `h - if (c) 1.0 else 2.0 - ih` is 118, the parenthesised form 78, and both
			// compile). Requiring the parens in the SOURCE is what makes this host safe.
			ifExpressionChainHostKinds: SWITCH_EXPRESSION_HOST_KINDS.concat(
				['ThinArrow', 'ThinParenLambdaExpr', 'ParenLambdaExpr', 'ParenExpr']
			)
				.concat(BRANCH_SCOPE_KINDS),
			nullLiteralKind: 'NullLit',
			nullCoalesceKind: 'NullCoal',
			nullCoalesceOperatorText: '??',
			eqKind: 'Eq',
			notEqKind: 'NotEq',
			logicalAndKind: 'And',
			logicalOrKind: 'Or',
			newExprKind: 'NewExpr',
			fieldAccessKind: 'FieldAccess',
			returnStatementKind: 'ReturnStmt',
			conditionFirstChildKinds: ['IfStmt', 'IfExpr', 'WhileStmt', 'WhileExpr'],
			conditionLastChildKinds: ['DoWhileStmt'],
			parenLambdaKind: 'ThinParenLambdaExpr',
			fnExprKind: 'FnExpr',
			typeAnnotationKinds: ['Named', 'Anon', 'Arrow', 'ArrowFn'],
			forStmtKind: 'ForStmt',
			iterationBindingKinds: ['ForStmt', 'ForExpr'],
			iterationValueBinderKinds: ['KeyValueBinder'],
			paramKinds: ['Required', 'Optional', 'Rest'],
			supertypeClauseKinds: ['ExtendsClause', 'ImplementsClause'],
			noBodyKind: 'NoBody',
			catchClauseKind: 'CatchClause',
			catchAllTypeNames: ['Dynamic', 'Any'],
			exceptionTypePath: 'haxe.Exception',
			rawThrowWrapperTypePath: 'haxe.ValueException',
			controlExitKinds: [
				'ThrowStmt',
				'ThrowExpr',
				'ReturnStmt',
				'VoidReturnStmt',
				'BreakStmt',
				'ContinueStmt',
				'BreakExpr',
				'ContinueExpr',
				'VoidReturnExpr'
			],
			caseLiteralKinds: ['IntLit', 'FloatLit', 'BoolLit', 'NullLit'],
			tuplePatternDelimiters: { open: '[', close: ']' },
			visibilityContainerKinds: ['ClassDecl', 'ClassForm', 'AbstractClassDecl', 'AbstractDecl'],
			memberDeclKinds: ['VarMember', 'FinalMember', 'FnMember', 'FinalModifiedMember'],
			visibilityModifierKinds: ['Public', 'Private'],
			modifierOrderKinds: ['Override', 'Public', 'Private', 'Static', 'Inline', 'Final'],
			// EVERY modifier the grammar projects as a sibling, `abstract` and `overload` included.
			// `modifierOrderKinds` ranks six of them and is NOT this set: `overload` has no canonical
			// position, so ranking it would invent an order, while leaving it out of the membership set
			// ended every leading run it stood in. One list, written down in `HaxeNamingSupport`.
			modifierKinds: HaxeNamingSupport.MODIFIER_KINDS,
			finalModifierMemberKind: 'FinalModifiedMember',
			finalModifierRankKind: 'Final',
			fieldDeclKinds: ['VarMember', 'FinalMember'],
			// Every `HxFnBody` ctor, `UntypedBlockBody` and `CondBody` included: a consumer reads this
			// to tell a body child from a return-type child, so a missing ctor reads as a return type
			// (or, for a boundary scan, as no body at all).
			functionBodyKinds: ['BlockBody', 'UntypedBlockBody', 'ExprBody', 'NoBody', 'CondBody'],
			enumAbstractDeclKind: 'EnumAbstractDecl',
			enumAbstractMetaName: '@:enum',
			operatorOverloadMetaName: '@:op',
			// The same three tokens `MemberWriteScan.carriesBuildMacro` matches, published so the
			// STRUCTURAL leading-run walk `unused-private` uses asks the grammar rather than spelling
			// them itself. `BuildMacroMetaSeamTest` fails if the two lists ever disagree.
			typeBuildMacroMetaNames: ['@:build', '@:autoBuild', '@:genericBuild'],
			// The one of those three that builds SUBTYPES rather than its carrier. `SymbolIndex` needs the
			// split because it reads the flags while climbing a chain upward; the file-scoped text scan does
			// not and keeps the union.
			descendantBuildMacroMetaNames: ['@:autoBuild'],
			retainedDeclMetaName: '@:keep',
			// `@:rtti` emits a `haxe.rtti.Rtti` description keyed by member NAME — a separate question from
			// `@:keep`, which only keeps the member alive.
			reflectedDeclMetaName: '@:rtti',
			// `@:access(T)` lets the CARRIER read T's privates. The mirror tag `@:allow(T)`, which lets T
			// read the carrier's, is a different question and still spelled by its two readers.
			takesPrivateAccessMetaName: '@:access',
			forwardingDeclMetaName: '@:forward',
			implicitConstructorDeclMetaName: '@:structInit',
			// `@:nativeGen` is what makes a cs/java class a plain native type foreign code holds
			// directly — the Unity MonoBehaviour idiom. It is the marker, not `extends MonoBehaviour`:
			// Pony declares `@:nativeGen class Tooltip` with no superclass at all, and
			// `class PercentSize extends MonoBehaviour` with no annotation.
			nativeInteropDeclMetaName: '@:nativeGen',
			enumAbstractSyntax: { head: 'enum abstract {name}({under}) to {under}', bodyOpen: '{' },
			rawDynamicTypeName: 'Dynamic',
			bareConstructorTypeKinds: ['EnumDecl', 'EnumAbstractDecl'],
			runtimeTaggedTypeKinds: ['EnumDecl'],
			overrideModifierKind: 'Override',
			dynamicModifierKind: 'Dynamic',
			defaultVisibilityModifierText: 'private',
			externModifierKind: 'Extern',
			publicDefaultMetaNames: ['@:publicFields'],
			mutableFieldDeclKinds: ['VarMember'],
			voidReturnKind: 'VoidReturnStmt',
			valueReturnKinds: ['ReturnStmt', 'ReturnExpr'],
			throwKinds: ['ThrowStmt', 'ThrowExpr'],
			blockBodyKind: 'BlockBody',
			voidTypeName: 'Void',
			literalTypeNames: [
				'IntLit' => 'Int',
				'HexLit' => 'Int',
				'FloatLit' => 'Float',
				'BoolLit' => 'Bool',
				'SingleStringExpr' => 'String',
				'DoubleStringExpr' => 'String'
			],
			numericLiteralKinds: ['IntLit', 'FloatLit', 'HexLit'],
			arrayLiteralKind: 'ArrayExpr',
			arrayTypeNames: ['Array'],
			objectLiteralKind: 'ObjectLit',
			trailingCommaHostKinds: ['ArrayExpr', 'ObjectLit', 'Anon', 'Call', 'NewExpr', 'MetaCall'],
			mandatoryTrailingCommaChildKinds: ['ExtendsField'],
			negationKind: 'Neg',
			objectFieldKind: 'Field',
			sizeFieldNames: ['length'],
			positionMethodNames: ['substr', 'substring', 'charAt', 'charCodeAt', 'indexOf', 'lastIndexOf', 'hex'],
			additiveKinds: ['Add', 'Sub'],
			staticModifierKind: 'Static',
			inlineModifierKind: 'Inline',
			inlineConstantLiteralKinds: ['IntLit', 'HexLit', 'FloatLit', 'BoolLit'],
			constructorName: 'new',
			accessorMethodPrefixes: ['get_', 'set_'],
			conditionalMemberKind: 'Conditional',
			conditionalIfKeyword: '#if',
			conditionalElseKeywords: ['#else', '#elseif'],
			conditionalEndKeyword: '#end',
			condDeclPrefixKeywordKinds: ['EnumKw', 'AbstractKw', 'FinalKw'],
			opaqueCondRegionKinds: [
				'CondSpliceExpr',
				'CondSpliceOpExpr',
				'CondSpliceTail',
				'CondSpliceStmt',
				'CondSpliceBlockOpen',
				'CondSpliceSwitchOpen',
				'CondSpliceBlockClose',
				'CondSpliceCase',
				'CondSpliceMember',
				'CondSharedBodyDecl'
			],
			condOperandRunKinds: ['CondSpliceOpExpr'],
			stringInterpIdentKind: 'Ident',
			stringInterpBlockKind: 'Block',
			reservedWords: HaxeNamingSupport.KEYWORDS,

			declTypeChildKinds: ['Anon', 'TypeRef'],
			typeRefChildKinds: ['TypeRef'],
			anonTypeKind: 'Anon',
			defaultBranchKind: 'DefaultBranch',
			plainCasePatternKind: 'Plain',
			wildcardPatternName: '_',
			exprStatementKind: 'ExprStmt',
			nullCoalAssignKind: 'NullCoalAssign',
			numericOperatorKinds: [
				'Add', 'Sub', 'Mul', 'Div', 'Mod', 'Lt', 'Gt', 'LtEq', 'GtEq', 'BitAnd', 'BitOr', 'BitXor', 'Shl', 'Shr', 'UShr', 'Neg',
				'BitNot'
			],
			nullableNumericReturnCalls: ['Std.parseInt', 'Std.parseFloat'],
			stringLiteralKinds: ['SingleStringExpr', 'DoubleStringExpr'],
			stringLiteralMethodReturns: [
				'split' => 'Array<String>',
				'substr' => 'String',
				'substring' => 'String',
				'charAt' => 'String',
				'toUpperCase' => 'String',
				'toLowerCase' => 'String',
				'toString' => 'String',
				'indexOf' => 'Int',
				'lastIndexOf' => 'Int'
			],
			staticMethodReturns: [
				'Context.resolvePath' => 'String',
				'Context.currentPos' => 'haxe.macro.Expr.Position',
				'Date.now' => 'Date',
				'File.append' => 'sys.io.FileOutput',
				// `Dynamic` is the ANSWER here, not a missing one: a rule that must know the receiver
				// type reads an untabled call as "unresolved" and degrades to report-only, while
				// `Dynamic` lets it apply its own `Dynamic` policy (`prefer-static-extension` drops the
				// site — an extension dispatches no method on a `Dynamic` value at runtime).
				'Reflect.field' => 'Dynamic',
				// Reflection statics whose return is a plain `Array<String>` on every target — the
				// shapes real code iterates (`for (key in Reflect.fields(o))`), where the binder
				// carries no annotation and the element type is only readable from this return.
				'Reflect.fields' => 'Array<String>',
				'Type.getInstanceFields' => 'Array<String>',
				'Type.getClassFields' => 'Array<String>',
				'Type.getEnumConstructs' => 'Array<String>'
			],
			// `haxe.ds.Map`'s abstract wrappers carry no return annotation (`public inline
			// function exists(key:K) return this.exists(key);`), so no resolution scope can read
			// one. Both entries are the return their forwarded-to `haxe.Constraints.IMap` member
			// declares — `exists(k:K):Bool`, `remove(k:K):Bool` — fixed on every target. `get` is
			// absent on purpose: its `Null<V>` depends on the type argument.
			instanceMethodReturns: ['Map.exists' => 'Bool', 'Map.remove' => 'Bool'],
			nullableIndexTypeNames: ['Map', 'StringMap', 'IntMap', 'ObjectMap', 'EnumValueMap', 'WeakMap'],
			mapAbstractTypeNames: ['Map'],
			nullableInstanceReturnCalls: [
				'Array.pop',
				'Array.shift',
				'List.pop',
				'List.first',
				'List.last',
				'Map.get',
				'StringMap.get',
				'IntMap.get',
				'ObjectMap.get',
				'EnumValueMap.get',
				'WeakMap.get'
			],
			nullableReturnMarkerTypes: ['Null'],
			nullableFlowExcludedCalls: ['Array.pop', 'Array.shift', 'List.pop', 'List.first', 'List.last'],
			nullAssertionCalls: ['Assert.notNull'],
			assertTrueCalls: ['Assert.isTrue'],
			assertFalseCalls: ['Assert.isFalse'],
			mapExistsMethods: ['exists'],
			mapLiteralEntryKind: 'Arrow',
			finalClassMetaName: '@:final',
			// `@:generic` expands its class per type parameter, so there is no single class to hold a
			// static — Haxe rejects one with "A generic class can't have static fields" (verified 4.3.7).
			staticlessTypeMetaNames: ['@:generic'],
			plainClassDeclKind: 'ClassDecl',
			finalClassDeclKind: 'FinalDecl',
			typeDeclKinds: [
				'ClassDecl',
				'FinalDecl',
				'AbstractClassDecl',
				'AbstractDecl',
				'InterfaceDecl',
				'EnumDecl',
				'TypedefDecl'
			],
			interfaceDeclKinds: ['InterfaceDecl'],
			packageDeclKind: 'PackageDecl',
			publicModifierKind: 'Public',
			classDeclKinds: ['ClassDecl', 'AbstractClassDecl'],
			indexedElementTypeParams: ['Map' => 1, 'Array' => 0, 'Vector' => 0],
			// Haxe iteration semantics: `Array<T>` / `haxe.ds.Vector<T>` / `List<T>` yield `T`;
			// `Iterable<T>` yields `T` through the `iterator():Iterator<T>` it declares, and an
			// `Iterator<T>` is itself iterable yielding `T`. `Map<K, V>` is the odd one: its
			// `iterator()` yields the VALUES, so the element parameter is 1, not 0 (the keys need
			// the explicit `for (k => v in m)` form, whose KEY binder the element-type arm refuses).
			// OBLIGATION: this map answers the ELEMENT question, and the same entry now also types a
			// key-value loop's VALUE binder — so every name here must have `iterator()` element type
			// == `keyValueIterator()` value type. All six do; a container where they diverge does not
			// belong here, since the arm licenses NaN-unsound ordered-comparison rewrites.
			iterationElementTypeParams: [
				'Array' => 0,
				'Vector' => 0,
				'List' => 0,
				'Iterable' => 0,
				'Iterator' => 0,
				'Map' => 1
			],
			untypedKinds: ['UntypedExpr'],
			casePatternBinderKinds: ['Capture'],
			// The Haxe extractor: `case f(_) => p:` evaluates `f` on the subject before
			// matching `p`. Reaching such an arm RUNS code, so a rewrite that newly makes
			// one reachable has to refuse it.
			casePatternExtractorKinds: ['Arrow'],
			aliasingDeclKinds: ['TypedefDecl', 'AbstractDecl', 'EnumAbstractDecl'],
			// Delimited expression slots, derived from the grammar productions:
			// `HxVarDecl.init` is `@:lead('=')` up to the decl's `;` / `,`;
			// `HxStatement.ReturnStmt` is `@:kw('return') @:trail(';')` and its
			// expression twin `HxExpr.ReturnExpr` parses its value at minPrec 0;
			// `HxExpr.ArrayExpr` is `@:lead('[') @:trail(']') @:sep(',')`;
			// `HxObjectFieldBody.value` is `@:lead(':')` inside the literal's
			// `@:lead('{') @:trail('}') @:sep(',')`; `HxNewExpr` closes its argument
			// Star with `)`. The `VarStmt`/`VarMember` type-annotation child and the
			// `NewExpr` type arguments project as type kinds (`Anon` / `Named`), never
			// as `ParenExpr`, so a whole-host listing stays exact.
			//
			// `HxStringSegment.Block` — the `${ … }` interpolation of a single-quoted
			// literal — is the same fact stated by a lead / trail pair: `@:lead('${')`
			// and `@:trail('}')` bound its ONE expression child, which `parseHxExpr`
			// reads at minPrec 0. The REAL compiler agrees by a different route: its
			// interpolation scanner slices the text between `${` and the brace-counted
			// matching `}` and parses that slice standalone, so nothing outside the
			// braces can bind into it. Dropping a paren pair inside the braces cannot
			// disturb that scan either — a parenthesis is none of the four characters
			// that scanner reacts to (`{`, `}`, `$`, a backslash) and no line break, so
			// it reads exactly the same text either way, whatever it makes of that text.
			//
			// `DollarBlockExpr` — the MACRO reification `${ … }` — is bound by the same
			// two hard tokens and is ABSENT, but only conservatively: `${ … }` is the
			// reification ESCAPE, its content is macro-TIME code, and `macro ${(e)}`
			// builds exactly what `macro ${e}` builds (measured — no `EParenthesis`
			// survives). The pair that DOES reify is one written in the quoted region,
			// which `parenOpaqueSubtreeKinds` covers. Listing this kind is untaken work,
			// not a refused hazard.
			delimitedAllChildKinds: [
				'Block',
				'VarStmt',
				'FinalStmt',
				'VarExpr',
				'FinalExpr',
				'VarMember',
				'FinalMember',
				'ReturnStmt',
				'ReturnExpr',
				'ArrayExpr',
				'Field',
				'NewExpr'
			],
			// `Call`'s child 0 is the callee — an operand position, where parens can be
			// load-bearing (`(a ? b : c)(x)`); the arguments after it are delimited by
			// `(` / `,` / `)`. The assignment family's child 0 is likewise the target,
			// while the right-hand side is the right operand of a prec-0
			// right-associative operator, i.e. parsed at minPrec 0 up to the enclosing
			// terminator. `IndexAccess` is the same shape one bracket over: child 0 is the
			// RECEIVER, an operand position (`(a ? b : c)[i]` needs its parens), while the
			// index at child 1 is bounded by the `[` and `]` themselves and parses at
			// minPrec 0 — `arr[untyped i]`, `arr[cast i]`, `arr[if (c) 1 else 2]` and
			// `arr[@:privateAccess q.v]` all compile bare, the `]` ending each of them.
			// `Interval`, `Arrow` and the other infix kinds are deliberately absent: their
			// operands parse above minPrec 0 and re-associate on unwrap — a map-literal key
			// `[(a ? b : c) => d]` bare is `Unexpected =>`, which is why an index slot and
			// an `=>` operand are not the same question.
			delimitedTailChildKinds: ['Call', 'IndexAccess'].concat(ASSIGN_KINDS),
			// `macro final w = 1` re-enters the unrestricted expression parse, where the
			// declaration's `, b = 2` continuation reaches past the separator that ends
			// the slot — so a paren around one is load-bearing while it is the last thing
			// inside them.
			separatorGreedyExprKinds: ['VarExpr', 'FinalExpr'],
			// `$a{exprs}` splices its array into the surrounding argument / element list
			// only when nothing wraps it, so a paren around one changes the built call's
			// ARITY with no syntax error. All `$x{…}` forms share this kind.
			spliceSensitiveExprKinds: ['DollarReifExpr'],
			// Provably tighter than `?:`, so a paren around one as a ternary condition is
			// redundant. Fail-closed: the loose / right-greedy kinds (assignment, ternary,
			// arrow, `untyped`/`macro`/metadata, block-like `if`/`switch` exprs) are absent,
			// so they keep their parens. Object literals (leading-`{` ambiguity) and casts
			// (rare) are conservatively omitted too.
			ternaryConditionUnwrapKinds: [
				'Add',
				'Sub',
				'Mul',
				'Div',
				'Mod',
				'Eq',
				'NotEq',
				'Lt',
				'LtEq',
				'Gt',
				'GtEq',
				'And',
				'Or',
				'NullCoal',
				'BitAnd',
				'BitOr',
				'BitXor',
				'Shl',
				'Shr',
				'UShr',
				'Interval',
				'Is',
				'Neg',
				'Not',
				'BitNot',
				'PreIncr',
				'PreDecr',
				'PostIncr',
				'PostDecr',
				'IdentExpr',
				'IntLit',
				'FloatLit',
				'HexLit',
				'BoolLit',
				'NullLit',
				'SingleStringExpr',
				'DoubleStringExpr',
				'RegexLit',
				'Call',
				'FieldAccess',
				'SafeFieldAccess',
				'ForceFieldAccess',
				'IndexAccess',
				'ArrayExpr',
				'NewExpr'
			],
			// Self-delimiting content: no operator outside can bind into it. `IdentExpr`
			// covers `this`. `SingleStringExpr` projects its segments and `${…}`
			// interpolations as children — all sealed inside the quotes, so they are not
			// re-examined. `RegexLit` is out: its closing `/` welds onto a following `/`.
			atomExprKinds: [
				'IdentExpr',
				'IntLit',
				'FloatLit',
				'HexLit',
				'BoolLit',
				'NullLit',
				'SingleStringExpr',
				'DoubleStringExpr'
			],
			// A transparent link: `a.b.c` is one atom, while `f().b` / `arr[i].b` /
			// `a?.b` are not — their unlisted child stops the chain.
			atomChainKinds: ['FieldAccess'],
			// One tier each, left-associative, so `(a * b) / c` and `a * b / c` parse
			// alike. `Mod` is deliberately in NO family: Haxe binds `%` TIGHTER
			// than `*` and `/` (`2 * 7 % 4` is 6), and the grammar models that as its own
			// prec-10 tier, so `%` never shares a tier with another operator. A single-member
			// `['Mod']` family would be sound (`(a % b) % c` re-parses to the tree it already
			// had) but stays out of scope here.
			leftAssociativeBinaryFamilies: [['Mul', 'Div'], ['Add', 'Sub']],
			// The prec-5 tier's two VALUE comparisons apiece. `Is` (a type on the right)
			// and `Interval` (a `...` that abuts numeric-literal / field-access `.`
			// lexing) share the tier but are deliberately not hosts.
			comparisonOperandHostKinds: ['Eq', 'NotEq', 'Lt', 'LtEq', 'Gt', 'GtEq'],
			// The arithmetic core plus the POSTFIX in/decrements: tiers 8-10 and the
			// postfix chain links, strictly tighter than a comparison here AND in every
			// C-family language, so the drop is right on both readings. `PostIncr` /
			// `PostDecr` are what `while ((a++) < 36)` needs; their own `++` / `--`
			// token closes the content, so no greedy tail can reach past the pair, and
			// their leftmost token is the OPERAND, so the leading-minus rule has nothing
			// to refuse. The PREFIX `PreIncr` / `PreDecr` are equally provable and stay
			// off on READABILITY grounds — bare, `(++b) < 36` reads `++b < 36` — but by
			// mere absence from this ROOT whitelist, not by the gate that keeps `Neg` out:
			// `unaryMinusKinds` refuses a leading minus at ANY depth and has no prefix
			// in/decrement analogue, so `(--b * c) > d` is a `Mul` root and still drops.
			// The BITWISE tier (6) is out for CORRECTNESS — C binds
			// `& | ^` LOOSER than `==`, so `(x & m) != 0` reads differently there once
			// the pair is gone. The SHIFT tier (7) binds tighter than a comparison in C
			// exactly as it does here and WOULD be provable; it is out on READABILITY
			// alone, since a shift operand is habitually parenthesized. Atoms are the
			// `atoms` arm's; the two converge over `lint --fix` passes. `Neg` USED to be
			// here as a root; `unaryMinusKinds` now owns the whole leading-minus rule,
			// so listing it as well would be a whitelist entry nothing can pass.
			comparisonOperandUnwrapKinds: ['Add', 'Sub', 'Mul', 'Div', 'Mod', 'PostIncr', 'PostDecr'],
			// The prec-8 tier. NOT the multiplicative one above it: Haxe binds `%` tighter
			// than `*` and `/`, but C makes the three ONE tier, so a bare `a * b % c` reads
			// `(a * b) % c` to a C-trained eye and the pair in `a * (b % c)` is what makes
			// the two readings agree. Bitwise and shift are no hosts either — not for
			// correctness (`(a * b) & c` bare re-parses the same here and in C) but on the
			// READABILITY ground that keeps shifts off the comparison whitelist.
			additiveOperandHostKinds: ['Add', 'Sub'],
			// Tiers 9 and 10 and the POSTFIX in/decrements — strictly tighter than `+` / `-`
			// here AND in C, so the drop is right on both readings; `(a++) + b` bare is the
			// tree it already had. The SAME tier (`Add` / `Sub`) is out for CORRECTNESS:
			// `a + (b - c)` bare is `(a + b) - c`, a different value. `Neg` is provable and
			// out on READABILITY alone (`a - (-b)` bare reads `a - -b`). The PREFIX
			// `PreIncr` / `PreDecr` are off on that same ground (`a - (--b)` bare reads
			// `a - --b`) but only as a ROOT — `Neg` has `unaryMinusKinds` refusing it at any
			// depth, a prefix in/decrement has no such gate, so `a - (--b * c)` still drops.
			// Only the POSTFIX spelling puts the operand first.
			// Everything looser re-associates outward and is excluded by construction.
			additiveOperandUnwrapKinds: ['Mul', 'Div', 'Mod', 'PostIncr', 'PostDecr'],
			// Everything whose extent runs to the enclosing bracket. Probed one shape
			// apiece: each of these swallows a trailing `- d` that a parenthesis would
			// have kept out. `CastExpr` is here on the COMPILER's answer, not this
			// parser's — `x + b * cast c - d` is 7 there and this grammar models the
			// cast as bounded; `MetaExpr` diverges the same way. Deliberately absent:
			// the brace- and bracket-closed forms (`switch`, a block, an object or
			// array literal, `cast(e, T)`, `(e : T)`, `macro class`, `new T(…)`) and
			// the tight unary prefixes (`-`, `!`, `~`, `++`, `--`), none of which reach
			// past their own last token.
			rightGreedyExprKinds: [
				'UntypedExpr',
				'MacroExpr',
				'MetaExpr',
				'CastExpr',
				'FnExpr',
				'NamedFnExpr',
				'ThinParenLambdaExpr',
				'ParenLambdaExpr',
				'ThrowExpr',
				'ReturnExpr',
				'InlineExpr',
				'IfExpr',
				'ForExpr',
				'ForReifExpr',
				'WhileExpr',
				'TryExpr',
				'Ternary'
			],
			// `a + (-b * c)` bare reads `a + -b * c` — a `Mul` root over a leading
			// minus, the same defect a bare `Neg` root is excluded for.
			unaryMinusKinds: ['Neg'],
			// `@:m expr` — the annotation binds to whatever `expr` starts with, so a pair
			// on that left edge is holding it there. `MetaCall` is the annotation node
			// INSIDE this one, not a prefix of anything.
			prefixAnnotationKinds: ['MetaExpr'],
			// A direct paren child of these is grammar syntax (`case X if (g)`) or an
			// idiom the project keeps out of scope (a second `switch` subject pair,
			// metadata arguments).
			parenRequiredHostKinds: [
				'CaseBranch',
				'SwitchStmt',
				'SwitchStmtBare',
				'SwitchExpr',
				'SwitchExprBare',
				'MetaCall',
				'MetaExpr'
			],
			// Inside a `macro` quotation a paren reifies as `EParenthesis`; inside a case
			// pattern the syntax is matched structurally, not by expression precedence.
			parenOpaqueSubtreeKinds: ['MacroExpr', 'Plain']
		};
	}

	public function metaShape(): MetaShape {
		// Annotation nodes come through the three `HxMetadata` enum
		// ctors: `MetaCall` for the paren-bearing `@:name(args)` form
		// (its arg expressions are children), `Meta` for the paren-less
		// `@:name`, and `PlainMeta` for the verbatim raw catch-all
		// (`@:name(args)` carried inline as the node's `name` slot).
		// Decl-host kinds are shared with `refShape` so an annotation
		// attributes to the same binding-declaration nodes the refs
		// walker recognises.
		return {
			metaKinds: ['MetaCall', 'Meta', 'PlainMeta'],
			declHostKinds: DECL_HOST_KINDS
		};
	}

	public function selectKindEquivalence(): KindEquivalence {
		return SELECT_KIND_EQUIVALENCE;
	}

	public function parsePattern(source: String): Pattern {
		// `$X` / `$_` are not valid Haxe identifier prefixes outside string
		// interpolation, so we substitute them for reserved-identifier
		// placeholders before parsing and reclassify the resulting leaves
		// post-parse. The grammar parser stays unmodified.
		final substituted: String = Metavar.substituteMetavarsHaxe(source);
		final attempts: Array<{ wrap: String -> String, extract: QueryNode -> Null<QueryNode>, category: PatternCategory }> = [
			{ wrap: src -> src, extract: HaxePatternFragment.extractFirstDecl, category: PatternCategory.Decl },
			{ wrap: HaxePatternFragment.wrapAsStmt, extract: HaxePatternFragment.extractFirstStmt, category: PatternCategory.Stmt },
			{ wrap: HaxePatternFragment.wrapAsExpr, extract: HaxePatternFragment.extractFirstExpr, category: PatternCategory.Expr },
			{ wrap: HaxePatternFragment.wrapAsMetaArgs, extract: HaxePatternFragment.extractFirstMeta, category: PatternCategory.MetaArgs }
		];
		// A declaration / statement fragment whose only defect is the missing
		// terminator (`final x:T = []`) parses with a `;` appended — retried as a
		// SECOND variant through the SAME category ladder, so it lands in its
		// proper category with correct spans (a single-category retry mis-spans).
		for (variant in [substituted, '$substituted;']) for (attempt in attempts) {
			final wrapped: String = attempt.wrap(variant);
			final tree: Null<QueryNode> = try parseFile(wrapped) catch (e: ParseError) null
			catch (e: Exception) null;
			if (tree == null) continue;
			final extracted: Null<QueryNode> = attempt.extract(tree);
			if (extracted == null) continue;
			// A Decl extraction must CONSUME the whole fragment: modifiers
			// project as separate sibling nodes, so `static final x = []`
			// extracts a bare `(Static)` leaf — a degenerate pattern that would
			// silently match every static modifier. Reject partial extractions.
			if (attempt.category == PatternCategory.Decl && !HaxePatternFragment.consumesVariant(extracted, variant)) continue;
			// A bare-meta pattern (`@:foo($_)`) with the auto-appended `;`
			// parses as `MetaStmt(meta, EmptyStmt)` since the MetaStmt slice —
			// a degenerate statement that would shadow the MetaArgs attempt
			// every meta pattern relied on. Reject it so the ladder falls
			// through; real `@:meta <keyword-stmt>` patterns keep matching.
			if (
				attempt.category == PatternCategory.Stmt && extracted.kind == 'MetaStmt' && extracted.children.length > 0
				&& extracted.children[extracted.children.length - 1].kind == 'EmptyStmt'
			)
				continue;
			// `final x = …` extracts as the nameless wrapper `FinalDecl(VarForm …)`,
			// which can never unify with the flat `FinalMember` / `FinalStmt`. Re-root
			// onto the named inner node — after the `consumesVariant` gate above, which
			// needs the wrapper's span.
			final rooted: QueryNode = HaxePatternFragment.rerootFinalVarDecl(extracted);
			// Only a bare-identifier node may collapse into a whole-subtree
			// metavar: it is the one position where `$x` genuinely stands for
			// "any expression". A metavar landing in the NAME slot of a node
			// that happens to be childless — `new $x()`, `extends $B`, a
			// return type — is a name-position metavar, and collapsing it
			// erased its kind, turning the pattern into a match-everything
			// wildcard.
			// The `...` ellipsis first, so the metavar path never sees the star
			// placeholder: a star is not a metavar (it does not bind), and the
			// same `reclassify` collapse that erased `new $x()` would erase a
			// starred node just as silently.
			final starred: QueryNode = PatternStar.reclassify(rooted);
			final refusal: Null<String> = PatternStar.validate(starred);
			if (refusal != null) throw refusal;
			final reclassified: QueryNode = Metavar.reclassify(starred, refShape().identKind);
			return new Pattern(
				reclassified, attempt.category, source, SEARCH_KIND_EQUIVALENCE, Metavar.ignoredNames(variant, reclassified)
			);
		}
		// Every attempt's parser error is offset into a synthetic wrapper
		// string, so leaking it (`expected HxDecl at 0`) only misleads.
		// Report the actionable fact: the fragment is not valid in any
		// supported pattern position.
		throw 'pattern: not valid as a declaration, statement, expression, or metadata argument (a statement fragment is retried with a '
			+ 'trailing ";" automatically; a MODIFIER-bearing declaration cannot be a pattern — modifiers project as separate nodes; for '
			+ 'those and for non-standalone fragments such as object fields use `apq patch` or `replace-node --select`)';
	}

	/** The Haxe naming-convention capability — projects declarations and resolves a file's policy. */
	public function namingSupport(): Null<NamingSupport> {
		return new HaxeNamingSupport();
	}

	/**
	 * The Haxe adjacent-string-literal folding capability, consumed by the
	 * `fold-adjacent-string-literals` check.
	 */
	public function stringFoldSupport(): Null<StringFoldSupport> {
		return new HaxeStringFoldSupport();
	}

	/**
	 * The maximum cyclomatic complexity the `complexity` check should allow for a
	 * function in the file at `path`: read from a discovered `checkstyle.json`'s
	 * `CyclomaticComplexity` config, or null when none applies (the check then
	 * uses its built-in default).
	 */
	public function maxComplexity(path: String): Null<Int> {
		final content: Null<String> = CheckstyleConfigFinder.findConfigContent(path);
		return content == null ? null : try CheckstyleConfigLoader.loadComplexityMax(content) catch (exception: Exception) null;
	}

	public function controlFlowSupport(): Null<ControlFlowSupport> {
		return new HaxeControlFlowSupport();
	}

	public function booleanLogicSupport(): Null<BooleanLogicSupport> {
		return new HaxeBooleanLogicSupport();
	}

	/**
	 * The `using`-eligible extension methods `using <modulePath>` brings into scope,
	 * DERIVED from the discovered std source via `StdResolver`: any-visibility static
	 * `FnMember`s of the module that take at least a first parameter, computed lazily
	 * and cached per module path. Falls back to the hardcoded `EXTENSION_METHODS`
	 * constant when std is undiscovered or the module is not a std file — so a name a
	 * live `using` relies on is never dropped. `unused-import` deletes a `using` only
	 * when NONE of the returned names is called, and a superset name is harmless (it
	 * only makes the "used" test more generous).
	 */
	public function knownExtensionMethods(modulePath: String): Null<Array<String>> {
		return extensionMethodsFromStd(modulePath) ?? EXTENSION_METHODS[modulePath];
	}

	public function checkOverrides(path: String): Null<CheckOverrides> {
		final content: Null<String> = CheckstyleConfigFinder.findConfigContent(path);
		return content == null ? null : try CheckstyleConfigLoader.loadOverrides(content) catch (exception: Exception) null;
	}

	/**
	 * `TypeInfoProvider`: maps each typed declaration's binding-span `from` to the
	 * SIMPLE name of its nominal declared type, recovered from the grammar AST
	 * (which the QueryNode projection drops). Walks the same structure `appendNodes`
	 * does, associating an enum-ctor decl's Span param with the `type` on its
	 * payload struct, and a spanned struct's `_span` with its own `type`.
	 */
	public function declaredTypes(source: String): Map<Int, String> {
		return spanTypeInfo(source).declaredTypes;
	}

	public function returnTypes(source: String): Map<Int, String> {
		return spanTypeInfo(source).returnTypes;
	}

	/**
	 * `TypeInfoProvider`: maps each property-bearing member's binding-span `from` to
	 * whether its read accessor is a getter (`get` / `dynamic` → side-effecting,
	 * true) vs a plain stored read (`default` / `never` / a method name → false).
	 * A member with NO accessor clause (a plain field) is ABSENT — the consumer
	 * treats absence as a plain field. Same grammar-AST walk as `declaredTypes`,
	 * keyed on `HxVarDecl.access` (dropped from the QueryNode projection).
	 */
	public function propertyAccessors(source: String): Map<Int, Bool> {
		return spanTypeInfo(source).propertyAccessors;
	}

	/**
	 * `TypeInfoProvider`: maps each property-bearing member's binding-span `from` to
	 * whether its WRITE accessor is a setter (`set` / `dynamic` -> side-effecting,
	 * true) vs a plain stored write (`default` / `null` / `never` -> false). The
	 * write-side counterpart of `propertyAccessors`, keyed on `HxVarDecl.access`
	 * `ids[1]`. A member with NO accessor clause (a plain field) is ABSENT - the
	 * consumer treats absence as no set-accessor.
	 */
	public function propertyWriteAccessors(source: String): Map<Int, Bool> {
		return spanTypeInfo(source).propertyWriteAccessors;
	}

	/**
	 * `TypeInfoProvider`: maps each declaration's binding-span `from` to the VERBATIM
	 * source of its `:Type` annotation (`var x: Array<Int>` → `Array<Int>`), recovered
	 * by slicing the type node's span. Same walk + key as `declaredTypes`; the value is
	 * the written form rather than the package-stripped simple name.
	 */
	public function declaredTypeSources(source: String): Map<Int, String> {
		return spanTypeInfo(source).declaredTypeSources;
	}

	/**
	 * `TypeInfoProvider`: maps each typed-cast / type-check node's payload `_span.from`
	 * to the VERBATIM source of its TARGET type (`cast(x, Array<Int>)` → `Array<Int>`).
	 * Same discriminated walk as the simple-name cast recovery (a `type` field plus an
	 * operand `target` / `expr`, no `name`), but the value is the written type source.
	 */
	public function castTargetSources(source: String): Map<Int, String> {
		return spanTypeInfo(source).castTargetSources;
	}

	/**
	 * `SpanTypeInfoProvider`: the six span-indexed maps from ONE `HaxeModuleSpanParser`
	 * parse + ONE `walkGrammarSpans` traversal - the batched form of `declaredTypes`
	 * / `returnTypes` / `propertyAccessors` / `propertyWriteAccessors` / `declaredTypeSources`
	 * / `castTargetSources`, whose six separate `walkSpanMap` calls each re-parse the
	 * source. Each map is produced by the SAME visitor logic as its individual accessor
	 * over the SAME traversal, so the bundle is byte-for-byte the six separate walks
	 * (pinned by `SpanTypeInfoPinTest`).
	 */
	public function spanTypeInfo(source: String): SpanTypeInfo {
		return spanTypeInfoFromRoot(parseRoot(source), source);
	}

	/**
	 * `ParsedRootProvider`: parse `source` into the grammar root - the handle the three
	 * projections below share, so a caller needing more than one of them pays ONE parse
	 * instead of one per projection. Null when the source does not parse; each projection
	 * then behaves exactly as its source-taking twin did on that source.
	 */
	public function parseRoot(source: String): Null<Any> {
		return HaxeQueryWalker.parseRoot(source);
	}

	/**
	 * `ParsedRootProvider`: the `parseFile` / `parseFileTypeRefs` projection of an
	 * already-parsed root, with `HxInterpProjection` applied: a single-quoted literal's
	 * text fragment may SPELL its interpolation through escapes (`'\x24a'` is a read
	 * of `a`), which the `@:rawString` terminal deliberately keeps verbatim and every
	 * tree consumer would otherwise read as plain text. Applied at this one seat so
	 * `parseFile` and `parseFileTypeRefs` — and through them every check, op and
	 * probe — see the same model the compiler does. Throws on a null root, exactly as
	 * `parseFile` always threw on a source that does not parse.
	 */
	public function treeFromRoot(root: Null<Any>, source: String, withTypeRefs: Bool): QueryNode {
		final tree: QueryNode = new QueryNode('module', null, HaxeQueryWalker.walkRoot(cast root, withTypeRefs));
		HxInterpProjection.reproject(tree, source);
		HxArrowParamProjection.reproject(tree, source);
		return tree;
	}

	/** `ParsedRootProvider`: the `spanTypeInfo` projection of an already-parsed root — the empty bundle on a null one. */
	public function spanTypeInfoFromRoot(root: Null<Any>, source: String): SpanTypeInfo {
		return HaxeQueryWalker.spanInfoRoot(cast root, source);
	}

	/**
	 * `TypeInfoProvider`: maps each simple name brought into scope by a plain
	 * `import a.b.X;` to its fully-qualified path (`X` → `a.b.X`). Aliased / wildcard
	 * imports and `using` are skipped (an alias's original path is not exposed by the
	 * grammar). A name also used as a TYPE PARAMETER anywhere in the file is excluded —
	 * a type param shadows an import of the same name within its scope, so a bare
	 * reference to it must not resolve to the import (drops the rare collision).
	 */
	public function importMap(source: String): Map<String, String> {
		return importMapFromRoot(parseRoot(source), source);
	}

	/**
	 * `ParsedRootProvider`: the `importMap` projection of an already-parsed root. The
	 * import walk and the type-parameter sweep both read THIS root, where the
	 * source-taking form parsed once for each of them. The empty map on a null root.
	 */
	public function importMapFromRoot(root: Null<Any>, source: String): Map<String, String> {
		final out: Map<String, String> = [];
		final tree: Null<QueryNode> = try treeFromRoot(root, source, false) catch (exception: Exception) null;
		if (tree == null) return out;
		for (node in tree.children) if (node.kind == 'ImportDecl') {
			final raw: Null<String> = node.name;
			if (raw != null) {
				final dot: Int = raw.lastIndexOf('.');
				out[dot == -1 ? raw : raw.substring(dot + 1)] = raw;
			}
		}
		for (tp in HaxeQueryWalker.typeParamNamesRoot(cast root, source)) out.remove(tp);
		return out;
	}

	/** Lazily extract + cache the `using`-eligible method names of `modulePath` from the std source, or null when std / the module file is absent. */
	private function extensionMethodsFromStd(modulePath: String): Null<Array<String>> {
		if (extMethodsCache.exists(modulePath)) return extMethodsCache[modulePath];
		final computed: Null<Array<String>> = computeExtensionMethodsFromStd(modulePath);
		extMethodsCache[modulePath] = computed;
		return computed;
	}

	/** Parse `<std>/<modulePath>.hx` and collect its static-with-first-param `FnMember` names, or null when std is undiscovered or the file is missing / unparseable. */
	private function computeExtensionMethodsFromStd(modulePath: String): Null<Array<String>> {
		final dir: Null<String> = StdResolver.stdDir();
		if (dir == null) return null;
		final src: Null<String> = readStdModule(dir, modulePath);
		if (src == null) return null;
		final tree: Null<QueryNode> = try parseFile(src) catch (exception: Exception) null;
		if (tree == null) return null;
		final names: Array<String> = [];
		collectStaticMethodsWithParam(tree, names);
		return names;
	}

	/**
	 * The write options `optsJson` names: the writer's own defaults for `null` (no
	 * config discovered) and equally for a BLANK payload, which is what a 0-byte
	 * `hxformat.json` reads as — settings the project did not state. Handing that to
	 * the config parser instead raises `unexpected input (expected {)`. The three
	 * entries that read it (`writeRoundTrip`, `layoutMetrics`, `writeRoundTripPlain`)
	 * must agree on that, or a width-aware check MEASURES through one and WRITES
	 * through another and reports findings it can never apply.
	 */
	private static function writeOptionsOf(optsJson: Null<String>): HxModuleWriteOptions {
		final stated: Null<String> = FormatConfigDiscovery.normalize(optsJson);
		return stated == null ? HaxeFormat.instance.defaultWriteOptions : HaxeFormatConfigLoader.loadHxFormatJson(stated);
	}

	/** Read `<dir>/<modulePath-as-path>.hx`, or null when it does not exist / is unreadable (a non-std module then falls back to the table). */
	private static function readStdModule(dir: String, modulePath: String): Null<String> {
		#if (sys || nodejs)
		final file: String = haxe.io.Path.join([dir, '${modulePath.split('.').join('/')}.hx']);
		return !sys.FileSystem.exists(file) ? null : try sys.io.File.getContent(file) catch (exception: Exception) null;
		#else
		return null;
		#end
	}

	/**
	 * Walk `container`'s children collecting the names of static `FnMember`s that take
	 * at least one parameter. Modifiers are FLAT siblings preceding their member, so a
	 * `Static` seen since the last member marks the next `FnMember` static; a
	 * non-`Static` modifier preserves the flag. `#if` members nest in a `Conditional`
	 * (their own modifier + member sequence) and type decls nest their members — both
	 * are recursed into. Visibility is intentionally NOT filtered: a private static can
	 * never be reached through `using`, so including it is a harmless superset that
	 * also preserves the historical `EXTENSION_METHODS` table (which listed private
	 * helpers).
	 */
	private static function collectStaticMethodsWithParam(container: QueryNode, into: Array<String>): Void {
		var sawStatic: Bool = false;
		// A `#if X inline #end` between `static` and the function wraps its modifiers in a
		// `Conditional`; flattening those inline keeps the modifier run continuous, and a
		// whole `#if`-guarded member (its own modifiers + FnMember) is handled by the same
		// linear pass — so target-conditional statics are captured either way.
		for (child in flattenConditionals(container.children)) {
			final kind: String = child.kind;
			if (kind == 'Static')
				sawStatic = true;
			else if (kind == 'FnMember') {
				final name: Null<String> = child.name;
				if (sawStatic && name != null && hasParam(child)) into.push(name);
				sawStatic = false;
			} else if (FIELD_BOUNDARY_KINDS.contains(kind))
				sawStatic = false;
			else if (!MODIFIER_KINDS.contains(kind)) {
				collectStaticMethodsWithParam(child, into);
				sawStatic = false;
			}
		}
	}

	/** Dissolve `Conditional` (`#if`) wrappers, splicing their children in place (recursively), so a modifier or member guarded by conditional compilation reads as a plain sibling. */
	private static function flattenConditionals(children: Array<QueryNode>): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		for (c in children) if (c.kind == 'Conditional')
			for (g in flattenConditionals(c.children)) out.push(g);
		else
			out.push(c);
		return out;
	}

	/** Whether `fn` declares at least one parameter (a `Required` / `Optional` / `Rest` child) — the `using`-eligibility gate. */
	private static function hasParam(fn: QueryNode): Bool {
		return fn.children.exists(c -> c.kind == 'Required' || c.kind == 'Optional' || c.kind == 'Rest');
	}

	/** The all-empty bundle returned when the source does not parse - the six maps are simply unpopulated, never null. */
}
