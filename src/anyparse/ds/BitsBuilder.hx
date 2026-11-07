package anyparse.ds;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

/** A fixed domain as the lowering needs it: the bit of every value, and the two conversions over `value` and `index`. */
private typedef Domain = {
	final bits: Array<Int>;
	final bitOfValue: Expr;
	final valueAtIndex: Expr;
};
/**
 * One of the two stores a set can sit on: its type, each bit operation as an expression over `this`, `bit` and `other`,
 * and the class that walks it.
 */
private typedef Store = {
	final type: ComplexType;
	final empty: Expr;
	final has: Expr;
	final with: Expr;
	final without: Expr;
	final isEmpty: Expr;
	final union: Expr;
	final intersect: Expr;
	final complement: Expr;
	final same: Expr;
	final cursor: TypeDefinition;
};

/**
 * Lowers `Bits<E>` to an abstract of its own, built once per domain — the one answer to "which bit stands for a value
 * of a fixed domain, and how wide is its store". A parameterless enum gives each constructor its index, an `Int` enum
 * abstract each value its rank among the distinct values; anything else is refused. Up to 32 bits the abstract is over one
 * `Int`, above that over a
 * `haxe.ds.Vector<Int>`, never an `Int64`, which is an object on js.
 */
final class BitsBuilder {

	private static inline final WORD: Int = 32;
	private static inline final MODULE: String = 'anyparse.ds';

	public static function build(): ComplexType {
		final pos: Position = Context.currentPos();
		final element: Type = switch (Context.getLocalType()) {
			case TInst(_, [param]): Context.follow(param);
			case _: Context.fatalError('Bits takes one type parameter', pos);
		};
		final domain: Domain = domainOf(element, pos);
		final name: String = 'Bits_${keyOf(element)}';
		if (!isDefined(name)) {
			final valueType: ComplexType = Context.toComplexType(element);
			var width: Int = 0;
			for (bit in domain.bits) if (bit >= width) width = bit + 1;
			final store: Store = width <= WORD ? narrow(domain, valueType) : wide(domain, valueType, width);
			for (type in lower(name, valueType, domain, store, pos)) Context.defineType(type);
		}
		return TPath({ pack: MODULE.split('.'), name: name });
	}

	/** The domain of `element`, or a compile error naming why it is not fixed. */
	private static function domainOf(element: Type, pos: Position): Domain {
		final shown: String = TypeTools.toString(element);
		final isPrivate: Bool = switch (element) {
			case TEnum(ref, _): ref.get().isPrivate;
			case TAbstract(ref, _): ref.get().isPrivate;
			case _: false;
		};
		if (isPrivate) Context.fatalError('Bits<$shown>: a private type cannot be named outside its module, where Bits lowers', pos);
		final domain: Domain = switch (element) {
			case TEnum(ref, params):
				if (params.length > 0) Context.fatalError('Bits<$shown>: an enum with type parameters is not a fixed domain', pos);
				enumDomain(ref.get(), shown, pos);
			case TAbstract(ref, _) if (ref.get().meta.has(':enum')): abstractDomain(ref.get(), shown, pos);
			case _:
				Context.fatalError(
					'Bits<$shown'
					+ '>: the domain is not fixed - Bits takes an enum whose constructors take no arguments, or an Int enum abstract',
					pos
				);
		};
		if (domain.bits.length == 0) Context.fatalError('Bits<$shown>: the domain has no value', pos);
		return domain;
	}

	/** A constructor's bit is its index; the last constructor answers any index the others do not. */
	private static function enumDomain(type: EnumType, shown: String, pos: Position): Domain {
		final path: Array<String> = type.module.split('.');
		if (path[path.length - 1] != type.name) path.push(type.name);
		final bits: Array<Int> = [];
		final cases: Array<Case> = [];
		var last: Expr = macro null;
		for (name in type.names) {
			final ctor: EnumField = type.constructs[name];
			switch (ctor.type) {
				case TFun(_, _):
					Context.fatalError('Bits<$shown>: the constructor $name takes arguments, so the domain is not fixed', pos);
				case _:
			}
			if (bits.length > 0) cases.push({ values: [macro $v{bits[bits.length - 1]}], expr: last });
			bits.push(ctor.index);
			last = macro $p{path.concat([name])};
		}
		return { bits: bits, bitOfValue: macro Type.enumIndex(value), valueAtIndex: { expr: ESwitch(macro index, cases, last), pos: pos } };
	}

	/**
	 * A value's bit is its rank among the distinct values in ascending order, so the store is as wide as the domain is
	 * large, never as its largest value. When the values run 0 to n - 1 the rank is the value and both conversions are casts.
	 */
	private static function abstractDomain(type: AbstractType, shown: String, pos: Position): Domain {
		switch (Context.followWithAbstracts(type.type)) {
			case TAbstract(_.get() => { pack: [], name: 'Int' }, _):
			case _:
				Context.fatalError('Bits<$shown>: an enum abstract over anything but Int is not a fixed domain', pos);
		}
		final values: Array<Int> = [];
		for (field in type.impl.get().statics.get()) if (field.meta.has(':enum')) {
			final meta: Array<MetadataEntry> = field.meta.extract(':value');
			final value: Int = meta.length == 1 && meta[0].params != null ? literalOf(meta[0].params[0]) : -1;
			if (value < 0) Context.fatalError('Bits<$shown>: ${field.name} is not a non-negative Int literal', pos);
			if (!values.contains(value)) values.push(value);
		}
		values.sort(Reflect.compare);
		final bits: Array<Int> = [for (rank in 0...values.length) rank];
		final dense: Bool = values.length == 0 || values[values.length - 1] == values.length - 1;
		if (dense) return { bits: bits, bitOfValue: macro (cast value: Int), valueAtIndex: macro cast index };
		final last: Int = values.length - 1;
		final toRank: Array<Case> = [
			for (rank in 0...last) { values: [macro $v{values[rank]}], expr: macro $v{rank} }
		];
		final toValue: Array<Case> = [
			for (rank in 0...last) { values: [macro $v{rank}], expr: macro cast $v{values[rank]} }
		];
		return {
			bits: bits,
			bitOfValue: { expr: ESwitch(macro (cast value: Int), toRank, macro $v{last}), pos: pos },
			valueAtIndex: { expr: ESwitch(macro index, toValue, macro cast $v{values[last]}), pos: pos }
		};
	}

	/** The Int literal `expr` spells under its casts and parentheses, or -1. */
	private static function literalOf(expr: Expr): Int {
		return switch (expr.expr) {
			case ECast(inner, _), EParenthesis(inner), ECheckType(inner, _): literalOf(inner);
			case EConst(CInt(digits)): Std.parseInt(digits) ?? -1;
			case _: -1;
		};
	}

	/** The name part that tells one domain's lowering from another's: the module and name of `element`. */
	private static function keyOf(element: Type): String {
		final path: Array<String> = switch (element) {
			case TEnum(ref, _): ref.get().module.split('.').concat([ref.get().name]);
			case TAbstract(ref, _): ref.get().module.split('.').concat([ref.get().name]);
			case _: [];
		};
		return path.join('_');
	}

	/** Whether this compilation already lowered the domain named `name`. */
	private static function isDefined(name: String): Bool {
		try {
			Context.getType('$MODULE.$name');
			return true;
		} catch (_: haxe.Exception) {
			return false;
		}
	}

	/** The store of a domain whose bits all fit in one `Int`; `~` keeps only the bits a value stands for. */
	private static function narrow(domain: Domain, valueType: ComplexType): Store {
		var full: Int = 0;
		for (bit in domain.bits) full |= 1 << bit;
		final valueAtIndex: Expr = domain.valueAtIndex;
		return {
			type: macro : Int,
			empty: macro 0,
			has: macro (this & (1 << bit)) != 0,
			with: macro this | (1 << bit),
			without: macro this & ~(1 << bit),
			isEmpty: macro this == 0,
			union: macro this | (cast other: Int),
			intersect: macro this & (cast other: Int),
			complement: macro ~this & $v{full},
			same: macro this == (cast other: Int),
			cursor: macro class Cursor {
				private var rest: Int;

				public inline function new(bits: Int) rest = bits;

				public inline function hasNext(): Bool return rest != 0;

				public inline function next(): $valueType {
					final index: Int = anyparse.ds.BitWords.lowest(rest);
					rest &= ~(1 << index);
					return $valueAtIndex;
				}
			}
		};
	}

	/** The store of a domain wider than one `Int`: a vector of words that every change replaces, so a copy never shares one. */
	private static function wide(domain: Domain, valueType: ComplexType, width: Int): Store {
		final count: Int = ((width - 1) >>> BitWords.SHIFT) + 1;
		final full: Array<Int> = [for (_ in 0...count) 0];
		for (bit in domain.bits) full[bit >>> BitWords.SHIFT] |= 1 << (bit & BitWords.LAST);
		final fullWords: Expr = macro $a{full.map(word -> macro $v{word})};
		final valueAtIndex: Expr = domain.valueAtIndex;
		return {
			type: macro : haxe.ds.Vector<Int>,
			empty: macro anyparse.ds.BitWords.make($v{count}),
			has: macro anyparse.ds.BitWords.has(this, bit),
			with: macro anyparse.ds.BitWords.with(this, bit),
			without: macro anyparse.ds.BitWords.without(this, bit),
			isEmpty: macro anyparse.ds.BitWords.isEmpty(this),
			union: macro anyparse.ds.BitWords.or(this, cast other),
			intersect: macro anyparse.ds.BitWords.and(this, cast other),
			complement: macro anyparse.ds.BitWords.complement(this, $fullWords),
			same: macro anyparse.ds.BitWords.same(this, cast other),
			cursor: macro class Cursor {
				private final words: haxe.ds.Vector<Int>;
				private var word: Int = 0;
				private var rest: Int;

				public inline function new(words: haxe.ds.Vector<Int>) {
					this.words = words;
					rest = words[0];
				}

				public inline function hasNext(): Bool {
					while (rest == 0 && ++word < words.length) rest = words[word];
					return rest != 0;
				}

				public inline function next(): $valueType {
					final bit: Int = anyparse.ds.BitWords.lowest(rest);
					rest &= ~(1 << bit);
					final index: Int = (word << anyparse.ds.BitWords.SHIFT) + bit;
					return $valueAtIndex;
				}
			}
		};
	}

	/** The set abstract named `name` over `store`, and the class that walks it. */
	private static function lower(
		name: String, valueType: ComplexType, domain: Domain, store: Store, pos: Position
	): Array<TypeDefinition> {
		final pack: Array<String> = MODULE.split('.');
		final selfPath: TypePath = { pack: pack, name: name };
		final self: ComplexType = TPath(selfPath);
		final cursorPath: TypePath = { pack: pack, name: '${name}_Iterator' };
		final cursor: ComplexType = TPath(cursorPath);
		final bitOfValue: Expr = domain.bitOfValue;
		final empty: Expr = store.empty;
		final has: Expr = store.has;
		final with: Expr = store.with;
		final without: Expr = store.without;
		final isEmpty: Expr = store.isEmpty;
		final union: Expr = store.union;
		final intersect: Expr = store.intersect;
		final complement: Expr = store.complement;
		final same: Expr = store.same;
		final set: TypeDefinition = macro class $name {
			public inline function new() this = $empty;

			@:from public static inline function ofValue(value: $valueType): $self {
				var bits: $self = new $selfPath();
				bits.add(value);
				return bits;
			}

			@:from public static inline function ofArray(values: Array<$valueType>): $self {
				var bits: $self = new $selfPath();
				for (value in values) bits.add(value);
				return bits;
			}

			private static inline function bitOf(value: $valueType): Int return $bitOfValue;

			public inline function add(value: $valueType): Void {
				final bit: Int = bitOf(value);
				this = $with;
			}

			public inline function has(value: $valueType): Bool {
				final bit: Int = bitOf(value);
				return $has;
			}

			public inline function remove(value: $valueType): Bool {
				final bit: Int = bitOf(value);
				final had: Bool = $has;
				if (had) this = $without;
				return had;
			}

			public inline function clear(): Void this = $empty;

			public inline function isEmpty(): Bool return $isEmpty;

			public inline function copy(): $self return cast this;

			@:op(A | B) public inline function union(other: $self): $self return cast $union;

			@:op(A & B) public inline function intersect(other: $self): $self return cast $intersect;

			@:op(~A) public inline function complement(): $self return cast $complement;

			@:op(A == B) public inline function equals(other: $self): Bool return $same;

			@:op(A != B) public inline function differs(other: $self): Bool return !$same;

			public inline function iterator(): $cursor return new $cursorPath(this);
		};
		set.kind = TDAbstract(store.type);
		set.pack = pack;
		final iterator: TypeDefinition = store.cursor;
		iterator.name = cursorPath.name;
		iterator.meta = [{ name: ':final', pos: pos }];
		iterator.pack = pack;
		return [set, iterator];
	}

}
#end
