using Lambda;

class Item {

	public var n: Int = 0;

	public function new() {}

}

class Probe {

	static function optArg(f: (?a:Int) -> Void): Void {}

	static function gen<A>(x: A, f: (?a:A) -> Void): Void {}

	static function main() {
		final xs: Array<Item> = [];
		trace(xs.map((?x) -> x));
		trace(xs.map(function(?x) return x));
		xs.iter(function(x = null) trace(x));
		final f1: Item -> Bool = (?x) -> x != null;
		final fs: Array<Item -> Void> = [(?x) -> trace(x)];
		optArg((?x) -> trace(x));
		gen(new Item(), (?x) -> trace(x));
		trace(f1, fs);
	}

}
