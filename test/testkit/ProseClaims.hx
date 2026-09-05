package testkit;

using StringTools;

/**
 * The prose conventions a fixture's doc comment uses to claim a role, read as
 * data — the other half of `@:pin` / `@:killer`.
 *
 * S96 made the metadata real: a `@:killer` naming no declared arm stops the
 * build, and so does an arm whose member has moved. It then stated its own
 * residue: 39 pins against 14 039 fixtures, and the doc-comment conventions the
 * metadata was meant to replace still unchecked prose everywhere else. This
 * class is the predicate that finds that prose, so the gap can be counted and
 * kept from growing.
 *
 * Four claim kinds, and they are not equal. TWO of them have an annotation that
 * can retire the claim — an `arm` claim is recorded by `@:killer`, a `control`
 * claim by `@:pin` — so a fixture making one has somewhere to go. The other two,
 * `base` (this fixture was RED / green at the base commit) and `vacuity` (its
 * assertions were audited for passing trivially), have NO annotation and cannot
 * get a useful one: neither is answerable at build time, and metadata a build
 * cannot check is prose retyped, which is the state this layer exists to end.
 * They are censused, not gated toward a fix.
 *
 * Every function here is PURE over its arguments. `testkit.TestDiscovery` asks
 * them of the tree's real doc comments; `unit.ProseClaimCensusTest` asks them of
 * hand-written sentences of its own, which is a SECOND instance of the
 * declaration — a fixture reading back the census the macro already computed
 * could not fail (S66).
 */
@:nullSafety(Strict)
final class ProseClaims {

	/** An arm relationship: the prose names a mutation that must break the fixture. */
	public static inline final ARM: String = 'arm';

	/** A control relationship: the prose calls the fixture the control for something. */
	public static inline final CONTROL: String = 'control';

	/** A base-redness claim: the prose says the fixture was RED or green at the base commit. */
	public static inline final BASE: String = 'base';

	/** A vacuity audit: the prose says whether an assertion can pass trivially. */
	public static inline final VACUITY: String = 'vacuity';

	/**
	 * `control` spelled about CODE rather than about a fixture's role.
	 *
	 * A rule about `if` / `while` / `#if` regions talks about control flow, a
	 * control-exit node, a control head; a check's doc quotes the role NAME in
	 * backticks. None of those is a fixture calling itself the control for a
	 * sibling, and without this list the word alone flags 16 fixtures that claim
	 * nothing.
	 */
	private static final CODE_SENSES: Array<String> = [
		'control flow',
		'control-flow',
		'control falls',
		'control character',
		'control head',
		'control-head',
		'control exit',
		'control-exit',
		'would control',
		'controls nothing',
		'control nothing',
		'`control`',
		'`controls`'
	];

	/**
	 * Spellings that DENY an arm relationship instead of claiming one.
	 *
	 * "NOT killed by any arm in this slice, and that is what it is here to say"
	 * is a fixture stating it has no arm. Reading it as a claim would put the one
	 * fixture that says so most clearly on the list of fixtures that owe an arm.
	 */
	private static final NEGATED_ARM: Array<String> = ['not killed by', 'killed by nothing'];

	/**
	 * Every claim `doc` makes, in `ARM`, `CONTROL`, `BASE`, `VACUITY` order.
	 *
	 * The comparison is on the NORMALIZED doc: a claim wrapped across two lines
	 * of a doc block is one sentence to a reader and has to be one string
	 * here, which is exactly what a line-oriented search cannot do.
	 */
	public static function kindsOf(doc: Null<String>): Array<String> {
		final text: String = normalize(doc).toLowerCase();
		if (text == '') return [];
		final out: Array<String> = [];
		if (withoutNegatedArm(text).contains('killed by')) out.push(ARM);
		final coded: String = withoutCodeSenses(text);
		if (containsWord(coded, 'control') || containsWord(coded, 'controls')) out.push(CONTROL);
		if (text.contains('red at base') || text.contains('green at base')) out.push(BASE);
		if (containsWord(text, 'vacuous') || containsWord(text, 'vacuously')) out.push(VACUITY);
		return out;
	}

	/**
	 * Does an annotation on the fixture already record a claim of this kind.
	 *
	 * `roles` are the `@:pin` arguments, `killers` the `@:killer` ones. A control
	 * claim needs the CONTROL role specifically — any other role names a different
	 * job — while an arm claim takes any killer at all. `BASE` and `VACUITY` answer
	 * false for every input on purpose; see the class doc.
	 */
	public static function records(kind: String, roles: Array<String>, killers: Array<String>): Bool {
		return switch kind {
			case ARM: killers.length > 0;
			case CONTROL: roles.contains(CONTROL);
			case _: false;
		};
	}

	/** The claims `doc` makes that no annotation on the fixture records. */
	public static function unrecorded(doc: Null<String>, roles: Array<String>, killers: Array<String>): Array<String> {
		return kindsOf(doc).filter(kind -> !records(kind, roles, killers));
	}

	/** One census line: `<class>#<method> :: <kind>[,<kind>…]`. */
	public static function render(owner: String, kinds: Array<String>): String return '$owner :: ${kinds.join(',')}';

	/**
	 * A doc comment as one line: gutter stripped, line breaks closed up.
	 *
	 * `ClassField.doc` arrives raw, `\n\t * ` and all, so every phrase that wraps
	 * would otherwise be invisible to a substring test.
	 */
	public static function normalize(doc: Null<String>): String {
		if (doc == null) return '';
		final parts: Array<String> = [];
		for (line in doc.split('\n')) {
			final trimmed: String = line.trim();
			parts.push(trimmed.startsWith('*') ? trimmed.substr(1).trim() : trimmed);
		}
		final words: Array<String> = parts.join(' ').replace('\t', ' ').split(' ');
		return words.filter(word -> word != '').join(' ');
	}

	/**
	 * `text` with every code sense of `control` blanked out.
	 *
	 * `M-CLAIM-CODE-BLIND` cuts this member, and it is a FRAGMENT arm rather than a
	 * forced return because the member is `inline`: a forced return ahead of an
	 * inlined body is a non-final return the compiler refuses, which is how S96's
	 * M-PATHWALK-NULL came back BUILD-FAIL.
	 */
	private static inline function withoutCodeSenses(text: String): String {
		return without(text, CODE_SENSES);
	}

	/**
	 * `text` with every denial of an arm relationship blanked out.
	 *
	 * `M-CLAIM-NEG-BLIND` cuts this member, as a fragment arm for the reason above.
	 */
	private static inline function withoutNegatedArm(text: String): String {
		return without(text, NEGATED_ARM);
	}

	/** `text` with each phrase replaced by a space, so neighbours cannot fuse into a new word. */
	private static function without(text: String, phrases: Array<String>): String {
		var out: String = text;
		for (phrase in phrases) out = out.replace(phrase, ' ');
		return out;
	}

	/** Does `word` occur in `hay` as a whole word — `control` must not match `controller`. */
	private static function containsWord(hay: String, word: String): Bool {
		var at: Int = hay.indexOf(word);
		while (at >= 0) {
			final after: Int = at + word.length;
			if ((at == 0 || !isWordChar(hay.fastCodeAt(at - 1))) && (after >= hay.length || !isWordChar(hay.fastCodeAt(after))))
				return true;
			at = hay.indexOf(word, at + 1);
		}
		return false;
	}

	/** Letter, digit or underscore — the boundary `containsWord` refuses to break on. */
	private static function isWordChar(code: Int): Bool {
		return (code >= 'a'.code && code <= 'z'.code) || (code >= 'A'.code && code <= 'Z'.code) || (code >= '0'.code && code <= '9'.code)
			|| code == '_'.code;
	}

}
