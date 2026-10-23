typedef Opts = { a: Float, ?b: Int, ?c: String }
typedef Pt = { x: Int, y: Int }
typedef D = { m: Dynamic }

typedef Many = {
	f: Float,
	nf: Null<Float>,
	?ob: Bool,
	xs: Array<Float>,
	p: Pt,
	d: Dynamic,
	fn: Int -> Int,
	s: String,
	col: Color
}

typedef OptsAlias = Opts

class Base {

	public function new() {}

}

class SubA extends Base {

	public function new() {
		super();
	}

}

class Dflt<T = String> {

	public function new() {}

}

@:generic class Gen<T> {

	public function new() {}

}

typedef IntDflt = Dflt<Int>

enum abstract Color(Int) to Int {
	var Red;
	var Green = 2;

	public static function make(): Color return Red;

	public static var count = 2;
}

typedef ColorAlias = Color

class K {

	public static var V = 1;
	public static final W = "w";

}

abstract Op(Array<Int>) {

	public function new() this = [];

	@:op([]) public function get(i: Int): Float return 1.0;

}

abstract SLook(Array<Int>) {

	public function new() this = [];

	@:arrayAccess public static function sget(a: SLook, i: Int): String return "s";

}

abstract ILook(Array<Int>) {

	public function new() this = [];

	@:arrayAccess public inline function get(i: Float): Bool return true;

	@:arrayAccess public function geti(i: Int): String return "s";

}

class Box {

	public function new() {}

	public function d(o: D): Void {}

	public function opts(o: Opts): Void {}

	public function many(o: Many): Void {}

	public function alias(o: OptsAlias): Void {}

	public function dyn(x: Dynamic): Void {}

}

class Probe {

	static function main() {
		var box = new Box();
		var i = 1;
		var n: Null<Int> = 1;
		var c = Math.random() > 0.5;
		box.d({ m: ["a" => 1] });
		box.d({ m: [1, "a"] });
		box.d({ m: [["a" => 1]] });
		box.dyn([["a" => 1]]);
		box.opts({ a: 1, b: 2 });
		box.opts({ a: i, b: n });
		box.opts({ a: 1, b: i });
		box.alias({ a: 1, c: "x" });
		box.many({
			f: 1,
			nf: 1,
			ob: true,
			xs: [1, 2],
			p: { x: 1, y: 2 },
			d: { q: 1 },
			fn: x -> x,
			s: "s",
			col: Color.Red
		});
		box.many({
			f: 1.0,
			nf: n,
			xs: [],
			p: { x: 1, y: 2 },
			d: [1],
			fn: function(x) return x,
			s: null,
			col: Red
		});
		var dd = new Dflt();
		var di = new IntDflt();
		var g = new Gen<Int>();
		var cm = Color.make;
		var cc = Color.count;
		var ca = ColorAlias.Red;
		var kv = K.V;
		var kw = K.W;
		var op = new Op();
		var o1 = op[0];
		var sl = new SLook();
		var s1 = sl[0];
		var il = new ILook();
		var i1 = il[1];
		var i2 = il[1.5];
		var t1 = c ? new SubA() : new Base();
		var t2 = c ? "a" : null;
		var t3 = if (c)
			1
		else
			n;
		var cmp = Color.Red == Color.Green;
		var cadd = Color.Red + 1;
		trace([dd, di, g, cm, cc, ca, kv, kw, o1, s1, i1, i2, t1, t2, t3, cmp, cadd]);
	}

}
