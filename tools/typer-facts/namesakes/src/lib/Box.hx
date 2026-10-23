package lib;

import lib.Item;

class Box<T> {

	public function new() {}

	public function plain(f: Item -> Void): Void {}

	public function both(f: T -> Item -> Void): Void {}

	public static function gen<A>(x: A, f: A -> Item -> Void): Void {}

	public static function sPlain(f: Item -> Void): Void {}

}
