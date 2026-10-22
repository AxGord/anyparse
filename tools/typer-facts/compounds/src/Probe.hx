class Probe {

	static function main() {
		var ni: Null<Int> = 1;
		var i = 1;
		var f = 1.5;
		var s = "s";
		var b = true;
		var nb: Null<Bool> = true;
		var a1 = (ni += 1);
		var a2 = (i += 1);
		var a3 = (f += 1);
		var a4 = (s += 1);
		var a5 = (i -= 1);
		var a6 = (f *= 2);
		var a7 = (i %= 2);
		var a8 = i < f;
		var a9 = ni == i;
		var a10 = s == s;
		var a11 = s < s;
		var a12 = b && nb;
		var a13 = !nb;
		var a14 = nb || b;
		var a15 = b == nb;
		var a16 = new StringBuf();
		var a17 = !b;
		trace(([a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17]: Array<Dynamic>));
	}

}
