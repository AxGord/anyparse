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

	/** RETURN arm: `return <force>;` inserted directly after the signature, or null. */
	force: Null<String>,

	/** FRAGMENT arm: the exact text replaced inside the member, or null. */
	find: Null<String>,

	/** What replaces `find`; the empty string deletes it. Null for a RETURN arm. */
	replace: Null<String>,

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

	/** Keys every arm must carry a non-empty string for. */
	private static final REQUIRED_KEYS: Array<String> = ['name', 'type', 'method', 'note'];

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
				force: nonEmpty(entry, 'force'),
				find: nonEmpty(entry, 'find'),
				replace: text(entry, 'replace'),
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
		final force: Null<String> = nonEmpty(entry, 'force');
		final fragment: Null<String> = nonEmpty(entry, 'find');
		if (force == null && fragment == null) out.push('$at declares neither "force" nor "find" — an arm has to say what it cuts');
		if (force != null && fragment != null) out.push('$at declares both "force" and "find" — an arm cuts one way');
		if (fragment == null && text(entry, 'replace') != null) out.push('$at declares "replace" without "find"');
		return out;
	}

	/** The arm called `name`, or null — the question a `@:killer` asks. */
	public static function find(arms: Array<MutationArm>, name: String): Null<MutationArm> {
		return arms.find(arm -> arm.name == name);
	}

	/** One line for `node bin/test.js --list-arms`, and the shape the parity test pins. */
	public static function render(arm: MutationArm): String {
		final cut: String = arm.force == null ? 'fragment' : 'return ${arm.force};';
		return '${arm.name} :: ${arm.type}#${arm.method} :: $cut :: ${arm.note}';
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
