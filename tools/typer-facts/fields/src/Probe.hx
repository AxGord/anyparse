typedef Pt = { x: Int, y: Int }
typedef WP = { p: Pt }
typedef WXs = { xs: Array<Float> }
typedef WFn = { fn: Int -> Int }
typedef WNP = { ?p: Pt }
typedef WD = { d: Dynamic }
typedef WA = { a: Any }
typedef WNF = { nf: Null<Float> }
typedef WF = { f: Float }
typedef WB = { b: Base }

class Base {

	public function new() {}

}

class SubA extends Base {

	public function new() {
		super();
	}

}

class Box {

	public function new() {}

	public function wp(o: WP): Void {}

	public function wxs(o: WXs): Void {}

	public function wfn(o: WFn): Void {}

	public function wnp(o: WNP): Void {}

	public function wd(o: WD): Void {}

	public function wa(o: WA): Void {}

	public function wnf(o: WNF): Void {}

	public function wf(o: WF): Void {}

	public function wb(o: WB): Void {}

	public function nwf(o: Null<WF>): Void {}

}

class Probe {

	static function main() {
		var box = new Box();
		var i = 1;
		var n: Null<Int> = 1;
		var nf: Null<Float> = 1;
		box.wp({ p: { x: 1, y: 2 } });
		box.wxs({ xs: [1, 2] });
		box.wxs({ xs: [1.5] });
		box.wfn({ fn: x -> x });
		box.wfn({ fn: function(a) return a + 1 });
		box.wnp({ p: { x: 1, y: 2 } });
		box.wd({ d: { q: 1 } });
		box.wd({ d: 1 });
		box.wd({ d: "s" });
		box.wa({ a: 1 });
		box.wnf({ nf: 1 });
		box.wnf({ nf: 1.5 });
		box.wnf({ nf: nf });
		box.wf({ f: 1 });
		box.wf({ f: n });
		box.wf({ f: 1 + 1 });
		box.wb({ b: new SubA() });
		box.nwf({ f: 1 });
		box.wf(({ f: 1 }));
	}

}
