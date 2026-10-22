typedef Opts = { a: Float, ?b: Int, ?c: String }
typedef Pt = { x: Int, y: Int }

class Box<T> {

	public function new() {}

	public function addAll(xs: Array<T>): Array<T> return xs;

	public function dyn(x: Dynamic): Void {}

	public function opts(o: Opts): Opts return o;

	public function pts(p: Array<Pt>): Void {}

	public function nested(o: { inner: Array<Float> }): Void {}

	public function skip(?a: Array<String>, b: Array<Float>): Void {}

	public function opt(?o: Opts): Void {}

	public function anyv(a: Any): Void {}

	public function floats(xs: Array<Float>): Array<Float> return xs;

	@:overload(function(xs: Array<String>): Void {})
	public function ov(xs: Array<Float>): Void {}

}

class Probe {

	static function sdyn(x: Dynamic): Void {}

	static function main() {
		var box = new Box<Int>();
		box.dyn([1, "a"]);
		box.dyn(["a" => 1]);
		box.dyn({ a: 1, b: [1, 2.0] });
		box.dyn([{ x: 1 }, { x: 2 }]);
		box.anyv([1, 2]);
		box.opts({ a: 1 });
		box.opts({ a: 1, b: 2 });
		box.opts({ a: 1.5, c: "s" });
		box.pts([{ x: 1, y: 2 }]);
		box.nested({ inner: [1, 2] });
		box.skip([1]);
		box.opt({ a: 1 });
		var r1 = box.addAll([1, 2]);
		var r2 = box.floats([1, 2]);
		box.ov([1.0]);
		sdyn([1, "a"]);
		sdyn(["a" => 1]);
		var ternMap = Math.random() > 0.5 ? ["a" => 1] : ["b" => 2];
		var ml = ["a" => 1];
		var ml2 = [1 => "a", 2 => "b"];
		var arrOfMaps = [["a" => 1]];
		var e = [][0];
		trace([r1, r2, ternMap, ml, ml2, arrOfMaps]);
	}

}
