class Base {

	public function new() {}

}

class SubA extends Base {

	public function new() {
		super();
	}

}

class SubB extends Base {

	public function new() {
		super();
	}

}

class Box<T> {

	public var item: Null<T> = null;

	public function new() {}

	public function addAll(xs: Array<T>): Void {}

	public function take(xs: Array<Float>): Void {}

}

class IntBox extends Box<Int> {}

typedef Opts = { a: Float, ?b: Int, ?c: String }

abstract Money(Int) from Int to Int {

	@:op(A + B) public function add(o: Money): Money return new Money(this + (o: Int));

	@:op(A < B) public function lt(o: Money): String return "x";

	@:op(A * B) @:commutative public static function scale(a: Money, f: Float): Float return 1.0;

	public function new(v: Int) this = v;

}

abstract Lookup(Array<String>) {

	public function new() this = [];

	@:arrayAccess public function byIndex(i: Int): String return this[i];

	@:arrayAccess public function byName(s: String): Int return 0;

}

enum abstract Color(Int) to Int {
	var Red;
	var Green = 2;

	public static var Count = 3;
	public static final Other = 4;
}

abstract Plain(Int) {

	public static var K = 1;
	public static inline var L = 2;

}

class Probe {

	static function f2(?a: Array<String>, b: Array<Float>): Void {}

	static function gen<T>(xs: Array<T>): Void {}

	static function main() {
		var i: Int = 1;
		var f: Float = 2.0;
		var s: String = "s";
		var b: Bool = true;
		var n: Null<Int> = null;
		var nf: Null<Float> = null;
		var nb: Null<Bool> = null;
		var d: Dynamic = 1;
		var u: UInt = 3;
		var c = Math.random() > 0.5;
		var a1 = i + f;
		var a2 = i / 2;
		var a3 = i % 2;
		var a4 = -i;
		var a5 = s + i;
		var a6 = i + s;
		var a7 = n + 1;
		var a8 = n + f;
		var a9 = i == f;
		var a10 = !nb;
		var a11 = s < s;
		var a12 = d + 1;
		var a13 = u + 1;
		var a14 = u + 1.0;
		var a15 = u < 1;
		var a16 = n += 1;
		var a17 = f += 1;
		var a18 = s += 1;
		var a19 = nf += 1;
		var a20 = i % 2.0;
		var a21 = s + b;
		var a22 = f % i;
		var l1 = [1, 1.0];
		var l2 = [n, 1];
		var l3 = [1, n];
		var l4 = [nf, 1];
		var l5 = [1, nf];
		var l6 = [new SubA(), new SubB()];
		var l7 = [[1, 2.0]];
		var t1 = c ? 1 : 1.0;
		var t2 = c ? n : 1;
		var t3 = c ? 1 : n;
		var t4 = c ? new SubA() : new SubB();
		var t5 = if (c)
			1
		else
			2.0;
		var t6 = c ? nf : 1;
		var dd: Dynamic = [1, "a"];
		var dm: Dynamic = ["a" => 1];
		var dm2: Any = [1, 2];
		var o1: Opts = { a: 1 };
		var o2: Opts = { a: 1.5, b: 2 };
		var o3: Opts = { a: 1, c: "x" };
		var o4: Dynamic = { a: 1, b: [1, 2.0] };
		var o5: Null<Opts> = { a: 1, b: n };
		var box = new Box<Int>();
		var ib = new IntBox();
		box.addAll([1, 2]);
		box.take([1, 2]);
		ib.addAll([1, 2]);
		f2([1]);
		gen([1, 2]);
		var m1 = new Money(1);
		var m2 = m1 + m1;
		var m3 = m1 + 1;
		var m4 = m1 < m1;
		var m5 = m1 * 2.0;
		var m6 = 2.0 * m1;
		var lk = new Lookup();
		var e1 = lk[0];
		var e2 = lk["x"];
		var mp = new Map<String, Int>();
		var e3 = mp["a"];
		var arr: Array<Null<Int>> = [1];
		var e4 = arr[0];
		var vec = new haxe.ds.Vector<Int>(3);
		var e5 = vec[0];
		var nar: Null<Array<Int>> = [1];
		var e6 = nar[0];
		var col = Color.Red;
		var col2 = Color.Green;
		var col3 = Color.Count;
		var col4 = Color.Other;
		var pk = Plain.K;
		var pl = Plain.L;
		var ra: haxe.ds.ReadOnlyArray<Int> = [1];
		var e7 = ra[0];
		for (k in 0...i) {
			var kk = k;
		}
		for (k in 0...n) {
			var kk = k;
		}
		var i64 = haxe.Int64.make(0, 1);
		var x64 = i64 + 1;
		var y64 = i64 < i64;
		var i32: haxe.Int32 = 1;
		var x32 = i32 + 1;
		var x32b = i32 + 1.5;
		var x32c = i32 * i32;
		var ar = new Array();
		ar.push(1);
		var sm = new haxe.ds.StringMap<Int>();
		var ii = ~i;
		var sh = i << 1;
		var paren = (i + f) * 2;
		trace([
			a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21, a22
		]);
		trace([
			l1, l2, l3, l4, l5, l6, l7, t1, t2, t3, t4, t5, t6, dd, dm, dm2, o1, o2, o3, o4, o5, m2, m3, m4, m5, m6, e1, e2, e3, e4, e5,
			e6, col, col2, col3, col4, pk, pl, x64, y64, x32, x32b, x32c, sm, ii, sh, paren, ra, e7
		]);
	}

}
