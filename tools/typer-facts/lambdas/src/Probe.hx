using Lambda;

private typedef Entry = { name: String };

class Item {

	public var n: Int = 0;

	public function new() {}

}

class Box<T> {

	public function new() {}

	public function each(f: T -> Void): Void {}

	public function mapTo<U>(f: T -> U): Box<U> {
		return new Box<U>();
	}

	public static function make<A>(a: A, f: A -> Void): Void {}

	public static function late<A>(f: A -> Void, a: A): Void {}

}

class Sub extends Box<Item> {}

class Bag<T> {

	private final data: Array<T> = [];

	public function new() {}

	public function iterator(): Iterator<T> {
		return data.iterator();
	}

	public function some(a: Array<T>): Bool {
		return a.exists(e -> e != null);
	}

	public function own(): Bool {
		return data.exists(e -> e != null);
	}

}

class Registry {

	private final entries: Array<Entry> = [];

	public function new() {}

	public function has(name: String): Bool {
		return entries.exists(e -> e.name == name);
	}

	public function viaThis(name: String): Bool {
		return this.entries.exists(e -> e.name == name);
	}

}

abstract Names(Bag<String>) {

	public function new() {
		this = new Bag<String>();
	}

	public function any(): Bool {
		return Lambda.exists(this, e -> e.length > 0);
	}

}

class Probe {

	static function gen<A, B>(xs: Array<A>, f: A -> B): Array<B> {
		return [];
	}

	static function nul<A>(x: Null<A>, f: A -> Void): Void {}

	static function two<A>(x: A, y: A, f: A -> Void): Void {}

	static function box<A>(x: Box<A>, f: A -> Void): Void {}

	static function takeItem(f: Item -> Bool): Void {}

	static function main() {
		final xs: Array<Item> = [];
		xs.exists(x -> x.n > 0);
		xs.map(x -> x.n);
		xs.filter(x -> x.n > 1);
		xs.iter(x -> trace(x));
		xs.fold((x, acc: Int) -> acc + x.n, 0);
		Lambda.exists(xs, x -> x.n > 2);
		final m: Map<String, Item> = [];
		Lambda.count(m, x -> x.n > 0);
		final b: Box<Item> = new Box<Item>();
		b.each(x -> trace(x));
		b.mapTo(x -> x.n);
		Box.make(new Item(), x -> trace(x));
		Box.late(x -> trace(x), new Item());
		gen(xs, x -> x.n);
		final n: Null<Int> = 1;
		nul(n, x -> trace(x));
		nul(1, x -> trace(x));
		two(n, 1, x -> trace(x));
		two(1, n, x -> trace(x));
		box(new Sub(), x -> trace(x));
		final na: Null<Array<Item>> = xs;
		na.exists(x -> x.n > 3);
		xs.sort((a, b) -> a.n - b.n);
		takeItem(x -> x.n > 0);
		final f: Item -> Bool = x -> x.n > 4;
		final bag: Bag<Item> = new Bag<Item>();
		bag.exists(x -> x.n > 5);
		final o: {} = {};
		final fields: Array<String> = Reflect.fields(o);
		trace(fields.foreach(k -> k.length > 0));
		final dyn: Array<Dynamic> = [];
		trace(dyn.filter(x -> x.lock == 'a'));
		trace(f, bag.some([]), bag.own(), new Registry().has(''), new Registry().viaThis(''), new Names().any());
	}

}
