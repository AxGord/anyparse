typedef Inner = { x: Int };

typedef N = {
	id: Null<Int>,
	inner: Null<Inner>,
	arr: Null<Array<Int>>,
	?o: Int,
	s: Null<String>,
	t: String,
	?u: String
};

class Probe {

	static inline final K: String = "k";

	static function take(n: N): Void {}

	static function main() {
		var i = 1;
		var ni: Null<Int> = 2;
		var ns: Null<String> = null;
		take({
			id: i,
			inner: { x: 1 },
			arr: [1],
			o: ni,
			s: K,
			t: ns,
			u: ns
		});
		take({
			id: ni,
			inner: null,
			arr: null,
			s: "a",
			t: "b",
			u: "c"
		});
	}

}
