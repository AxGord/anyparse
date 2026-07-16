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
final class HaxeQueryPlugin implements GrammarPlugin implements TypeInfoProvider {

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
	 * Extension-method names that `using <module>` brings into scope, for the
	 * Haxe standard-library modules used with `using` in practice. Sourced from
	 * the installed Haxe std (every `FnMember` of each module), so the set is
	 * complete: `unused-import` deletes a `using` only when NONE of these is
	 * called, and a missing name would risk deleting a live `using`. A superset
	 * name is harmless — it only makes the "used" test more generous.
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
			writeParentKinds: [
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
				'PreIncr',
				'PreDecr',
				'PostIncr',
				'PostDecr',
			],
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
			localDeclKinds: ['VarStmt', 'FinalStmt'],
			mutableLocalDeclKinds: ['VarStmt'],
			ifStatementKinds: ['IfStmt'],
			equalityKinds: ['Eq', 'NotEq'],
			optionalParamKind: 'Optional',
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
			eqKind: 'Eq',
			notEqKind: 'NotEq',
			newExprKind: 'NewExpr',
			fieldAccessKind: 'FieldAccess',
			returnStatementKind: 'ReturnStmt',
			conditionFirstChildKinds: ['IfStmt', 'IfExpr', 'WhileStmt', 'WhileExpr'],
			conditionLastChildKinds: ['DoWhileStmt'],
			parenLambdaKind: 'ThinParenLambdaExpr',
			forStmtKind: 'ForStmt',
			paramKinds: ['Required', 'Optional', 'Rest'],
			supertypeClauseKinds: ['ExtendsClause', 'ImplementsClause'],
			noBodyKind: 'NoBody',
			catchClauseKind: 'CatchClause',
			catchAllTypeNames: ['Dynamic', 'Any'],
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
			functionBodyKinds: ['BlockBody', 'ExprBody', 'NoBody'],
			enumAbstractDeclKind: 'EnumAbstractDecl',
			bareConstructorTypeKinds: ['EnumDecl', 'EnumAbstractDecl'],
			overrideModifierKind: 'Override',
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
			negationKind: 'Neg',
			objectFieldKind: 'Field',
			sizeFieldNames: ['length'],
			positionMethodNames: ['substr', 'substring', 'charAt', 'charCodeAt', 'indexOf', 'lastIndexOf', 'hex'],
			additiveKinds: ['Add', 'Sub'],
			staticModifierKind: 'Static',
			constructorName: 'new',
			accessorMethodPrefixes: ['get_', 'set_'],
			conditionalMemberKind: 'Conditional',
			conditionalIfKeyword: '#if',
			conditionalElseKeywords: ['#else', '#elseif'],
			stringInterpIdentKind: 'Ident',

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
			finalClassMetaName: '@:final',
			plainClassDeclKind: 'ClassDecl',
			finalClassDeclKind: 'FinalDecl',
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
			{ wrap: src -> src, extract: extractFirstDecl, category: PatternCategory.Decl },
			{ wrap: wrapAsStmt, extract: extractFirstStmt, category: PatternCategory.Stmt },
			{ wrap: wrapAsExpr, extract: extractFirstExpr, category: PatternCategory.Expr },
			{ wrap: wrapAsMetaArgs, extract: extractFirstMeta, category: PatternCategory.MetaArgs },
		];
		// A declaration / statement fragment whose only defect is the missing
		// terminator (`final x:T = []`) parses with a `;` appended — retried as a
		// SECOND variant through the SAME category ladder, so it lands in its
		// proper category with correct spans (a single-category retry mis-spans).
		for (variant in [substituted, substituted + ';']) for (attempt in attempts) {
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
			if (attempt.category == PatternCategory.Decl && !consumesVariant(extracted, variant)) continue;
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

	public function knownExtensionMethods(modulePath: String): Null<Array<String>> {
		return EXTENSION_METHODS[modulePath];
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
		return walkSpanMap(source, (node, span, out: Map<Int, String>) -> {
			if (Reflect.hasField(node, 'type')) {
				final nm: Null<String> = nominalTypeName(Reflect.field(node, 'type'));
				if (nm != null) out[span.from] = nm;
			}
		});
	}

	public function returnTypes(source: String): Map<Int, String> {
		return walkSpanMap(source, (node, span, out: Map<Int, String>) -> {
			if (Reflect.hasField(node, 'returnType')) {
				final nm: Null<String> = nominalTypeName(Reflect.field(node, 'returnType'));
				if (nm != null) out[span.from] = nm;
			}
		});
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
		return walkSpanMap(source, (node, span, out: Map<Int, Bool>) -> {
			if (Reflect.hasField(node, 'access')) {
				final access: Dynamic = Reflect.field(node, 'access');
				if (access != null) out[span.from] = isGetterAccess(access);
			}
		});
	}

	/**
	 * `TypeInfoProvider`: maps each declaration's binding-span `from` to the VERBATIM
	 * source of its `:Type` annotation (`var x: Array<Int>` → `Array<Int>`), recovered
	 * by slicing the type node's span. Same walk + key as `declaredTypes`; the value is
	 * the written form rather than the package-stripped simple name.
	 */
	public function declaredTypeSources(source: String): Map<Int, String> {
		return walkSpanMap(source, (node, span, out: Map<Int, String>) -> {
			if (Reflect.hasField(node, 'type')) {
				final ts: Null<Span> = typeFieldSpan(Reflect.field(node, 'type'));
				if (ts != null) out[span.from] = source.substring(ts.from, ts.to);
			}
		});
	}

	/**
	 * `TypeInfoProvider`: maps each typed-cast / type-check node's payload `_span.from`
	 * to the VERBATIM source of its TARGET type (`cast(x, Array<Int>)` → `Array<Int>`).
	 * Same discriminated walk as the simple-name cast recovery (a `type` field plus an
	 * operand `target` / `expr`, no `name`), but the value is the written type source.
	 */
	public function castTargetSources(source: String): Map<Int, String> {
		return walkSpanMap(source, (node, span, out: Map<Int, String>) -> {
			if (
				Reflect.hasField(node, 'type') && !Reflect.hasField(node, 'name')
				&& (Reflect.hasField(node, 'target') || Reflect.hasField(node, 'expr'))
			) {
				final ts: Null<Span> = typeFieldSpan(Reflect.field(node, 'type'));
				if (ts != null) out[span.from] = source.substring(ts.from, ts.to);
			}
		});
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

	/** Every declare-site type-parameter name in the file (`class C<T>`, `function f<U>`, …). */
	private function typeParamNames(source: String): Array<String> {
		final names: Array<String> = [];
		final root: Null<Dynamic> = try HaxeModuleSpanParser.parse(source) catch (exception: Exception) null;
		if (root == null) return names;
		walkGrammarSpans(Reflect.field(root, 'decls'), null, (node, _span) -> {
			if (Reflect.hasField(node, 'constraintMore') && Reflect.hasField(node, 'name')) {
				final nm: Null<String> = extractName(Reflect.field(node, 'name'));
				if (nm != null && !names.contains(nm)) names.push(nm);
			}
		});
		return names;
	}

	private function buildTree(source: String, withTypeRefs: Bool): QueryNode {
		final root: Dynamic = HaxeModuleSpanParser.parse(source);
		final children: Array<QueryNode> = [];
		appendNodes(Reflect.field(root, 'decls'), children, withTypeRefs);
		return new QueryNode('module', null, orderBySpan(children));
	}

	private function appendNodes(value: Dynamic, into: Array<QueryNode>, withTypeRefs: Bool): Void {
		if (isLeafValue(value)) return;
		final t: Type.ValueType = Type.typeof(value);
		switch t {
			case TEnum(_):
				into.push(makeEnumNode(value, withTypeRefs));
			case TObject:
				if (Reflect.hasField(value, 'node')) {
					appendNodes(Reflect.field(value, 'node'), into, withTypeRefs);
					return;
				}
				// `@:spanned('<Kind>')` Seq structs carry `_kind` + `_span`
				// (see SpanTypeSynth / Lowering ω-spanned-struct): surface
				// them as addressable nodes instead of descending
				// transparently, so decl-bearing transparent structs (catch
				// clause, lambda param) resolve in `apq refs`.
				final kindVal: Dynamic = Reflect.hasField(value, '_kind') ? Reflect.field(value, '_kind') : null;
				final spanVal: Dynamic = Reflect.hasField(value, '_span') ? Reflect.field(value, '_span') : null;
				if (kindVal is String && Std.isOfType(spanVal, Span)) {
					appendSpannedStruct(value, into, withTypeRefs, kindVal, cast spanVal);
					return;
				}
				appendObjectFields(value, into, withTypeRefs);
			case TClass(_):
				if (Std.isOfType(value, Array)) {
					final arr: Array<Dynamic> = cast value;
					for (e in arr) appendNodes(e, into, withTypeRefs);
				}
			case _:
		}
	}

	/**
	 * Emits one addressable node for a `@:spanned('<Kind>')` Seq struct
	 * (`kindStr` + `spanObj` lifted from its `_kind` / `_span` fields),
	 * descending its non-meta fields into the node's children.
	 */
	private function appendSpannedStruct(value: Dynamic, into: Array<QueryNode>, withTypeRefs: Bool, kindStr: String, spanObj: Span): Void {
		final children: Array<QueryNode> = [];
		for (field in Reflect.fields(value)) if (!(field == 'name' || field == '_span' || field == '_kind')) {
			// Mirror the generic branch: descend an anon-struct
			// `type` (decl-host members), skip name-slot type-refs.
			if (field == 'type' && !isAnonType(Reflect.field(value, 'type'))) {
				if (withTypeRefs) appendTypeRefs(Reflect.field(value, 'type'), children, spanObj);
				continue;
			}
			appendNodes(Reflect.field(value, field), children, withTypeRefs);
		}
		into.push(new QueryNode(kindStr, extractName(value), orderBySpan(children), spanObj));
	}

	/**
	 * Descends the fields of a plain (non-`node`, non-spanned) anon
	 * struct into `into`, applying the name-slot / type-ref skip rules.
	 */
	private function appendObjectFields(value: Dynamic, into: Array<QueryNode>, withTypeRefs: Bool): Void {
		for (field in Reflect.fields(value)) if (field != 'name') {
			// `type` is normally a name-slot leaf (`new T(...)`,
			// `var x:Foo`) and skipped — but an anon struct type
			// (`typedef T = {…}`, `var x:{…}`) carries decl-host
			// members + their metadata, so descend it. `HxType` is
			// an enum; the `Anon` ctor gate keeps `Named` type-refs
			// skipped (no phantom child per typed binding) — unless
			// `withTypeRefs` (the `parseFileTypeRefs` projection for
			// `apq uses`), where the skipped name-slot type is
			// surfaced as `TypeRef` node(s) instead.
			if (field == 'type' && !isAnonType(Reflect.field(value, 'type'))) {
				if (withTypeRefs) appendTypeRefs(Reflect.field(value, 'type'), into, null);
				continue;
			}
			appendNodes(Reflect.field(value, field), into, withTypeRefs);
		}
	}

	private function makeEnumNode(value: Dynamic, withTypeRefs: Bool): QueryNode {
		final ctor: String = Type.enumConstructor(value);
		final params: Array<Dynamic> = Type.enumParameters(value);
		var name: Null<String> = null;
		var span: Null<Span> = null;
		final children: Array<QueryNode> = [];
		for (p in params) {
			if (Std.isOfType(p, Span)) {
				span = cast p;
				continue;
			}
			if (name == null) name = extractName(p);
			appendNodes(p, children, withTypeRefs);
		}
		return new QueryNode(ctor, name, orderBySpan(children), span);
	}

	/**
	 * Surface every nominal type name inside an `HxType` value as a
	 * `TypeRef` `QueryNode` — used only by the `parseFileTypeRefs`
	 * projection (`apq uses`). `Array<HxVarMore>` emits `TypeRef(Array)`
	 * and `TypeRef(HxVarMore)` (the campaign cares about the inner
	 * grammar type). Spans come from the span-mode `HxType` enum's own
	 * `Span` param; `fallbackSpan` (the enclosing decl/struct span)
	 * covers values that carry none. A node with no resolvable span is
	 * dropped — consistent with the `Refs` walker's not-addressable rule.
	 * `Anon` is intentionally not handled here: the anon-struct body is
	 * surfaced by the existing decl-host descent in `appendNodes`.
	 */
	private function appendTypeRefs(value: Dynamic, into: Array<QueryNode>, fallbackSpan: Null<Span>): Void {
		if (isLeafValue(value)) return;
		final t: Type.ValueType = Type.typeof(value);
		switch t {
			case TEnum(_):
				appendTypeRefsEnum(value, into, fallbackSpan);
			case TObject:
				if (Reflect.hasField(value, 'node')) {
					appendTypeRefs(Reflect.field(value, 'node'), into, fallbackSpan);
					return;
				}
				// `HxTypeRef` (name slot already emitted by the `Named`
				// arm) — descend `params` for nested type refs; skip the
				// `name` String leaf.
				for (field in Reflect.fields(value)) if (!(field == 'name' || field == '_span' || field == '_kind')) {
					appendTypeRefs(Reflect.field(value, field), into, fallbackSpan);
				}
			case TClass(_):
				if (Std.isOfType(value, Array)) {
					final arr: Array<Dynamic> = cast value;
					for (e in arr) appendTypeRefs(e, into, fallbackSpan);
				}
			case _:
		}
	}

	/**
	 * Surfaces type-ref nodes from an `HxType` enum value: the `Named` /
	 * `DollarType` name slot becomes a `TypeRef`, and every operand is
	 * recursed for nested type parameters. `Anon` is skipped (handled by
	 * the decl-host descent in `appendNodes`).
	 */
	private function appendTypeRefsEnum(value: Dynamic, into: Array<QueryNode>, fallbackSpan: Null<Span>): Void {
		final ctor: String = Type.enumConstructor(value);
		final params: Array<Dynamic> = Type.enumParameters(value);
		var span: Null<Span> = fallbackSpan;
		for (p in params) if (Std.isOfType(p, Span)) span = cast p;
		switch ctor {
			case 'Anon':
				// handled by the decl-host descent, not here
			case 'Named' | 'DollarType':
				appendNamedTypeRef(params, into, span);
			case _:
				// Arrow / ArrowFn / Parens / … — recurse operands
				for (p in params) if (!Std.isOfType(p, Span))
					appendTypeRefs(p, into, span);
		}
	}

	/**
	 * Emits the `TypeRef` node for a `Named` / `DollarType` head and
	 * recurses its type parameters. Reads the first non-`Span` operand.
	 */
	private function appendNamedTypeRef(params: Array<Dynamic>, into: Array<QueryNode>, span: Null<Span>): Void {
		for (p in params) if (!Std.isOfType(p, Span)) {
			final nm: Null<String> = extractName(p);
			if (nm != null && span != null) into.push(new QueryNode('TypeRef', nm, [], span));
			// recurse type parameters (`Array<HxVarMore>`)
			appendTypeRefs(p, into, span);
			break;
		}
	}

	private function extractName(value: Dynamic): Null<String> {
		if (value == null) return null;
		if (value is String) return value;
		final t: Type.ValueType = Type.typeof(value);
		switch t {
			case TObject:
				// Try canonical name slots in priority order. `name` is the
				// common case (HxClassDecl, HxFnDecl, ...); `type` covers
				// `new T(...)` (HxNewExpr) and similar nominally-typed
				// nodes; `varName` covers for-loop iterators (HxForStmt /
				// HxForExpr); `node` unwraps Trivial<T> envelopes for the
				// future Trivia + span composition.
				for (field in ['name', 'type', 'varName']) if (Reflect.hasField(value, field)) {
					final n: Dynamic = Reflect.field(value, field);
					if (n is String) return n;
				}
				// `param` unwraps HxCatchClause / HxCatchClauseStmtBare /
				// HxCatchClauseExpr — the catch-param shape (name + optional
				// `:Type`) lives in `param:HxCatchParam`, lifted there to
				// support the bare `catch (name)` form (e.g. `catch (_)`).
				// Mirror of the `node` unwrap for Trivial<T> envelopes.
				if (Reflect.hasField(value, 'param')) return extractName(Reflect.field(value, 'param'));
				if (Reflect.hasField(value, 'node')) return extractName(Reflect.field(value, 'node'));
				// `fn` unwraps `HxFinalModifierMember` — the
				// `{ modifiers, fn:HxFnDecl }` body of a `final` METHOD
				// (`HxClassMember.FinalModifiedMember`). The method name lives
				// on the inner `HxFnDecl`, so surface it onto the
				// `FinalModifiedMember` node — parity with the plain `FnMember`,
				// whose `HxFnDecl` is the ctor's direct param. Self-guarding: a
				// non-name-bearing `fn` value (lambda `HxFnExpr` / arrow
				// `HxArrowFnType`) yields null, and those are reached as `fn`
				// VALUES of an enum ctor, never as a struct CARRYING an `fn`
				// field — so no other node is affected.
				if (Reflect.hasField(value, 'fn')) return extractName(Reflect.field(value, 'fn'));
			case TEnum(_):
				// Slice 27 — transparent unwrap for the single-Ref wrapper
				// enum `HxAnonVarBody` (`Optional(decl)` / `Plain(decl)`):
				// `HxAnonField.VarField` / `FinalField` now carries a post-
				// keyword-`?` Alt-enum wrapper, so the name slot lives one
				// level deeper than before. Scoped by ctor name to avoid
				// surfacing names from arbitrary enum ctor payloads (the
				// general TEnum recurse broke pattern-matcher
				// `extractFirstExpr` / etc., which rely on name being null
				// for non-decl enum nodes).
				final ctor: String = Type.enumConstructor(value);
				if (ctor == 'Optional' || ctor == 'Plain') {
					final params: Array<Dynamic> = Type.enumParameters(value);
					for (p in params) if (!Std.isOfType(p, Span)) {
						final n: Null<String> = extractName(p);
						if (n != null) return n;
					}
				}
			case _:
		}
		return null;
	}

	/** Simple name of a nominal `HxType.Named(payload)` (the name lives on the payload struct), else null. */
	private function nominalTypeName(typeVal: Dynamic): Null<String> {
		if (typeVal == null || !Type.typeof(typeVal).match(TEnum(_))) return null;
		if (Type.enumConstructor(typeVal) != 'Named') return null;
		for (p in Type.enumParameters(typeVal)) if (!Std.isOfType(p, Span)) {
			final nm: Null<String> = extractName(p);
			if (nm != null) {
				final dot: Int = nm.lastIndexOf('.');
				return dot == -1 ? nm : nm.substring(dot + 1);
			}
		}
		return null;
	}

	/** The span of an `HxType` value — the `Named` ctor's `Span` param — or null when absent. */
	private function typeFieldSpan(typeVal: Dynamic): Null<Span> {
		if (typeVal == null || !Type.typeof(typeVal).match(TEnum(_))) return null;
		for (p in Type.enumParameters(typeVal)) if (Std.isOfType(p, Span)) return cast p;
		return null;
	}

	/**
	 * Whether an `HxAccessClause`'s READ accessor (`ids[0]`) runs code on read — a
	 * getter. Only the three stored-field reads `default` / `null` / `never` are
	 * side-effect-free; everything else (`get`, `dynamic`, or a custom method-name
	 * accessor) is treated as a getter, so the classification is sound by default.
	 */
	private function isGetterAccess(access: Dynamic): Bool {
		final ids: Dynamic = Reflect.field(access, 'ids');
		if (!Std.isOfType(ids, Array)) return true;
		final arr: Array<Dynamic> = cast ids;
		if (arr.length == 0) return true;
		final first: Dynamic = arr[0];
		if (!(first is String)) return true;
		final s: String = first;
		return !(s == 'default' || s == 'null' || s == 'never');
	}

	/**
	 * Walk the raw grammar AST (which the QueryNode projection drops type/accessor
	 * detail from), invoking `visit(node, span)` for every spanned struct node with
	 * the nearest enclosing binding span threaded down — an enum decl ctor carries
	 * the span as a `Span` param, its payload struct carries `type`/`access` with no
	 * own `_span`. The shared traversal for `declaredTypes` / `propertyAccessors`.
	 */
	private function walkGrammarSpans(value: Dynamic, currentSpan: Null<Span>, visit: (Dynamic, Null<Span>) -> Void): Void {
		if (value == null || (value is String) || Std.isOfType(value, Span)) return;
		final t: Type.ValueType = Type.typeof(value);
		switch t {
			case TEnum(_):
				final params: Array<Dynamic> = Type.enumParameters(value);
				var span: Null<Span> = currentSpan;
				for (p in params) if (Std.isOfType(p, Span)) span = cast p;
				for (p in params) if (!Std.isOfType(p, Span))
					walkGrammarSpans(p, span, visit);
			case TObject:
				final spanField: Dynamic = Reflect.hasField(value, '_span') ? Reflect.field(value, '_span') : null;
				final span: Null<Span> = Std.isOfType(spanField, Span) ? cast spanField : currentSpan;
				visit(value, span);
				for (field in Reflect.fields(value)) walkGrammarSpans(Reflect.field(value, field), span, visit);
			case TClass(_):
				if (Std.isOfType(value, Array)) {
					final arr: Array<Dynamic> = cast value;
					for (e in arr) walkGrammarSpans(e, currentSpan, visit);
				}
			case _:
		}
	}

	/**
	 * Parse `source` and fold every grammar-span-bearing node into a
	 * `Map<Int, V>` keyed on the node's `span.from`. `visit` writes the
	 * value(s) for a node into `out` (see `declaredTypes` et al.); it runs
	 * only for nodes carrying a non-null span. An unparseable source yields
	 * an empty map.
	 */
	private function walkSpanMap<V>(source: String, visit: (node:Dynamic, span:Span, out:Map<Int, V>) -> Void): Map<Int, V> {
		final out: Map<Int, V> = [];
		final root: Null<Dynamic> = try HaxeModuleSpanParser.parse(source) catch (exception: Exception) null;
		if (root == null) return out;
		walkGrammarSpans(Reflect.field(root, 'decls'), null, (node, span) -> {
			if (span != null) visit(node, span, out);
		});
		return out;
	}

	/** A non-structural leaf the grammar walkers skip: null, a `String`, or a `Span`. */
	private inline function isLeafValue(value: Dynamic): Bool {
		return value == null || value is String || Std.isOfType(value, Span);
	}

	/**
	 * Whether the extracted pattern root's span covers (nearly) the whole
	 * variant text — the guard against a partial Decl extraction (slack of one
	 * byte tolerates a span that excludes the trailing `;`).
	 */
	private static function consumesVariant(extracted: QueryNode, variant: String): Bool {
		final span: Null<Span> = extracted.span;
		return span == null || span.to - span.from >= StringTools.trim(variant).length - 1;
	}

	private static function wrapAsStmt(src: String): String {
		return 'class _ApqPattern { static function _apq() { ${trimTrailingSemicolons(src)}; } }';
	}

	private static function wrapAsExpr(src: String): String {
		return 'class _ApqPattern { static function _apq() { var _v = ${trimTrailingSemicolons(src)}; } }';
	}

	/**
	 * Drop the trailing run of `;` and whitespace from a pattern fragment.
	 * A statement or expression pattern is naturally written with a
	 * closing `;` (`return $_;`), but `wrapAsStmt` / `wrapAsExpr` append
	 * their own `;`; without trimming, the wrapped source becomes `…;;`
	 * and the Haxe grammar — which has no empty-statement production —
	 * rejects it, failing the whole cascade on a valid statement pattern.
	 * The unwrapped decl attempt keeps the original source (a
	 * `typedef X = Y;` decl pattern needs its `;`), so the trim is scoped
	 * to the wrappers only.
	 */
	private static function trimTrailingSemicolons(src: String): String {
		var end: Int = src.length;
		while (end > 0) {
			final c: Int = StringTools.fastCodeAt(src, end - 1);
			if (c == ';'.code || c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code)
				end--;
			else
				break;
		}
		return src.substring(0, end);
	}

	private static function wrapAsMetaArgs(src: String): String {
		return 'class _ApqPattern { $src var _v:Int = 0; }';
	}

	private static function extractFirstDecl(module: QueryNode): Null<QueryNode> {
		return module.children.length == 0 ? null : module.children[0];
	}

	private static function extractFirstStmt(module: QueryNode): Null<QueryNode> {
		// module → ClassDecl wrapper → FunctionField → FnDecl struct →
		// HxFnBody.BlockBody (enum) → HxFnBlock struct (flattened) →
		// stmts[0]. We navigate by enum kind names; struct envelopes are
		// transparent in the QueryNode tree.
		final cls: Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		if (cls == null) return null;
		final block: Null<QueryNode> = findFirstByKind(cls, 'BlockBody');
		if (block == null) return null;
		if (block.children.length == 0) return null;
		final first: QueryNode = block.children[0];
		// A bare expression-statement pattern (`$a + $b`, `$f($_)`,
		// `trace($_);`) wraps its expression in a synthetic `ExprStmt`
		// node. Returning that wrapper as the pattern root constrains
		// matches to statement position only — the expression stays
		// invisible in var-init / argument / sub-expression position (the
		// common case). Reject it so the cascade proceeds to the Expr
		// attempt, which yields the bare expression as the root; the
		// matcher then walks every subtree and finds it anywhere.
		// Non-expression statements (if/for/while/return/var/switch/try/
		// throw) are not `ExprStmt` and pass through unchanged. Node-level
		// analog of the `trimTrailingSemicolons` wrapper-artifact fix (#3).
		return first.kind == 'ExprStmt' ? null : first;
	}

	private static function extractFirstExpr(module: QueryNode): Null<QueryNode> {
		final cls: Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		if (cls == null) return null;
		final varStmt: Null<QueryNode> = findFirstByKind(cls, 'VarStmt');
		return varStmt == null ? null : varStmt.children.length == 0 ? null : varStmt.children[varStmt.children.length - 1];
	}

	private static function extractFirstMeta(module: QueryNode): Null<QueryNode> {
		final cls: Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		return cls == null ? null : findFirstByKind(cls, 'HxMeta') ?? findFirstByKind(cls, 'Meta') ?? findFirstByKindPrefix(cls, 'Meta');
	}

	private static function findFirstByKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = findFirstByKind(c, kind);
			if (found != null) return found;
		}
		return null;
	}

	private static function findFirstByKindPrefix(node: QueryNode, prefix: String): Null<QueryNode> {
		if (StringTools.startsWith(node.kind, prefix)) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = findFirstByKindPrefix(c, prefix);
			if (found != null) return found;
		}
		return null;
	}


	/**
	 * True when `v` is an `HxType.Anon` enum value — the anon-struct
	 * type whose `fields` carry decl-host members + their metadata.
	 * Gates the `appendNodes` `type`-field descent so only anon
	 * bodies surface; `Named` / `Arrow` / `Parens` type-refs stay
	 * skipped (descending them would emit a phantom child per typed
	 * binding).
	 */
	private static inline function isAnonType(v: Dynamic): Bool {
		if (v == null) return false;
		final t: Type.ValueType = Type.typeof(v);
		return switch t {
			case TEnum(_): Type.enumConstructor(v) == 'Anon';
			case _: false;
		}
	}

	/**
	 * Order a node's children by source position so the `apq ast`
	 * dump is engine-independent. `appendNodes` flattens struct
	 * fields via `Reflect.fields`, whose iteration order is
	 * target-defined (neko hash order vs js insertion order), so
	 * without this the then-body / else-body of an `IfStmt` (and any
	 * other struct-bearing node) surface in different order on neko
	 * vs node. Stable sort by span start; left untouched unless every
	 * child carries a span, since a span-less node has no defined
	 * source position to order against.
	 */
	private static function orderBySpan(children: Array<QueryNode>): Array<QueryNode> {
		final indexed: Array<{ from: Int, idx: Int, node: QueryNode }> = [];
		for (i in 0...children.length) {
			final s: Null<Span> = children[i].span;
			if (s == null) return children;
			indexed.push({ from: s.from, idx: i, node: children[i] });
		}
		indexed.sort((a, b) -> a.from != b.from ? a.from - b.from : a.idx - b.idx);
		return [for (e in indexed) e.node];
	}

}
