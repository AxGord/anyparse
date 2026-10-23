abstract W(Int) from Int to Int {

	public function new(v: Int) this = v;
	#if !nothing_defined
	@:op(A * B) static function mulA(a: W, b: W): W return new W((a: Int) * (b: Int));
	#end
	@:op(A * B) static function mulB(a: W, b: Float): Float return 1.0;

}

abstract V(Array<Int>) {

	public function new() this = [];
	#if !nothing_defined
	@:arrayAccess function geta(i: Int): String return "a";
	#end
	@:arrayAccess function getb(i: Float): Bool return true;

}

abstract Px(Int) from Int to Int {}

class Probe {

	static function main() {
		var w = new W(2);
		var ww = w * w;
		var v = new V();
		var vv = v[0];
		var px: Px = 1;
		var pp = px + 1;
		trace([ww, vv, pp]);
	}

}
