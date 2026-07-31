package anyparse.grammar.haxe;

import anyparse.query.GrammarPlugin;
import anyparse.query.Pattern;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.QueryNode;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin.CheckOverrides;
import anyparse.query.TypeInfoProvider;
import anyparse.query.SpanTypeInfoProvider;
import anyparse.query.StdResolver;

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
final class HaxeQueryPlugin implements GrammarPlugin implements TypeInfoProvider implements SpanTypeInfoProvider {

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
	 * every declaration-walking check was blind to them.
	 */
	private static final DECL_HOST_KINDS: Array<String> = [
		'VarDecl',
		'FnDecl',
		'LocalFnStmt',
		'ClassDecl',
		'InterfaceDecl',
		'EnumDecl',
		'AbstractDecl',
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
		'BoolOrAssign',
	];

	/**
	 * Search-only kind-equivalence. A Haxe `var` declaration surfaces
	 * as three position-specific `QueryNode` kinds — module-level
	 * `VarDecl`, class-field `VarMember`, local `VarStmt` — all
	 * wrapping the same `HxVarDecl` struct (identical child shape). A
	 * `var $v = …` pattern parses via the Decl attempt to `VarDecl`;
	 * without this equivalence it would never match fields or locals
	 * (the S2 dogfood gap). Carried on the `Pattern` and consulted
	 * only by the search `Matcher`, so the `QueryNode` tree keeps the
	 * precise per-position kinds: `ast` / `--select` / `refs` /
	 * `meta` vocabulary — including the published `--on VarMember` —
	 * is unchanged, and `DECL_HOST_KINDS` above stays correct (it
	 * intentionally distinguishes the three for scope/decl-host
	 * resolution). `final` declarations (`FinalMember` / `FinalStmt`
	 * / `FinalField`) are deliberately a separate family: a different
	 * keyword with immutability semantics, not in this gap's scope.
	 */
	private static final SEARCH_KIND_EQUIVALENCE: KindEquivalence = new KindEquivalence([['VarDecl', 'VarMember', 'VarStmt']]);

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
	private static final _extMethodsCache: Map<String, Null<Array<String>>> = new Map();

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
		return buildTree(source, false);
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		return buildTree(source, true);
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
	 */
	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> {
		final tree: Dynamic = HaxeModuleTriviaParser.parse(source);
		final opts: HxModuleWriteOptions = optsJson == null
			? HaxeFormat.instance.defaultWriteOptions
			: HaxeFormatConfigLoader.loadHxFormatJson(optsJson);
		return HaxeModuleTriviaWriter.write(tree, opts);
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
	 * `optsJson` follows the same convention as `writeRoundTrip` — a
	 * non-null `hxformat.json`-shaped payload routes through
	 * `HaxeFormatConfigLoader.loadHxFormatJson`; `null` keeps the
	 * defaults.
	 */
	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String> {
		final tree: Dynamic = HaxeModuleParser.parse(source);
		final opts: HxModuleWriteOptions = optsJson == null
			? HaxeFormat.instance.defaultWriteOptions
			: HaxeFormatConfigLoader.loadHxFormatJson(optsJson);
		return HxModuleWriter.write(tree, opts);
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
			underlyingThisTypeKinds: ['AbstractDecl', 'EnumAbstractDecl'],
			declHostKinds: DECL_HOST_KINDS,
			// `CatchClause` is surfaced by `appendNodes` from the
			// `@:spanned('CatchClause')` paired struct; it opens a scope
			// (the clause body) and self-binds the exception name into
			// that frame (see `selfScopeDeclKinds`).
			scopeKinds: [
				'ClassDecl',
				// `final class` projects as `FinalDecl(ClassForm …)` and `abstract class`
				// as `AbstractClassDecl`; both hold instance fields whose bare (non-`this`)
				// references resolve only if the class body opens a scope frame here.
				'ClassForm',
				'AbstractClassDecl',
				'InterfaceDecl',
				'AbstractDecl',
				'EnumDecl',
				'TypedefDecl',
				'FnDecl',
				'FnExpr',
				'FnMember',
				'FinalModifiedMember',
				// A local `function f(...) {...}` statement opens its own frame —
				// without it sibling local fns' same-named params collect into the
				// ENCLOSING function's frame and reads mis-bind across siblings
				// (the CallGraph `span` collision).
				'LocalFnStmt',
				'ThinParenLambdaExpr',
				'ParenLambdaExpr',
				'BlockBody',
				'BlockExpr',
				'BlockStmt',
				'ForStmt',
				'ForExpr',
				'CatchClause',
			],
			writeParentKinds: ASSIGN_KINDS.concat(['PreIncr', 'PreDecr', 'PostIncr', 'PostDecr']),
			// Self-scoped decl kinds: scope-introducers whose own name binds
			// into the frame they open (the for-loop iterator pattern). Listed
			// in scopeKinds, absent from declHostKinds — the binding is visible
			// only inside the loop, not to enclosing-scope siblings.
			selfScopeDeclKinds: [
				'ForStmt',
				'ForExpr',
				'CatchClause',
			],
			opaqueKinds: ['MacroExpr'],
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
			callKind: 'Call',
			caseBranchKind: 'CaseBranch',
			switchKinds: ['SwitchStmt', 'SwitchStmtBare', 'SwitchExpr', 'SwitchExprBare'],
			parenKind: 'ParenExpr',
			macroModifierKind: 'Macro',
			boolLitKind: 'BoolLit',
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
			mutableLocalDeclKinds: ['VarStmt'],
			ifStatementKinds: ['IfStmt'],
			equalityKinds: ['Eq', 'NotEq'],
			optionalParamKind: 'Optional',
			restParamKind: 'Rest',
			structureFieldHostKinds: ['Anon', 'ObjectLit'],
			nullableWrapperTypeNames: ['Null', 'Dynamic', 'Any'],
			nullSafetyDisableArg: 'Off',
			nonNullableTypeNames: ['Int', 'Float', 'Bool', 'UInt'],
			nullSafetyMetaName: '@:nullSafety',
			typedCastKinds: ['TypedCastExpr', 'ECheckTypeExpr'],
			checkedCastKind: 'TypedCastExpr',
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
			visibilityContainerKinds: ['ClassDecl', 'ClassForm', 'AbstractClassDecl', 'AbstractDecl'],
			memberDeclKinds: ['VarMember', 'FinalMember', 'FnMember', 'FinalModifiedMember'],
			visibilityModifierKinds: ['Public', 'Private'],
			modifierOrderKinds: ['Override', 'Public', 'Private', 'Static', 'Inline', 'Final'],
			finalModifierMemberKind: 'FinalModifiedMember',
			finalModifierRankKind: 'Final',
			fieldDeclKinds: ['VarMember', 'FinalMember'],
			// Every `HxFnBody` ctor, `UntypedBlockBody` and `CondBody` included: a consumer reads this
			// to tell a body child from a return-type child, so a missing ctor reads as a return type
			// (or, for a boundary scan, as no body at all).
			functionBodyKinds: ['BlockBody', 'UntypedBlockBody', 'ExprBody', 'NoBody', 'CondBody'],
			enumAbstractDeclKind: 'EnumAbstractDecl',
			rawDynamicTypeName: 'Dynamic',
			bareConstructorTypeKinds: ['EnumDecl', 'EnumAbstractDecl'],
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
			stringInterpIdentKind: 'Ident',
			reservedWords: HaxeNamingSupport.KEYWORDS,

			declTypeChildKinds: ['Anon'],
			defaultBranchKind: 'DefaultBranch',
			plainCasePatternKind: 'Plain',
			wildcardPatternName: '_',
			exprStatementKind: 'ExprStmt',
			nullCoalAssignKind: 'NullCoalAssign',
			numericOperatorKinds: [
				'Add', 'Sub', 'Mul', 'Div', 'Mod', 'Lt', 'Gt', 'LtEq', 'GtEq', 'BitAnd', 'BitOr', 'BitXor', 'Shl', 'Shr', 'UShr', 'Neg',
				'BitNot',
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
				'File.append' => 'sys.io.FileOutput'
			],
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
				'WeakMap.get',
			],
			nullableReturnMarkerTypes: ['Null'],
			nullableFlowExcludedCalls: ['Array.pop', 'Array.shift', 'List.pop', 'List.first', 'List.last'],
			nullAssertionCalls: ['Assert.notNull'],
			assertTrueCalls: ['Assert.isTrue'],
			assertFalseCalls: ['Assert.isFalse'],
			mapExistsMethods: ['exists'],
			finalClassMetaName: '@:final',
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
			publicModifierKind: 'Public',
			classDeclKinds: ['ClassDecl', 'AbstractClassDecl'],
			indexedElementTypeParams: ['Map' => 1, 'Array' => 0, 'Vector' => 0],
			untypedKinds: ['UntypedExpr'],
			casePatternBinderKinds: ['Capture'],
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
			delimitedAllChildKinds: [
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
				'NewExpr',
			],
			// `Call`'s child 0 is the callee — an operand position, where parens can be
			// load-bearing (`(a ? b : c)(x)`); the arguments after it are delimited by
			// `(` / `,` / `)`. The assignment family's child 0 is likewise the target,
			// while the right-hand side is the right operand of a prec-0
			// right-associative operator, i.e. parsed at minPrec 0 up to the enclosing
			// terminator. `Interval`, `Arrow` and the other infix kinds are deliberately
			// absent: their operands parse above minPrec 0 and re-associate on unwrap.
			delimitedTailChildKinds: ['Call'].concat(ASSIGN_KINDS),
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
				'NewExpr',
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
				'DoubleStringExpr',
			],
			// A transparent link: `a.b.c` is one atom, while `f().b` / `arr[i].b` /
			// `a?.b` are not — their unlisted child stops the chain.
			atomChainKinds: ['FieldAccess'],
			// One tier each, left-associative, so `(a * b) / c` and `a * b / c` parse
			// alike. `Mod` is in NO family: Haxe binds `%` TIGHTER than `*` and `/`
			// (`2 * 7 % 4` is 6) while this parser puts it at the multiplicative tier, so
			// its own tree cannot prove a `%` re-association.
			leftAssociativeBinaryFamilies: [['Mul', 'Div'], ['Add', 'Sub']],
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
				'MetaExpr',
			],
			// Inside a `macro` quotation a paren reifies as `EParenthesis`; inside a case
			// pattern the syntax is matched structurally, not by expression precedence.
			parenOpaqueSubtreeKinds: ['MacroExpr', 'Plain'],
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
			declHostKinds: DECL_HOST_KINDS,
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
			{ wrap: HaxePatternFragment.wrapAsMetaArgs, extract: HaxePatternFragment.extractFirstMeta, category: PatternCategory.MetaArgs },
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
			final reclassified: QueryNode = Metavar.reclassify(extracted);
			return new Pattern(reclassified, attempt.category, source, SEARCH_KIND_EQUIVALENCE);
		}
		// Every attempt's parser error is offset into a synthetic wrapper
		// string, so leaking it (`expected HxDecl at 0`) only misleads.
		// Report the actionable fact: the fragment is not valid in any
		// supported pattern position.
		throw 'pattern: not valid as a declaration, statement, expression, or metadata argument'
			+ ' (a statement fragment is retried with a trailing ";" automatically; a MODIFIER-bearing declaration'
			+ ' cannot be a pattern — modifiers project as separate nodes; for those and for non-standalone fragments'
			+ ' such as object fields use `apq patch` or `replace-node --select`)';
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
		return HaxeQueryWalker.spanInfo(source);
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
		final out: Map<String, String> = [];
		final tree: Null<QueryNode> = try buildTree(source, false) catch (exception: Exception) null;
		if (tree == null) return out;
		for (node in tree.children) if (node.kind == 'ImportDecl') {
			final raw: Null<String> = node.name;
			if (raw != null) {
				final dot: Int = raw.lastIndexOf('.');
				out[dot == -1 ? raw : raw.substring(dot + 1)] = raw;
			}
		}
		for (tp in typeParamNames(source)) out.remove(tp);
		return out;
	}

	/** Lazily extract + cache the `using`-eligible method names of `modulePath` from the std source, or null when std / the module file is absent. */
	private function extensionMethodsFromStd(modulePath: String): Null<Array<String>> {
		if (_extMethodsCache.exists(modulePath)) return _extMethodsCache[modulePath];
		final computed: Null<Array<String>> = computeExtensionMethodsFromStd(modulePath);
		_extMethodsCache[modulePath] = computed;
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

	/** Every declare-site type-parameter name in the file (`class C<T>`, `function f<U>`, …). */
	private function typeParamNames(source: String): Array<String> {
		return HaxeQueryWalker.typeParamNames(source);
	}

	private function buildTree(source: String, withTypeRefs: Bool): QueryNode {
		return new QueryNode('module', null, HaxeQueryWalker.walk(source, withTypeRefs));
	}


	/** Read `<dir>/<modulePath-as-path>.hx`, or null when it does not exist / is unreadable (a non-std module then falls back to the table). */
	private static function readStdModule(dir: String, modulePath: String): Null<String> {
		#if (sys || nodejs)
		final file: String = haxe.io.Path.join([dir, modulePath.split('.').join('/') + '.hx']);
		if (!sys.FileSystem.exists(file)) return null;
		return try sys.io.File.getContent(file) catch (exception: Exception) null;
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
		for (c in fn.children) if (c.kind == 'Required' || c.kind == 'Optional' || c.kind == 'Rest') return true;
		return false;
	}


	/** The all-empty bundle returned when the source does not parse - the six maps are simply unpopulated, never null. */
	private static function emptySpanTypeInfo(): SpanTypeInfo {
		return {
			declaredTypes: [],
			returnTypes: [],
			propertyAccessors: [],
			propertyWriteAccessors: [],
			declaredTypeSources: [],
			castTargetSources: []
		};
	}

}
