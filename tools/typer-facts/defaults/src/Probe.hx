class Item {

	public function new() {}

}

class Item2 {

	public function new() {}

}

class Def<T = Item> {

	public function new() {}

	public function set(t: T): Void {}

}

class Dflt<T = String> {

	public function new() {}

	public function set(t: T): Void {}

}

class Probe {

	static function main() {
		final d = new Def();
		d.set(new Item2());
		final e = new Dflt();
		e.set(5);
	}

}
