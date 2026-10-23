import haxe.ds.Vector;
import haxe.ds.ReadOnlyArray;
import haxe.DynamicAccess;

abstract U(Int) from Int to Int {

	@:op(A + B) static function add(a: U, b: U): U return (a: Int) + (b: Int);

	@:op(A * B) @:commutative static function mulInt(a: U, b: Int): Float return 1.5;

	@:arrayAccess function get(i: Int): String return 'a';

}

abstract Two(Int) from Int {

	@:arrayAccess function byInt(i: Int): Float return 1.0;

	@:arrayAccess function byName(s: String): Bool return true;

}

abstract Gen<T>(Array<T>) from Array<T> {

	@:arrayAccess function at(i: Int): Null<T> return this[i];

}

abstract NoOp(Int) from Int to Int {}

enum abstract Color(Int) {
	var Red = 1;
	var Green = 2;

	public static var Other: Int = 3;
}

class Box<T> {

	public var v: Null<T>;

	public function new(?t: T) {
		v = t;
	}

}

class Def<T = Int> {

	public function new() {}

}

class Probe {

	static function gnew<T:haxe.Constraints.Constructible<() -> Void>>(): Void {}

	static function main() {
		var a: Array<Int> = [1];
		var na: Null<Array<Int>> = [1];
		var an: Array<Null<Int>> = [1];
		var v = new Vector<Float>(2);
		var ro: ReadOnlyArray<String> = ['x'];
		var da: DynamicAccess<Int> = {};
		var u: U = 1;
		var two: Two = 1;
		var g: Gen<String> = ['s'];
		var no: NoOp = 1;
		var s = "s";
		var f = 1.5;
		var i = 1;
		var ni: Null<Int> = 1;
		var d: Dynamic = null;
		var e1 = a[0];
		var e2 = na[0];
		var e3 = an[0];
		var e4 = v[0];
		var e5 = ro[0];
		var e6 = da["k"];
		var e7 = u[0];
		var e8 = two[0];
		var e9 = two["k"];
		var e10 = g[0];
		var c1 = new Box<Int>();
		var c2 = new Box(1);
		var c3 = new Def();
		var c4 = new Def<String>();
		var c5 = new Vector<Int>(3);
		var c6 = new Map<String, Int>();
		var c7 = new haxe.ds.StringMap<Bool>();
		var c8 = new Box<Array<Int>>();
		var o1 = 1 + 2;
		var o2 = 1 + 2.5;
		var o3 = 1 / 2;
		var o4 = s + 1;
		var o5 = 1 + s;
		var o6 = s + true;
		var o7 = ni + 1;
		var o8 = -f;
		var o9 = -i;
		var o10 = u + u;
		var o11 = u * 2;
		var o12 = 2 * u;
		var o13 = no + 1;
		var o14 = d + 1;
		var o15 = i % 2;
		var o16 = f % 2;
		var o17 = -ni;
		var o18 = s + s;
		var o19 = i - f;
		for (k in 0...i) trace(k);
		for (k in 0...ni) trace(k);
		var ev = Color.Red;
		var ev2 = Color.Other;
		trace(([
			e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, c1, c2, c3, c4, c5, c6, c7, c8, o1, o2, o3, o4, o5, o6, o7, o8, o9, o10, o11, o12,
			o13, o14, o15, o16, o17, o18, o19, ev, ev2
		]: Array<Dynamic>));
	}

}
