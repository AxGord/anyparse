typedef Pt = { x: Int, y: Int }
typedef A1 = { ?xs: Array<Float> }
typedef A2 = { xs: Null<Array<Float>> }
typedef A3 = { ?p: Pt }
typedef A4 = { p: Null<Pt> }
typedef A5 = { ?s: String }
typedef A6 = { ?b: Bool }
typedef A7 = { ?f: Float }
typedef A8 = { ?d: Dynamic }

class Box {

	public function new() {}

	public function a1(o: A1): Void {}

	public function a2(o: A2): Void {}

	public function a3(o: A3): Void {}

	public function a4(o: A4): Void {}

	public function a5(o: A5): Void {}

	public function a6(o: A6): Void {}

	public function a7(o: A7): Void {}

	public function a8(o: A8): Void {}

}

class Probe {

	static function main() {
		var box = new Box();
		box.a1({ xs: [1] });
		box.a2({ xs: [1] });
		box.a3({ p: { x: 1, y: 2 } });
		box.a4({ p: { x: 1, y: 2 } });
		box.a5({ s: "s" });
		box.a6({ b: true });
		box.a7({ f: 1 });
		box.a7({ f: 1.5 });
		box.a8({ d: [1] });
	}

}
