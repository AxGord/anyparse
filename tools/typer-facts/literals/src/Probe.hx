typedef Opts = { a: Int, ?b: String };

class P {

	public var x: Int;

	public function new(x: Int) {
		this.x = x;
	}

}

class Probe {

	static var field: Opts = { a: 1 };

	static function take(o: Opts): Void {}

	static function takeD(o: Dynamic): Void {}

	static function takeArr(a: Array<Float>): Void {}

	static function takeIt(a: Iterable<Int>): Void {}

	static function ret(): Opts return { a: 2 };

	static function main() {
		var o1: Opts = { a: 1 };
		var o2 = { a: 1, b: "x" };
		take({ a: 3 });
		takeD({ a: 3, c: true });
		var arr1: Array<Float> = [1, 2];
		var arr2 = [1, 2];
		var arr3 = [1, 2.5];
		var arr4 = ["a", "b"];
		takeArr([1, 2]);
		takeD([1, 2]);
		takeIt([1, 2]);
		var arr5: Array<Opts> = [{ a: 1 }];
		var arr6 = [new P(1), new P(2)];
		var arr7 = [[1], [2]];
		for (s in ["x", "y"]) trace(s);
		var j = [1, 2].length;
		var objs = [{ a: 1 }, { a: 2 }];
		var o3: { a: Int } = { a: 1 };
		var o4: Null<Opts> = { a: 1 };
		var o5: Dynamic = { a: 1 };
		var arr8: Dynamic = [1];
		var arr9: Array<Dynamic> = [1, "a"];
		trace(o1, o2, arr1, arr2, arr3, arr4, arr5, arr6, arr7, j, objs, o3, o4, o5, arr8, arr9, ret(), field);
	}

}
