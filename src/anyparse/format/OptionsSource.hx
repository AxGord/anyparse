package anyparse.format;

import haxe.Exception;

using StringTools;

/**
 * The one answer to "how does the value of an options-record knob read back as Haxe source, and which knobs did an edit change".
 *
 * A knob's type is data (`OptionShape`, built from the record's declaration at compile time by `anyparse.macro.OptionKnobs`),
 * because the runtime value alone cannot name its type: an `enum abstract` over `Int` is an `Int` at run time. A value with no
 * source spelling (a function) is refused, never approximated.
 */
@:nullSafety(Strict)
final class OptionsSource {

	/** The Haxe expression that rebuilds `value`; every type it names is added to `imports` as an import path. */
	public static function spell(shape: OptionShape, value: OptionValue, imports: Array<String>): String {
		final records: Map<String, Array<OptionField>> = [];
		return spellIn(shape, value, imports, records);
	}

	/** The knobs whose value in `edited` differs from `base`, in knob order, each with the source that sets it. */
	public static function changes(
		knobs: Array<OptionKnob>, base: OptionValue, edited: OptionValue, imports: Array<String>
	): Array<OptionAssignment> {
		final out: Array<OptionAssignment> = [];
		for (knob in knobs) {
			final was: OptionValue = knob.read(base);
			final now: OptionValue = knob.read(edited);
			if (was == now) continue;
			if (Reflect.isFunction(was) || Reflect.isFunction(now)) throw new Exception('${knob.name}: a function has no source spelling');
			final needed: Array<String> = [];
			final spelled: String = spell(knob.shape, now, needed);
			if (spelled == spell(knob.shape, was, [])) continue;
			out.push({ name: knob.name, source: spelled });
			for (path in needed) if (!imports.contains(path)) imports.push(path);
		}
		return out;
	}

	private static function spellIn(
		shape: OptionShape, value: OptionValue, imports: Array<String>, records: Map<String, Array<OptionField>>
	): String {
		switch shape {
			case Scalar:
				return Std.string(value);
			case Text:
				return quote(Std.string(value));
			case Constants(type, from, names):
				for (c in names) if (c.value == value) {
					if (!imports.contains(from)) imports.push(from);
					return '$type.${c.name}';
				}
				throw new Exception('$type: no constant holds $value');
			case Nullable(inner):
				return value == null ? 'null' : spellIn(inner, value, imports, records);
			case List(item):
				final items: Array<OptionValue> = cast value;
				return '[' + items.map(x -> spellIn(item, x, imports, records)).join(', ') + ']';
			case Record(id, fields):
				records[id] = fields;
				return spellRecord(fields, value, imports, records);
			case Again(id):
				final fields: Null<Array<OptionField>> = records[id];
				if (fields == null) throw new Exception('$id: a recursive type met before its own declaration');
				return spellRecord(fields, value, imports, records);
			case Opaque(type):
				throw new Exception('$type: no source spelling');
		}
	}

	private static function spellRecord(
		fields: Array<OptionField>, value: OptionValue, imports: Array<String>, records: Map<String, Array<OptionField>>
	): String {
		final parts: Array<String> = [];
		for (f in fields) {
			final v: OptionValue = Reflect.field(value, f.name);
			if (f.optional && v == null) continue;
			parts.push('${f.name}: ${spellIn(f.shape, v, imports, records)}');
		}
		return parts.length == 0 ? '{}' : '{ ' + parts.join(', ') + ' }';
	}

	private static function quote(text: String): String {
		final escaped: String = text.replace('\\', '\\\\')
			.replace("'", "\\'")
			.replace('$', "$$")
			.replace('\n', '\\n')
			.replace('\r', '\\r')
			.replace('\t', '\\t');
		return '\'$escaped\'';
	}

}

/** The value of one knob: what it is, only its `OptionShape` says. */
abstract OptionValue(Dynamic) from Dynamic to Dynamic {} // noqa: avoid-dynamic
/** The type of one knob, as much of it as source needs. */
enum OptionShape {

	/** A `Bool`, `Int` or `Float`: `Std.string` is its source. */
	Scalar;

	/** A `String`. */
	Text;

	/** An `enum abstract`: the constant holding the value, `type` its simple name and `from` the import path that brings it. */
	Constants(type: String, from: String, names: Array<OptionConstant>);

	/** A `Null<T>`. */
	Nullable(inner: OptionShape);

	/** An `Array<T>`. */
	List(item: OptionShape);

	/** An anonymous structure, named so a recursive one can point back at itself. */
	Record(id: String, fields: Array<OptionField>);

	/** The `Record` of this `id` that is still open around it. */
	Again(id: String);

	/** A type with no source spelling, such as a function. */
	Opaque(type: String);

}

/**
 * One constant of an `enum abstract`: its name and the value that equals it.
 */
typedef OptionConstant = { name: String, value: OptionValue };

/**
 * One field of a `Record`: whether the type declares it `@:optional`, so a value without it spells without it.
 */
typedef OptionField = { name: String, optional: Bool, shape: OptionShape };

/** One knob of an options record: its name, type and a read of it. */
typedef OptionKnob = { name: String, shape: OptionShape, read: OptionValue -> OptionValue };

/** `<name> = <source>`: the statement that sets a knob. */
typedef OptionAssignment = { name: String, source: String };
