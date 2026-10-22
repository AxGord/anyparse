typedef Inner = { x: Int };
typedef Outer = { a: Int, inner: Inner, ?list: Array<Int> };
typedef Alias = Outer;
typedef WithFinal = { final a: Int; };

@:structInit class SI {

	public var a: Int;

	public function new(a: Int) {
		this.a = a;
	}

}

abstract FromObj({ a: Int }) from { a: Int } {}

class Probe {

	static function takeO(o: Outer): Void {}

	static function takeA(o: Alias): Void {}

	static function takeOpt(?o: Inner): Void {}

	static function takeF(o: WithFinal): Void {}

	static function takeSI(o: SI): Void {}

	static function takeFO(o: FromObj): Void {}

	static function takeAny(o: Any): Void {}

	static function takeD(o: Dynamic): Void {}

	static function takeG<T>(o: T): Void {}

	static function takeArrF(a: Array<Float>): Void {}

	static function takeNA(a: Null<Array<Int>>): Void {}

	static function main() {
		takeO({ a: 1, inner: { x: 2 } });
		takeO({ a: 1, inner: { x: 2 }, list: [1] });
		takeA({ a: 1, inner: { x: 2 } });
		takeOpt({ x: 3 });
		takeF({ a: 1 });
		takeSI({ a: 1 });
		takeFO({ a: 1 });
		takeAny({ a: 1 });
		takeD({ a: 1, b: [1, 2] });
		takeD([{ a: 1 }, { a: 2 }]);
		takeD([for (i in 0...3) i]);
		takeArrF([for (i in 0...3) i]);
		takeArrF([1, 2]);
		takeNA([1, 2]);
		takeG({ a: 1 });
		takeG([1, 2]);
		var xs: Array<Outer> = [{ a: 1, inner: { x: 1 } }];
		var m = [1 => 2];
		var ys: Array<Array<Float>> = [[1, 2], [3]];
		trace(xs, m, ys);
	}

}
