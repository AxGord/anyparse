class Dflt<T = String> {

	public function new() {}

	public var v: Null<T> = null;

}

class Two<A, B = Int> {

	public function new() {}

	public var a: Null<A> = null;
	public var b: Null<B> = null;

}

class Cond {

	public function new() {}
	#if js
	public var x: Int = 0;
	#else
	public var x: String = "";
	#end
	public var y: #if js Int #else Float #end = 0;

}

#if js
class Split {

	public function new() {}

	public var z: Int = 0;

}
#else
class Split {

	public function new() {}

	public var z: Bool = false;

}
#end

class Probe {

	static function main() {
		var dd = new Dflt();
		dd.v = 5;
		var tw = new Two<String>();
		var cx = new Cond().x;
		var cy = new Cond().y;
		var sz = new Split().z;
		var c = new Cond();
		var cx2 = c.x;
		trace([dd, tw, cx, cy, sz, cx2]);
	}

}
