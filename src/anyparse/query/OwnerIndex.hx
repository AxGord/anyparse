package anyparse.query;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Span;

/** One declaration `OwnerIndex` ranks: a type or one of its members, with what its doc comment says. */
typedef OwnerEntry = {
	/** The declaring type's name. */
	final type: String;

	/** The member's name, or null for the type itself. */
	final member: Null<String>;

	/** The file declaring it, as the index holds it. */
	final file: String;

	/** The 1-based line of the declaration. */
	final line: Int;

	/** The doc comment's first sentence, or the empty string when the declaration has no doc. */
	final summary: String;

	/** The question the doc says this declaration is the one answer to, or null when it names none. */
	final question: Null<String>;

	/** The search terms of the declaration's own name (`OwnerIndex.terms`). */
	final nameTerms: Array<String>;

	/** The search terms of the owned question, empty when the doc names none. */
	final questionTerms: Array<String>;

	/** The search terms of the doc comment's first sentence. */
	final summaryTerms: Array<String>;

	/** The search terms of the whole doc comment. */
	final docTerms: Array<String>;
};

/** A ranked answer: the declaration, and how well its name and doc cover the question. */
typedef OwnerHit = {
	final entry: OwnerEntry;
	final score: Float;
};

/**
 * Which declaration answers a question asked in words: every type and member of a scope, ranked by the question's terms
 * its name and doc comment carry, a term few declarations carry counting more than a common one. A doc states the question its
 * declaration owns in double quotes right after the words `one answer to`, and `owned` lists those, so one question has one
 * component to call. Built from the scope's `SymbolIndex` and the doc each declaration owns (`SourceSlice.leadingDocBlock`).
 */
@:nullSafety(Strict)
final class OwnerIndex {

	/** How much a term of the declaration's own name, or of the question its doc says it owns, counts. */
	private static inline final NAME_WEIGHT: Float = 3;

	/** How much a term of the doc's first sentence counts. */
	private static inline final SUMMARY_WEIGHT: Float = 2;

	/** How much a term found only further down the doc counts. */
	private static inline final DOC_WEIGHT: Float = 0.5;

	/** The shortest word that is a search term. */
	private static inline final MIN_TERM_LENGTH: Int = 2;

	/** The phrase a doc introduces the question it owns with, before the quoted question. */
	private static inline final OWNED_PHRASE: String = 'one answer to';

	/** Words a question is phrased with that name no concept, so they rank nothing. */
	private static final STOP_WORDS: Array<String> = [
		'a',
		'about',
		'after',
		'all',
		'also',
		'an',
		'and',
		'any',
		'are',
		'as',
		'at',
		'be',
		'been',
		'before',
		'both',
		'but',
		'by',
		'can',
		'could',
		'did',
		'do',
		'does',
		'each',
		'every',
		'for',
		'from',
		'had',
		'has',
		'have',
		'here',
		'how',
		'if',
		'in',
		'into',
		'is',
		'it',
		'its',
		'just',
		'may',
		'might',
		'must',
		'no',
		'nor',
		'not',
		'of',
		'on',
		'one',
		'only',
		'or',
		'our',
		'own',
		'should',
		'so',
		'some',
		'such',
		'than',
		'that',
		'the',
		'their',
		'them',
		'then',
		'there',
		'these',
		'they',
		'this',
		'those',
		'to',
		'too',
		'very',
		'was',
		'we',
		'were',
		'what',
		'when',
		'where',
		'whether',
		'which',
		'while',
		'who',
		'whom',
		'whose',
		'why',
		'will',
		'with',
		'would',
		'you',
		'your'
	];

	/** Every declaration of the scope, in file order then declaration order. */
	public final entries: Array<OwnerEntry>;

	/** How many entries carry each term anywhere. */
	private final _documentFrequency: Map<String, Int> = [];

	public function new(entries: Array<OwnerEntry>) {
		this.entries = entries;
		for (entry in entries) for (term in distinct(entry.nameTerms.concat(entry.questionTerms).concat(entry.docTerms)))
			_documentFrequency[term] = (_documentFrequency[term] ?? 0) + 1;
	}

	/**
	 * The `limit` declarations whose name and doc best cover `question`, best first: each term of the question its name or the question
	 * its doc owns carries counts most, one its doc's first sentence carries less, one further down the doc least,
	 * each weighted by how rare the term is in the scope, and the sum scaled by the share of the question's terms matched.
	 */
	public function rank(question: String, limit: Int): Array<OwnerHit> {
		final asked: Array<String> = distinct(terms(question));
		if (asked.length == 0) return [];
		final hits: Array<OwnerHit> = [];
		for (entry in entries) {
			var score: Float = 0;
			var matched: Int = 0;
			for (term in asked) {
				final weight: Float = if (entry.nameTerms.contains(term) || entry.questionTerms.contains(term))
					NAME_WEIGHT
				else if (entry.summaryTerms.contains(term))
					SUMMARY_WEIGHT
				else if (entry.docTerms.contains(term))
					DOC_WEIGHT
				else
					0;
				if (weight == 0) continue;
				matched++;
				score += weight * Math.log(1 + entries.length / (_documentFrequency[term] ?? 1));
			}
			if (matched > 0) hits.push({ entry: entry, score: score * matched / asked.length });
		}
		hits.sort((a, b) -> if (a.score > b.score)
			-1
		else if (a.score < b.score)
			1
		else
			entryOrder(a.entry, b.entry));
		return hits.slice(0, limit);
	}

	/** Every declaration whose doc names the question it is the one answer to, ordered by that question. */
	public function owned(): Array<OwnerEntry> {
		final out: Array<OwnerEntry> = entries.filter(entry -> entry.question != null);
		out.sort((a, b) -> {
			final qa: String = (a.question ?? '').toLowerCase();
			final qb: String = (b.question ?? '').toLowerCase();
			return if (qa < qb)
				-1
			else if (qa > qb)
				1
			else
				entryOrder(a, b);
		});
		return out;
	}

	/** Every type and member `index` holds, each with the doc it owns read off its file's source. */
	public static function build(index: SymbolIndex, plugin: GrammarPlugin): OwnerIndex {
		final entries: Array<OwnerEntry> = [];
		for (info in index.allFiles()) {
			final source: Null<String> = index.sourceOf(info.file);
			if (source == null) continue;
			final regions: Array<LexRegion> = plugin.lexicalRegions(source);
			final lines: LineIndex = new LineIndex(source);
			for (type in info.types) {
				entries.push(entryOf(source, regions, lines, info.file, type.name, null, type.span.from));
				for (member in type.members)
					entries.push(entryOf(source, regions, lines, info.file, type.name, member.name, member.declFrom));
			}
		}
		return new OwnerIndex(entries);
	}

	/** `Type` or `Type.member`: how a row names the declaration. */
	public static function nameOf(entry: OwnerEntry): String {
		return entry.member == null ? entry.type : '${entry.type}.${entry.member}';
	}

	/**
	 * The search terms of `text`: its words, each identifier split at its case and digit boundaries (`realPath` is `real`
	 * and `path`), lower-cased, stop words and one-letter words dropped, and each reduced to a crude stem so a plural or an
	 * `-ing` / `-ed` form meets its base word.
	 */
	public static function terms(text: String): Array<String> {
		final out: Array<String> = [];
		var i: Int = 0;
		while (i < text.length) {
			if (!isWordCode(text.fastCodeAt(i))) {
				i++;
				continue;
			}
			var end: Int = i;
			while (end < text.length && isWordCode(text.fastCodeAt(end))) end++;
			splitIdentifier(text.substring(i, end), out);
			i = end;
		}
		return out;
	}

	/**
	 * The first sentence of `prose`: up to the first `.`, `?` or `!` a space or the end follows, outside a backquoted span and
	 * not closing `e.g` / `i.e`; the whole text when no sentence ends.
	 */
	public static function firstSentence(prose: String): String {
		var inCode: Bool = false;
		for (i in 0...prose.length) {
			final code: Int = prose.fastCodeAt(i);
			if (code == '`'.code) {
				inCode = !inCode;
				continue;
			}
			if (inCode || (code != '.'.code && code != '?'.code && code != '!'.code)) continue;
			if (i + 1 < prose.length && prose.fastCodeAt(i + 1) != ' '.code) continue;
			final head: String = prose.substring(0, i);
			if (head.endsWith('e.g') || head.endsWith('i.e')) continue;
			return prose.substring(0, i + 1);
		}
		return prose;
	}

	/** The question `prose` says its declaration is the one answer to — the quoted text after the owned phrase — or null. */
	public static function ownedQuestion(prose: String): Null<String> {
		final at: Int = prose.toLowerCase().indexOf(OWNED_PHRASE);
		if (at < 0) return null;
		var open: Int = at + OWNED_PHRASE.length;
		while (open < prose.length && prose.fastCodeAt(open) == ' '.code) open++;
		if (open >= prose.length || !isQuote(prose.fastCodeAt(open))) return null;
		var close: Int = open + 1;
		while (close < prose.length && !isQuote(prose.fastCodeAt(close))) close++;
		return close >= prose.length || close == open + 1 ? null : prose.substring(open + 1, close);
	}

	private static inline function entryOrder(a: OwnerEntry, b: OwnerEntry): Int {
		return if (a.file < b.file)
			-1
		else if (a.file > b.file)
			1
		else
			a.line - b.line;
	}

	private static inline function isQuote(code: Int): Bool {
		return code == '"'.code || code == '“'.code || code == '”'.code;
	}

	private static inline function isWordCode(code: Int): Bool {
		return isUpper(code) || isLower(code) || isDigit(code);
	}

	private static inline function isUpper(code: Int): Bool {
		return code >= 'A'.code && code <= 'Z'.code;
	}

	private static inline function isLower(code: Int): Bool {
		return code >= 'a'.code && code <= 'z'.code;
	}

	private static inline function isDigit(code: Int): Bool {
		return code >= '0'.code && code <= '9'.code;
	}

	private static function entryOf(
		source: String, regions: Array<LexRegion>, lines: LineIndex, file: String, type: String, member: Null<String>, from: Int
	): OwnerEntry {
		final block: Null<Span> = SourceSlice.leadingDocBlock(source, new Span(from, from), regions);
		final doc: String = block == null ? '' : SourceSlice.docProse(source, block);
		final summary: String = firstSentence(doc);
		final question: Null<String> = ownedQuestion(doc);
		return {
			type: type,
			member: member,
			file: file,
			line: lines.lineColAt(from).line,
			summary: summary,
			question: question,
			nameTerms: distinct(terms(member ?? type)),
			questionTerms: distinct(terms(question ?? '')),
			summaryTerms: distinct(terms(summary)),
			docTerms: distinct(terms(doc))
		};
	}

	/** Push the terms of one word, split where its case or its digits change (`HTTPServer64` is `http`, `server`, `64`). */
	private static function splitIdentifier(word: String, out: Array<String>): Void {
		var start: Int = 0;
		for (k in 1...word.length) {
			final before: Int = word.fastCodeAt(k - 1);
			final here: Int = word.fastCodeAt(k);
			final next: Int = k + 1 < word.length ? word.fastCodeAt(k + 1) : 0;
			final lowerToUpper: Bool = !isUpper(before) && isUpper(here);
			final acronymEnd: Bool = isUpper(before) && isUpper(here) && isLower(next);
			final digitEdge: Bool = isDigit(before) != isDigit(here);
			if (!lowerToUpper && !acronymEnd && !digitEdge) continue;
			pushTerm(word.substring(start, k), out);
			start = k;
		}
		pushTerm(word.substring(start), out);
	}

	private static function pushTerm(part: String, out: Array<String>): Void {
		final lower: String = part.toLowerCase();
		if (lower.length < MIN_TERM_LENGTH || STOP_WORDS.contains(lower)) return;
		out.push(stem(lower));
	}

	/** A crude suffix strip, applied alike to a question and to the docs, so `reads`, `reading` and `read` meet. */
	private static function stem(word: String): String {
		var s: String = word;
		if (s.length > 4 && s.endsWith('ies'))
			s = '${s.substr(0, s.length - 3)}y';
		else if (s.length > 3 && s.endsWith('s') && !s.endsWith('ss'))
			s = s.substr(0, s.length - 1);
		if (s.length > 5 && s.endsWith('ing'))
			s = s.substr(0, s.length - 3);
		else if (s.length > 3 && s.endsWith('ed'))
			s = s.substr(0, s.length - 2);
		return s.length > 2 && s.endsWith('e') ? s.substr(0, s.length - 1) : s;
	}

	private static function distinct(items: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (item in items) if (!out.contains(item)) out.push(item);
		return out;
	}

}
