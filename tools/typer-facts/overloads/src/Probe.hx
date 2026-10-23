typedef Opts = { a: Float, ?b: Int }
typedef Other = { a: Int, ?c: String }
typedef Dy = { d: Dynamic }

extern class Ext {

	@:overload(function(o: Other): Void {})
	public static function ovo(o: Opts): Void;
	overload public static function ol(o: Opts): Void;
	overload public static function ol(o: Other, x: Int): Void;

}

class Box {

	public function new() {}

	@:overload(function(o: Other): Void {})
	public function ovo(o: Opts): Void {}

	public function sk(?n: Int, o: Opts): Void {}

	public function sk2(?s: String, o: Opts): Void {}

	public function rest(o: Opts, ...more: Opts): Void {}

	public function dyn(o: Dy): Void {}

}

class Sub extends Box {

	override public function sk(?n: Int, o: Opts): Void {}

}

class Probe {

	static function main() {
		var box = new Box();
		box.ovo({ a: 1 });
		box.ovo({ a: 1, c: "x" });
		Ext.ovo({ a: 1 });
		Ext.ol({ a: 1 });
		box.sk({ a: 1 });
		box.sk(1, { a: 1 });
		box.sk2({ a: 1 });
		box.rest({ a: 1 }, { a: 2, b: 1 });
		var sub: Box = new Sub();
		sub.sk({ a: 2 });
		box.dyn({ d: { e: [1] } });
	}

}
