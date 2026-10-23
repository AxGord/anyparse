package app2;

import lib.SubBox;

class Item {

	public var tag: String = '';

	public function new() {}

}

class Sub2 extends SubBox {

	public function f(): Void {
		this.each(x -> trace(x.tag));
		each(x -> trace(x.tag));
	}

}
