package anyparse.check.common.members;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.common.design.ConfiguredTypes;
import anyparse.query.CondRegionScan;
import anyparse.query.ElementSpan;
import anyparse.query.LexicalRegions;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import haxe.ds.ArraySort;

using anyparse.util.Groups;

/**
 * One top-level type declaration of a module, in source order. `slot` is the source it owns as
 * a movable unit - leading doc comment, metadata and modifier run, the declaration, a comment
 * closing its last line - and is null on the report path, which moves nothing. `region` names
 * the conditional-compilation region holding the declaration, 0 for the module's top level: a
 * reorder moves the declarations of one region among themselves only. `rank` is its place in
 * the `kindOrder` option, the option's length when unlisted; `after` says a secondary type's
 * word is in the `afterMainKinds` option.
 */
private typedef ModuleType = {
	final name: String;
	final word: String;
	final isMain: Bool;
	final rank: Int;
	final after: Bool;
	final span: Span;
	final region: Int;
	final slot: Null<Span>;
}

/** A pair the options forbid: `earlier` precedes `later` in the source but must follow it, for `reason`. */
private typedef OrderBreak = { final earlier: ModuleType; final later: ModuleType; final reason: String; }

/**
 * The one answer to "is a module's set of top-level type declarations in the configured order":
 * the `module-type-order` check and its reordering fix. The module's MAIN type - the one named
 * like its file - goes where the `mainType` option says (`last`, the default: every secondary
 * type precedes it; `first`; or `any`, which leaves it where it is), and the secondary types
 * follow the `kindOrder` option, a list of the grammar's declaration words
 * (`RefShape.typeDeclKindWords`); an unlisted kind ranks after every listed one, and an empty
 * list keeps their source order. With `mainType` `last` and a main type present, the
 * `afterMainKinds` option names the words whose types go after the main type instead, every
 * other secondary type staying before it; `kindOrder` then orders each
 * side apart. The fix is a stable permutation of whole slots that keeps the
 * blank-line layout positional, so the gap between the k-th and the next declaration stays what
 * the source wrote there. It is withheld, the finding kept with its reason, when the moved range
 * spans more than one conditional region (the top level counting as one), or when anything but whitespace separates
 * two of its slots - a comment no slot owns, a module-level function, a conditional block - since
 * a permutation would carry that to the wrong neighbour.
 */
@:nullSafety(Strict)
final class ModuleTypeOrder extends RuleBase implements DefaultOff implements ConfigAware implements OptionKeyed {

	private static inline final RULE_ID: String = 'module-type-order';

	/** The option placing the main type. */
	private static final OPTION_MAIN: String = 'mainType';

	private static final MAIN_LAST: String = 'last';
	private static final MAIN_FIRST: String = 'first';
	private static final MAIN_ANY: String = 'any';

	/** The option ordering the secondary types by declaration word. */
	private static final OPTION_KINDS: String = 'kindOrder';

	/** The option naming the declaration words whose secondary types go after the main type. */
	private static final OPTION_AFTER: String = 'afterMainKinds';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID,
			'a module\'s top-level type declarations not in the configured order (the main type last by default, the other types '
			+ 'by the kindOrder option)',
			RuleCategory.Members
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collect(files, plugin, (entry, tree, violations) -> {
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			warnUnknownAfterKinds(config, plugin);
			final regions: () -> Array<LexRegion> = ElementSpan.lazyRegions(entry.source, plugin);
			final types: Array<ModuleType> = typesOf(
				entry.file, entry.source, tree, plugin, kindOrderOf(config), afterKindsOf(config), regions, false
			);
			final broken: Null<OrderBreak> = firstBreak(types, mainPlacement(config));
			if (broken == null) return;
			violations.push({
				file: entry.file,
				span: broken.later.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: '${broken.later.word} ${broken.later.name} follows ${broken.earlier.word} ${broken.earlier.name}: ${broken.reason}'
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return violations.length == 0
			? []
			: RunScan.edits(plugin, source, tree -> {
				final file: String = violations[0].file;
				final config: LintConfig = LintConfig.resolveWith(_resolveConfig, file);
				final regions: () -> Array<LexRegion> = ElementSpan.lazyRegions(source, plugin);
				final types: Array<ModuleType> = typesOf(
					file, source, tree, plugin, kindOrderOf(config), afterKindsOf(config), regions, true
				);
				final sorted: Array<ModuleType> = canonicalOrder(types, mainPlacement(config));
				var lo: Int = 0;
				while (lo < types.length && types[lo] == sorted[lo]) lo++;
				if (lo == types.length) return [];
				var hi: Int = types.length - 1;
				while (types[hi] == sorted[hi]) hi--;
				// The two orders agree outside `lo..hi`, so `sorted` holds exactly the declarations of `moved` there.
				final moved: Array<ModuleType> = types.slice(lo, hi + 1);
				final slots: Array<Span> = [];
				for (type in moved) {
					final slot: Null<Span> = type.slot;
					if (slot == null || type.region != moved[0].region) {
						// Of two declarations in different regions, the one not on the top level is the one under `#if`.
						final guarded: ModuleType = type.region == 0 ? moved[0] : type;
						return decline(
							violations,
							'${guarded.word} ${guarded.name} sits inside a conditional region the reorder would have to move or cross'
						);
					}
					slots.push(slot);
				}
				final stray: Null<Int> = strayGap(source, slots);
				if (stray != null)
					return decline(
						violations,
						'something other than blank lines separates ${moved[stray].name} from ${moved[stray + 1].name} (a comment no '
						+ 'declaration owns, a module-level declaration or a conditional block), which a reorder would carry to the wrong '
						+ 'neighbour'
					);
				final parts: Array<String> = [];
				for (k in 0...moved.length) {
					final slot: Span = slots[moved.indexOf(sorted[lo + k])];
					parts.push(source.substring(slot.from, slot.to));
					if (k + 1 < moved.length) parts.push(source.substring(slots[k].to, slots[k + 1].from));
				}
				return [
					{ span: new Span(slots[0].from, slots[slots.length - 1].to), text: parts.join('') }
				];
			});
	}

	public function acceptedOptions(): Array<String> {
		return [OPTION_MAIN, OPTION_KINDS, OPTION_AFTER];
	}

	/** Refuses, as a config diagnostic, each `afterMainKinds` word the grammar does not declare a type kind under. */
	private function warnUnknownAfterKinds(config: LintConfig, plugin: GrammarPlugin): Void {
		final known: Array<String> = [];
		for (word in (plugin.refShape().typeDeclKindWords ?? [])) known.pushUnique(word);
		ArraySort.sort(known, Reflect.compare);
		for (word in afterKindsOf(config)) if (!known.contains(word))
			ConfiguredTypes.warn(
				_configNotes, RULE_ID, '$OPTION_AFTER names "$word", which is not a type declaration word (${known.join(', ')})'
			);
	}

	private static inline function kindOrderOf(config: LintConfig): Array<String> {
		return config.stringListOption(RULE_ID, OPTION_KINDS) ?? [];
	}

	private static inline function afterKindsOf(config: LintConfig): Array<String> {
		return config.stringListOption(RULE_ID, OPTION_AFTER) ?? [];
	}

	/** Whether `afterMainKinds` applies: the main type goes last and the module has one to go after. */
	private static inline function splitsAroundMain(types: Array<ModuleType>, main: String): Bool {
		return main == MAIN_LAST && types.exists(t -> t.isMain);
	}

	/** The `mainType` option; an unrecognised value reads as the default `last`. */
	private static function mainPlacement(config: LintConfig): String {
		final value: Null<String> = config.stringOption(RULE_ID, OPTION_MAIN);
		return switch (value) {
			case MAIN_FIRST: MAIN_FIRST;
			case MAIN_ANY: MAIN_ANY;
			case _: MAIN_LAST;
		};
	}

	/**
	 * The module's type declarations in source order: the top level's own, each with its slot when
	 * `withSlots` (the fix path), and those inside a conditional region at any depth, each region
	 * numbered apart from the top level and from every other region.
	 */
	private static function typesOf(
		file: String, source: String, tree: QueryNode, plugin: GrammarPlugin, kindOrder: Array<String>, afterKinds: Array<String>,
		regions: () -> Array<LexRegion>, withSlots: Bool
	): Array<ModuleType> {
		final shape: RefShape = plugin.refShape();
		final words: Map<String, String> = shape.typeDeclKindWords ?? [];
		final mainName: String = RefactorSupport.moduleNameOf(file);
		final out: Array<ModuleType> = [];
		var regionCount: Int = 0;
		function visit(parent: QueryNode, region: Int): Void {
			for (child in parent.children) {
				final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(child);
				if (decl == null) {
					if (CondRegionScan.isConditionalKind(child.kind, shape)) visit(child, ++regionCount);
					continue;
				}
				final group: Span = ElementSpan.declGroupSpan(decl.declNode, parent, decl.fullSpan);
				final word: String = words[decl.kind] ?? decl.kind;
				final listed: Int = kindOrder.indexOf(word);
				final isMain: Bool = decl.name == mainName;
				out.push({
					name: decl.name,
					word: word,
					isMain: isMain,
					rank: listed < 0 ? kindOrder.length : listed,
					after: !isMain && afterKinds.contains(word),
					span: new Span(decl.fullSpan.from, ElementSpan.trailingTrimmedSpan(source, group, regions).to),
					region: region,
					slot: withSlots ? slotSpan(source, group, regions) : null
				});
			}
		}
		visit(tree, 0);
		return out;
	}

	/** The bytes a top-level declaration owns as a movable unit (`ModuleType.slot`). */
	private static function slotSpan(source: String, group: Span, regions: () -> Array<LexRegion>): Span {
		final owned: Span = ElementSpan.trailingTrimmedSpan(source, group, regions);
		return ElementSpan.docExtendedSpan(source, ElementSpan.lineClosingCommentSpan(source, owned, regions), regions());
	}

	/**
	 * The first forbidden pair in source order of its LATER member. The main type is compared
	 * only by `mainType`, the secondary types by side of the main type, then by rank.
	 */
	private static function firstBreak(types: Array<ModuleType>, main: String): Null<OrderBreak> {
		final split: Bool = splitsAroundMain(types, main);
		for (j in 1...types.length) for (i in 0...j) {
			final reason: Null<String> = breakReason(types[i], types[j], main, split);
			if (reason != null) return { earlier: types[i], later: types[j], reason: reason };
		}
		return null;
	}

	private static function breakReason(earlier: ModuleType, later: ModuleType, main: String, split: Bool): Null<String> {
		if (earlier.isMain && later.isMain) return null;
		if (earlier.isMain)
			return main == MAIN_LAST && !(split && later.after) ? 'mainType "last" puts every other type before the main type' : null;
		final afterReason: String = 'afterMainKinds puts ${earlier.word} after the main type';
		if (later.isMain) {
			if (split && earlier.after) return afterReason;
			return main == MAIN_FIRST ? 'mainType "first" puts the main type before every other type' : null;
		}
		if (split && earlier.after != later.after) return earlier.after ? afterReason : null;
		return earlier.rank > later.rank ? 'kindOrder puts ${later.word} before ${earlier.word}' : null;
	}

	/**
	 * `types` in the order the options ask: the secondary types stably sorted by rank (the
	 * `afterMainKinds` ones behind the rest when the main type goes last), the main type placed
	 * after the others (`last`; before the `afterMainKinds` ones), prepended (`first`) or kept at its own index (`any`). It holds no
	 * pair `firstBreak` reports, so one fix pass converges.
	 */
	private static function canonicalOrder(types: Array<ModuleType>, main: String): Array<ModuleType> {
		final mains: Array<ModuleType> = types.filter(t -> t.isMain);
		final others: Array<ModuleType> = types.filter(t -> !t.isMain);
		final split: Bool = splitsAroundMain(types, main);
		ArraySort.sort(others, (a, b) -> split && a.after != b.after ? (a.after ? 1 : -1) : a.rank - b.rank);
		if (mains.length == 0) return others;
		final at: Int = switch (main) {
			case MAIN_FIRST: 0;
			case MAIN_ANY: types.indexOf(mains[0]);
			case _: others.filter(t -> !t.after).length;
		};
		return others.slice(0, at).concat(mains).concat(others.slice(at));
	}

	/** The index of the first slot whose gap to the next one holds anything but whitespace, or null. */
	private static function strayGap(source: String, slots: Array<Span>): Null<Int> {
		for (k in 0...slots.length - 1)
			for (at in slots[k].to ... slots[k + 1].from)
				if (!SourceText.isSpace(source.fastCodeAt(at))) return k;
		return null;
	}

	/** Withhold the fix: every finding of the file carries `reason`, and no edit is written. */
	private static function decline(violations: Array<Violation>, reason: String): Array<{ span: Span, text: String }> {
		for (v in violations) v.declineReason = reason;
		return [];
	}

}
