package unit.query;

import anyparse.grammar.haxe.HaxeQueryWalker;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.cli.CliArgs;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.ds.StringMap;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

/**
 * Every kind name a grammar plugin DECLARES, against every kind name its parser PROJECTS.
 *
 * `RefShape` publishes a few hundred fields, most of which carry a kind name or a set of them, and a kind set is
 * an `Array<String>`. The exact counts are read off the tree by the assertions below and move with every field a
 * slice adds, so they live in the `MIN_*` floors rather than in this sentence: a snapshot quoted here would be
 * wrong by the next slice and read as a fact. A name the grammar stopped spelling — or never spelled — therefore
 * costs nothing at compile time and fails OPEN at run time: the walker never matches that
 * kind, so a query silently does not see the node and every consumer reading the set loses
 * a case with no diagnostic anywhere. `HxArrowParam.Named` was the same seam from the other
 * side — a spelling two `@:peg` enums SHARED, which made `uses` / `rename` read an
 * arrow-parameter label as a type — and a kind set cannot say which rule it means.
 *
 * The two sides have different authors, which is what makes the comparison worth running:
 * the declared side is hand-typed in `HaxeQueryPlugin.refShape`, the projected side is
 * `HaxeQueryWalker.projectedKinds()`, emitted by `QueryWalkerLowering` from the same grammar
 * shape the walk itself is generated from. Nothing else in the tree compares them.
 *
 * The catch on the first run was `LambdaParam`: dead since `327ae658` (2026-05-22) turned
 * `HxLambdaParam` from a `@:spanned('LambdaParam')` typedef into an `Optional` / `Required`
 * Alt enum, and left the retired kind behind in three kind lists and two doc sentences. Its
 * repair is a DELETION, not a grammar edit — the two ctors that replaced it were already
 * declared, so minting the old kind again would change the tree every consumer reads.
 *
 * Scope, stated: the fields this reads are `RefShape`'s, and it reads them along two axes — kind NAMES against the projected
 * vocabulary, and declared TOKENS against what a parse of the smallest source carrying them shows, by NAME where the grammar names
 * one and by span where it does not. A third axis reads the projected vocabulary alone: every kind it holds has to be one some
 * source can make the parser emit, or a name this file declares unreachable and says why (`KIND_SOURCES` / `UNREACHABLE_KINDS`). A
 * structure-valued field IS descended into (a kind name nested in one used to pass both arms); a class INSTANCE is not,
 * which today means `refsCache` and the engine caches behind it. Kind vocabularies hardcoded OUTSIDE `RefShape` —
 * `FieldRefScan.bindsNameHere`, `HaxeNamingSupport.categoryOf` — carry the same hazard and are still not reachable from here.
 */
@:nullSafety(Strict)
final class RefShapeKindProjectionTest extends Test {

	/** Floor under the number of `RefShape` fields the declared side reads (178 of 238 on this tree). */
	private static inline final MIN_KIND_FIELDS: Int = 160;

	/** Floor under the distinct kind names those fields declare (202 on this tree). */
	private static inline final MIN_DECLARED_KINDS: Int = 185;

	/** Floor under the projected vocabulary the declarations are checked against (238 on this tree). */
	private static inline final MIN_PROJECTED_KINDS: Int = 220;

	/**
	 * Floor under the distinct kinds the parse arm sees the tree's own sources emit (140 of the
	 * 238 projected, over 516 files — 137 before this arm learned to descend the `type` SLOT).
	 *
	 * The gap is what this repo happens to spell: no `do while`, no `untyped`, no `overload`, no `>>>=`, so
	 * a ctor for one of those cannot be seen missing from here. That direction used to be the declared-side
	 * arm's job alone and is now `KIND_SOURCES`', which covers the 98 kinds this corpus does not reach.
	 */
	private static inline final MIN_EMITTED_KINDS: Int = 130;

	/** Floor under the number of `.hx` files the parse arm reaches — an empty walk asserts nothing. */
	private static inline final MIN_PARSED_FILES: Int = 450;

	/** Floor under the token-bearing slots the capture differential probes (35 on this tree). */
	private static inline final MIN_TOKEN_SLOTS: Int = 28;

	/** A capture probe whose projected node NAMES the token: the assertion is name EQUALITY. */
	private static inline final NAME_IS: String = 'is';

	/** A capture probe whose token OPENS the projected name: the assertion is a name PREFIX. */
	private static inline final NAME_OPENS: String = 'opens';

	/** A capture probe whose projected node names something else, or nothing: the assertion is span containment. */
	private static inline final NAME_NONE: String = 'none';

	/**
	 * The `RefShape` fields that hold kind names without saying `Kind` in their name.
	 *
	 * `leftAssociativeBinaryFamilies` is `Array<Array<String>>` of operator KINDS grouped by
	 * precedence tier. Its name describes the grouping, not the contents, so the name-based
	 * reading would skip it — and `testNoUnclassifiedFieldCarriesAProjectedKindName` is what
	 * stops a future field from being skipped the same way in silence.
	 */
	private static final EXTRA_KIND_FIELDS: Array<String> = ['leftAssociativeBinaryFamilies'];

	/**
	 * Fields carrying a TYPE or method name that merely COINCIDES with a projected kind.
	 *
	 * Every entry here is `Dynamic`: the Haxe grammar spells `dynamic` as a member modifier,
	 * so the modifier ctor and the type name are the same six letters. A field listed here is
	 * NOT checked against the projected vocabulary — a type name has no business being one.
	 */
	private static final KIND_LOOKALIKE_FIELDS: Array<String> = [
		'catchAllTypeNames',
		'nullableWrapperTypeNames',
		'rawDynamicTypeName',
		'staticMethodReturns'
	];

	/**
	 * Fields whose value is a KEYWORD the parser captures, spelled like an identifier.
	 *
	 * The token census below derives its own membership — a string carrying a character no
	 * identifier may hold is a token, and a field carrying one has to be probed. That derivation
	 * cannot see these: `this`, `super`, `new`, `private` and `_` are name-shaped, and nothing
	 * separates them from `Bool` or `haxe.Exception`, which are library names with no parser-side
	 * oracle at all. So they are named here, and the census requires each to be probed AND still
	 * declared — the derivation is what fails by default, this list is what stops the five known
	 * keyword fields from falling out of it silently.
	 */
	private static final KEYWORD_TOKEN_FIELDS: Array<String> = [
		'constructorName',
		'defaultVisibilityModifierText',
		'selfReferenceText',
		'superReferenceText',
		'wildcardPatternName'
	];

	/**
	 * Slots whose token-shaped string is an EMISSION template, not text any parse captures.
	 *
	 * `enumAbstractSyntax.head` is the whole list: it carries `{name}` / `{under}` holes a fixer
	 * fills, so no source slice can ever contain it verbatim and a capture probe would be asserting
	 * the wrong thing. What owns it is the check that emits it
	 * (`unit.check.PreferEnumAbstractCheckTest`, over the produced fix text) — recorded here so the
	 * census admits the slot by ADDRESS and a second template slot cannot join it in silence.
	 *
	 * Addressed by `<field>#<slot>` and not by field, which is the S203 repair: the exemption used to
	 * name `enumAbstractSyntax` WHOLE, and the same structure's `bodyOpen: '{'` is a real token the
	 * parser does capture — freed as a template by a field it merely shares, and probed by nothing
	 * for it.
	 */
	private static final TEMPLATE_SLOTS: Array<String> = ['enumAbstractSyntax#head'];

	/**
	 * Per grammar, one probe per token-bearing slot: the smallest source that can carry the
	 * token, and the kind the parse must project for it to count as CAPTURED.
	 *
	 * `slot` addresses the string INSIDE the field's value — `''` for a plain `String` field, an
	 * index for an array, a key for a map, a field name for an anonymous structure — so a probe
	 * reads the shape's OWN text instead of a copy of it. That is what makes this a differential
	 * and not a string compare: a token that drifts is parsed in its NEW spelling, and the arm goes red on the parse rather
	 * than on an equality nobody wrote down. `names` says what the parse has to show, and it is the sharp half of the record. `NAME_IS`
	 * — 20 slots — demands that a node of `kind` be NAMED exactly the token: the four identifier keywords (`this`, `super`, `new`, `_`)
	 * and the sixteen `@:<name>` metadata fields, where `Meta` is projected for any name at all and its span is the whole declaration
	 * (`@:keepx class C {}` is `(Meta @:keepx)`), so span containment proved only that the token PARSES in that position. `NAME_OPENS`
	 * — 3 slots — demands that the token open the projected name, which is what a delimiter can claim: the `@:` / `@` prefixes of a
	 * metadata name, and the quote a `DoubleStringExpr` carries. `NAME_NONE` — 12 slots — is span containment, and it is the honest
	 * answer where the grammar names nothing (the operators, the `#if` family, the paren and bracket delimiters, `private`) or names
	 * something else entirely (`enumAbstractSyntax.bodyOpen`, whose `EnumAbstractDecl` is named for the type, not for its brace). Those
	 * twelve still discriminate: their drift stops the parse or changes the kind. A `NAME_NONE` slot whose kind DOES name the token is
	 * reported and has to be promoted — that is the direction this classification fails closed in. `before` / `after` wrap
	 * it. A probe that needs the token TWICE — a string delimiter closes what it opened — spells
	 * the second occurrence as a literal in `after`, the same way the paren and bracket probes
	 * hold their partner fixed while varying one end.
	 */
	private static final TOKEN_PROBES: Map<String, Array<TokenProbe>> = [
		'haxe' => [
			{
				field: 'andOperatorText',
				slot: '',
				kind: 'And',
				names: NAME_NONE,
				before: 'class C { function f() { var a = b ',
				after: ' c; } }'
			},
			{
				field: 'conditionalElseKeywords',
				slot: '0',
				kind: 'Conditional',
				names: NAME_NONE,
				before: '#if js\nclass C {}\n',
				after: '\nclass D {}\n#end\n'
			},
			{
				field: 'conditionalElseKeywords',
				slot: '1',
				kind: 'Conditional',
				names: NAME_NONE,
				before: '#if js\nclass C {}\n',
				after: ' cpp\nclass D {}\n#end\n'
			},
			{
				field: 'conditionalEndKeyword',
				slot: '',
				kind: 'Conditional',
				names: NAME_NONE,
				before: '#if js\nclass C {}\n',
				after: '\n'
			},
			{
				field: 'conditionalIfKeyword',
				slot: '',
				kind: 'Conditional',
				names: NAME_NONE,
				before: '',
				after: ' js\nclass C {}\n#end\n'
			},
			{
				field: 'constructorName',
				slot: '',
				kind: 'FnMember',
				names: NAME_IS,
				before: 'class C { function ',
				after: '() {} }'
			},
			{
				field: 'defaultVisibilityModifierText',
				slot: '',
				kind: 'Private',
				names: NAME_NONE,
				before: 'class C { ',
				after: ' var a: Int; }'
			},
			{
				field: 'descendantBuildMacroMetaNames',
				slot: '0',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'enumAbstractMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'enumAbstractSyntax',
				slot: 'bodyOpen',
				kind: 'EnumAbstractDecl',
				names: NAME_NONE,
				before: 'enum abstract E(Int) to Int ',
				after: ' var A = 1; }'
			},
			{
				field: 'finalClassMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'forwardingDeclMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'implicitConstructorDeclMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'metadataNamePrefixes',
				slot: '0',
				kind: 'Meta',
				names: NAME_OPENS,
				before: '',
				after: 'keep class C {}'
			},
			{
				field: 'metadataNamePrefixes',
				slot: '1',
				kind: 'Meta',
				names: NAME_OPENS,
				before: '',
				after: 'keep class C {}'
			},
			{
				field: 'nativeInteropDeclMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'nullCoalesceOperatorText',
				slot: '',
				kind: 'NullCoal',
				names: NAME_NONE,
				before: 'class C { function f() { var a = b ',
				after: ' c; } }'
			},
			{
				field: 'nullSafetyMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'operatorOverloadMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'parenDelimiters',
				slot: 'open',
				kind: 'ParenExpr',
				names: NAME_NONE,
				before: 'class C { function f() { var a = ',
				after: 'b); } }'
			},
			{
				field: 'parenDelimiters',
				slot: 'close',
				kind: 'ParenExpr',
				names: NAME_NONE,
				before: 'class C { function f() { var a = (b',
				after: '; } }'
			},
			{
				field: 'publicDefaultMetaNames',
				slot: '0',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'reflectedDeclMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'retainedDeclMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'selfReferenceText',
				slot: '',
				kind: 'IdentExpr',
				names: NAME_IS,
				before: 'class C { function f() { var a = ',
				after: '; } }'
			},
			{
				field: 'staticlessTypeMetaNames',
				slot: '0',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'stringLiteralDelimiters',
				slot: 'DoubleStringExpr',
				kind: 'DoubleStringExpr',
				names: NAME_OPENS,
				before: 'class C { function f() { var a = ',
				after: 'b"; } }'
			},
			{
				field: 'superReferenceText',
				slot: '',
				kind: 'IdentExpr',
				names: NAME_IS,
				before: 'class C { function new() { ',
				after: '(); } }'
			},
			{
				field: 'takesPrivateAccessMetaName',
				slot: '',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'tuplePatternDelimiters',
				slot: 'open',
				kind: 'ArrayExpr',
				names: NAME_NONE,
				before: 'class C { function f() { switch v { case ',
				after: 'a, b]: 0; } } }'
			},
			{
				field: 'tuplePatternDelimiters',
				slot: 'close',
				kind: 'ArrayExpr',
				names: NAME_NONE,
				before: 'class C { function f() { switch v { case [a, b',
				after: ': 0; } } }'
			},
			{
				field: 'typeBuildMacroMetaNames',
				slot: '0',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'typeBuildMacroMetaNames',
				slot: '1',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'typeBuildMacroMetaNames',
				slot: '2',
				kind: 'Meta',
				names: NAME_IS,
				before: '',
				after: ' class C {}'
			},
			{
				field: 'wildcardPatternName',
				slot: '',
				kind: 'IdentExpr',
				names: NAME_IS,
				before: 'class C { function f() { switch v { case ',
				after: ': 0; } } }'
			}
		]
	];

	/**
	 * Per grammar, the declared kind names that TWO OR MORE of its `@:peg` rules spell, and are meant to.
	 * A registered grammar missing from this map fails `testEveryRegisteredGrammarHasAProjectedKindSource`.
	 *
	 * A kind set names a spelling and never the rule that owns it, so each of these is
	 * admitted for every rule that spells it at once. All are deliberate, and every pair is named here because the next reader
	 * audits THIS list and not the grammar: the modifier ctors are declared identically by `HxModifier` / `HxMemberModifier` /
	 * `HxCondModPrefix` and a consumer wants all three; `Conditional` is the `#if` wrapper on sixteen rules; `EnumKw` is the
	 * `enum` keyword on both `HxCondDeclPrefix` and `HxCondModPrefix`; the body ctors (`BlockBody` / `ExprBody`) are shared by
	 * the three function-body enums; `Required` / `Optional` are the param splits of `HxParam` AND `HxLambdaParam`, and ALSO
	 * the bare `name: Type` labels of `HxAnonField` / `HxAnonVarBody`; `Plain` is `HxAnonVarBody`'s and `HxCasePatternBody`'s,
	 * where `FieldRefScan.bindsNameHere` handles only the case-pattern one, so the overlap costs a false negative and never a
	 * wrong rewrite; `Arrow` is the only CROSS-CATEGORY pair, `HxExpr.Arrow` (`=>` in a map literal or case extractor) against
	 * `HxType.Arrow` (`->` in a function type), probed harmless only because both sides answer "declares no value" to
	 * `Refs.isTypeAnnotation` - it is the entry to re-probe when that predicate changes; `CatchClause` is one `@:spanned` kind
	 * on three catch-clause spellings. A name arriving here that is NOT on this list is the `HxArrowParam.Named`
	 * shape and has to be renamed in the grammar, not admitted here.
	 */
	private static final KNOWN_AMBIGUOUS: Map<String, Array<String>> = [
		'haxe' => [
			'Arrow',
			'BlockBody',
			'CatchClause',
			'Conditional',
			'Dynamic',
			'EnumKw',
			'ExprBody',
			'Extern',
			'Inline',
			'Macro',
			'Optional',
			'Overload',
			'Override',
			'Plain',
			'Private',
			'Public',
			'Required',
			'Static'
		]
	];

	/**
	 * The source roots the parse arm reads, from the repo itself rather than from fixtures: the
	 * query engine and the whole Haxe grammar package. Real code covers far more of the
	 * vocabulary than a hand-written snippet can, and it moves with the tree instead of
	 * freezing one slice of it.
	 */
	private static final PARSE_ROOTS: Array<String> = ['src/anyparse/query', 'src/anyparse/grammar/haxe'];

	/**
	 * Per grammar, one source per construct family: the kinds that source is this file's cover for,
	 * and the smallest source that emits them.
	 *
	 * The parse arm above reads the repo's OWN sources, so a kind this repo does not happen to spell
	 * is watched by nothing there — measured on this tree, 140 of the 238 projected kinds are
	 * emitted by 516 files under `PARSE_ROOTS`, leaving 98 unwatched. This table closes the census
	 * from the other end: every projected kind is emitted by exactly one row here, or is named in
	 * `UNREACHABLE_KINDS` with the reason no source can produce it. A ctor the grammar declares and
	 * no input can reach fails HERE, by name, instead of living on in the vocabulary as a name every
	 * consumer reads and nothing can ever match — and the first run found one.
	 *
	 * `kinds` is the row's own CLAIM, not a snapshot of what it emits: every row emits far more than
	 * it is the cover for, and the assertion is that it still emits the ones it claims. That is what
	 * turns a source going stale into a failure that names the kind, rather than a hole the next row
	 * happens to fill.
	 *
	 * The oracle is the generated parser, whose author is not this hand-written table's — the same
	 * split that makes `TOKEN_PROBES` a differential rather than a string compare. A source is
	 * written in the smallest shape that reaches its ctor; several are lifted verbatim from the
	 * slice fixtures that motivated the ctor (the `CondSplice*` family, `HxCondUnbalancedRegionSliceTest`).
	 * A few rows are NOT valid Haxe on purpose — `EllipsisStmt`'s `....` is the haxe-formatter corpus
	 * convention `HxStatement` parses deliberately — because the oracle here is the generated parser,
	 * not the `haxe` compiler; do not «repair» such a row into code the compiler accepts.
	 */
	private static final KIND_SOURCES: Map<String, Array<KindSource>> = [
		'haxe' => [
			{
				kinds: [
					'ClassForm',
					'FinalDecl',
					'ImplementsClause',
					'ImportDecl',
					'ImportWildDecl',
					'Named',
					'PackageDecl',
					'UsingDecl'
				],
				source: 'package pkg;\nimport a.B;\nimport a.*;\nusing a.C;\nfinal class D implements I {}'
			},
			{ kinds: ['EnumDecl', 'ParamCtor', 'Required', 'SimpleCtor', 'TypeRef'], source: 'enum E { A; B(v: Int); }' },
			{ kinds: ['FnMember', 'InterfaceDecl', 'NoBody'], source: 'interface I { function f(): Void; }' },
			{
				kinds: [
					'AbstractDecl',
					'Assign',
					'ExprBody',
					'FromClause',
					'IdentExpr',
					'Public',
					'ToClause'
				],
				source: 'abstract A(Int) from Int to Int { public function new(v) this = v; }'
			},
			{
				kinds: ['Anon', 'FinalField', 'Plain', 'TypedefDecl', 'VarField'],
				source: 'typedef T = { var a: Int; final b: Int; c: Int; }'
			},
			{
				kinds: [
					'Add',
					'AddAssign',
					'And',
					'BitAnd',
					'BitNot',
					'BitOr',
					'BlockBody',
					'ClassDecl',
					'Div',
					'Eq',
					'ExprStmt',
					'Gt',
					'GtEq',
					'IndexAccess',
					'IntLit',
					'Interval',
					'Is',
					'Lt',
					'LtEq',
					'Mod',
					'Mul',
					'Neg',
					'Not',
					'NotEq',
					'NullCoal',
					'NullCoalAssign',
					'Or',
					'PostDecr',
					'PostIncr',
					'PreDecr',
					'PreIncr',
					'SafeFieldAccess',
					'Shr',
					'Sub',
					'SubAssign',
					'Ternary',
					'VarStmt'
				],
				source: 'class C { function f() { var a = b + c - d * e / f % g; a += 1; a -= 1; a = b == c; a = b != c; a = b > c; a = b '
					+ '>= c; a = b < c; a = b <= c; a = b && c; a = b || c; a = b ?? c; a ??= c; a = ~b; a = !b; a = -b; a = b & c; a = '
					+ 'b | c; a = b >> c; a = 0...10; a = b is C; a = b ? c : d; a++; a--; ++a; --a; a = b[0]; a = b?.c; } }'
			},
			{
				kinds: [
					'DoubleStringExpr',
					'Field',
					'FloatLit',
					'HexLit',
					'Literal',
					'NewExpr',
					'NullLit',
					'ObjectLit',
					'RegexLit',
					'SingleStringExpr',
					'ThinArrow'
				],
				source: 'class C { function f() { var a = 1.5; var b = 0xFF; var c = null; var d = ~/re/g; var e = \'str\'; var g = "dbl"; '
					+ 'var h = {x: 1}; var i = new C(); var j = x -> x; } }'
			},
			{
				kinds: [
					'BlockStmt',
					'Call',
					'CatchClause',
					'ContinueStmt',
					'FinalStmt',
					'LocalFnStmt',
					'LocalInlineFnStmt',
					'ReturnStmt',
					'ThrowStmt',
					'TryCatchStmt',
					'WhileStmt'
				],
				source: 'class C { function f() { try { g(); } catch (e: Int) { throw e; } while (a) continue; { h(); } function loc() {} '
					+ 'inline function loc2() {} final k = 1; return a; } }'
			},
			{
				kinds: ['FinalMember', 'Inline', 'Macro', 'Private', 'Static'],
				source: 'class C { private inline function f() {} macro static function g() {} final a: Int = 1; }'
			},
			{
				kinds: [
					'BlockExpr',
					'CaseBranch',
					'CastExpr',
					'ECheckTypeExpr',
					'FnExpr',
					'ParenExpr',
					'SwitchExpr',
					'SwitchExprBare',
					'TryExpr'
				],
				source: 'class C { function f() { var a = switch (v) { case _: 0; }; var b = switch v { case _: 0; }; var c = try g() '
					+ 'catch (e: Int) 0; var d = { g(); }; var e = function() {}; var h = cast b; var i = (b : Int); var j = (b); } }'
			},
			{ kinds: ['ReturnExpr', 'UntypedExpr'], source: 'class C { function f() { untyped return a; } }' },
			{ kinds: ['ThrowExpr'], source: 'class C { function f() { untyped throw a; } }' },
			{ kinds: ['ContinueExpr'], source: 'class C { function f() { untyped continue; } }' },
			{ kinds: ['DollarReifExpr', 'MacroExpr'], source: "class C { macro static function f() { return macro $b{a}; } }" },
			{ kinds: ['DollarIdentExpr'], source: "class C { macro static function f() { return macro $a; } }" },
			{ kinds: ['MacroTypeExpr'], source: 'class C { macro static function f() { return macro : Int; } }' },
			{ kinds: ['ForStmt', 'KeyValueBinder'], source: 'class C { function f() { for (k => v in map) g(); } }' },
			{ kinds: ['Optional'], source: 'class C { function f(?a: Int) {} }' },
			{
				kinds: ['Block', 'Dollar', 'Ident', 'LoneDollar'],
				source: "class C { function f() { var a = 'x $b ${c} $$ y'; var d = 'cost $ 5'; } }"
			},
			{ kinds: ['DollarType', 'VarMember'], source: "class C { var a: $T; }" },
			{ kinds: ['TryCatchStmtBare'], source: 'class C { function f() { try g() catch (e: Int) h(); } }' },
			{ kinds: ['DollarBlockExpr'], source: "class C { macro static function f() { return macro ${a}; } }" },
			{ kinds: ['Abstract', 'AbstractClassDecl'], source: 'abstract class A { abstract function f(): Void; }' },
			{ kinds: ['EnumAbstractDecl'], source: 'enum abstract E(Int) { var A = 1; }' },
			{
				kinds: [
					'BitAndAssign',
					'BitOrAssign',
					'BitXor',
					'BitXorAssign',
					'BoolAndAssign',
					'BoolOrAssign',
					'DivAssign',
					'ModAssign',
					'MulAssign',
					'Shl',
					'ShlAssign',
					'ShrAssign',
					'UShr',
					'UShrAssign'
				],
				source: 'class C { function f() { a &= 1; a |= 1; a ^= 1; var q = a ^ 1; a &&= 1; a ||= 1; a /= 1; a %= 1; a *= 1; a <<= '
					+ '1; a >>= 1; a >>>= 1; var w = a << 1; var e = a >>> 1; } }'
			},
			{ kinds: ['BoolLit', 'BreakStmt'], source: 'class C { function f() { while (true) break; } }' },
			{ kinds: ['IfStmt'], source: 'class C { function f() { for (i in a) if (b) break; } }' },
			{
				kinds: ['ArrayExpr', 'DefaultBranch', 'SwitchStmtBare'],
				source: 'class C { function f() { switch v { case x = [1]: 0; default: 1; } } }'
			},
			{ kinds: ['DoWhileStmt'], source: 'class C { function f() { do { a(); } while (b); } }' },
			{ kinds: ['Dynamic'], source: 'class C { dynamic function f() {} }' },
			{ kinds: ['Extern'], source: 'extern class C {}' },
			{ kinds: ['Overload'], source: 'class C { overload function f() {} }' },
			{ kinds: ['ExtendsClause', 'Override'], source: 'class C extends B { override function f() {} }' },
			{ kinds: ['PackageEmpty'], source: 'package;' },
			{ kinds: ['UsingWildDecl'], source: 'using haxe.macro.*;' },
			{ kinds: ['ImportAliasDecl'], source: 'import a.B as C;' },
			{ kinds: ['ImportAliasInDecl'], source: 'import a.B in C;' },
			{ kinds: ['VoidReturnStmt'], source: 'class C { function f() { return; } }' },
			{ kinds: ['UntypedBlockStmt'], source: 'class C { function f() { untyped { a(); } } }' },
			{ kinds: ['TypedCastExpr'], source: 'class C { function f() { cast(a, Int); } }' },
			{ kinds: ['Rest'], source: 'class C { function f(...rest: Int) {} }' },
			{ kinds: ['Spread'], source: 'class C { function f() { g(...a); } }' },
			{ kinds: ['EmptyStmt'], source: 'class C { function f() { ; } }' },
			{ kinds: ['EmptySemiMember'], source: 'class C { ; }' },
			{ kinds: ['ExtendsField'], source: 'typedef T = { > Base, a: Int }' },
			{ kinds: ['FnField'], source: 'typedef T = { function f(): Void; }' },
			{ kinds: ['FnDecl'], source: 'function f() {}' },
			{ kinds: ['NamedFnExpr'], source: 'class C { function f() { var g = function h() {}; } }' },
			{ kinds: ['ArrowFn', 'NamedParam'], source: 'class C { function f(g: (a: Int) -> Void) {} }' },
			{ kinds: ['OptionalNamedParam'], source: 'class C { function f(g: (?a: Int) -> Void) {} }' },
			{ kinds: ['ThinParenLambdaExpr'], source: 'class C { function f() { var g = (a) -> a; } }' },
			{ kinds: ['Meta', 'MetaExpr'], source: 'class C { function f() { @:privateAccess a(); } }' },
			{ kinds: ['InlineExpr'], source: 'class C { function f() { inline g(); } }' },
			{ kinds: ['VarDecl'], source: 'static var a = 1;' },
			{ kinds: ['VarMore'], source: 'class C { function f() { var a = 1, b = 2; } }' },
			{ kinds: ['Conditional'], source: 'class C { function f() { #if js a(); #end } }' },
			{ kinds: ['ConditionalExpr'], source: 'class C { function f() { g(#if js a #else b #end); } }' },
			{ kinds: ['ConditionalType'], source: 'class C { var a: #if js Int #else String #end; }' },
			{ kinds: ['CondSpliceTail', 'OpTail'], source: 'class C { function f() { var a = b #if js + c #end; } }' },
			{ kinds: ['ListTail'], source: 'class C { function f() { g(a, b #if js, c #end); } }' },
			{ kinds: ['RawTail'], source: 'class C { function f() { var a = b #if js + c #else - c #end; } }' },
			{ kinds: ['VarExpr'], source: 'class C { function f() { untyped var a = 1; } }' },
			{ kinds: ['FinalExpr'], source: 'class C { function f() { untyped final a = 1; } }' },
			{ kinds: ['BreakExpr'], source: 'class C { function f() { untyped break; } }' },
			{ kinds: ['VoidReturnExpr'], source: 'class C { function f() { untyped return; } }' },
			{ kinds: ['WhileExpr'], source: 'class C { function f() { untyped while (a) b(); } }' },
			{ kinds: ['UntypedBlockBody'], source: 'class C { function f() untyped { a(); } }' },
			{ kinds: ['UntypedAtom'], source: 'class C { function f() { var a = untyped; } }' },
			{ kinds: ['MacroClassExpr', 'NamedHead'], source: 'class C { function f() { macro class Foo { var a: Int; } } }' },
			{ kinds: ['AnonHead'], source: 'class C { function f() { macro class { var a: Int; } } }' },
			{ kinds: ['ForceFieldAccess'], source: 'class C { function f() { var q = a!.b; } }' },
			{ kinds: ['In'], source: 'class C { function f() { var q = a in b; } }' },
			{ kinds: ['InnerDoWhile'], source: 'class C { function f() { do do a(); while (b); while (c); } }' },
			{ kinds: ['Capture'], source: 'class C { function f() { switch v { case var x: 0; } } }' },
			{ kinds: ['StaticFinalStmt', 'StaticVarStmt'], source: 'class C { function f() { static var a = 1; static final b = 2; } }' },
			{ kinds: ['EllipsisStmt'], source: 'class C { function f() { .... } }' },
			{ kinds: ['EllipsisMember'], source: 'class C { ... }' },
			{ kinds: ['FinalModifiedMember'], source: 'class C { final function f() {} }' },
			{ kinds: ['VarForm'], source: 'final FOO = 1;' },
			{ kinds: ['ConstStringType'], source: 'class C { var a: hl.Abstract<"hl_tls">; }' },
			{ kinds: ['BracketExprListType'], source: 'class C { var a: haxe.macro.MacroType<[build("x")]>; }' },
			{ kinds: ['Arrow', 'OptionalArg'], source: 'class C { var a: Int -> ?Int -> Void; }' },
			{ kinds: ['Positional'], source: 'class C { var a: (Int -> Void) -> Void; }' },
			{ kinds: ['FieldAccess', 'MetaCall'], source: '@:allow(a.B) class C {}' },
			{ kinds: ['IfExpr'], source: 'class C { function f() { @:meta if (a) b(); } }' },
			{ kinds: ['MetaCondStmt'], source: 'class C { function f() { @:meta #if js a(); #end } }' },
			{ kinds: ['CondSpliceReturnStmt'], source: 'class C { function f() { return #if X a; #else b; #end } }' },
			{ kinds: ['CondSpliceReturnExpr'], source: 'class C { function f() return #if X a; #else b; #end }' },
			{ kinds: ['CondBody'], source: 'class C { function f() #if js { a(); } #else { b(); } #end }' },
			{ kinds: ['CondNameFnMember'], source: 'class C { function #if js a #else b #end () {} }' },
			{ kinds: ['VarSemiCondInitMember'], source: 'class C { var a: Int = #if js 1; #else 2; #end }' },
			{ kinds: ['ErrorDecl'], source: '#if cs #error \'x\' #end' },
			{ kinds: ['ErrorMember'], source: 'class C { #if cs #error \'x\' #end }' },
			{ kinds: ['ErrorStmt'], source: 'class C { function f() { #if cs #error \'x\' #end } }' },
			{ kinds: ['ClassHead', 'CondSharedBodyDecl'], source: '#if js class C { #else class D { #end function f() {} }' },
			{ kinds: ['AbstractHead'], source: '#if js abstract A(Int) { #else abstract B(Int) { #end function f() {} }' },
			{ kinds: ['EnumKw'], source: '#if js enum #end abstract E(Int) {}' },
			{ kinds: ['AbstractKw'], source: '#if js abstract #end class C {}' },
			{ kinds: ['FinalKw'], source: 'class C { #if js final #end var a: Int; }' },
			{
				kinds: ['CondSpliceBlockOpen', 'OrphanElseStmt'],
				source: 'class C { function f():Void { #if X if (a) { #else if (b) { #end g(); } else h(); } }'
			},
			{
				kinds: ['CondSpliceBlockTail', 'CondSpliceStmt'],
				source: 'class C { function f():Void { #if display try { #end g(); #if display } catch (_:Dynamic) { } #end return; } }'
			},
			{
				kinds: ['CondSpliceBlockClose'],
				source: 'class C { function f():Void { #if cs lock(f, function() { #end a(); #if cs }); #end } }'
			},
			{
				kinds: ['CondSpliceCase', 'SwitchStmt'],
				source: 'class C { function f():Void { switch (x) { #if A case P, Q: #else case P: #end g(); h(); case R: i(); } } }'
			},
			{
				kinds: ['CondSpliceSwitchOpen'],
				source: 'class M {\n\tfunction f():Void {\n#if utf16\n\t\tfor (c in it(tmp)) {\n\t\t\tswitch (c) {\n#else\n'
					+ '\t\tfor (i in 0...tmp.length) {\n\t\t\tswitch (fast(tmp, i)) {\n#end\n\t\t\t\tcase 1: aa(bb);\n'
					+ '\t\t\t\tcase _: ee(ff);\n\t\t\t}\n\t\t}\n\t}\n}'
			},
			{ kinds: ['ForExpr'], source: 'class C { function f() { macro for (i in a) b(); } }' },
			{ kinds: ['Parens'], source: 'class C { var a: (Int); }' },
			{ kinds: ['ParenLambdaExpr'], source: 'class C { function f() { var g = () => a; } }' },
			{ kinds: ['ForReifExpr'], source: "class C { function f() { for ($head) g(); } }" },
			{ kinds: ['ConditionalArgs'], source: 'class C { function f() { var a = [b, #if X c, d, #end e]; } }' },
			{ kinds: ['CondSpliceOpExpr'], source: 'class C { function f() { var a = #if c b + #end d; } }' },
			{ kinds: ['CondSpliceExpr'], source: 'class C { function f() { var a = #if c b + #else d + #end e; } }' },
			{ kinds: ['CondSpliceMember'], source: 'class C { #if js function f(): Int #else function f(): String #end { return a; } }' },
			{ kinds: ['MetaStmt'], source: 'class C { function f() { @:meta do { b(); } while (a); } }' }
		]
	];

	/**
	 * Per grammar, the projected kinds NO source can emit, each with the reason it cannot.
	 *
	 * `PlainMeta` is the whole list, and it is not a gap in the table above. `HxMetadata` dispatches
	 * `MetaCall`, then `Meta`, then `PlainMeta`, and `Meta`'s `HxMetaName` pattern is `PlainMeta`'s
	 * `HxMetaRaw` pattern with the optional argument parentheses removed — so every input the raw
	 * catch-all matches, the branch before it matches first, on the same prefix. The shape it was
	 * written for does not reach it either: for a tag whose arguments no expression parses,
	 * `MetaCall` rewinds, `Meta` takes the NAME, the leftover `(…)` fails in the DECLARATION, and no
	 * rewind returns to the metadata element to try a later branch — measured, `@:x(*) class C {}` is
	 * a parse error at the `(` and `@:allow(a.*) class C {}` one at the `*`, never a `PlainMeta`.
	 *
	 * So the ctor is a name every kind-set consumer can read and no parse can ever produce. Retiring
	 * it, or ordering it before `Meta`, is a grammar decision with a writer surface
	 * (`HxMetadataUtil.source` still answers for it) and not this fixture's to make; what this list
	 * does is stop the census from reading as complete while one of its names is dead.
	 */
	private static final UNREACHABLE_KINDS: Map<String, Array<String>> = ['haxe' => ['PlainMeta']];

	/**
	 * The control for the whole layer: no kind name a plugin declares may be one its own
	 * grammar never projects, and the ONE exemption is the sentinel the shape itself names.
	 *
	 * Killed by arm M-PROJECTED-KINDS-ALT-ONLY, which drops the `@:spanned` half of the shape
	 * walk: `CatchClause`, `KeyValueBinder` and `VarMore` are declared by six kind sets
	 * between them and stop being projected, while the floors below stay satisfied — so the
	 * subset assertion is what goes red, not the census. Killed also by arm M-DECL-HOST-KIND-STALE, which puts a retired
	 * name back into `DECL_HOST_KINDS` - the mutation is on the HAND-WRITTEN side, the one that produced this slice's real
	 * catch, and a dead name in a kind set changes no behaviour, so the new assertion is the only thing that can see it.
	 */
	@:pin('control')
	@:killer('M-PROJECTED-KINDS-ALT-ONLY')
	@:killer('M-DECL-HOST-KIND-STALE')
	public function testEveryDeclaredKindNameIsOneTheGrammarProjects(): Void {
		for (lang in CliArgs.langNames()) {
			final shape: RefShape = CliArgs.pickPlugin(lang).refShape();
			final projected: Array<String> = projectedKindsFor(lang);
			final fields: Array<String> = kindFieldsOf(shape, projected);
			final declared: Array<String> = declaredKindsOf(shape, fields, projected);
			final sentinel: Null<String> = shape.finalModifierRankKind;
			Assert.isTrue(fields.length >= MIN_KIND_FIELDS, '$lang: ${fields.length} kind-bearing RefShape field(s)');
			Assert.isTrue(declared.length >= MIN_DECLARED_KINDS, '$lang: ${declared.length} distinct declared kind name(s)');
			Assert.isTrue(projected.length >= MIN_PROJECTED_KINDS, '$lang: ${projected.length} projected kind(s)');
			final stale: String = declared.filter(kind -> !projected.contains(kind) && kind != sentinel).join(', ');
			Assert.equals('', stale, '$lang declares kind name(s) its grammar never projects: [$stale]');
		}
	}

	/**
	 * The exemption is one name, it is the one the shape declares as a sentinel, and it is
	 * really absent from the projection — otherwise the arm above would be exempting nothing
	 * and would read as green for the wrong reason.
	 */
	public function testTheOneExemptedNameIsTheShapesOwnSentinel(): Void {
		for (lang in CliArgs.langNames()) {
			final shape: RefShape = CliArgs.pickPlugin(lang).refShape();
			final sentinel: Null<String> = shape.finalModifierRankKind;
			if (sentinel == null) continue;
			final projected: Array<String> = projectedKindsFor(lang);
			final declared: Array<String> = declaredKindsOf(shape, kindFieldsOf(shape, projected), projected);
			Assert.isFalse(projected.contains(sentinel), '$lang: sentinel "$sentinel" IS projected — the exemption is dead');
			Assert.isTrue(declared.contains(sentinel), '$lang: sentinel "$sentinel" is declared by no kind set');
		}
	}

	/**
	 * Every declared name that two or more `@:peg` rules spell is a collision this file
	 * names. Set equality, not containment: a collision that gets repaired in the grammar has
	 * to leave the list, or the next one hides behind a stale entry.
	 */
	public function testEveryAmbiguousDeclaredNameIsAKnownCollision(): Void {
		for (lang in CliArgs.langNames()) {
			final shape: RefShape = CliArgs.pickPlugin(lang).refShape();
			final projected: Array<String> = projectedKindsFor(lang);
			final declared: Array<String> = declaredKindsOf(shape, kindFieldsOf(shape, projected), projected);
			final shared: Array<String> = ambiguousKindsFor(lang).filter(kind -> declared.contains(kind));
			shared.sort(Reflect.compare);
			final found: String = shared.join(', ');
			final known: String = (KNOWN_AMBIGUOUS[lang] ?? []).join(', ');
			Assert.equals(known, found, '$lang kind names two or more @:peg rules spell — known [$known], found [$found]');
		}
	}

	/**
	 * Every grammar the CLI registry can dispatch has a projected vocabulary this file can
	 * ask for. A plugin added to `CliArgs.langNames` without one fails HERE, by name, instead
	 * of quietly leaving every one of its declarations unchecked.
	 */
	public function testEveryRegisteredGrammarHasAProjectedKindSource(): Void {
		final langs: Array<String> = CliArgs.langNames();
		Assert.isTrue(langs.length > 0, 'the grammar registry is empty');
		for (lang in langs) {
			if (ambiguousKindsSourceFor(lang) == null)
				Assert.fail('grammar "$lang" declares a RefShape but this fixture has no shared-spelling source for it');
			if (!KNOWN_AMBIGUOUS.exists(lang))
				Assert.fail('grammar "$lang" declares a RefShape but names no audited set of shared kind spellings');
			if (!TOKEN_PROBES.exists(lang))
				Assert.fail('grammar "$lang" declares a RefShape but names no token-capture probes for its own tokens');
			if (!KIND_SOURCES.exists(lang))
				Assert.fail('grammar "$lang" declares a RefShape but names no source for any kind its own parser projects');
		}
	}

	/**
	 * A field whose name does not say `Kind` and whose value nonetheless holds a projected
	 * kind name is either a kind set the name-based reading would skip, or a type name that
	 * happens to be spelled like one. Both are decisions, so both are written down — and a
	 * NEW such field fails here rather than escaping the arm above.
	 */
	public function testNoUnclassifiedFieldCarriesAProjectedKindName(): Void {
		final classified: Array<String> = EXTRA_KIND_FIELDS.concat(KIND_LOOKALIKE_FIELDS);
		final expected: Array<String> = classified.copy();
		expected.sort(Reflect.compare);
		for (lang in CliArgs.langNames()) {
			final shape: RefShape = CliArgs.pickPlugin(lang).refShape();
			final projected: Array<String> = projectedKindsFor(lang);
			final unclassified: Array<String> = [];
			for (field in Reflect.fields(shape)) if (
				field.indexOf('Kind') < 0 && !classified.contains(field) && !isKindKeyedMap(Reflect.field(shape, field), projected)
			) {
				final strings: Array<String> = [];
				stringsOf(Reflect.field(shape, field), strings);
				if (strings.exists(name -> projected.contains(name))) unclassified.push(field);
			}
			unclassified.sort(Reflect.compare);
			final loose: String = unclassified.join(', ');
			Assert.equals('', loose, '$lang: RefShape field(s) carrying a projected kind name with no classification: [$loose]');
			final live: Array<String> = classified.filter(field -> Reflect.hasField(shape, field));
			live.sort(Reflect.compare);
			Assert.equals(expected.join(', '), live.join(', '), '$lang: classified field(s) the shape no longer declares');
		}
	}

	/**
	 * The map-key derivation splits cleanly or it is not a derivation.
	 *
	 * `isKindKeyedMap` answers YES on one projected key, so a map that is PART kind-keyed would be
	 * read as wholly kind-keyed and its other keys reported as kind names the grammar never
	 * projects — a true failure with a misleading message. On this tree no map is mixed, and this
	 * is what says so rather than assuming it.
	 */
	public function testEveryMapFieldIsKeyedByKindOrByNothing(): Void {
		for (lang in CliArgs.langNames()) {
			final shape: RefShape = CliArgs.pickPlugin(lang).refShape();
			final projected: Array<String> = projectedKindsFor(lang);
			final mixed: Array<String> = [];
			var maps: Int = 0;
			for (field in Reflect.fields(shape)) {
				final value: Any = Reflect.field(shape, field);
				if (!Std.isOfType(value, StringMap)) continue;
				maps++;
				final keys: Array<String> = [for (key in (cast value: StringMap<Any>).keys()) key];
				final hits: Int = keys.filter(key -> projected.contains(key)).length;
				if (hits != 0 && hits != keys.length) mixed.push('$field ($hits of ${keys.length} keys projected)');
			}
			Assert.isTrue(maps > 0, '$lang: the shape declares no map field, so the derivation is untested');
			final loose: String = mixed.join(', ');
			Assert.equals('', loose, '$lang: map field(s) neither wholly kind-keyed nor kind-free: [$loose]');
		}
	}

	/**
	 * Every token-bearing slot of the shape is covered by a capture probe, and every probe still
	 * addresses a slot the shape has.
	 *
	 * The membership is DERIVED for the punctuation half — a string that cannot be a name has to be a token, so a new field spelling
	 * one fails HERE until someone writes it a probe. The keyword half cannot be derived (`this` and `Bool` are the same shape) and
	 * is listed instead, so what this arm adds over the list is the direction the list cannot give: exact coverage, both ways.
	 *
	 * Both exemptions are checked against the shape, and they are checked at the granularity they are written at: a
	 * KEYWORD exemption names a field and the shape has to still declare it, a TEMPLATE exemption names a
	 * `<field>#<slot>` and the shape has to still hold that slot. The second half is the S203 repair — freeing a
	 * template by FIELD also freed `enumAbstractSyntax.bodyOpen`, a real `{` the parser captures, and nothing probed it.
	 */
	public function testEveryTokenBearingSlotIsProbedOrDeclaredATemplate(): Void {
		for (lang in CliArgs.langNames()) {
			final shape: RefShape = CliArgs.pickPlugin(lang).refShape();
			final probed: Array<String> = [for (probe in tokenProbesFor(lang)) '${probe.field}#${probe.slot}'];
			final wanted: Array<String> = tokenSlotsOf(shape);
			probed.sort(Reflect.compare);
			wanted.sort(Reflect.compare);
			Assert.isTrue(wanted.length >= MIN_TOKEN_SLOTS, '$lang: ${wanted.length} token-bearing slot(s)');
			final keywords: Array<String> = KEYWORD_TOKEN_FIELDS.copy();
			final liveKeywords: Array<String> = keywords.filter(field -> Reflect.hasField(shape, field));
			keywords.sort(Reflect.compare);
			liveKeywords.sort(Reflect.compare);
			Assert.equals(keywords.join(', '), liveKeywords.join(', '), '$lang: keyword field(s) the shape no longer declares');
			final templates: Array<String> = TEMPLATE_SLOTS.copy();
			final liveTemplates: Array<String> = templates.filter(address -> slotTextAt(shape, address) != null);
			templates.sort(Reflect.compare);
			liveTemplates.sort(Reflect.compare);
			Assert.equals(templates.join(', '), liveTemplates.join(', '), '$lang: template slot(s) the shape no longer declares');
			Assert.equals(wanted.join(', '), probed.join(', '), '$lang: token-bearing slots and capture probes differ');
		}
	}

	/**
	 * The SECOND differential: a token the shape declares has to be text this grammar's own parser
	 * captures.
	 *
	 * The first one compares kind NAMES, so every field whose value is a token — `@:` and `@`, the quote a string literal carries,
	 * `&&`, `#if`, `this` — was checked by nothing at all: a stale one fails open exactly the way a stale kind does, silently,
	 * with an `Array<String>` that no build can typo-check. Here each token is read out of the shape by ADDRESS, wrapped in the
	 * smallest source that can carry it, and the parse has to carry the declared kind over it. The oracle is the generated parser,
	 * whose author is not the hand-typed shape's — which is what keeps this from being a string compare with extra steps.
	 *
	 * WHAT the parse has to show is the probe's `names` mode, not one rule for all 35 slots. Twenty of them project a NAME and the
	 * assertion is equality with the token; three carry the token as the head of a projected name; twelve name nothing the token could be,
	 * and there span containment is the strongest true statement. The expected name is never written down — it is the shape's own text —
	 * so a token that drifts is still read out of the shape and the arm goes red on the parse rather than on an equality nobody wrote.
	 *
	 * KILLED by arm `M-AND-OPERATOR-TEXT-STALE`, which respells `andOperatorText` as the single `&`: still a real
	 * Haxe operator, so the probe source still parses — and projects `BitAnd`, so nothing in the tree changes except
	 * that a declared token stops being the one the parser reads. That is the whole failure mode this arm exists for.
	 *
	 * KILLED also by `M-CONSTRUCTOR-NAME-PADDED`, which is the SHARPENED half's own arm: `constructorName` gains a
	 * trailing space, `class C { function new () {} }` still parses, and the `FnMember` still spans text holding `new
	 * ` — so the span-containment reading this fixture shipped with is GREEN on it. Only the name-slot reading sees it.
	 */
	@:pin('control')
	@:killer('M-AND-OPERATOR-TEXT-STALE')
	@:killer('M-CONSTRUCTOR-NAME-PADDED')
	public function testEveryDeclaredTokenIsOneTheParserCaptures(): Void {
		for (lang in CliArgs.langNames()) {
			final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
			final shape: RefShape = plugin.refShape();
			final projected: Array<String> = projectedKindsFor(lang);
			final missed: Array<String> = [];
			for (probe in tokenProbesFor(lang)) {
				final token: Null<String> = slotText(shape, probe.field, probe.slot);
				if (token == null) {
					missed.push('${probe.field}#${probe.slot} (the shape holds no such slot)');
					continue;
				}
				if (!projected.contains(probe.kind)) {
					missed.push('${probe.field}#${probe.slot} (probe kind "${probe.kind}" is not projected)');
					continue;
				}
				if (probe.names != NAME_IS && probe.names != NAME_OPENS && probe.names != NAME_NONE) {
					missed.push('${probe.field}#${probe.slot} (unknown name mode "${probe.names}")');
					continue;
				}
				final source: String = probe.before + token + probe.after;
				final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: Exception) null;
				if (tree == null) {
					missed.push('${probe.field}#${probe.slot} "$token" (the probe source does not parse)');
					continue;
				}
				if (!capturesToken(tree, source, probe, token)) {
					missed.push('${probe.field}#${probe.slot} "$token" as ${probe.kind} (${probe.names})');
					continue;
				}
				if (probe.names == NAME_NONE && namesToken(tree, probe.kind, token))
					missed.push('${probe.field}#${probe.slot} "$token" (a ${probe.kind} node NAMES it — declare it $NAME_IS)');
			}
			final loose: String = missed.join(', ');
			Assert.equals('', loose, '$lang: declared token(s) no parse of this grammar captures: [$loose]');
		}
	}

	/**
	 * The THIRD differential, and the one that reads the vocabulary whole: every kind this grammar
	 * projects has to be a kind SOME source can make it emit.
	 *
	 * The two declared-side arms read what the shape spells against the projected vocabulary, and
	 * the parse arm reads that vocabulary against what this repo happens to spell. None of the three
	 * can see a projected name no input reaches: the grammar really does declare the ctor, so
	 * nothing is stale; nothing emits it, so nothing is missing; and every consumer reading a kind
	 * set that holds it silently matches no node, forever. `KIND_SOURCES` is the input side of that
	 * question and `UNREACHABLE_KINDS` the accounted exception, and the two have to add up to the
	 * vocabulary exactly — a new ctor with no source fails here by name, and so does a source that
	 * stopped reaching the ctor it was written for.
	 *
	 * KILLED by arm `M-ELLIPSIS-STMT-TOKEN-STALE`, which respells the statement-scope `....`
	 * placeholder as a five-dot token. The ctor stays declared and stays projected, and no source
	 * under `PARSE_ROOTS` spells the token at all, so the only thing that changes anywhere in the
	 * tree is that one row of this table stops emitting the kind it claims.
	 */
	@:pin('control')
	@:killer('M-ELLIPSIS-STMT-TOKEN-STALE')
	public function testEveryProjectedKindIsOneSomeSourceEmits(): Void {
		for (lang in CliArgs.langNames()) {
			final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
			final projected: Array<String> = projectedKindsFor(lang);
			final unreachable: Array<String> = UNREACHABLE_KINDS[lang] ?? [];
			final claimed: Array<String> = [];
			final everything: Array<String> = [];
			final missed: Array<String> = [];
			for (row in kindSourcesFor(lang)) {
				final emitted: Array<String> = [];
				try {
					collectChildKinds(plugin.parseFile(row.source), emitted);
					collectChildKinds(plugin.parseFileTypeRefs(row.source), emitted);
				} catch (exception: Exception) {
					missed.push('"${row.source}" does not parse: ${exception.message}');
					continue;
				}
				for (kind in emitted) if (!everything.contains(kind)) everything.push(kind);
				for (kind in row.kinds) {
					if (!emitted.contains(kind))
						missed.push('$kind (the source claiming it no longer emits it)');
					else if (claimed.contains(kind))
						missed.push('$kind (claimed by two sources)');
					else
						claimed.push(kind);
				}
			}
			final loose: String = missed.join(', ');
			Assert.equals('', loose, '$lang: kind source(s) that stopped covering what they claim: [$loose]');
			final dead: String = unreachable.filter(kind -> everything.contains(kind)).join(', ');
			Assert.equals('', dead, '$lang: kind(s) declared unreachable that a source DOES emit: [$dead]');
			final accounted: Array<String> = claimed.concat(unreachable);
			final unwatched: String = projected.filter(kind -> !accounted.contains(kind)).join(', ');
			Assert.equals('', unwatched, '$lang: projected kind(s) no source emits and nothing declares unreachable: [$unwatched]');
			final stale: String = accounted.filter(kind -> !projected.contains(kind)).join(', ');
			Assert.equals('', stale, '$lang: kind(s) this fixture accounts for that the grammar no longer projects: [$stale]');
		}
	}

	/** The kinds MORE THAN ONE rule of `lang`'s grammar declares, or null when no source is known. */
	private static function ambiguousKindsSourceFor(lang: String): Null<Array<String>> {
		return switch lang {
			case 'haxe': HaxeQueryWalker.ambiguousProjectedKinds();
			case _: null;
		};
	}

	/** The shared-spelling set of `lang`; a lang with none is a build-time gap, so it throws. */
	private static function ambiguousKindsFor(lang: String): Array<String> {
		final kinds: Null<Array<String>> = ambiguousKindsSourceFor(lang);
		if (kinds == null) throw 'no shared-spelling source for grammar "$lang"';
		return kinds;
	}

	/**
	 * The projected vocabulary of `lang` — the plugin's own, not a per-lang switch in this
	 * fixture. A grammar registered without one is now a COMPILE error (`GrammarPlugin` declares
	 * the method), which is what the `switch` used to catch at run time and only for a lang
	 * somebody remembered to add. What stays checkable at run time is emptiness: the vocabulary
	 * is what both differentials read, so a plugin answering `[]` would turn them green by
	 * answering nothing.
	 */
	private static function projectedKindsFor(lang: String): Array<String> {
		final kinds: Array<String> = CliArgs.pickPlugin(lang).projectedKinds();
		if (kinds.length == 0) throw 'grammar "$lang" publishes an empty projected-kind vocabulary';
		return kinds;
	}

	/** The `RefShape` fields the declared side reads: named `*Kind*`, listed as kind-bearing, or a kind-keyed map. */
	private static function kindFieldsOf(shape: RefShape, projected: Array<String>): Array<String> {
		return Reflect.fields(shape).filter(
			field ->
				field.indexOf('Kind') >= 0 || EXTRA_KIND_FIELDS.contains(field) || isKindKeyedMap(Reflect.field(shape, field), projected)
		);
	}

	/** Every distinct kind name `fields` declare — a kind-keyed map contributes its KEYS, everything else its strings. */
	private static function declaredKindsOf(shape: RefShape, fields: Array<String>, projected: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (field in fields) {
			final value: Any = Reflect.field(shape, field);
			final names: Array<String> = [];
			if (isKindKeyedMap(value, projected))
				for (key in (cast value: StringMap<Any>).keys()) names.push(key);
			else
				stringsOf(value, names);
			for (name in names) if (!out.contains(name)) out.push(name);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/**
	 * Whether `value` is a map KEYED BY KIND — DERIVED, where the classification used to be a
	 * hand list. S188 added `stringLiteralDelimiters` and had to classify it by eye, which is a
	 * step the next map field would have skipped in silence.
	 *
	 * ANY projected key, not every one. A map keyed by kind whose entry has gone STALE is
	 * precisely what the subset arm exists to report, and an all-keys rule would answer "not
	 * kind-keyed" for exactly that map and bury the stale name instead. The split is wide on
	 * this tree — 6 of 6 and 1 of 1 against 0 of 2, 3, 6, 9 and 9 — and
	 * `testEveryMapFieldIsKeyedByKindOrByNothing` is what keeps it wide.
	 */
	private static function isKindKeyedMap(value: Any, projected: Array<String>): Bool {
		if (!Std.isOfType(value, StringMap)) return false;
		for (key in (cast value: StringMap<Any>).keys()) if (projected.contains(key)) return true;
		return false;
	}

	/**
	 * Every string `value` carries: itself, an array's elements at any nesting, a map's keys
	 * and its string values, and the fields of an anonymous STRUCTURE.
	 *
	 * A class INSTANCE is deliberately not descended into. The one field that can hold one is
	 * `refsCache`, whose value is the engine's own run-scoped `RefsCache` — walking it would
	 * read a cache of parsed trees rather than a declaration, and it is absent from the shape a
	 * bare plugin returns anyway. The discriminator is `Type.getClass` and not a field-name
	 * list, so the refusal holds for whatever instance a future field carries, while a
	 * STRUCTURE — where a nested kind name would otherwise pass both arms — IS walked.
	 */
	private static function stringsOf(value: Any, out: Array<String>): Void {
		if (Std.isOfType(value, String))
			out.push(cast value);
		else if (Std.isOfType(value, Array))
			for (item in (cast value: Array<Any>)) stringsOf(item, out);
		else if (Std.isOfType(value, StringMap))
			for (key => item in (cast value: StringMap<Any>)) {
				out.push(key);
				stringsOf(item, out);
			}
		else if (isAnonymousStructure(value))
			for (field in Reflect.fields(value)) stringsOf(Reflect.field(value, field), out);
	}

	/**
	 * Whether `value` is an anonymous STRUCTURE. `Type.typeof` draws the line the walk needs in one
	 * answer: a class instance is `TClass`, a function `TFunction`, every scalar its own case, and
	 * only a structure is `TObject` — so nothing has to be enumerated and a future field holding an
	 * instance is refused by the same test that admits a structure.
	 */
	private static function isAnonymousStructure(value: Any): Bool {
		return Type.typeof(value) == TObject;
	}

	/**
	 * Every `<slot>` under `value` that holds a string, mapped to that string — an array's index,
	 * a map's key, an anonymous structure's field name, joined with `.` through nesting, and the
	 * empty slot for a plain `String`.
	 *
	 * This is what lets a probe name a token WITHOUT copying it: the record carries the address,
	 * the shape carries the text, so a token that drifts is parsed in its new spelling.
	 */
	private static function slotTextsOf(value: Any, prefix: String, out: Map<String, String>): Void {
		if (Std.isOfType(value, String))
			out[prefix] = cast value;
		else if (Std.isOfType(value, Array)) {
			final items: Array<Any> = cast value;
			for (i in 0...items.length) slotTextsOf(items[i], prefix == '' ? '$i' : '$prefix.$i', out);
		} else if (Std.isOfType(value, StringMap))
			for (key => item in (cast value: StringMap<Any>)) slotTextsOf(item, prefix == '' ? key : '$prefix.$key', out);
		else if (isAnonymousStructure(value))
			for (field in Reflect.fields(value)) slotTextsOf(Reflect.field(value, field), prefix == '' ? field : '$prefix.$field', out);
	}

	/** The string the `<field>#<slot>` address points at, or null when the shape no longer holds that slot. */
	private static function slotTextAt(shape: RefShape, address: String): Null<String> {
		final cut: Int = address.indexOf('#');
		return cut < 0 ? null : slotText(shape, address.substring(0, cut), address.substring(cut + 1));
	}

	/** The string `slot` addresses inside `field`'s value, or null when the shape no longer holds it. */
	private static function slotText(shape: RefShape, field: String, slot: String): Null<String> {
		final texts: Map<String, String> = [];
		if (Reflect.hasField(shape, field)) slotTextsOf(Reflect.field(shape, field), '', texts);
		return texts[slot];
	}

	/**
	 * Whether `text` may be a name at all: every character may appear in an identifier, a qualified path or a type expression,
	 * AND the first one may START one: `Array<String>` and `haxe.macro.Expr.Position` are names, `&&`, `#if`, `@:` and
	 * `(` are not. The COMPLEMENT is where the token census derives its membership, which is the
	 * half of it that fails by default when a field lands.
	 *
	 * An empty string is not name-shaped, so a shape slot declaring one demands a probe and gets a red arm — there
	 * is no token to capture and no name to mean, and silence on it would be the same fail-open one layer down.
	 *
	 * The leading-character half is the S203 repair. `.` / `<` / `>` / `,` are admitted because `Array<String>` and
	 * `haxe.macro.Expr.Position` are names, and admitting them CHARACTER-wise let a slot spelling one of them ALONE read as a name
	 * and skip the census. No live slot is spelled that way, which is why the hole cost nothing and could stay open indefinitely;
	 * a name has to begin with a letter or `_`, and that is now the predicate rather than an observation about today's fields.
	 */
	private static function isNameShaped(text: String): Bool {
		if (text.length == 0) return false;
		final head: Int = text.fastCodeAt(0);
		if (!((head >= 'a'.code && head <= 'z'.code) || (head >= 'A'.code && head <= 'Z'.code) || head == '_'.code)) return false;
		for (i in 0...text.length) {
			final c: Int = text.fastCodeAt(i);
			final ok: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code)
				|| c == '_'.code || c == '.'.code || c == '<'.code || c == '>'.code || c == ','.code;
			if (!ok) return false;
		}
		return true;
	}

	/** Every `<field>#<slot>` of `shape` a capture probe has to cover, derived plus the declared keyword fields. */
	private static function tokenSlotsOf(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (field in Reflect.fields(shape)) {
			final texts: Map<String, String> = [];
			slotTextsOf(Reflect.field(shape, field), '', texts);
			for (slot => text in texts) {
				final address: String = '$field#$slot';
				if (TEMPLATE_SLOTS.contains(address)) continue;
				if (!isNameShaped(text) || KEYWORD_TOKEN_FIELDS.contains(field)) out.push(address);
			}
		}
		return out;
	}


	/**
	 * Whether some node of `probe.kind` under `node` carries `token` the way `probe.names` demands —
	 * as its NAME, as the head of its name, or merely inside its span.
	 */
	private static function capturesToken(node: QueryNode, source: String, probe: TokenProbe, token: String): Bool {
		return node.kind == probe.kind && carriesToken(node, source, probe.names, token)
			|| node.children.exists(child -> capturesToken(child, source, probe, token));
	}

	/** Whether `node` itself carries `token` under name mode `names`; an unknown mode is a gap, so it throws. */
	private static function carriesToken(node: QueryNode, source: String, names: String, token: String): Bool {
		return switch names {
			case NAME_IS: node.name == token;
			case NAME_OPENS:
				node.name != null && (node.name: String).startsWith(token);
			case NAME_NONE: spansToken(node, source, token);
			case _: throw 'unknown name mode "$names"';
		}
	}

	/** Whether `node`'s own span covers source text holding `token`. */
	private static function spansToken(node: QueryNode, source: String, token: String): Bool {
		final span: Null<Span> = node.span;
		return span != null && source.substring(span.from, span.to).indexOf(token) >= 0;
	}

	/** Whether some node of `kind` under `node` is NAMED exactly `token` — the promotion check a `NAME_NONE` probe owes. */
	private static function namesToken(node: QueryNode, kind: String, token: String): Bool {
		return node.kind == kind && node.name == token || node.children.exists(child -> namesToken(child, kind, token));
	}

	/** The construct sources of `lang`; a lang with none is a build-time gap, so it throws. */
	private static function kindSourcesFor(lang: String): Array<KindSource> {
		final sources: Null<Array<KindSource>> = KIND_SOURCES[lang];
		if (sources == null) throw 'no kind sources for grammar "$lang"';
		return sources;
	}

	/** The capture probes of `lang`; a lang with none is a build-time gap, so it throws. */
	private static function tokenProbesFor(lang: String): Array<TokenProbe> {
		final probes: Null<Array<TokenProbe>> = TOKEN_PROBES[lang];
		if (probes == null) throw 'no token-capture probes for grammar "$lang"';
		return probes;
	}

	/**
	 * Every distinct kind under `root`, excluding `root` itself. The root is the plugin's own
	 * `module` wrapper, minted in `treeFromRoot` rather than projected by the grammar, and no
	 * kind set declares it.
	 */
	private static function collectChildKinds(root: QueryNode, out: Array<String>): Void {
		for (child in root.children) collectKinds(child, out);
		if (root.type != null) collectKinds((root.type: QueryNode), out);
	}

	/**
	 * Every distinct kind in the subtree at `node`, the `type` SLOT included.
	 *
	 * A declared type is a slot and not a child (`QueryNode.type` says why), so a walk over
	 * `children` alone never reaches the type vocabulary: measured on this tree, descending it adds
	 * `ConditionalType`, `NamedParam`, `OptionalNamedParam`, `Positional` and `DollarType` to what a
	 * source can be seen to emit, and 3 of those 5 are reached by the repo's own sources — the arms
	 * below were blind to every one of them, in the ONE direction they exist to watch.
	 */
	private static function collectKinds(node: QueryNode, out: Array<String>): Void {
		if (!out.contains(node.kind)) out.push(node.kind);
		for (child in node.children) collectKinds(child, out);
		if (node.type != null) collectKinds((node.type: QueryNode), out);
	}

	#if (sys || nodejs)
	/**
	 * The projected vocabulary read from the other end: every kind a real parse emits has to
	 * be in it. The list is DERIVED from the grammar shape, so it can be wrong in this
	 * direction too — `TypeRef`, which the type-reference projection mints rather than the
	 * grammar, was missing from the first version of it.
	 */
	public function testTheProjectedVocabularyCoversWhatAParseEmits(): Void {
		final plugin: GrammarPlugin = CliArgs.pickPlugin('haxe');
		final projected: Array<String> = projectedKindsFor('haxe');
		// One grammar by design: the roots below are Haxe sources, so widening the loop would
		// hand another plugin a corpus in a language it cannot parse. The registry fixture is
		// what notices a second grammar; this arm stays where its corpus is.
		final emitted: Array<String> = [];
		var parsed: Int = 0;
		for (root in PARSE_ROOTS) for (path in hxSourcesUnder(root)) {
			final source: String = File.getContent(path);
			collectChildKinds(plugin.parseFile(source), emitted);
			collectChildKinds(plugin.parseFileTypeRefs(source), emitted);
			parsed++;
		}
		final roots: String = PARSE_ROOTS.join(', ');
		Assert.isTrue(parsed >= MIN_PARSED_FILES, '$parsed file(s) reached under $roots');
		Assert.isTrue(emitted.length >= MIN_EMITTED_KINDS, '${emitted.length} distinct kind(s) emitted by the parse arm');
		final missing: String = emitted.filter(kind -> !projected.contains(kind)).join(', ');
		Assert.equals('', missing, 'kind(s) a parse emits that the derived vocabulary omits: [$missing]');
		final reachable: String = (UNREACHABLE_KINDS['haxe'] ?? []).filter(kind -> emitted.contains(kind)).join(', ');
		Assert.equals('', reachable, 'kind(s) declared unreachable that this corpus DOES emit: [$reachable]');
	}

	/** Every `.hx` under `dir`, recursively. */
	private static function hxSourcesUnder(dir: String): Array<String> {
		final out: Array<String> = [];
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$entry';
			if (FileSystem.isDirectory(path))
				for (nested in hxSourcesUnder(path)) out.push(nested);
			else if (entry.endsWith('.hx'))
				out.push(path);
		}
		return out;
	}
	#end

}

/**
 * One token-capture probe: where the token lives in the shape (`field` plus the `slot` that
 * addresses it inside the field's value), the source that carries it (`before` + token +
 * `after`, either side free to spell `{}` for a second occurrence), and the `kind` the parse
 * has to project for the token to count as captured.
 */
typedef TokenProbe = {
	var field: String;
	var slot: String;
	var kind: String;

	/**
	 * How the projected node's NAME relates to the token — `NAME_IS`, `NAME_OPENS` or `NAME_NONE`.
	 * Declared and not derived: `Meta` names the token and `EnumAbstractDecl` names the type its
	 * body brace opens, and nothing in a parse tells those two apart.
	 */
	var names: String;

	var before: String;
	var after: String;
};

/**
 * One construct source: the kinds this source is `KIND_SOURCES`' cover for, and the source itself.
 *
 * `kinds` is a claim about this source and not a description of it — a source emits many more kinds
 * than it is the cover for, and listing only the ones it OWNS is what keeps every projected kind
 * attributable to exactly one row.
 */
typedef KindSource = {
	var kinds: Array<String>;
	var source: String;
};
