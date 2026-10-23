package app;

import lib.Box;

class Item {

	public var tag: String = '';

	public function new() {}

}

class Probe {

	static function main() {
		final b: Box<Item> = new Box<Item>();
		b.plain(x -> trace(x.tag));
		b.both((a, c) -> trace(c.tag));
		Box.gen(new Item(), (a, c) -> trace(c.tag));
		Box.sPlain(x -> trace(x.tag));
		b.both((a, c) -> trace(a.tag));
	}

}
