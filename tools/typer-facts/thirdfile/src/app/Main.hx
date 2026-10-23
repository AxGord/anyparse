package app;

import app2.Third.Sub2;
import lib.Holder;

using Lambda;
using lib.LExt;

class Item {

	public var tag: String = '';

	public function new() {}

}

class Main {

	static function arr<A>(x: Array<A>, f: A -> Void): Void {}

	static function main() {
		final h: Holder = new Holder();
		trace(h.items.exists(x -> x.tag > 0));
		trace(h.items.map(x -> x.tag));
		h.items.visit(x -> trace(x.tag));
		h.box.each(x -> trace(x.tag));
		arr(h.items, x -> trace(x.tag));
		new Sub2().f();
		final it = h.items;
		trace(it.map(x -> x.tag));
	}

}
