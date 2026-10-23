class C {

	public function new() {}

}

abstract A(Int) from Int {}
abstract AS(String) from String {}

enum abstract EA(Int) {
	var X = 1;
}

enum E {
	One;
}

typedef S = { x: Int };

typedef O = {
	?c: C,
	?a: A,
	?as: AS,
	?ea: EA,
	?e: E,
	?s: S,
	?arr: Array<Int>,
	?f: Int -> Int,
	?d: Dynamic,
	?st: String,
	?i: Int,
	?m: Map<String, Int>
};

class Probe {

	static function take(o: O) {}

	static function main() {
		final c = new C();
		final a: A = 1;
		final as: AS = "x";
		final ea = EA.X;
		final e = One;
		final s: S = { x: 1 };
		final arr = [1];
		final f = (x: Int) -> x;
		final st = "s";
		final i = 1;
		final m = ["a" => 1];
		final d: Dynamic = 1;
		take(({ c: c }));
		take(({ a: a }));
		take(({ as: as }));
		take(({ ea: ea }));
		take(({ e: e }));
		take(({ s: s }));
		take(({ arr: arr }));
		take(({ f: f }));
		take(({ d: d }));
		take(({ st: st }));
		take(({ i: i }));
		take(({ m: m }));
		take(({ arr: [1] }));
		take(({ ea: X }));
	}

}
