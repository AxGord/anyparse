package unit.query;

import anyparse.grammar.haxe.HaxeQueryWalker;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.cli.CliArgs;
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
 * `RefShape` publishes 233 fields, 172 of which carry a kind name or a set of them (200 distinct names in all),
 * and a kind set is an `Array<String>`. A name the grammar stopped spelling — or never spelled — therefore
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
 * Scope, stated: the fields this reads are `RefShape`'s. Kind vocabularies hardcoded
 * OUTSIDE it — `FieldRefScan.bindsNameHere`, `HaxeNamingSupport.categoryOf` — carry the same
 * hazard and are not reachable from here; so are strings nested inside a field's anonymous
 * structure, which `stringsOf` deliberately does not descend into.
 */
@:nullSafety(Strict)
final class RefShapeKindProjectionTest extends Test {

	/** Floor under the number of `RefShape` fields the declared side reads (172 on this tree). */
	private static inline final MIN_KIND_FIELDS: Int = 160;

	/** Floor under the distinct kind names those fields declare (200 on this tree). */
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

	/**
	 * The `RefShape` fields that hold kind names without saying `Kind` in their name.
	 *
	 * `leftAssociativeBinaryFamilies` is `Array<Array<String>>` of operator KINDS grouped by
	 * precedence tier. Its name describes the grouping, not the contents, so the name-based
	 * reading would skip it — and `testNoUnclassifiedFieldCarriesAProjectedKindName` is what
	 * stops a future field from being skipped the same way in silence.
	 */
	private static final EXTRA_KIND_FIELDS: Array<String> = ['leftAssociativeBinaryFamilies'];

	/** The `RefShape` fields whose map KEYS are kind names — `literalTypeNames` maps kind to type. */
	private static final KIND_KEYED_MAP_FIELDS: Array<String> = ['literalTypeNames'];

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
			final fields: Array<String> = kindFieldsOf(shape);
			final declared: Array<String> = declaredKindsOf(shape, fields);
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
			final declared: Array<String> = declaredKindsOf(shape, kindFieldsOf(shape));
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
			final declared: Array<String> = declaredKindsOf(shape, kindFieldsOf(shape));
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
	 * of quietly leaving its 233 declarations unchecked.
	 */
	public function testEveryRegisteredGrammarHasAProjectedKindSource(): Void {
		final langs: Array<String> = CliArgs.langNames();
		Assert.isTrue(langs.length > 0, 'the grammar registry is empty');
		for (lang in langs) {
			if (projectedKindsSourceFor(lang) == null)
				Assert.fail('grammar "$lang" declares a RefShape but this fixture has no projected-kind source for it');
			if (ambiguousKindsSourceFor(lang) == null)
				Assert.fail('grammar "$lang" declares a RefShape but this fixture has no shared-spelling source for it');
			if (!KNOWN_AMBIGUOUS.exists(lang))
				Assert.fail('grammar "$lang" declares a RefShape but names no audited set of shared kind spellings');
		}
	}

	/**
	 * A field whose name does not say `Kind` and whose value nonetheless holds a projected
	 * kind name is either a kind set the name-based reading would skip, or a type name that
	 * happens to be spelled like one. Both are decisions, so both are written down — and a
	 * NEW such field fails here rather than escaping the arm above.
	 */
	public function testNoUnclassifiedFieldCarriesAProjectedKindName(): Void {
		final classified: Array<String> = EXTRA_KIND_FIELDS.concat(KIND_KEYED_MAP_FIELDS).concat(KIND_LOOKALIKE_FIELDS);
		final expected: Array<String> = classified.copy();
		expected.sort(Reflect.compare);
		for (lang in CliArgs.langNames()) {
			final shape: RefShape = CliArgs.pickPlugin(lang).refShape();
			final projected: Array<String> = projectedKindsFor(lang);
			final unclassified: Array<String> = [];
			for (field in Reflect.fields(shape)) if (field.indexOf('Kind') < 0 && !classified.contains(field)) {
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

	/** The projected vocabulary of `lang`, or null when this fixture knows no source for it. */
	private static function projectedKindsSourceFor(lang: String): Null<Array<String>> {
		return switch lang {
			case 'haxe': HaxeQueryWalker.projectedKinds();
			case _: null;
		};
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

	/** The projected vocabulary of `lang`; a lang with none is a build-time gap, so it throws. */
	private static function projectedKindsFor(lang: String): Array<String> {
		final kinds: Null<Array<String>> = projectedKindsSourceFor(lang);
		if (kinds == null) throw 'no projected-kind source for grammar "$lang"';
		return kinds;
	}

	/** The `RefShape` fields the declared side reads: named `*Kind*`, or classified as kind-bearing. */
	private static function kindFieldsOf(shape: RefShape): Array<String> {
		final classified: Array<String> = EXTRA_KIND_FIELDS.concat(KIND_KEYED_MAP_FIELDS);
		return Reflect.fields(shape).filter(field -> field.indexOf('Kind') >= 0 || classified.contains(field));
	}

	/** Every distinct kind name `fields` declare — a map field contributes its KEYS, an array its strings. */
	private static function declaredKindsOf(shape: RefShape, fields: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (field in fields) {
			final names: Array<String> = [];
			if (KIND_KEYED_MAP_FIELDS.contains(field)) {
				final value: Any = Reflect.field(shape, field);
				if (Std.isOfType(value, StringMap)) for (key in (cast value: StringMap<Any>).keys()) names.push(key);
			} else
				stringsOf(Reflect.field(shape, field), names);
			for (name in names) if (!out.contains(name)) out.push(name);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/**
	 * Every string `value` carries: itself, an array's elements at any nesting, a map's keys
	 * and its string values. An anonymous structure is deliberately NOT descended into —
	 * `refsCache` reaches the engine's own caches from there, and no kind name is spelled
	 * inside one today.
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
