package dev;

import anyparse.ds.Set;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.IndexScope;
import anyparse.query.OwnerIndex;
import devkit.Args;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/** How firmly the owner index says a declaration repeats the question of another component. */
enum abstract Confidence(Int) {

	/** The other component states the question it owns, and the two docs reach the similarity floor. */
	final High = 0;

	/** The two docs say the question in nearly the same words, and the other states no owned question. */
	final Medium = 1;

	/** The docs share most of their words. */
	final Low = 2;

	public inline function label(): String {
		return switch abstract {
			case High: 'high';
			case Medium: 'medium';
			case Low: 'low';
		}
	}

	public inline function order(): Int {
		return this;
	}

}

/** One declaration whose question another component already answers. */
typedef Overlap = {

	final entry: OwnerEntry;
	final owner: OwnerEntry;

	/** How much of the larger sense the two share, `OwnerOverlap.similarity`. */
	final similarity: Float;
	final confidence: Confidence;

}

/** A declared independent implementation: the declaration, the owner it may repeat (`*` for any), and why. */
typedef Allowed = {
	final declaration: String;
	final owner: String;
	final reason: String;
}

/** What `census` asks the owner index with. */
typedef OverlapConfig = {

	/** The least `OwnerOverlap.similarity` a lookalike has to reach. */
	final similarity: Float;

	/** How many ranked answers are read per question. */
	final top: Int;

	/** The fewest search terms a question needs to be asked at all. */
	final minTerms: Int;

	/** How many types declaring one member name make it an interface or registry hook rather than a repeat. */
	final interfaceWidth: Int;

}

/** The census of a scope: what was asked, what was set aside and why, and every overlap found. */
typedef Census = {
	final considered: Int;
	final interfaceShaped: Int;
	final excused: Int;
	final overlaps: Array<Overlap>;
}

/**
 * The one answer to "which declarations answer a question another component already owns": `dev owner-overlap
 * <repo-root> [<dir>...] [--similarity F] [--top N] [--min-terms N] [--interface-width N] [--allow FILE]` asks the owner
 * index (`OwnerIndex`) with each documented declaration's own first sentence, or the question its doc says it owns, and
 * reports the declarations of another type whose doc says the same in nearly the same words, grouped by that owner.
 * `duplicate-code` and `clone-census` find textual clones; this finds a second implementation written in other words.
 * A hit is a lead read by a person, never a verdict.
 *
 * `<dir>` defaults to `src tools/src`. `--allow` names a tab-separated file of `declaration<TAB>owner<TAB>reason` rows
 * (`Type`, `Type.member`, either with one `*` at an end for any text, or a bare `*` in the owner column) for independent
 * implementations that repeat a question on purpose; a row without a reason is refused.
 */
@:nullSafety(Strict)
final class OwnerOverlap {

	public static inline final USAGE: String = 'usage: dev owner-overlap <repo-root> [<dir>...] [--similarity F] [--top N]'
		+ ' [--min-terms N] [--interface-width N] [--allow FILE]';

	/** The allow-list read when `--allow` names none and the file exists. */
	public static inline final DEFAULT_ALLOW: String = 'tools/owner-overlap.allow';

	public static final DEFAULTS: OverlapConfig = {
		similarity: 0.6,
		top: 30,
		minTerms: 3,
		interfaceWidth: 6
	};

	private static inline final ANY: String = '*';

	/** The fewest words a type name has for a doc carrying them to point at that type: a one-word name is a common word. */
	private static inline final MIN_NAME_TERMS: Int = 2;

	/** A similarity is shown to two decimals. */
	private static inline final HUNDREDTHS: Int = 100;

	/** The similarity from which two docs are the same sentence in other inflections. */
	private static inline final NEAR_IDENTICAL: Float = 0.8;

	private static inline final ALLOW_COLUMNS: Int = 3;

	/** The directories read when none is given. */
	private static final DEFAULT_DIRS: Array<String> = ['src', 'tools/src'];

	/** Run the subcommand over `argv`; answers the exit status. */
	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final similarity: Null<String> = args.option('--similarity');
		final top: Null<String> = args.option('--top');
		final minTerms: Null<String> = args.option('--min-terms');
		final width: Null<String> = args.option('--interface-width');
		final allow: Null<String> = args.option('--allow');
		final given: Array<String> = args.rest(['<repo-root>']);
		final root: String = given[0];
		final dirs: Array<String> = given.length > 1 ? given.slice(1) : DEFAULT_DIRS;
		final config: OverlapConfig = {
			similarity: similarity == null ? DEFAULTS.similarity : floatOption('--similarity', similarity),
			top: top == null ? DEFAULTS.top : intOption('--top', top),
			minTerms: minTerms == null ? DEFAULTS.minTerms : intOption('--min-terms', minTerms),
			interfaceWidth: width == null ? DEFAULTS.interfaceWidth : intOption('--interface-width', width)
		};
		final allowFile: String = allow ?? Path.join([root, DEFAULT_ALLOW]);
		final allowed: Array<Allowed> = allow != null || FileSystem.exists(allowFile) ? parseAllowed(File.getContent(allowFile)) : [];
		final files: Array<SourceFile> = [];
		for (dir in dirs) {
			final base: String = Path.join([root, dir]);
			final found: Array<SourceFile> = [];
			EdgeDiff.collect(base, found);
			for (f in found) files.push({ file: Path.join([dir, f.file.substr(base.length + 1)]), source: f.source });
		}
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final owners: OwnerIndex = OwnerIndex.build(IndexScope.over(files, plugin), plugin);
		Sys.println(render(census(owners, allowed, config)).join('\n'));
		return 0;
	}

	/** Every declaration of `index` whose question another type's declaration answers in nearly its words, minus what `allowed` excuses. */
	public static function census(index: OwnerIndex, allowed: Array<Allowed>, config: OverlapConfig): Census {
		final widths: Map<String, Int> = memberWidths(index.entries);
		final found: Array<Overlap> = [];
		var considered: Int = 0;
		var interfaceShaped: Int = 0;
		var excused: Int = 0;
		for (entry in index.entries) {
			final question: String = entry.question ?? entry.summary;
			if (OwnerIndex.terms(question).length < config.minTerms) continue;
			considered++;
			final member: Null<String> = entry.member;
			if (member != null && (widths[member] ?? 0) >= config.interfaceWidth) {
				interfaceShaped++;
				continue;
			}
			final overlap: Null<Overlap> = overlapOf(
				index, entry, index.rank(question, config.top).map(hit -> hit.entry), config.similarity
			);
			if (overlap == null) continue;
			if (isAllowed(allowed, overlap)) {
				excused++;
				continue;
			}
			found.push(overlap);
		}
		return {
			considered: considered,
			interfaceShaped: interfaceShaped,
			excused: excused,
			overlaps: withoutEchoes(found)
		};
	}

	/**
	 * The overlap `entry` has with the most similar `candidate` that `rivals` it and reaches `threshold`, or null.
	 * `High` when that candidate states the question it owns, `Medium` when the wording is nearly identical, `Low` otherwise.
	 */
	public static function overlapOf(index: OwnerIndex, entry: OwnerEntry, candidates: Array<OwnerEntry>, threshold: Float): Null<Overlap> {
		var best: Null<OwnerEntry> = null;
		var top: Float = 0;
		for (candidate in candidates) if (rivals(entry, candidate)) {
			final similar: Float = similarity(index, entry, candidate);
			if (similar > top) {
				top = similar;
				best = candidate;
			}
		}
		if (best == null || top < threshold) return null;
		final confidence: Confidence = if (best.question != null)
			High
		else if (top >= NEAR_IDENTICAL)
			Medium
		else
			Low;
		return {
			entry: entry,
			owner: best,
			similarity: top,
			confidence: confidence
		};
	}

	/**
	 * Whether `candidate` could be a second implementation of what `entry` does: documented, in another file, and neither doc
	 * names the other's type (a doc that points at its neighbour describes a delegate or a consumer, not a rival).
	 */
	public static function rivals(entry: OwnerEntry, candidate: OwnerEntry): Bool {
		return candidate.summary != '' && candidate.file != entry.file && !mentions(entry, candidate) && !mentions(candidate, entry);
	}

	/**
	 * How much two declarations' docs say alike: the rarity of the search terms two senses have in common over that of all
	 * the terms either has, the best over the senses each doc offers (its owned question, its first sentence). A word most
	 * declarations carry (`name`, `type`) adds little, and a long doc containing a short one's words does not match it.
	 */
	public static function similarity(index: OwnerIndex, a: OwnerEntry, b: OwnerEntry): Float {
		var best: Float = 0;
		for (left in sensesOf(a)) for (right in sensesOf(b)) {
			var common: Float = 0;
			for (term in left) if (right.contains(term)) common += index.rarity(term);
			final union: Float = weight(index, left) + weight(index, right) - common;
			if (union > 0) best = Math.max(best, common / union);
		}
		return best;
	}

	/** The rows of an allow-list text: blank lines and `#` lines are skipped, a row without three columns or a reason is refused. */
	public static function parseAllowed(text: String): Array<Allowed> {
		final out: Array<Allowed> = [];
		for (number => line in text.replace('\r', '').split('\n')) if (line.trim() != '' && !line.startsWith('#')) {
			final columns: Array<String> = line.split('\t');
			if (columns.length < ALLOW_COLUMNS || columns[2].trim() == '')
				throw new UsageError('allow-list line ${number + 1} needs declaration, owner and a reason');
			out.push({ declaration: columns[0].trim(), owner: columns[1].trim(), reason: columns[2].trim() });
		}
		return out;
	}

	/** The report lines: the tally, the overlaps per directory, then each owner with the declarations repeating its question. */
	public static function render(result: Census): Array<String> {
		final lines: Array<String> = [
			'owner-overlap: ${result.considered} questions asked, ${result.interfaceShaped} interface-shaped members set aside,'
				+ ' ${result.excused} excused by the allow-list, ${result.overlaps.length} overlaps'
		];
		final perDir: Map<String, Int> = [];
		for (o in result.overlaps) {
			final dir: String = Path.directory(o.entry.file);
			perDir[dir] = (perDir[dir] ?? 0) + 1;
		}
		final dirs: Array<String> = [for (dir in perDir.keys()) dir];
		dirs.sort(compareText);
		for (dir in dirs) lines.push('  $dir\t${perDir[dir] ?? 0}');
		final groups: Map<String, Array<Overlap>> = [];
		for (o in result.overlaps) {
			final key: String = OwnerIndex.nameOf(o.owner);
			final group: Array<Overlap> = groups[key] ?? [];
			group.push(o);
			groups[key] = group;
		}
		final keys: Array<String> = [for (key in groups.keys()) key];
		keys.sort((a, b) -> {
			final size: Int = (groups[b] ?? []).length - (groups[a] ?? []).length;
			return size != 0 ? size : compareText(a, b);
		});
		for (key in keys) {
			final group: Array<Overlap> = groups[key] ?? [];
			group.sort((a, b) -> {
				final byConfidence: Int = a.confidence.order() - b.confidence.order();
				return if (byConfidence != 0)
					byConfidence
				else if (a.similarity > b.similarity)
					-1
				else if (a.similarity < b.similarity)
					1
				else
					0;
			});
			final owner: OwnerEntry = group[0].owner;
			lines.push('owner $key  ${owner.file}:${owner.line}  ${owner.summary}');
			for (o in group) {
				final ratio: String = Std.string(Math.round(o.similarity * HUNDREDTHS) / HUNDREDTHS);
				lines.push(
					'  [${o.confidence.label()} $ratio] ${OwnerIndex.nameOf(o.entry)}  ${o.entry.file}:${o.entry.line}  ${o.entry.summary}'
				);
			}
		}
		return lines;
	}

	/** Whether the doc of `from` carries every word of the name of `to`'s type. */
	private static function mentions(from: OwnerEntry, to: OwnerEntry): Bool {
		final name: Array<String> = OwnerIndex.terms(to.type);
		return name.length >= MIN_NAME_TERMS && name.foreach(term -> from.docTerms.contains(term));
	}

	private static function sensesOf(entry: OwnerEntry): Array<Array<String>> {
		return [entry.questionTerms, entry.summaryTerms].filter(terms -> terms.length > 0);
	}

	private static function weight(index: OwnerIndex, terms: Array<String>): Float {
		var sum: Float = 0;
		for (term in terms) sum += index.rarity(term);
		return sum;
	}

	private static function compareText(a: String, b: String): Int {
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

	/** How many types declare each member name. */
	private static function memberWidths(entries: Array<OwnerEntry>): Map<String, Int> {
		final types: Map<String, Map<String, Bool>> = [];
		for (entry in entries) {
			final name: Null<String> = entry.member;
			if (name == null) continue;
			final declaring: Map<String, Bool> = types[name] ?? [];
			declaring[entry.type] = true;
			types[name] = declaring;
		}
		final widths: Map<String, Int> = [];
		for (name => declaring in types) {
			var count: Int = 0;
			for (_ in declaring.keys()) count++;
			widths[name] = count;
		}
		return widths;
	}

	private static function isAllowed(allowed: Array<Allowed>, overlap: Overlap): Bool {
		return allowed.exists(row -> names(row.declaration, overlap.entry) && names(row.owner, overlap.owner));
	}

	/** Whether `pattern` names `entry`: its `Type` or `Type.member`, with one `*` at either end standing for any text. */
	private static function names(pattern: String, entry: OwnerEntry): Bool {
		final name: String = OwnerIndex.nameOf(entry);
		return if (pattern == ANY)
			true
		else if (pattern.startsWith(ANY))
			name.endsWith(pattern.substr(1))
		else if (pattern.endsWith(ANY))
			name.startsWith(pattern.substr(0, pattern.length - 1))
		else
			name == pattern;
	}

	/** A pair found from both ends is one finding, kept at the end whose owner `prefers` to be the owner. */
	private static function withoutEchoes(found: Array<Overlap>): Array<Overlap> {
		final seen: Set<String> = new Set<String>();
		for (o in found) seen.add(pairKey(o.entry, o.owner));
		return found.filter(o -> !(seen.has(pairKey(o.owner, o.entry)) && prefers(o.entry, o.owner)));
	}

	/** Whether `a` is the better owner of a question the two share: it states one, else the smaller name. */
	private static function prefers(a: OwnerEntry, b: OwnerEntry): Bool {
		return (a.question != null) != (b.question != null) ? a.question != null : OwnerIndex.nameOf(a) < OwnerIndex.nameOf(b);
	}

	private static function pairKey(from: OwnerEntry, to: OwnerEntry): String {
		return '${OwnerIndex.nameOf(from)} -> ${OwnerIndex.nameOf(to)}';
	}

	private static function intOption(name: String, value: String): Int {
		final parsed: Null<Int> = Std.parseInt(value);
		if (parsed == null) throw new UsageError('$name needs a whole number, got $value');
		return parsed;
	}

	/** `value` as a number from 0 to 1; anything else is refused, since a NaN floor would let every lookalike through. */
	private static function floatOption(name: String, value: String): Float {
		final parsed: Float = Std.parseFloat(value);
		if (Math.isNaN(parsed) || parsed < 0 || parsed > 1) throw new UsageError('$name needs a number from 0 to 1, got $value');
		return parsed;
	}

}
