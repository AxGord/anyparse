typedef Inner = { x: Int };

typedef T1 = {
	?opt: Inner,
	f: Float,
	cb: Int -> Void,
	?s: String
};

typedef T2 = { arr: Array<Inner> };

class Box<T> {

	public function new() {}

	public function put(v: T): Void {}

	public static function make(o: T1): Void {}

}

class Probe {

	static var field: T1 = { f: 1.5, cb: x -> {} };

	static function take1(o: T1): Void {}

	static function take2(o: T2): Void {}

	static function takeOv(o: T1, ?b: Bool, c: Int = 0): Void {}

	@:overload(function(o: T2): Void {})
	static function over(o: T1): Void {}

	static function ret(): T1 {
		return { f: 2, cb: x -> {} };
	}

	static function main() {
		take1({ f: 1, cb: x -> {} });
		take1({ f: 1.5, cb: x -> {}, s: "a" });
		take1({ f: 1.5, cb: function(x) {}, opt: { x: 1 } });
		take2({ arr: [{ x: 1 }] });
		take2({ arr: [] });
		takeOv({ f: 1.5, cb: x -> {} }, true);
		over({ f: 1.5, cb: x -> {} });
		Box.make({ f: 1.5, cb: x -> {} });
		new Box<T1>().put({ f: 1.5, cb: x -> {} });
		var t: T1 = { f: 0.5, cb: x -> {} };
		t = { f: 0.5, cb: x -> {} };
		trace(t, field, ret());
	}

}
