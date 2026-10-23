abstract D(Float) from Float to Float {

	@:op(A + B) static inline function add(a: D, b: D): D return (a: Float) + (b: Float);

	@:op(A > B) extern static inline function gt(a: D, b: D): Bool return (a: Float) > (b: Float);

	@:op(A - B) static function sub(a: D, b: D): D return (a: Float) - (b: Float);

	@:op(A == B) static inline function eqF(a: D, b: Float): Bool return (a: Float) == b;

}

class Probe {

	static function main() {
		var x: D = 1.0;
		var y: D = 2.0;
		var r1 = x + y;
		var r2 = x > y;
		var r3 = x - y;
		var r4 = x == y;
		trace(r1 > r3, x + y, x > y, x - y, r4, x == 1.5);
	}

}
