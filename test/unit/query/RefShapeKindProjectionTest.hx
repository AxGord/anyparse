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
 * Scope, stated: the fields this reads are `RefShape`'s, and it now reads them along TWO axes: kind NAMES against the
 * projected vocabulary, and declared TOKENS against what a parse of the smallest source carrying them captures. A
 * structure-valued field IS descended into (a kind name nested in one used to pass both arms); a class INSTANCE is not,
 * which today means `refsCache` and the engine caches behind it. Kind vocabularies hardcoded OUTSIDE `RefShape` —
 * `FieldRefScan.bindsNameHere`, `HaxeNamingSupport.categoryOf` — carry the same hazard and are still not reachable from here.
 */
@:nullSafety(Strict)
final class RefShapeKindProjectionTest extends Test {

	/** Floor under the number of `RefShape` fields the declared side reads (176 of 236 on this tree). */
	private static inline final MIN_KIND_FIELDS: Int = 160;

	/** Floor under the distinct kind names those fields declare (202 on this tree). */
	private static inline final MIN_DECLARED_KINDS: Int = 185;

	/** Floor under the projected vocabulary the declarations are checked against (238 on this tree). */
	private static inline final MIN_PROJECTED_KINDS: Int = 220;

	/**
	 * Floor under the distinct kinds the parse arm sees the tree's own sources emit (137 of the
	 * 238 projected, over 515 files). The gap is what this repo happens to spell: no `do while`,
	 * no `untyped`, no `overload`, no `>>>=`, so a ctor for one of those cannot be seen missing
	 * from here — that direction is the declared-side arm's job, not this one's.
	 */
	private static inline final MIN_EMITTED_KINDS: Int = 130;

	/** Floor under the number of `.hx` files the parse arm reaches — an empty walk asserts nothing. */
	private static inline final MIN_PARSED_FILES: Int = 450;

	/** Floor under the token-bearing slots the capture differential probes (34 on this tree). */
	private static inline final MIN_TOKEN_SLOTS: Int = 28;

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
	 * Fields whose token-shaped strings are EMISSION templates, not text any parse captures.
	 *
	 * `enumAbstractSyntax` is the whole list: its `head` carries `{name}` / `{under}` holes a
	 * fixer fills, so no source slice can ever contain it verbatim and a capture probe would be
	 * asserting the wrong thing. What owns it is the check that emits it
	 * (`unit.check.PreferEnumAbstractCheckTest`, over the produced fix text) — recorded here so
	 * the census admits the field by NAME and a second template field cannot join it in silence.
	 */
	private static final TEMPLATE_FIELDS: Array<String> = ['enumAbstractSyntax'];

	/**
	 * Per grammar, one probe per token-bearing slot: the smallest source that can carry the
	 * token, and the kind the parse must project for it to count as CAPTURED.
	 *
	 * `slot` addresses the string INSIDE the field's value — `''` for a plain `String` field, an
	 * index for an array, a key for a map, a field name for an anonymous structure — so a probe
	 * reads the shape's OWN text instead of a copy of it. That is what makes this a differential
	 * and not a string compare: a token that drifts is parsed in its NEW spelling, and the arm goes red on the parse rather
	 * than on an equality nobody wrote down. A probe is only as sharp as the kind it can name, though: where the grammar
	 * projects no node distinct to the token — `this`, `super`, `new`, `_` are ordinary identifiers to it — the probe proves
	 * the token PARSES in that position and nothing more, and a drift to another identifier would pass. The punctuation probes
	 * do not have that slack, since the drifted spelling stops parsing or projects a different node. `before` / `after` wrap
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
				before: 'class C { function f() { var a = b ',
				after: ' c; } }'
			},
			{
				field: 'conditionalElseKeywords',
				slot: '0',
				kind: 'Conditional',
				before: '#if js\nclass C {}\n',
				after: '\nclass D {}\n#end\n'
			},
			{
				field: 'conditionalElseKeywords',
				slot: '1',
				kind: 'Conditional',
				before: '#if js\nclass C {}\n',
				after: ' cpp\nclass D {}\n#end\n'
			},
			{
				field: 'conditionalEndKeyword',
				slot: '',
				kind: 'Conditional',
				before: '#if js\nclass C {}\n',
				after: '\n'
			},
			{
				field: 'conditionalIfKeyword',
				slot: '',
				kind: 'Conditional',
				before: '',
				after: ' js\nclass C {}\n#end\n'
			},
			{
				field: 'constructorName',
				slot: '',
				kind: 'FnMember',
				before: 'class C { function ',
				after: '() {} }'
			},
			{
				field: 'defaultVisibilityModifierText',
				slot: '',
				kind: 'Private',
				before: 'class C { ',
				after: ' var a: Int; }'
			},
			{
				field: 'descendantBuildMacroMetaNames',
				slot: '0',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'enumAbstractMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'finalClassMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'forwardingDeclMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'implicitConstructorDeclMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'metadataNamePrefixes',
				slot: '0',
				kind: 'Meta',
				before: '',
				after: 'keep class C {}'
			},
			{
				field: 'metadataNamePrefixes',
				slot: '1',
				kind: 'Meta',
				before: '',
				after: 'keep class C {}'
			},
			{
				field: 'nativeInteropDeclMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'nullCoalesceOperatorText',
				slot: '',
				kind: 'NullCoal',
				before: 'class C { function f() { var a = b ',
				after: ' c; } }'
			},
			{
				field: 'nullSafetyMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'operatorOverloadMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'parenDelimiters',
				slot: 'open',
				kind: 'ParenExpr',
				before: 'class C { function f() { var a = ',
				after: 'b); } }'
			},
			{
				field: 'parenDelimiters',
				slot: 'close',
				kind: 'ParenExpr',
				before: 'class C { function f() { var a = (b',
				after: '; } }'
			},
			{
				field: 'publicDefaultMetaNames',
				slot: '0',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'reflectedDeclMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'retainedDeclMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'selfReferenceText',
				slot: '',
				kind: 'IdentExpr',
				before: 'class C { function f() { var a = ',
				after: '; } }'
			},
			{
				field: 'staticlessTypeMetaNames',
				slot: '0',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'stringLiteralDelimiters',
				slot: 'DoubleStringExpr',
				kind: 'DoubleStringExpr',
				before: 'class C { function f() { var a = ',
				after: 'b"; } }'
			},
			{
				field: 'superReferenceText',
				slot: '',
				kind: 'IdentExpr',
				before: 'class C { function new() { ',
				after: '(); } }'
			},
			{
				field: 'takesPrivateAccessMetaName',
				slot: '',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'tuplePatternDelimiters',
				slot: 'open',
				kind: 'ArrayExpr',
				before: 'class C { function f() { switch v { case ',
				after: 'a, b]: 0; } } }'
			},
			{
				field: 'tuplePatternDelimiters',
				slot: 'close',
				kind: 'ArrayExpr',
				before: 'class C { function f() { switch v { case [a, b',
				after: ': 0; } } }'
			},
			{
				field: 'typeBuildMacroMetaNames',
				slot: '0',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'typeBuildMacroMetaNames',
				slot: '1',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'typeBuildMacroMetaNames',
				slot: '2',
				kind: 'Meta',
				before: '',
				after: ' class C {}'
			},
			{
				field: 'wildcardPatternName',
				slot: '',
				kind: 'IdentExpr',
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
	 * The membership is DERIVED for the punctuation half — a string holding a character no
	 * identifier may carry has to be a token, so a new field spelling one fails HERE until someone
	 * writes it a probe. The keyword half cannot be derived (`this` and `Bool` are the same shape)
	 * and is listed instead, so what this arm adds over the list is the direction the list cannot
	 * give: exact coverage, both ways.
	 */
	public function testEveryTokenBearingSlotIsProbedOrDeclaredATemplate(): Void {
		for (lang in CliArgs.langNames()) {
			final shape: RefShape = CliArgs.pickPlugin(lang).refShape();
			final probed: Array<String> = [for (probe in tokenProbesFor(lang)) '${probe.field}#${probe.slot}'];
			final wanted: Array<String> = tokenSlotsOf(shape);
			probed.sort(Reflect.compare);
			wanted.sort(Reflect.compare);
			Assert.isTrue(wanted.length >= MIN_TOKEN_SLOTS, '$lang: ${wanted.length} token-bearing slot(s)');
			final declaredFields: Array<String> = KEYWORD_TOKEN_FIELDS.concat(TEMPLATE_FIELDS);
			final live: Array<String> = declaredFields.filter(field -> Reflect.hasField(shape, field));
			declaredFields.sort(Reflect.compare);
			live.sort(Reflect.compare);
			Assert.equals(declaredFields.join(', '), live.join(', '), '$lang: keyword/template field(s) the shape no longer declares');
			Assert.equals(wanted.join(', '), probed.join(', '), '$lang: token-bearing slots and capture probes differ');
		}
	}

	/**
	 * The SECOND differential: a token the shape declares has to be text this grammar's own parser
	 * captures.
	 *
	 * The first one compares kind NAMES, so every field whose value is a token — `@:` and `@`, the
	 * quote a string literal carries, `&&`, `#if`, `this` — was checked by nothing at all: a stale
	 * one fails open exactly the way a stale kind does, silently, with an `Array<String>` that no
	 * build can typo-check. Here each token is read out of the shape by ADDRESS, wrapped in the
	 * smallest source that can carry it, and the parse has to project the declared kind over text
	 * that contains it. The oracle is the generated parser, whose author is not the hand-typed
	 * shape's — which is what keeps this from being a string compare with extra steps.
	 *
	 * KILLED by arm `M-AND-OPERATOR-TEXT-STALE`, which respells `andOperatorText` as the single
	 * `&`: still a real Haxe operator, so the probe source still parses — and projects `BitAnd`,
	 * so nothing in the tree changes except that a declared token stops being the one the parser
	 * reads. That is the whole failure mode this arm exists for.
	 */
	@:pin('control')
	@:killer('M-AND-OPERATOR-TEXT-STALE')
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
				final source: String = probe.before + token + probe.after;
				final captured: Bool = try capturesToken(
					plugin.parseFile(source), source, probe.kind, token
				) catch (exception: Exception) false;
				if (!captured) missed.push('${probe.field}#${probe.slot} "$token" as ${probe.kind}');
			}
			final loose: String = missed.join(', ');
			Assert.equals('', loose, '$lang: declared token(s) no parse of this grammar captures: [$loose]');
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

	/** The string `slot` addresses inside `field`'s value, or null when the shape no longer holds it. */
	private static function slotText(shape: RefShape, field: String, slot: String): Null<String> {
		final texts: Map<String, String> = [];
		if (Reflect.hasField(shape, field)) slotTextsOf(Reflect.field(shape, field), '', texts);
		return texts[slot];
	}

	/**
	 * Whether every character of `text` may appear in an identifier, a qualified path or a type
	 * expression: `Array<String>` and `haxe.macro.Expr.Position` are names, `&&`, `#if`, `@:` and
	 * `(` are not. The COMPLEMENT is where the token census derives its membership, which is the
	 * half of it that fails by default when a field lands.
	 *
	 * An empty string is not name-shaped, so a shape slot declaring one demands a probe and gets
	 * a red arm — there is no token to capture and no name to mean, and silence on it would be
	 * the same fail-open one layer down.
	 */
	private static function isNameShaped(text: String): Bool {
		if (text.length == 0) return false;
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
		for (field in Reflect.fields(shape)) if (!TEMPLATE_FIELDS.contains(field)) {
			final texts: Map<String, String> = [];
			slotTextsOf(Reflect.field(shape, field), '', texts);
			for (slot => text in texts) if (!isNameShaped(text) || KEYWORD_TOKEN_FIELDS.contains(field)) out.push('$field#$slot');
		}
		return out;
	}


	/** Whether any node of `kind` under `node` spans source that contains `token`. */
	private static function capturesToken(node: QueryNode, source: String, kind: String, token: String): Bool {
		final span: Null<Span> = node.span;
		if (node.kind == kind && span != null && source.substring(span.from, span.to).indexOf(token) >= 0) return true;
		return node.children.exists(child -> capturesToken(child, source, kind, token));
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
	}

	/** Every distinct kind in the subtree at `node`. */
	private static function collectKinds(node: QueryNode, out: Array<String>): Void {
		if (!out.contains(node.kind)) out.push(node.kind);
		for (child in node.children) collectKinds(child, out);
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
	var before: String;
	var after: String;
};
