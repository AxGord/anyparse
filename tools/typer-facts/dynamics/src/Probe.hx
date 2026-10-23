class Box<T> {

	public function new() {}

}

class Probe {

	static function arr<A>(x: A, f: Array<A> -> Void): Void {}

	static function box<A>(x: Box<A>, f: Array<A> -> Void): Void {}

	static function nul<A>(x: Null<A>, f: Array<A> -> Void): Void {}

	static function ab<A>(x: Array<A>, f: Array<A> -> Void): Void {}

	static function take(a: Array<String>): Void {}

	static function main() {
		final dyn: Dynamic = null;
		final bd: Box<Dynamic> = new Box<Dynamic>();
		final ad: Array<Dynamic> = [];
		arr(dyn, x -> take(x));
		box(bd, x -> take(x));
		nul(dyn, x -> take(x));
		ab(ad, x -> take(x));
	}

}
