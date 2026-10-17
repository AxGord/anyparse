package anyparse.check;

import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;

using StringTools;

/**
 * One `ownedTypes` declaration of `apqlint.json`: the types and members a layer of the project OWNS, the code that
 * owns them, and why — what the `owned-types` rule reads.
 *
 *  - `types` — qualified type paths (`pkg.Module` for a module's main type, `pkg.Module.Sub` for a sub-type) whose
 *    every mention outside `owners` is reported.
 *  - `members` — qualified `Type.member` paths (`pkg.Module.build`, `pkg.Module.new` for construction) whose every
 *    read or call outside `owners` is reported, while the type itself stays free to name.
 *  - `owners` — globs over qualified names, the syntax of `reflectiveClasses` (`Glob.qualifiedNames`): a mention is
 *    owned when one of them matches the module it is written in or the type declaration enclosing it.
 *  - `why` — the reason, quoted in every finding.
 */
typedef TypeOwnership = {
	final types: Array<String>;
	final members: Array<String>;
	final owners: Array<String>;
	final why: String;
}

/**
 * The `apqlint.json` `ownedTypes` key's reader: one JSON array → the declarations it carries.
 *
 * Per-ENTRY lenient, like `frameworks`: an entry that is not an object, names no owner, owns nothing or gives no
 * reason is dropped, and every drop or ignored value appends a line to `drops`, which `LintConfig.discover` prints once
 * per config file. A declaration that vanished in silence would read as a layer nobody reaches past.
 */
@:nullSafety(Strict)
final class OwnedTypesDeclaration {

	/** The key's own name, as every diagnostic line spells it. */
	private static inline final KEY: String = 'ownedTypes';

	/** Every declaration of `raw` the reader could keep, in declared order. */
	public static function read(raw: Array<JValue>, drops: Array<String>): Array<TypeOwnership> {
		final out: Array<TypeOwnership> = [];
		for (i => value in raw) switch value {
			case JObject(fields):
				final entry: Null<TypeOwnership> = readEntry('$KEY[$i]', fields, drops);
				if (entry != null) out.push(entry);
			case _:
				drops.push('$KEY[$i] is not an object — dropped');
		}
		return out;
	}

	/** One entry's fields, `label` naming it in a diagnostic; null when the entry has to be dropped. */
	private static function readEntry(label: String, fields: Array<JEntry>, drops: Array<String>): Null<TypeOwnership> {
		final types: Array<String> = [];
		final members: Array<String> = [];
		final owners: Array<String> = [];
		var why: Null<String> = null;
		for (field in fields) switch [field.key, field.value] {
			case ['types', JArray(items)]:
				collect(label, field.key, items, types, drops);
			case ['members', JArray(items)]:
				collect(label, field.key, items, members, drops);
			case ['owners', JArray(items)]:
				collect(label, field.key, items, owners, drops);
			case ['why', JString(v)]:
				why = v;
			case ['types', _], ['members', _], ['owners', _]:
				drops.push('$label "${field.key}" is not an array of strings — ignored');
			case ['why', _]:
				drops.push('$label "why" is not a string — ignored');
			case _:
				drops.push('$label declares unknown key "${field.key}" — ignored');
		}
		// A member path is a type path plus the member, so it has a dot that is neither its first nor its last character.
		final paths: Array<String> = members.filter(m -> m.lastIndexOf('.') > 0 && !m.endsWith('.'));
		for (m in members) if (!paths.contains(m)) drops.push('$label member "$m" is not a Type.member path — ignored');
		final reason: String = (why ?? '').trim();
		final problem: Null<String> = if (owners.length == 0)
			'declares no "owners"'
		else if (types.length == 0 && paths.length == 0)
			'declares neither "types" nor "members"'
		else if (reason == '')
			'declares no "why"'
		else
			null;
		if (problem == null) return {
			types: types,
			members: paths,
			owners: owners,
			why: reason
		};
		drops.push('$label $problem — dropped');
		return null;
	}

	/** Append the strings of `items` to `into` through `LintConfig`'s own per-element reader, reporting what it skipped. */
	private static function collect(label: String, key: String, items: Array<JValue>, into: Array<String>, drops: Array<String>): Void {
		final before: Int = into.length;
		LintDocuments.collectStrings(items, into);
		final skipped: Int = items.length - (into.length - before);
		if (skipped > 0) drops.push('$label "$key" ignored $skipped value(s) that are not strings');
	}

}
