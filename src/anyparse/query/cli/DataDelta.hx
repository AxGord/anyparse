package anyparse.query.cli;

import anyparse.grammar.json.JsonFormat;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.cli.DeclarationDelta;
import anyparse.query.merge.RecordTree;

using Lambda;

/** The two documents `DataDelta` walks and the grammar shape that reads both. */
private typedef Versions = {
	final shape: RefShape;
	final base: String;
	final now: String;
}

/**
 * The one answer to "which key paths of a data document differ between two versions of it": an object is compared by
 * key, an array by element (an element of the same value, then the one `RecordTree` gives the same identity, is the same
 * element wherever it sits, so an element inserted in the middle shifts no other one), and every other value as
 * written. Each added, removed or changed value is named by its `DataPath` and carries its value as compact JSON,
 * shortened. A document added or removed whole is one row naming its top-level keys, or its element count.
 *
 * Grammar-agnostic: it reads the projected tree through `RefShape`'s object, array and string kinds, and applies to
 * a grammar that declares `RefShape.dataDocument`. A version the grammar does not parse makes the answer a line count.
 */
@:nullSafety(Strict)
final class DataDelta {

	/** The longest value, in characters, a change shows before it is cut. */
	private static inline final MAX_SHOWN: Int = 72;

	/** A hexadecimal string at least this long is a digest, shown by its first `DIGEST_KEPT` characters. */
	private static inline final DIGEST_MIN: Int = 32;

	private static inline final DIGEST_KEPT: Int = 12;
	private static inline final CUT: String = '…';

	/** The change a document whose values all agree still shows when its keys sit in another order. */
	private static inline final KEY_ORDER: String = '(key order)';

	/** The path standing for the whole document. */
	private static inline final ROOT: String = '.';

	/** The suffix of the row for an array whose elements moved. */
	private static inline final ARRAY_ORDER: String = '(order)';

	/** The suffix of the row for a key whose entries were repeated a different number of times. */
	private static inline final DUPLICATE_KEY: String = '(duplicate key)';

	/** Whether the grammar `shape` describes reads a document as a value tree. */
	public static inline function reads(shape: RefShape): Bool {
		return shape.dataDocument == true && DataPath.walkable(shape);
	}

	/**
	 * The change from `base` to `now`, both read with `plugin`: `Values` with the changed key paths, `Layout` when only
	 * the text differs, `Text` when a version does not parse.
	 */
	public static function compare(plugin: GrammarPlugin, base: String, now: String): FileDelta {
		final lines: FileDelta = DeclarationDelta.compareText(base, now);
		if (base == now) return lines;
		final shape: RefShape = plugin.refShape();
		final whole: Bool = base == '' || now == '';
		final before: Null<QueryNode> = parsed(plugin, base);
		final after: Null<QueryNode> = parsed(plugin, now);
		final versions: Versions = { shape: shape, base: base, now: now };
		final changes: Array<ValueChange> = [];
		if (whole) {
			final present: Null<QueryNode> = base == '' ? after : before;
			if (present == null) return lines;
			changes.push(summary(present, versions, base == ''));
			return valuesDelta(changes, lines);
		}
		if (before == null || after == null) return lines;
		walk([], before, after, versions, changes);
		if (changes.length == 0 && !sameKeyOrder(before, after, versions)) changes.push({
			status: Changed,
			path: KEY_ORDER,
			before: '',
			after: ''
		});
		return valuesDelta(changes, lines);
	}

	private static inline function isContainer(value: QueryNode, shape: RefShape): Bool {
		return value.kind == shape.objectLiteralKind || value.kind == shape.arrayLiteralKind;
	}

	private static function parsed(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try plugin.parseFile(source) catch (exception: Exception) null;
	}

	/** Whether both documents spell their values in the same order, which the key-wise walk does not see. */
	private static function sameKeyOrder(before: QueryNode, after: QueryNode, versions: Versions): Bool {
		final shape: RefShape = versions.shape;
		return DataPath.json(
			DataPath.valueOf(before, shape), versions.base, shape
		) == DataPath.json(DataPath.valueOf(after, shape), versions.now, shape);
	}

	private static function walk(
		path: Array<String>, before: QueryNode, after: QueryNode, versions: Versions, out: Array<ValueChange>
	): Void {
		final shape: RefShape = versions.shape;
		final old: QueryNode = DataPath.valueOf(before, shape);
		final now: QueryNode = DataPath.valueOf(after, shape);
		if (old.kind == shape.objectLiteralKind && now.kind == old.kind) return walkObjects(path, old, now, versions, out);
		if (old.kind == shape.arrayLiteralKind && now.kind == old.kind) return walkArrays(path, old, now, versions, out);
		if (DataPath.json(old, versions.base, shape) != DataPath.json(now, versions.now, shape)) out.push({
			status: Changed,
			path: DataPath.format(path),
			before: shown(old, versions.base, shape),
			after: shown(now, versions.now, shape)
		});
	}

	/** Entries by key, the last entry of a repeated key standing for it, as a JSON reader keeps it. */
	private static function entriesOf(object: QueryNode): Map<String, QueryNode> {
		final out: Map<String, QueryNode> = [];
		for (entry in object.children) out[entry.name ?? ''] = entry;
		return out;
	}

	/** The keys in order of first appearance. */
	private static function keysOf(object: QueryNode): Array<String> {
		final out: Array<String> = [];
		for (entry in object.children) {
			final key: String = entry.name ?? '';
			if (!out.contains(key)) out.push(key);
		}
		return out;
	}

	private static function walkObjects(
		path: Array<String>, old: QueryNode, now: QueryNode, versions: Versions, out: Array<ValueChange>
	): Void {
		final shape: RefShape = versions.shape;
		final oldEntries: Map<String, QueryNode> = entriesOf(old);
		final nowEntries: Map<String, QueryNode> = entriesOf(now);
		for (key in keysOf(old)) {
			final was: Null<QueryNode> = oldEntries[key];
			if (was == null) continue;
			final is: Null<QueryNode> = nowEntries[key];
			final keyPath: Array<String> = path.concat([key]);
			if (is == null)
				out.push(removal(keyPath, DataPath.valueOf(was, shape), versions))
			else
				walk(keyPath, was, is, versions, out);
		}
		for (key in keysOf(now)) if (oldEntries.exists(key) && occurrences(old, key) != occurrences(now, key))
			out.push(orderChange(path.concat([key]), DUPLICATE_KEY));
		for (key in keysOf(now)) {
			final is: Null<QueryNode> = nowEntries[key];
			if (is != null && !oldEntries.exists(key)) out.push(addition(path.concat([key]), DataPath.valueOf(is, shape), versions));
		}
	}

	/**
	 * The element of `is` (the values of `now`'s elements) standing for each of `was` (those of `old`), or -1 for none: one with the
	 * same value first, then the one `RecordTree` gives the same identity, the rule the merge driver pairs records by.
	 */
	private static function counterparts(
		old: QueryNode, now: QueryNode, was: Array<QueryNode>, is: Array<QueryNode>, versions: Versions
	): Array<Int> {
		final shape: RefShape = versions.shape;
		final partner: Array<Int> = [for (_ in is) -1];
		final taken: Array<Bool> = [for (_ in was) false];
		pairEqual(
			[for (element in was) DataPath.json(element, versions.base, shape)],
			[for (element in is) DataPath.json(element, versions.now, shape)],
			partner, taken
		);
		pairEqual(
			remainingKeys(versions.base, old.children, taken), remainingKeys(versions.now, now.children, [for (j in partner) j >= 0]),
			partner, taken
		);
		return partner;
	}

	/**
	 * The rows follow the new order; what pairs with nothing is added or removed, but a scalar left on both sides pairs in
	 * order, a container left over never pairing with one. Elements that moved are one `ARRAY_ORDER` row on the array.
	 */
	private static function walkArrays(
		path: Array<String>, old: QueryNode, now: QueryNode, versions: Versions, out: Array<ValueChange>
	): Void {
		final shape: RefShape = versions.shape;
		final was: Array<QueryNode> = [for (element in old.children) DataPath.valueOf(element, shape)];
		final is: Array<QueryNode> = [for (element in now.children) DataPath.valueOf(element, shape)];
		final partner: Array<Int> = counterparts(old, now, was, is, versions);
		final taken: Array<Bool> = [for (j in 0...was.length) partner.contains(j)];
		final leftOld: Array<Int> = [for (j in 0...was.length) if (!taken[j] && !isContainer(was[j], shape)) j];
		var next: Int = 0;
		if (reordered(partner)) out.push(orderChange(path, ARRAY_ORDER));
		for (i => element in is) {
			final elementPath: Array<String> = path.concat([Std.string(i)]);
			var j: Int = partner[i];
			final left: Int = next < leftOld.length ? leftOld[next] : -1;
			if (j < 0 && left >= 0 && !isContainer(element, shape)) {
				j = left;
				next++;
				taken[j] = true;
			}
			if (j >= 0)
				walk(elementPath, was[j], element, versions, out)
			else
				out.push(addition(elementPath, element, versions));
		}
		for (j => element in was) if (!taken[j]) out.push(removal(path.concat([Std.string(j)]), element, versions));
	}

	private static function addition(path: Array<String>, value: QueryNode, versions: Versions): ValueChange {
		return {
			status: Added,
			path: DataPath.format(path),
			before: '',
			after: shown(value, versions.now, versions.shape)
		};
	}

	private static function removal(path: Array<String>, value: QueryNode, versions: Versions): ValueChange {
		return {
			status: Removed,
			path: DataPath.format(path),
			before: shown(value, versions.base, versions.shape),
			after: ''
		};
	}

	/** `value` as compact JSON, a digest cut to its head and anything longer than `MAX_SHOWN` cut with an ellipsis. */
	private static function shown(value: QueryNode, source: String, shape: RefShape): String {
		final name: Null<String> = DataPath.isString(value, shape) ? value.name : null;
		final text: String = name != null && isDigest(name)
			? JsonFormat.instance.quote(name.substr(0, DIGEST_KEPT) + CUT)
			: DataPath.json(value, source, shape);
		return text.length > MAX_SHOWN ? text.substr(0, MAX_SHOWN) + CUT : text;
	}

	private static function isDigest(text: String): Bool {
		if (text.length < DIGEST_MIN) return false;
		for (i in 0...text.length) {
			final code: Int = text.fastCodeAt(i);
			if (!(code >= '0'.code && code <= '9'.code || code >= 'a'.code && code <= 'f'.code)) return false;
		}
		return true;
	}

	/** Whether the counterparts of the new elements, in the new order, sit in another order in the base. */
	private static function reordered(partner: Array<Int>): Bool {
		var last: Int = -1;
		for (j in partner) if (j >= 0) {
			if (j < last) return true;
			last = j;
		}
		return false;
	}

	/** How many entries of `object` carry `key`; a repeated key's earlier entries are invisible to the key-wise walk. */
	private static function occurrences(object: QueryNode, key: String): Int {
		return object.children.count(entry -> (entry.name ?? '') == key);
	}

	/** A row for a change no value shows: `path` with `what` after it, nothing before or after. */
	private static function orderChange(path: Array<String>, what: String): ValueChange {
		return {
			status: Changed,
			path: '${path.length == 0 ? ROOT : DataPath.format(path)} $what',
			before: '',
			after: ''
		};
	}

	/** `changes` as the delta of a file whose text changed by `lines`; no change is layout. */
	private static function valuesDelta(changes: Array<ValueChange>, lines: FileDelta): FileDelta {
		return {
			change: changes.length == 0 ? Layout : Values,
			headerAdded: [],
			headerRemoved: [],
			headerReordered: false,
			renames: [],
			declarations: [],
			values: changes,
			added: lines.added,
			removed: lines.removed
		};
	}

	/** The one row for a document added or removed whole: an object's top-level keys with the size of each container, an array's length. */
	private static function summary(document: QueryNode, versions: Versions, added: Bool): ValueChange {
		final shape: RefShape = versions.shape;
		final value: QueryNode = DataPath.valueOf(document, shape);
		final entries: Map<String, QueryNode> = entriesOf(value);
		final text: String = if (value.kind == shape.objectLiteralKind)
			'{'
				+ [
					for (key in keysOf(value)) sized(key, DataPath.valueOf(entries[key] ?? value, shape), shape)
				].join(', ')
				+ '}'
		else if (value.kind == shape.arrayLiteralKind)
			'[${value.children.length} element(s)]'
		else
			shown(value, added ? versions.now : versions.base, shape);
		final cut: String = text.length > MAX_SHOWN ? text.substr(0, MAX_SHOWN) + CUT : text;
		return {
			status: added ? Added : Removed,
			path: ROOT,
			before: added ? '' : cut,
			after: added ? cut : ''
		};
	}

	/** `key`, followed by the number of members or elements when `value` is a container. */
	private static function sized(key: String, value: QueryNode, shape: RefShape): String {
		return isContainer(value, shape) ? '$key[${value.children.length}]' : key;
	}

	/** Pairs each unpaired new element with the first untaken old one under the same key, marking both. */
	private static function pairEqual(oldKeys: Array<String>, newKeys: Array<String>, partner: Array<Int>, taken: Array<Bool>): Void {
		for (i => newKey in newKeys) if (partner[i] < 0) for (j => oldKey in oldKeys) if (!taken[j] && oldKey == newKey) {
			partner[i] = j;
			taken[j] = true;
			break;
		}
	}

	/**
	 * The `RecordTree` key of each of `items` that is not `paired`, at its own index, and an empty string for the rest;
	 * only the unpaired elements are numbered among their repeats, so two versions number the same leftovers alike.
	 */
	private static function remainingKeys(source: String, items: Array<QueryNode>, paired: Array<Bool>): Array<String> {
		final keys: Array<String> = RecordTree.identities(source, [for (i => item in items) if (!paired[i]) item], '');
		var next: Int = 0;
		return [for (i in 0...items.length) paired[i] ? '' : keys[next++]];
	}

}
