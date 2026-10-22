class Probe {

	static function takeD(o: Dynamic): Void {}

	static function takeF(f: Float): Void {}

	static function main() {
		var c = Math.random() > 0.5;
		var x = c ? 1 : 2.5;
		var y = c ? "a" : "b";
		var z = if (c)
			1
		else
			2;
		takeD({ alpha: c ? 0.0 : 1.0, x: c ? 1 : 2 });
		takeD(c ? 1 : 2);
		takeF(c ? 1 : 2);
		var w = [c ? 1 : 2];
		trace(x, y, z, w);
	}

}
