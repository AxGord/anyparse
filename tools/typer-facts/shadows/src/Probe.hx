class Item {

	public function new() {}

}

class Box<T> {

	public function new() {}

	public function shadow<T>(x: T, f: T -> Void): Void {}

	public function own(f: T -> Void): Void {}

}

class Probe {

	static function main() {
		final b: Box<Item> = new Box<Item>();
		b.shadow(1, x -> trace(x));
		b.shadow('s', x -> trace(x));
		b.own(x -> trace(x));
	}

}
