package testkit;

import haxe.Exception;
import haxe.Json;

using Lambda;

/**
 * One declared mutation arm: where the cut lands, and what it replaces.
 *
 * `type` + `method` address a member the way `hxq patch --select
 * 'FnMember:<method>'` does, so an arm survives every edit that does not rename
 * its member — which is exactly what a stored line number or a checked-in git
 * patch does not.
 */
typedef MutationArm = {

	/** The name a pinned fixture spells in `@:killer`. */
	name: String,

	/** Dotted path of the type whose member the cut rewrites. */
	type: String,

	/** The member. */
	method: String,

	/**
	 * The projected node KIND the selector addresses, `FnMember` unless the record says
	 * otherwise — a grammar declaration has no method to cut, and its `@:re` terminal is a
	 * module-level `MetaCall`.
	 */
	kind: String,

	/** RETURN arm: `return <force>;` inserted directly after the signature, or null. */
	force: Null<String>,

	/**
	 * FRAGMENT arm: the exact texts replaced inside the member, or null.
	 *
	 * One element for the scalar spelling, N for a cut that needs several edits at once.
	 * `hxq patch` has taken N pairs in one payload all along, and it locates every pair
	 * against the ORIGINAL member text, so the list is order-independent and a pair may
	 * not be written against another pair's output.
	 */
	find: Null<Array<String>>,

	/** What replaces each `find`, element for element; an empty string deletes one. Null for a RETURN arm. */
	replace: Null<Array<String>>,

	/** One sentence: what stops working once the arm is applied. */
	note: String
};

/**
 * Everything one read of the arm table found.
 *
 * `errors` is not an exception channel — the build macro reports every entry of
 * it at once, so a table with three defects names three, not the first.
 */
typedef ArmTable = {

	/** The arms, in declaration order. */
	arms: Array<MutationArm>,

	/** Every complaint about the table; non-empty is a build error at the call site. */
	errors: Array<String>
};

/**
 * `test/testkit/mutation-arms.json` read as data — the registry that makes a
 * `@:killer` name mean something.
 *
 * `@:pin('control')` + `@:killer('<arm>')` already refused to BUILD a control
 * naming no arm, so the SHAPE was enforced and the SUBSTANCE was not: the arm
 * name was free text, and nothing said the named arm existed, still addressed
 * live code, or still killed anything. This table is the substance — one record
 * per arm, naming the layer, the member and the cut — and `testkit.TestDiscovery`
 * cross-checks it against the tree in both directions at build time.
 *
 * Every function here is PURE over its arguments, which is the point: the build
 * macro and `unit.MutationArmsTest` ask the same questions of the same code, and
 * the test asks them of a SECOND table of its own rather than of the one the
 * macro validated — a fixture reading back the table the build already accepted
 * could not fail.
 */
@:nullSafety(Strict)
final class MutationArms {

	/**
	 * The node kind an arm addresses when its record names none — the shape every arm had
	 * before a grammar DECLARATION needed one, and the only shape a `force` cut can take
	 * (the runner splices a `return` after a function's signature).
	 */
	public static inline final DEFAULT_KIND: String = 'FnMember';

	/** Keys every arm must carry a non-empty string for. */
	private static final REQUIRED_KEYS: Array<String> = ['name', 'type', 'method', 'note'];

	/** Keys a record may spell as one string or as a list of them — the two halves of a FRAGMENT cut. */
	private static final FRAGMENT_KEYS: Array<String> = ['find', 'replace'];

	/** The classpath roots `test-js.hxml` declares, in its order — where an arm's `type` is looked for. */
	private static final SOURCE_ROOTS: Array<String> = ['src', 'test'];

	/**
	 * The files `tools/mutation-arm.sh` would try for an arm's `type`, in classpath order.
	 *
	 * The script resolves a type to a file by hand (`for root in src test`) and every
	 * arm's cut is applied to whichever candidate exists. Nothing checked that the
	 * mapping still lands on a file, let alone on a live member — and for a type behind
	 * `#if macro` the build macro cannot check either, because the typer sees no such
	 * class in a non-macro build. `unit.MutationArmAddressTest` asks these paths of the
	 * parser instead, which reads conditional regions like any other bytes.
	 */
	public static function candidateFiles(type: String): Array<String> {
		final relative: String = '${type.split('.').join('/')}.hx';
		return [for (root in SOURCE_ROOTS) '$root/$relative'];
	}

	/**
	 * Read a whole arm table. A table that is not JSON at all, or carries no
	 * `arms` array, yields no arms and one error — never a thrown exception,
	 * because the caller is a build macro that wants to report, not to abort.
	 */
	public static function parse(source: String): ArmTable {
		final arms: Array<MutationArm> = [];
		final errors: Array<String> = [];
		var root: Null<Any> = null;
		try root = Json.parse(source) catch (exception: Exception) {
			errors.push('the arm table is not valid JSON: ${exception.message}');
			return { arms: arms, errors: errors };
		}
		final rows: Any = Reflect.field(root, 'arms');
		if (!(rows is Array)) {
			errors.push('the arm table needs a top-level "arms" array');
			return { arms: arms, errors: errors };
		}
		final entries: Array<Any> = rows;
		for (index => entry in entries) {
			final issues: Array<String> = rowErrors(entry, index);
			if (issues.length > 0) {
				for (issue in issues) errors.push(issue);
				continue;
			}
			arms.push({
				name: required(entry, 'name'),
				type: required(entry, 'type'),
				method: required(entry, 'method'),
				kind: nonEmpty(entry, 'kind') ?? DEFAULT_KIND,
				force: nonEmpty(entry, 'force'),
				find: strings(entry, 'find'),
				replace: strings(entry, 'replace'),
				note: required(entry, 'note')
			});
		}
		final seen: Array<String> = [];
		for (arm in arms) if (seen.contains(arm.name))
			errors.push('"${arm.name}" is declared more than once — two arms under one name make the name useless');
		else
			seen.push(arm.name);
		return { arms: arms, errors: errors };
	}

	/**
	 * Everything wrong with ONE row, named so a reader can find it: the four
	 * mandatory keys, and the rule that an arm cuts exactly one way.
	 */
	public static function rowErrors(entry: Any, index: Int): Array<String> {
		final out: Array<String> = [];
		if (entry == null) {
			out.push('arms[$index] is null');
			return out;
		}
		final name: Null<String> = nonEmpty(entry, 'name');
		final at: String = name == null ? 'arms[$index]' : 'arms[$index] "$name"';
		for (key in REQUIRED_KEYS) if (nonEmpty(entry, key) == null) out.push('$at has no non-empty "$key"');
		for (issue in cutErrors(entry, at)) out.push(issue);
		return out;
	}

	/** The arm called `name`, or null — the question a `@:killer` asks. */
	public static function find(arms: Array<MutationArm>, name: String): Null<MutationArm> {
		return arms.find(arm -> arm.name == name);
	}

	/** One line for `node bin/test.js --list-arms`, and the shape the parity test pins. */
	public static function render(arm: MutationArm): String {
		final force: Null<String> = arm.force;
		final pairs: Int = arm.find?.length ?? 0;
		final cut: String = if (force != null)
			'return $force;'
		else if (pairs > 1)
			'$pairs fragments'
		else
			'fragment';
		return '${arm.name} :: ${address(arm)} :: $cut :: ${arm.note}';
	}

	/**
	 * Where the cut lands, as one token — `<type>#<method>` for the ordinary member arm and
	 * `<type>#<kind>:<method>` for an arm addressing anything else.
	 *
	 * The default kind stays UNSPELLED so 97 of 98 existing rows are byte-unchanged, and the
	 * one that is not says what it addresses. `selectorOf` reads the second half back; the
	 * rendered line is the only place the runner's address is written down, so both the
	 * `--list-arms` output and `TestRegistry.deferredArms()` go through here.
	 */
	public static function address(arm: MutationArm): String {
		return arm.kind == DEFAULT_KIND ? '${arm.type}#${arm.method}' : '${arm.type}#${arm.kind}:${arm.method}';
	}

	/**
	 * The `hxq` selector for the member half of an `address` — `FnMember:walk` for a bare
	 * name, and the record's own kind when one is spelled.
	 *
	 * Split at the FIRST colon: a metadata name is itself colon-bearing (`MetaCall:@:re`), so
	 * splitting on every colon would hand the selector `MetaCall:@`.
	 */
	public static function selectorOf(member: String): String {
		final at: Int = member.indexOf(':');
		return at == -1 ? '$DEFAULT_KIND:$member' : member;
	}

	/**
	 * Everything wrong with the way ONE row declares its cut: the two spellings are
	 * exclusive, a `find` list and a `replace` list pair up element for element, and only a
	 * function signature can carry a forced return.
	 *
	 * Split out of `rowErrors` because the list spelling doubled the questions asked here and
	 * the two halves answer about different things — the four mandatory keys, and the cut.
	 */
	private static function cutErrors(entry: Any, at: String): Array<String> {
		final out: Array<String> = [];
		final force: Null<String> = nonEmpty(entry, 'force');
		final fragments: Null<Array<String>> = strings(entry, 'find');
		final replacements: Null<Array<String>> = strings(entry, 'replace');
		var malformed: Bool = false;
		for (key in FRAGMENT_KEYS) {
			final shape: Null<String> = listShapeError(entry, key);
			if (shape == null) continue;
			out.push('$at $shape');
			malformed = true;
		}
		if (fragments != null && fragments.contains(''))
			out.push('$at declares a blank "find" fragment — `apq patch` refuses an empty one, so there would be nothing to cut');
		// The two clauses gated on `malformed` read ABSENCE as intent, and a malformed list is
		// absent to `strings` exactly as a missing key is — so without the gate a row whose
		// "find" holds a number collects "declares neither cut" and "replace without find" on
		// top of the one complaint that is true, and sends its author to the wrong key.
		if (force == null && fragments == null && !malformed)
			out.push('$at declares neither "force" nor "find" — an arm has to say what it cuts');
		if (force != null && fragments != null) out.push('$at declares both "force" and "find" — an arm cuts one way');
		if (fragments == null && replacements != null && !malformed) out.push('$at declares "replace" without "find"');
		if (fragments != null && replacements != null) for (issue in pairErrors(fragments, replacements, at)) out.push(issue);
		final kind: Null<String> = nonEmpty(entry, 'kind');
		if (force != null && kind != null && kind != DEFAULT_KIND)
			out.push(
				'$at declares "force" with kind "$kind" — a forced return is spliced after a function signature,'
				+ ' so only $DEFAULT_KIND can carry one; use "find"/"replace"'
			);
		return out;
	}

	/**
	 * What is wrong with the SHAPE of the list at `key`, or null — an array with no entry at
	 * all, or one holding something that is not a string.
	 *
	 * Named rather than silently normalised: `strings` answers null for both, and a row that
	 * fell through as "declares neither cut" would send the author looking at the wrong key.
	 */
	private static function listShapeError(entry: Any, key: String): Null<String> {
		final raw: Null<Array<Any>> = items(entry, key);
		return if (raw == null)
			null
		else if (raw.length == 0)
			'declares an empty "$key" array — a cut is at least one pair'
		else if (strings(entry, key) == null)
			'declares a "$key" entry that is not a string'
		else
			null;
	}

	/**
	 * Everything wrong with the way N fragments pair up with N replacements: the two lists are
	 * the same length, and no pair replaces its own fragment with itself.
	 *
	 * The second is `apq patch`'s own refusal — `the old and new fragments are identical` — and
	 * it is pure over the two lists the row already carries, so the registry answers it at BUILD
	 * time instead of leaving it for whoever runs the arm.
	 */
	private static function pairErrors(fragments: Array<String>, replacements: Array<String>, at: String): Array<String> {
		if (fragments.length != replacements.length) return [
			'$at declares ${fragments.length} "find" fragment(s) against ${replacements.length} "replace" — every pair of a'
				+ ' multi-pair cut replaces its own fragment, so the two lists are the same length'
		];
		final out: Array<String> = [];
		for (index => piece in fragments) if (piece == replacements[index]) {
			final pair: String = fragments.length > 1 ? ' in pair ${index + 1}' : '';
			out.push('$at declares the same text as "find" and "replace"$pair — `apq patch` refuses a pair that changes nothing');
		}
		return out;
	}

	/**
	 * The raw items at `key`: null when the key is absent, the array's own items for the list
	 * spelling, and a one-item list for the scalar one — so every question after this is
	 * asked of a list whichever way the record was written.
	 */
	private static function items(entry: Any, key: String): Null<Array<Any>> {
		final raw: Any = Reflect.field(entry, key);
		return if (raw == null)
			null
		else if (raw is Array)
			(raw: Array<Any>)
		else
			[raw];
	}

	/** The items at `key` as strings, or null when the key is absent or any item is not one. */
	private static function strings(entry: Any, key: String): Null<Array<String>> {
		final raw: Null<Array<Any>> = items(entry, key);
		if (raw == null) return null;
		final out: Array<String> = [];
		for (item in raw) if (item is String)
			out.push((item: String));
		else
			return null;
		return out;
	}

	/** A key the row is already known to carry; the fallback never fires after `rowErrors`. */
	private static function required(entry: Any, key: String): String {
		return nonEmpty(entry, key) ?? '';
	}

	/** The string at `key`, treating an empty one as absent — `force` and `find` are never blank. */
	private static function nonEmpty(entry: Any, key: String): Null<String> {
		final value: Null<String> = text(entry, key);
		return value == '' ? null : value;
	}

	/** The string at `key`, or null when the key is absent or holds something else. */
	private static function text(entry: Any, key: String): Null<String> {
		final value: Any = Reflect.field(entry, key);
		return value is String ? (value: String) : null;
	}

}
